package com.godot.game;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.util.Log;

import org.tensorflow.lite.Interpreter;
import org.tensorflow.lite.gpu.CompatibilityList;
import org.tensorflow.lite.gpu.GpuDelegate;
import org.tensorflow.lite.gpu.GpuDelegateFactory;

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
    private static final int GPU_INPUT_SIZE = 256;
    private static final int HQ_INPUT_SIZE = 256;
    private static final String MODEL_MIDAS = "midas-midas-v2-w8a8.tflite";
    private static final String MODEL_DEPTH_ANYTHING = "depth-anything-v2-small.tflite";
    // MiDaS v2.1 small, fp16, vendored from Gilleece/moonlight-android-xr's own
    // conversion (tools/convert_midas.py there) of the MIT-licensed MIDAS_ISL
    // ONNX export, for a same-model/same-delegate A/B comparison against our
    // existing w8a8 CPU/NNAPI path. Comparison-only: this exact binary hasn't
    // been re-derived from source here, so don't ship it without revisiting
    // provenance/licensing.
    private static final String MODEL_MIDAS_GPU = "midas_v21_small_256_fp16.tflite";

    private Interpreter tfliteMidas;
    private Interpreter tfliteDepthAnything;
    private Interpreter tfliteMidasGpu;
    private GpuDelegate gpuDelegateMidasGpu;
    private boolean midasGpuAccelerated;
    // Same underlying weights as tfliteMidas (MODEL_MIDAS), loaded as a genuinely
    // separate Interpreter instance via NNAPI - lets model index 3 ("MiDaS-NNAPI")
    // feed the new occlusion-aware warp pipeline without the GPU delegate's GLES
    // context fighting Godot's own Vulkan renderer for the GPU (see runInferenceMidasHq()).
    // Two instances from the same file share the OS page cache for the read-only
    // weight bytes, so this isn't a second full copy of the model.
    private Interpreter tfliteMidasHq;
    private Interpreter activeInterpreter;
    private ByteBuffer inputBufferMidas;
    private ByteBuffer inputBufferDA;
    private ByteBuffer inputBufferGpu;
    private ByteBuffer inputBufferHq;
    private ByteBuffer outputBufferMidas;
    private ByteBuffer outputBufferDA;
    private ByteBuffer outputBufferGpu;
    private ByteBuffer outputBufferHq;
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
            inputBufferMidas = ByteBuffer.allocateDirect(1 * OUTPUT_SIZE * OUTPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferMidas = ByteBuffer.allocateDirect(1 * OUTPUT_SIZE * OUTPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            inputBufferDA = ByteBuffer.allocateDirect(1 * DA_INPUT_SIZE * DA_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferDA = ByteBuffer.allocateDirect(1 * DA_INPUT_SIZE * DA_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            inputBufferGpu = ByteBuffer.allocateDirect(1 * GPU_INPUT_SIZE * GPU_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferGpu = ByteBuffer.allocateDirect(1 * GPU_INPUT_SIZE * GPU_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            inputBufferHq = ByteBuffer.allocateDirect(1 * HQ_INPUT_SIZE * HQ_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferHq = ByteBuffer.allocateDirect(1 * HQ_INPUT_SIZE * HQ_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            tfliteMidas = loadInterpreter(MODEL_MIDAS);

            try {
                tfliteDepthAnything = loadInterpreter(MODEL_DEPTH_ANYTHING);
                Log.i(TAG, "Depth Anything V2 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "Depth Anything V2 model not available", e);
                tfliteDepthAnything = null;
            }

            try {
                tfliteMidasGpu = loadMidasGpuInterpreter();
                Log.i(TAG, "MiDaS v2.1-small GPU model loaded, accelerated=" + midasGpuAccelerated);
            } catch (Exception e) {
                Log.w(TAG, "MiDaS v2.1-small GPU model not available", e);
                tfliteMidasGpu = null;
            }

            try {
                // Same weights as MODEL_MIDAS (mode 0), separate instance, via the
                // proven NNAPI-with-CPU-fallback path - feeds the new warp pipeline
                // (stereo_mode 6) without the GPU delegate's GLES/Vulkan contention.
                tfliteMidasHq = loadInterpreter(MODEL_MIDAS);
                Log.i(TAG, "MiDaS-NNAPI (HQ) model loaded");
            } catch (Exception e) {
                Log.w(TAG, "MiDaS-NNAPI (HQ) model not available", e);
                tfliteMidasHq = null;
            }

            activeInterpreter = tfliteMidas;
            activeModelIndex = 0;
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

    // Mirrors Gilleece/moonlight-android-xr's MidasDepthSource.initialize(): GPU
    // delegate with fp16 precision loss allowed and sustained-speed preference,
    // falling back to CPU only if delegate creation/model load fails. Unlike
    // our other models this deliberately skips NNAPI - their comparison point
    // is the GPU delegate specifically.
    private Interpreter loadMidasGpuInterpreter() throws IOException {
        MappedByteBuffer buffer = loadModelFile(MODEL_MIDAS_GPU);

        CompatibilityList compatibility = new CompatibilityList();
        Log.i(TAG, "MiDaS GPU: allowlist says " + compatibility.isDelegateSupportedOnThisDevice()
                + ", trying the delegate anyway");

        Interpreter.Options options = new Interpreter.Options();
        try {
            GpuDelegateFactory.Options gpuOptions = new GpuDelegateFactory.Options();
            gpuOptions.setPrecisionLossAllowed(true);
            gpuOptions.setInferencePreference(
                    GpuDelegateFactory.Options.INFERENCE_PREFERENCE_SUSTAINED_SPEED);
            gpuDelegateMidasGpu = new GpuDelegate(gpuOptions);
            options.addDelegate(gpuDelegateMidasGpu);
            midasGpuAccelerated = true;
        } catch (Exception e) {
            Log.w(TAG, "MiDaS GPU delegate creation failed, using CPU: " + e.getMessage());
        }
        if (!midasGpuAccelerated) {
            options.setNumThreads(2);
        }

        try {
            return new Interpreter(buffer, options);
        } catch (Exception e) {
            Log.w(TAG, "MiDaS GPU model failed to load with the GPU delegate: " + e.getMessage());
            if (gpuDelegateMidasGpu != null) {
                gpuDelegateMidasGpu.close();
                gpuDelegateMidasGpu = null;
            }
            midasGpuAccelerated = false;
            Interpreter.Options cpuOptions = new Interpreter.Options();
            cpuOptions.setNumThreads(2);
            return new Interpreter(buffer, cpuOptions);
        }
    }

    public void setActiveModel(int modelIndex) {
        if (!initialized) return;
        Interpreter target;
        if (modelIndex == 1 && tfliteDepthAnything != null) {
            target = tfliteDepthAnything;
        } else if (modelIndex == 2 && tfliteMidasGpu != null) {
            target = tfliteMidasGpu;
        } else if (modelIndex == 3 && tfliteMidasHq != null) {
            target = tfliteMidasHq;
        } else {
            target = tfliteMidas;
            modelIndex = 0;
        }
        if (activeModelIndex != modelIndex) {
            while (isInferencing.get()) {
                Thread.yield();
            }
            smoothedDepthFloat = null;
            rangeValid = false;
            activeInterpreter = target;
            activeModelIndex = modelIndex;
            String modelName;
            switch (modelIndex) {
                case 1: modelName = "Depth Anything V2"; break;
                case 2: modelName = "MiDaS-GPU"; break;
                case 3: modelName = "MiDaS-NNAPI"; break;
                default: modelName = "MiDaS"; break;
            }
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
                } else if (modelIdx == 2) {
                    result = runInferenceMidasGpu(frameCopy, width, height);
                } else if (modelIdx == 3) {
                    result = runInferenceMidasHq(frameCopy, width, height);
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
                String modelName;
                switch (modelIdx) {
                    case 1: modelName = "DA"; break;
                    case 2: modelName = "MiDaS-GPU"; break;
                    case 3: modelName = "MiDaS-HQ"; break;
                    default: modelName = "MiDaS"; break;
                }
                Log.d(TAG, "Inference: " + duration + "ms (" + modelName + ")");
            }
        });
    }

    public byte[] getLatestDepth() {
        return latestDepthMap.getAndSet(null);
    }

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
                inputBufferMidas.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBufferMidas.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBufferMidas.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBufferMidas.rewind();

        tfliteMidas.run(inputBufferMidas, outputBufferMidas);
        outputBufferMidas.rewind();

        return postProcess(outputBufferMidas, OUTPUT_SIZE, true);
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

        return postProcess(outputBufferDA, DA_INPUT_SIZE, true);
    }

    private byte[] runInferenceMidasGpu(byte[] rgbaPixels, int width, int height) {
        inputBufferGpu.rewind();
        outputBufferGpu.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / GPU_INPUT_SIZE;
        float scaleY = (float) height / GPU_INPUT_SIZE;

        for (int y = 0; y < GPU_INPUT_SIZE; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < GPU_INPUT_SIZE; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBufferGpu.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBufferGpu.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBufferGpu.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBufferGpu.rewind();

        tfliteMidasGpu.run(inputBufferGpu, outputBufferGpu);
        outputBufferGpu.rewind();

        // No dilate/blur here - the warp shader does its own edge-aware joint
        // bilateral upsample against the actual color frame (stereo_screen.gdshader,
        // stereo_mode 5), which snaps depth to real edges instead of averaging
        // small objects (taskbar icons, widgets) away like the CPU blur below does.
        return postProcess(outputBufferGpu, GPU_INPUT_SIZE, false);
    }

    // Same model weights as runInferenceMidas() (mode 0), but via the separate
    // tfliteMidasHq NNAPI instance, feeding stereo_mode 6's warp pipeline. No
    // dilate/blur here either, for the same reason as runInferenceMidasGpu() above -
    // this is model-independent, not specific to which delegate produced the depth.
    private byte[] runInferenceMidasHq(byte[] rgbaPixels, int width, int height) {
        inputBufferHq.rewind();
        outputBufferHq.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / HQ_INPUT_SIZE;
        float scaleY = (float) height / HQ_INPUT_SIZE;

        for (int y = 0; y < HQ_INPUT_SIZE; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < HQ_INPUT_SIZE; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBufferHq.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBufferHq.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBufferHq.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBufferHq.rewind();

        tfliteMidasHq.run(inputBufferHq, outputBufferHq);
        outputBufferHq.rewind();

        return postProcess(outputBufferHq, HQ_INPUT_SIZE, false);
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

    private byte[] postProcess(ByteBuffer output, int size, boolean dilateAndBlur) {
        output.rewind();
        FloatBuffer floatOut = output.asFloatBuffer();
        int count = size * size;
        float[] raw = new float[count];
        for (int i = 0; i < count; i++) {
            raw[i] = floatOut.get(i);
        }

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
        if (tfliteMidasGpu != null) {
            tfliteMidasGpu.close();
            tfliteMidasGpu = null;
        }
        if (gpuDelegateMidasGpu != null) {
            gpuDelegateMidasGpu.close();
            gpuDelegateMidasGpu = null;
        }
        if (tfliteMidasHq != null) {
            tfliteMidasHq.close();
            tfliteMidasHq = null;
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
