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

    private byte[] previousDepthBytes = null;
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

            tfliteMidas = loadInterpreter(MODEL_MIDAS);

            try {
                tfliteDepthAnything = loadInterpreter(MODEL_DEPTH_ANYTHING);
                Log.i(TAG, "Depth Anything V2 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "Depth Anything V2 model not available", e);
                tfliteDepthAnything = null;
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

    public void setActiveModel(int modelIndex) {
        if (!initialized) return;
        Interpreter target;
        if (modelIndex == 1 && tfliteDepthAnything != null) {
            target = tfliteDepthAnything;
        } else {
            target = tfliteMidas;
            modelIndex = 0;
        }
        if (activeModelIndex != modelIndex) {
            while (isInferencing.get()) {
                Thread.yield();
            }
            previousDepthBytes = null;
            smoothedDepthFloat = null;
            activeInterpreter = target;
            activeModelIndex = modelIndex;
            Log.i(TAG, "Switched to model " + (modelIndex == 0 ? "MiDaS" : "Depth Anything V2"));
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
                Log.d(TAG, "Inference: " + duration + "ms (" + (modelIdx == 1 ? "DA" : "MiDaS") + ")");
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

        return postProcess(outputBufferMidas, OUTPUT_SIZE);
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

        return postProcess(outputBufferDA, DA_INPUT_SIZE);
    }

    // Literal per-frame min/max (the previous version here) lets a single stray
    // pixel own the whole mapping - on one measured frame the 2nd..98th
    // percentile span was only 638 of an 805-wide min/max range, meaning a
    // fifth of the usable 0..1 depth range was being spent on a handful of
    // outlier pixels instead of the actual scene. Replaced with a
    // histogram-based robust range (2nd/98th percentile), temporally smoothed
    // so the range itself doesn't jitter frame to frame.
    private byte[] postProcess(ByteBuffer output, int size) {
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

        float[] dilated = dilate(normalized, size, 6);
        float[] blurred = separableBoxBlur(dilated, size, 14);
        float[] smoothed = temporalSmooth(blurred, size);

        byte[] depthBytes = new byte[count];
        for (int i = 0; i < count; i++) {
            float v = Math.max(0.0f, Math.min(1.0f, smoothed[i]));
            depthBytes[i] = (byte) (v * 255.0f);
        }
        return depthBytes;
    }

    // 2nd and 98th percentile of the model output, via a histogram.
    private static final int HIST_BINS = 256;
    private float smoothLo = 0.0f;
    private float smoothHi = 1.0f;
    private boolean rangeValid = false;
    private static final float RANGE_ALPHA = 0.15f;

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

    private float[] temporalSmooth(float[] newDepth, int size) {
        int len = size * size;
        if (smoothedDepthFloat == null) {
            smoothedDepthFloat = newDepth.clone();
            previousDepthBytes = new byte[len];
            for (int i = 0; i < len; i++) {
                previousDepthBytes[i] = (byte) (newDepth[i] * 255.0f);
            }
            return newDepth;
        }

        double totalDiff = 0.0;
        double totalSqDiff = 0.0;
        for (int i = 0; i < len; i++) {
            float oldVal = (previousDepthBytes[i] & 0xFF) / 255.0f;
            float diff = newDepth[i] - oldVal;
            totalDiff += Math.abs(diff);
            totalSqDiff += diff * diff;
        }
        double meanDiff = totalDiff / len;
        double stdDev = Math.sqrt(totalSqDiff / len - meanDiff * meanDiff);
        double depthDiff = Math.max(meanDiff, stdDev);

        float smoothing;
        if (depthDiff > 0.1) {
            smoothing = 1.0f;
        } else if (depthDiff > 0.01) {
            smoothing = (float) (depthDiff * 2.0);
            smoothing = Math.min(smoothing, 1.0f);
        } else {
            smoothing = 0.0f;
        }

        float[] result = new float[len];
        for (int i = 0; i < len; i++) {
            float prev = smoothedDepthFloat[i];
            float curr = newDepth[i];
            result[i] = prev * (1.0f - smoothing) + curr * smoothing;
        }

        for (int i = 0; i < len; i++) {
            previousDepthBytes[i] = (byte) (newDepth[i] * 255.0f);
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
