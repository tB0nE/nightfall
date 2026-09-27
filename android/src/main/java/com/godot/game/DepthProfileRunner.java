package com.godot.game;

import android.content.Context;

import com.godot.game.diagnostics.Log;

import org.tensorflow.lite.Interpreter;
import org.tensorflow.lite.gpu.GpuDelegate;
import org.tensorflow.lite.gpu.GpuDelegateFactory;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.util.Arrays;
import java.util.Locale;

/** Opt-in ADB-triggered LiteRT OpenCL profiler; never runs in normal launches. */
final class DepthProfileRunner {
    private static final String TAG = "DepthStageProfile";
    private static final int WARMUP = 10;
    private static final int ITERATIONS = 50;

    private static final String[][] MODELS = {
            {"f1", "FPN-f1", "zipdepth-base-384-profile-f1-gpu.tflite"},
            {"f_half", "Half-fusion", "zipdepth-base-384-profile-f-half-gpu.tflite"},
            {"direct", "Direct-192", "zipdepth-base-384-direct-half-gpu.tflite"},
            {"mask", "Mask-logits", "zipdepth-base-384-profile-mask-gpu.tflite"},
            {"softmax", "Mask-softmax", "zipdepth-base-384-profile-softmax-gpu.tflite"},
            {"weighted", "Weighted", "zipdepth-base-384-profile-weighted-gpu.tflite"},
            {"standard", "Standard-v1", "zipdepth-base-384-standard-v1-gpu.tflite"},
            {"softmax4", "Standard-Softmax4", "zipdepth-base-384-standard-packed-softmax4-gpu.tflite"},
            {"conv4", "Standard-Conv4", "zipdepth-base-384-standard-packed-conv4-gpu.tflite"},
            {"conv4_reduceconv", "Standard-Conv4-ReduceConv", "zipdepth-base-384-standard-packed-conv4-reduceconv-gpu.tflite"},
            {"conv4_zeropad", "Standard-Conv4-ZeroPad", "zipdepth-base-384-standard-packed-conv4-reduceconv-zeropad-gpu.tflite"},
            {"conv4_edgepad", "Standard-Conv4-EdgePad", "zipdepth-base-384-standard-packed-conv4-reduceconv-edgepad-gpu.tflite"},
    };

    private DepthProfileRunner() {}

    static boolean isKnownStage(String stage) {
        return findModel(stage) != null;
    }

    static void start(Context context, String stage) {
        Context appContext = context.getApplicationContext();
        Thread worker = new Thread(() -> run(appContext, stage), "DepthStageProfile");
        worker.setDaemon(true);
        worker.start();
    }

    private static void run(Context context, String stage) {
        try {
            // Let OpenXR/Godot finish startup so delegate compilation does not
            // race one-time application initialization differently per model.
            Thread.sleep(3000L);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return;
        }

        String[] model = findModel(stage);
        if (model == null) {
            persist(context, stage, "PROFILE_ERROR unknown_stage=" + stage);
            return;
        }
        String begin = String.format(Locale.US,
                "PROFILE_BEGIN stage=%s label=%s backend=OpenCL warmup=%d iterations=%d",
                stage, model[1], WARMUP, ITERATIONS);
        Log.i(TAG, begin);
        clearPersistedResult(context, stage);
        persist(context, stage, begin);
        benchmarkOne(context, stage, model[1], model[2]);
    }

