package com.godot.game;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.util.Log;

import org.tensorflow.lite.Interpreter;

import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public class DepthEstimator {
    private static final String TAG = "DepthEstimator";
    private static final int OUTPUT_SIZE = 256;
    private static final int DA_INPUT_SIZE = 256;
    private static final String MODEL_MIDAS = "midas-midas-v2-w8a8.tflite";
    // midas-midas-v2-w8a8.tflite's actual per-tensor quantization parameters,
    // read directly from the model via ai-edge-litert's Interpreter.get_input/
    // output_details() (2026-08-18) - NOT assumed. Both the input ("image")
    // and output ("depth_estimates") tensors are UINT8, not float32:
    //   input:  scale=0.00487531116232276, zero_point=24
    //   output: scale=6.514299392700195,   zero_point=0
    // Getting either of these wrong doesn't throw - the interpreter runs
    // "successfully" and produces silently garbage output (confirmed:
    // sending raw 0..255 pixel bytes as input, and reading the output
    // ByteBuffer via asFloatBuffer() as if it were float32, both "worked"
    // with zero exceptions but produced near-black noise). The real/dequantized
    // value is (quantized - zero_point) * scale; quantizing the other
    // direction is round(real / scale) + zero_point, clamped to 0..255.
    private static final float MIDAS_INPUT_SCALE = 0.00487531116232276f;
    private static final int MIDAS_INPUT_ZERO_POINT = 24;
    private static final float MIDAS_OUTPUT_SCALE = 6.514299392700195f;
    private static final int MIDAS_OUTPUT_ZERO_POINT = 0;
    private static final String MODEL_DEPTH_ANYTHING = "depth-anything-v2-small.tflite";

    private Interpreter tfliteMidas;
    private Interpreter tfliteDepthAnything;
    private Interpreter activeInterpreter;
    private ByteBuffer inputBufferMidas;
    private ByteBuffer inputBufferDA;
    private ByteBuffer outputBufferMidas;
    private ByteBuffer outputBufferDA;
    private volatile boolean initialized = false;
    private volatile int activeModelIndex = 0;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean isInferencing = new AtomicBoolean(false);
    private final AtomicReference<byte[]> latestDepthMap = new AtomicReference<>();

    private float[] smoothedDepthFloat = null;

    private Context appContext;

    public synchronized boolean initialize(Context context) {
        if (initialized) return true;
        appContext = context.getApplicationContext();

        try {
            // midas-midas-v2-w8a8.tflite ("w8a8" = 8-bit weights AND
            // activations) takes a quantized UINT8 input tensor (raw
            // 0..255 pixel bytes, no normalization) - NOT float32. Sending
            // float32 here throws "Cannot copy to a TensorFlowLite tensor
            // (image) with 196608 bytes from a Java Buffer with 786432
            // bytes" (exactly 4x, the float32/uint8 ratio) on EVERY
            // inference call, deterministically - confirmed via full-session
            // log analysis (2026-08-18): 0 successes out of hundreds of
            // calls, regardless of what other models had run before. Caught
            // by submitFrame()'s try/catch, logged as "Async inference
            // failed" but easy to miss next to the similarly-worded per-call
            // "Inference: Xms" duration log that still prints from the
            // finally block regardless of success. Only affects this w8a8
            // model - inputBufferDA (a genuinely different, float32 model)
            // is untouched.
            inputBufferMidas = ByteBuffer.allocateDirect(1 * OUTPUT_SIZE * OUTPUT_SIZE * 3)
                    .order(ByteOrder.nativeOrder());
            // Output tensor ("depth_estimates") is ALSO quantized UINT8, not
            // float32 - see MIDAS_OUTPUT_SCALE/ZERO_POINT above. 1 byte/pixel,
            // not 4.
            outputBufferMidas = ByteBuffer.allocateDirect(1 * OUTPUT_SIZE * OUTPUT_SIZE * 1)
                    .order(ByteOrder.nativeOrder());

            inputBufferDA = ByteBuffer.allocateDirect(1 * DA_INPUT_SIZE * DA_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferDA = ByteBuffer.allocateDirect(1 * DA_INPUT_SIZE * DA_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            tfliteMidas = loadInterpreter(MODEL_MIDAS);

            try {
                tfliteDepthAnything = loadInterpreter(MODEL_DEPTH_ANYTHING);
                Log.i(TAG, "Depth Anything V2 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "Depth Anything V2 model not available", e);
                tfliteDepthAnything = null;
            }

            activeInterpreter = tfliteMidas;
            activeModelIndex = 3;
            initialized = true;
            Log.i(TAG, "Initialized successfully (MiDaS=" + (tfliteMidas != null) + ", DA=" + (tfliteDepthAnything != null) + ")");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize", e);
            return false;
        }
    }

    private Interpreter loadInterpreter(String modelFile) throws IOException {
        MappedByteBuffer buffer = loadModelFile(modelFile);
        try {
            Interpreter.Options opts = new Interpreter.Options();
            opts.setUseNNAPI(true);
            opts.setNumThreads(4);
            Interpreter interp = new Interpreter(buffer, opts);
            Log.i(TAG, modelFile + " loaded with NNAPI");
            return interp;
        } catch (Exception e) {
            Log.w(TAG, "NNAPI failed for " + modelFile + ", falling back to CPU", e);
            Interpreter.Options opts = new Interpreter.Options();
            opts.setNumThreads(4);
            return new Interpreter(buffer, opts);
        }
    }

    public void setActiveModel(int modelIndex) {
        if (!initialized) return;
        Interpreter target;
        if (modelIndex == 1 && tfliteDepthAnything != null) {
            target = tfliteDepthAnything;
        } else {
            // MiDaS-Std and MiDaS-Fast (see settings_controller.gd) share this
            // one interpreter - the separate "crude warp" MiDaS instance that
            // used to live at index 0 is gone, so fold any other/unrecognized
            // index into this one too rather than requiring index 3 exactly.
            target = tfliteMidas;
            modelIndex = 3;
        }
        if (activeModelIndex != modelIndex) {
            while (isInferencing.get()) {
                Thread.yield();
            }
            smoothedDepthFloat = null;
            rangeValid = false;
            activeInterpreter = target;
            activeModelIndex = modelIndex;
            String modelName = (modelIndex == 1) ? "Depth Anything V2" : "MiDaS";
            Log.i(TAG, "Switched to model " + modelName);
        }
    }

    public int getActiveModel() {
        return activeModelIndex;
    }

    public void submitFrame(byte[] rgbaPixels, int width, int height) {
        if (!initialized || activeInterpreter == null) return;
        if (rgbaPixels == null || rgbaPixels.length < width * height * 4) return;
        if (!isInferencing.compareAndSet(false, true)) return;

        final byte[] frameCopy = rgbaPixels.clone();
        final int modelIdx = activeModelIndex;
        executor.submit(() -> {
            long startTime = System.nanoTime();
            try {
                byte[] result;
                if (modelIdx == 1) {
                    result = runInferenceDA(frameCopy, width, height);
                } else {
                    result = runInferenceMidas(frameCopy, width, height);
                }
                if (result != null) {
                    latestDepthMap.set(result);
                }
            } catch (Exception e) {
                Log.e(TAG, "Async inference failed", e);
            } finally {
                isInferencing.set(false);
                long duration = (System.nanoTime() - startTime) / 1_000_000;
                String modelName = (modelIdx == 1) ? "DA" : "MiDaS";
                Log.d(TAG, "Inference: " + duration + "ms (" + modelName + ")");
            }
        });
    }

    public byte[] getLatestDepth() {
        return latestDepthMap.getAndSet(null);
    }

    // real (0..1 normalized pixel) -> quantized uint8, per MIDAS_INPUT_SCALE/
    // ZERO_POINT above.
    private static byte quantizeMidasInput(int rawPixelByte) {
        float real = (rawPixelByte & 0xFF) / 255.0f;
        int q = Math.round(real / MIDAS_INPUT_SCALE) + MIDAS_INPUT_ZERO_POINT;
        q = Math.max(0, Math.min(255, q));
        return (byte) q;
    }

    private byte[] runInferenceDA(byte[] rgbaPixels, int width, int height) {
        inputBufferDA.rewind();
        outputBufferDA.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / DA_INPUT_SIZE;
        float scaleY = (float) height / DA_INPUT_SIZE;

        for (int y = 0; y < DA_INPUT_SIZE; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < DA_INPUT_SIZE; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBufferDA.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBufferDA.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBufferDA.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBufferDA.rewind();

        tfliteDepthAnything.run(inputBufferDA, outputBufferDA);
        outputBufferDA.rewind();

        return postProcess(extractFloatOutput(outputBufferDA, DA_INPUT_SIZE * DA_INPUT_SIZE), DA_INPUT_SIZE, true);
    }

    // No dilate/blur here - the warp shader does its own edge-aware joint
    // bilateral upsample against the actual color frame
    // (depth_upsample.gdshader), which snaps depth to real edges instead of
    // averaging small objects (taskbar icons, widgets) away like a CPU blur
    // would.
    private byte[] runInferenceMidas(byte[] rgbaPixels, int width, int height) {
        inputBufferMidas.rewind();
        outputBufferMidas.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / OUTPUT_SIZE;
        float scaleY = (float) height / OUTPUT_SIZE;

        for (int y = 0; y < OUTPUT_SIZE; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < OUTPUT_SIZE; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBufferMidas.put(quantizeMidasInput(rgbaPixels[srcIdx]));
                inputBufferMidas.put(quantizeMidasInput(rgbaPixels[srcIdx + 1]));
                inputBufferMidas.put(quantizeMidasInput(rgbaPixels[srcIdx + 2]));
            }
        }
        inputBufferMidas.rewind();

        tfliteMidas.run(inputBufferMidas, outputBufferMidas);
        outputBufferMidas.rewind();

        return postProcess(dequantizeMidasOutput(outputBufferMidas, OUTPUT_SIZE * OUTPUT_SIZE), OUTPUT_SIZE, false);
    }

    // dequantize (quantized - zero_point) * scale, per MIDAS_OUTPUT_SCALE/
    // ZERO_POINT above.
    private static float[] dequantizeMidasOutput(ByteBuffer output, int count) {
        output.rewind();
        float[] raw = new float[count];
        for (int i = 0; i < count; i++) {
            int q = output.get(i) & 0xFF;
            raw[i] = (q - MIDAS_OUTPUT_ZERO_POINT) * MIDAS_OUTPUT_SCALE;
        }
        return raw;
    }

    // Plain float32 output tensor extraction, for models that genuinely are
    // float32 (runInferenceDA) - not quantized like the w8a8 MiDaS model.
    private static float[] extractFloatOutput(ByteBuffer output, int count) {
        output.rewind();
        FloatBuffer floatOut = output.asFloatBuffer();
        float[] raw = new float[count];
        for (int i = 0; i < count; i++) {
            raw[i] = floatOut.get(i);
        }
        return raw;
    }

    // Ported from Gilleece/moonlight-android-xr's xr_renderer.c
    // nativeUploadDepth()/robustRange(): literal per-frame min/max lets a
    // single stray pixel own the whole mapping - on one of their measured
    // frames the 2nd..98th percentile span was only 638 of an 805-wide
    // min/max range, meaning a fifth of the usable 0..1 depth range was
    // being spent on a handful of outlier pixels instead of the actual
    // scene. Our old code did exactly that (literal min/max), and did it
    // TWICE (once on the raw model output, again on the already-smoothed
    // result), compounding the loss - this was very likely the dominant
    // cause of the depth effect measuring "shallow" even after the warp
    // itself got fixed, more so than the parallax constant.
    private static final int HIST_BINS = 512;
    // How fast the normalization RANGE itself (smoothLo/smoothHi) and the
    // final per-texel depth values (in temporalSmooth) track new inferences.
    // Matches their own tuned defaults (rangeAlpha/depthAlpha) - range moves
    // slowly so the mapping doesn't jump when the scene changes, texels
    // move faster since they're already normalized into a stable band by
    // that point.
    private static final float RANGE_ALPHA = 0.15f;
    private static final float DEPTH_ALPHA = 0.60f;
    private float smoothLo = 0.0f;
    private float smoothHi = 1.0f;
    private boolean rangeValid = false;

    // Takes the already-decoded real-valued depth array, not a raw
    // ByteBuffer - the float32 output tensor (runInferenceDA) and the
    // quantized UINT8 one (runInferenceMidas) decode completely differently
    // at the source (see each call site), and this logic downstream is
    // identical either way once it's a plain float[].
    private byte[] postProcess(float[] raw, int size, boolean dilateAndBlur) {
        int count = size * size;

        float[] loHi = robustRange(raw, count);
        if (!rangeValid) {
            smoothLo = loHi[0];
            smoothHi = loHi[1];
            rangeValid = true;
        } else {
            smoothLo += RANGE_ALPHA * (loHi[0] - smoothLo);
            smoothHi += RANGE_ALPHA * (loHi[1] - smoothHi);
        }
        float scale = 1.0f / Math.max(smoothHi - smoothLo, 1e-6f);

        float[] normalized = new float[count];
        for (int i = 0; i < count; i++) {
            float v = (raw[i] - smoothLo) * scale;
            normalized[i] = Math.max(0.0f, Math.min(1.0f, v));
        }

        float[] preSmooth = normalized;
        if (dilateAndBlur) {
            float[] dilated = dilate(normalized, size, 6);
            preSmooth = separableBoxBlur(dilated, size, 14);
        }
        float[] smoothed = temporalSmooth(preSmooth, size);

        byte[] depthBytes = new byte[count];
        for (int i = 0; i < count; i++) {
            float v = Math.max(0.0f, Math.min(1.0f, smoothed[i]));
            depthBytes[i] = (byte) (v * 255.0f);
        }
        return depthBytes;
    }

    // 2nd and 98th percentile of the model output, via a histogram - see the
    // postProcess() comment above for why this replaces literal min/max.
    private float[] robustRange(float[] v, int count) {
        float lo = v[0], hi = v[0];
        for (int i = 1; i < count; i++) {
            if (v[i] < lo) lo = v[i];
            if (v[i] > hi) hi = v[i];
        }
        if (hi <= lo) {
            return new float[]{lo, lo + 1.0f};
        }

        int[] hist = new int[HIST_BINS];
        float binScale = HIST_BINS / (hi - lo);
        for (int i = 0; i < count; i++) {
            int b = (int) ((v[i] - lo) * binScale);
            if (b < 0) b = 0;
            if (b >= HIST_BINS) b = HIST_BINS - 1;
            hist[b]++;
        }

        int loTarget = (int) (count * 0.02f);
        int hiTarget = (int) (count * 0.98f);
        int acc = 0;
        int loBin = 0, hiBin = HIST_BINS - 1;
        for (int b = 0; b < HIST_BINS; b++) {
            acc += hist[b];
            if (acc >= loTarget) {
                loBin = b;
                break;
            }
        }
        acc = 0;
        for (int b = 0; b < HIST_BINS; b++) {
            acc += hist[b];
            if (acc >= hiTarget) {
                hiBin = b;
                break;
            }
        }

        float binWidth = (hi - lo) / HIST_BINS;
        float robustLo = lo + loBin * binWidth;
        float robustHi = lo + (hiBin + 1) * binWidth;
        if (robustHi <= robustLo) {
            robustHi = robustLo + 1e-3f;
        }
        return new float[]{robustLo, robustHi};
    }

    private float[] dilate(float[] depth, int size, int radius) {
        float[] horizontal = new float[depth.length];
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                float maxVal = 0.0f;
                for (int dx = -radius; dx <= radius; dx++) {
                    int nx = Math.min(Math.max(x + dx, 0), size - 1);
                    float v = depth[y * size + nx];
                    if (v > maxVal) maxVal = v;
                }
                horizontal[y * size + x] = maxVal;
            }
        }
        float[] result = new float[depth.length];
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                float maxVal = 0.0f;
                for (int dy = -radius; dy <= radius; dy++) {
                    int ny = Math.min(Math.max(y + dy, 0), size - 1);
                    float v = horizontal[ny * size + x];
                    if (v > maxVal) maxVal = v;
                }
                result[y * size + x] = maxVal;
            }
        }
        return result;
    }

    private float[] separableBoxBlur(float[] depth, int size, int radius) {
        float[] horizontal = new float[depth.length];
        int diam = radius * 2 + 1;
        for (int y = 0; y < size; y++) {
            float sum = 0.0f;
            for (int x = -radius; x <= radius; x++) {
                int nx = Math.min(Math.max(x, 0), size - 1);
                sum += depth[y * size + nx];
            }
            horizontal[y * size + 0] = sum / diam;
            for (int x = 1; x < size; x++) {
                int addX = Math.min(x + radius, size - 1);
                int remX = Math.max(x - radius - 1, 0);
                sum += depth[y * size + addX] - depth[y * size + remX];
                horizontal[y * size + x] = sum / diam;
            }
        }
        float[] result = new float[depth.length];
        for (int x = 0; x < size; x++) {
            float sum = 0.0f;
            for (int y = -radius; y <= radius; y++) {
                int ny = Math.min(Math.max(y, 0), size - 1);
                sum += horizontal[ny * size + x];
            }
            result[0 * size + x] = sum / diam;
            for (int y = 1; y < size; y++) {
                int addY = Math.min(y + radius, size - 1);
                int remY = Math.max(y - radius - 1, 0);
                sum += horizontal[addY * size + x] - horizontal[remY * size + x];
                result[y * size + x] = sum / diam;
            }
        }
        return result;
    }

    // Fixed-rate per-texel EMA, matching their depthAlpha - values entering
    // here are already normalized into a stable [0,1] band by postProcess()'s
    // robust+smoothed range, so a simple fixed blend is enough. The previous
    // version instead measured how much the WHOLE frame changed and picked
    // a smoothing amount from that, which could hit exactly zero on a fully
    // static desktop (the common case) and permanently freeze the entire
    // depth map at whatever one inference produced - small/ambiguous static
    // elements (a clock widget, a subtly-3D background) that happened to
    // get a weak first estimate stayed weak forever. A fixed rate never
    // freezes, so it keeps denoising even when nothing on screen is moving.
    private float[] temporalSmooth(float[] newDepth, int size) {
        int len = size * size;
        if (smoothedDepthFloat == null) {
            smoothedDepthFloat = newDepth.clone();
            return newDepth;
        }

        float[] result = new float[len];
        for (int i = 0; i < len; i++) {
            float prev = smoothedDepthFloat[i];
            float curr = newDepth[i];
            result[i] = prev + DEPTH_ALPHA * (curr - prev);
        }
        smoothedDepthFloat = result;

        return result;
    }

    public synchronized void close() {
        if (tfliteMidas != null) {
            tfliteMidas.close();
            tfliteMidas = null;
        }
        if (tfliteDepthAnything != null) {
            tfliteDepthAnything.close();
            tfliteDepthAnything = null;
        }
        activeInterpreter = null;
        initialized = false;
        executor.shutdownNow();
    }

    public int getModelSize() {
        return OUTPUT_SIZE;
    }

    public boolean isInitialized() {
        return initialized;
    }

    private MappedByteBuffer loadModelFile(String filename) throws IOException {
        AssetFileDescriptor fd = appContext.getAssets().openFd(filename);
        FileInputStream is = new FileInputStream(fd.getFileDescriptor());
        FileChannel ch = is.getChannel();
        long offset = fd.getStartOffset();
        long length = fd.getDeclaredLength();
        return ch.map(FileChannel.MapMode.READ_ONLY, offset, length);
    }
}
