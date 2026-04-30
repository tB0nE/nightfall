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
    private static final int MODEL_SIZE = 256;

    private Interpreter tflite;
    private ByteBuffer inputBuffer;
    private ByteBuffer outputBuffer;
    private volatile boolean initialized = false;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean isInferencing = new AtomicBoolean(false);
    private final AtomicReference<byte[]> latestDepthMap = new AtomicReference<>();

    private byte[] previousDepthBytes = null;
    private byte[] smoothedDepthBytes = null;

    public synchronized boolean initialize(Context context) {
        if (initialized) return true;

        try {
            inputBuffer = ByteBuffer.allocateDirect(1 * MODEL_SIZE * MODEL_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBuffer = ByteBuffer.allocateDirect(1 * MODEL_SIZE * MODEL_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            boolean useNnapi = false;
            try {
                Interpreter.Options opts = new Interpreter.Options();
                opts.setUseNNAPI(true);
                opts.setNumThreads(4);
                tflite = new Interpreter(loadModelFile(context), opts);
                useNnapi = true;
            } catch (Exception e) {
                Log.w(TAG, "NNAPI failed, falling back to CPU", e);
            }

            if (!useNnapi) {
                Interpreter.Options opts = new Interpreter.Options();
                opts.setNumThreads(4);
                tflite = new Interpreter(loadModelFile(context), opts);
            }

            initialized = true;
            Log.i(TAG, "Initialized successfully (NNAPI=" + useNnapi + ")");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize", e);
            return false;
        }
    }

    public void submitFrame(byte[] rgbaPixels, int width, int height) {
        if (!initialized || tflite == null) return;
        if (rgbaPixels == null || rgbaPixels.length < width * height * 4) return;
        if (!isInferencing.compareAndSet(false, true)) return;

        final byte[] frameCopy = rgbaPixels.clone();
        executor.submit(() -> {
            long startTime = System.nanoTime();
            try {
                byte[] result = runInference(frameCopy, width, height);
                if (result != null) {
                    latestDepthMap.set(result);
                }
            } catch (Exception e) {
                Log.e(TAG, "Async inference failed", e);
            } finally {
                isInferencing.set(false);
                long duration = (System.nanoTime() - startTime) / 1_000_000;
                Log.d(TAG, "Inference: " + duration + "ms");
            }
        });
    }

    public byte[] getLatestDepth() {
        return latestDepthMap.getAndSet(null);
    }

    private byte[] runInference(byte[] rgbaPixels, int width, int height) {
        inputBuffer.rewind();
        outputBuffer.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / MODEL_SIZE;
        float scaleY = (float) height / MODEL_SIZE;

        for (int y = 0; y < MODEL_SIZE; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < MODEL_SIZE; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBuffer.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBuffer.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBuffer.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBuffer.rewind();

        tflite.run(inputBuffer, outputBuffer);
        outputBuffer.rewind();

        FloatBuffer floatOut = outputBuffer.asFloatBuffer();
        float min = Float.MAX_VALUE, max = Float.MIN_VALUE;
        for (int i = 0; i < floatOut.capacity(); i++) {
            float v = floatOut.get(i);
            if (v < min) min = v;
            if (v > max) max = v;
        }

        float range = max - min;
        byte[] depthBytes = new byte[MODEL_SIZE * MODEL_SIZE];
        if (range > 0) {
            floatOut.rewind();
            for (int i = 0; i < floatOut.capacity(); i++) {
                float normalized = (floatOut.get() - min) / range;
                float contrast = (float) Math.pow(normalized, 0.5);
                depthBytes[i] = (byte) (contrast * 255.0f);
            }
        }

        depthBytes = boxBlur(depthBytes);

        return temporalSmooth(depthBytes);
    }

    private byte[] boxBlur(byte[] depth) {
        byte[] result = new byte[depth.length];
        int r = 2;
        for (int y = 0; y < MODEL_SIZE; y++) {
            for (int x = 0; x < MODEL_SIZE; x++) {
                int sum = 0;
                int count = 0;
                for (int dy = -r; dy <= r; dy++) {
                    for (int dx = -r; dx <= r; dx++) {
                        int nx = x + dx;
                        int ny = y + dy;
                        if (nx >= 0 && nx < MODEL_SIZE && ny >= 0 && ny < MODEL_SIZE) {
                            sum += depth[ny * MODEL_SIZE + nx] & 0xFF;
                            count++;
                        }
                    }
                }
                result[y * MODEL_SIZE + x] = (byte) (sum / count);
            }
        }
        return result;
    }

    private byte[] temporalSmooth(byte[] newDepth) {
        if (previousDepthBytes == null) {
            previousDepthBytes = newDepth.clone();
            smoothedDepthBytes = newDepth.clone();
            return newDepth;
        }

        float smoothing = 0.15f;

        long totalDiff = 0;
        for (int i = 0; i < newDepth.length; i++) {
            totalDiff += Math.abs((newDepth[i] & 0xFF) - (previousDepthBytes[i] & 0xFF));
        }
        double avgDiff = (double) totalDiff / newDepth.length;

        if (avgDiff > 80.0) {
            smoothing = 0.5f;
        } else if (avgDiff > 50.0) {
            smoothing = 0.3f;
        }

        byte[] result = new byte[newDepth.length];
        for (int i = 0; i < newDepth.length; i++) {
            float prev = smoothedDepthBytes[i] & 0xFF;
            float curr = newDepth[i] & 0xFF;
            result[i] = (byte) (prev * (1.0f - smoothing) + curr * smoothing);
        }

        previousDepthBytes = newDepth.clone();
        smoothedDepthBytes = result.clone();
        return result;
    }

    public synchronized void close() {
        if (tflite != null) {
            tflite.close();
            tflite = null;
        }
        initialized = false;
        executor.shutdownNow();
    }

    public int getModelSize() {
        return MODEL_SIZE;
    }

    public boolean isInitialized() {
        return initialized;
    }

    private MappedByteBuffer loadModelFile(Context context) throws IOException {
        AssetFileDescriptor fd = context.getAssets().openFd("midas-midas-v2-w8a8.tflite");
        FileInputStream is = new FileInputStream(fd.getFileDescriptor());
        FileChannel ch = is.getChannel();
        long offset = fd.getStartOffset();
        long length = fd.getDeclaredLength();
        return ch.map(FileChannel.MapMode.READ_ONLY, offset, length);
    }
}