    private static void benchmarkOne(
            Context context, String stage, String label, String assetFile) {
        GpuDelegate delegate = null;
        Interpreter interpreter = null;
        try {
            long initializationStart = System.nanoTime();
            MappedByteBuffer model = mapAsset(context, assetFile);
            GpuDelegateFactory.Options gpuOptions = new GpuDelegateFactory.Options();
            gpuOptions.setPrecisionLossAllowed(true);
            gpuOptions.setInferencePreference(
                    GpuDelegateFactory.Options.INFERENCE_PREFERENCE_SUSTAINED_SPEED);
            gpuOptions.setForceBackend(GpuDelegateFactory.Options.GpuBackend.OPENCL);
            delegate = new GpuDelegate(gpuOptions);
            Interpreter.Options interpreterOptions = new Interpreter.Options();
            interpreterOptions.addDelegate(delegate);
            interpreter = new Interpreter(model, interpreterOptions);

            int inputBytes = interpreter.getInputTensor(0).numBytes();
            int outputBytes = interpreter.getOutputTensor(0).numBytes();
            ByteBuffer input = ByteBuffer.allocateDirect(inputBytes)
                    .order(ByteOrder.nativeOrder());
            ByteBuffer output = ByteBuffer.allocateDirect(outputBytes)
                    .order(ByteOrder.nativeOrder());
            fillDeterministicInput(input);

            double initializationMs = (System.nanoTime() - initializationStart) / 1_000_000.0;
            for (int iteration = 0; iteration < WARMUP; iteration++) {
                input.rewind();
                output.rewind();
                interpreter.run(input, output);
            }

            double[] samples = new double[ITERATIONS];
            for (int iteration = 0; iteration < ITERATIONS; iteration++) {
                input.rewind();
                output.rewind();
                long start = System.nanoTime();
                interpreter.run(input, output);
                samples[iteration] = (System.nanoTime() - start) / 1_000_000.0;
            }
            Arrays.sort(samples);
            double total = 0.0;
            for (double sample : samples) total += sample;
            double median = percentile(samples, 0.50);
            double p90 = percentile(samples, 0.90);
            double p99 = percentile(samples, 0.99);
            String result = String.format(Locale.US,
                    "PROFILE_RESULT label=%s asset=%s input=%s output=%s init_ms=%.3f "
                            + "median_ms=%.3f mean_ms=%.3f p90_ms=%.3f p99_ms=%.3f",
                    label, assetFile,
                    Arrays.toString(interpreter.getInputTensor(0).shape()),
                    Arrays.toString(interpreter.getOutputTensor(0).shape()),
                    initializationMs, median, total / samples.length, p90, p99);
            Log.i(TAG, result);
            persist(context, stage, result);
        } catch (Throwable error) {
            Log.e(TAG, "PROFILE_ERROR label=" + label + " asset=" + assetFile, error);
            persist(context, stage, "PROFILE_ERROR label=" + label + " asset=" + assetFile
                    + " error=" + error);
        } finally {
            if (interpreter != null) interpreter.close();
            if (delegate != null) delegate.close();
        }
    }

    private static String[] findModel(String stage) {
        if (stage == null) return null;
        for (String[] model : MODELS) {
            if (model[0].equals(stage)) return model;
        }
        return null;
    }

    private static void persist(Context context, String stage, String line) {
        java.io.File directory = context.getExternalFilesDir(null);
        if (directory == null) return;
        java.io.File output = new java.io.File(directory, "depth-profile-" + stage + ".txt");
        try (FileOutputStream stream = new FileOutputStream(output, true);
             Writer writer = new OutputStreamWriter(stream, java.nio.charset.StandardCharsets.UTF_8)) {
            writer.write(line);
            writer.write('\n');
            writer.flush();
            stream.getFD().sync();
        } catch (Throwable error) {
            Log.e(TAG, "Could not persist profile result for stage=" + stage, error);
        }
    }

    private static void clearPersistedResult(Context context, String stage) {
        java.io.File directory = context.getExternalFilesDir(null);
        if (directory == null) return;
        java.io.File output = new java.io.File(directory, "depth-profile-" + stage + ".txt");
        if (output.exists() && !output.delete()) {
            Log.i(TAG, "Could not clear prior profile result for stage=" + stage);
        }
    }

    private static double percentile(double[] sorted, double fraction) {
        int index = (int) Math.round((sorted.length - 1) * fraction);
        return sorted[Math.max(0, Math.min(index, sorted.length - 1))];
    }

    private static void fillDeterministicInput(ByteBuffer input) {
        int floatCount = input.capacity() / Float.BYTES;
        for (int index = 0; index < floatCount; index++) {
            // Repeatable 0..1 RGB-like signal without allocating a float[].
            input.putFloat((index % 1021) / 1020.0f);
        }
        input.rewind();
    }

    private static MappedByteBuffer mapAsset(Context context, String filename) throws Exception {
        try (android.content.res.AssetFileDescriptor descriptor =
                     context.getAssets().openFd(filename);
             FileInputStream stream = new FileInputStream(descriptor.getFileDescriptor())) {
            return stream.getChannel().map(
                    FileChannel.MapMode.READ_ONLY,
                    descriptor.getStartOffset(), descriptor.getDeclaredLength());
        }
    }
}
