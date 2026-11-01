package app.nightfall.browserlab;

import android.content.Context;
import android.graphics.PixelFormat;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import java.io.File;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicBoolean;

/** Desk-side framebuffer/Surface smoke check; no headset or account inspection. */
final class DirectFrameProbe {
    private static final AtomicBoolean active = new AtomicBoolean();
    static void start(Context context) {
        if (!active.compareAndSet(false, true)) return;
        new Thread(() -> run(context.getApplicationContext()), "DirectFrameProbe").start();
    }
    private static void run(Context context) {
        HandlerThread drain = new HandlerThread("DirectFrameProbeDrain");
        drain.start();
        AtomicLong received = new AtomicLong();
        AtomicLong colorError = new AtomicLong(-1), comparedChannels = new AtomicLong();
        int sourceWidth = 1280, sourceHeight = 720;
        try (java.io.RandomAccessFile source = new java.io.RandomAccessFile(
                new File(context.getFilesDir(), "linux/rootfs/tmp/nightfall-framebuffer/Xvfb_screen0"), "r")) {
            source.seek(16); sourceWidth = source.readInt(); sourceHeight = source.readInt();
            if (sourceWidth < 1 || sourceHeight < 1 || sourceWidth > 4096 || sourceHeight > 4096)
                throw new IllegalStateException("Invalid probe dimensions");
        } catch (Exception error) {
            android.util.Log.e("DirectFrameProbe", "Cannot read source dimensions", error);
            drain.quitSafely(); active.set(false); return;
        }
        ImageReader reader = ImageReader.newInstance(sourceWidth, sourceHeight, PixelFormat.RGBA_8888, 3);
        reader.setOnImageAvailableListener(r -> {
            try (Image image = r.acquireLatestImage()) {
                if (image == null) return;
                long count = received.incrementAndGet();
                if (count == 30) {
                    // Compare sparse pixels, not stored media. Use a paused generated
                    // test frame; concurrent animation can invalidate this comparison.
                    try (java.io.RandomAccessFile source = new java.io.RandomAccessFile(
                            new File(context.getFilesDir(), "linux/rootfs/tmp/nightfall-framebuffer/Xvfb_screen0"), "r")) {
                        byte[] header = new byte[100]; source.readFully(header);
                        java.nio.ByteBuffer h = java.nio.ByteBuffer.wrap(header).order(java.nio.ByteOrder.BIG_ENDIAN);
                        int width = h.getInt(16), height = h.getInt(20), stride = h.getInt(48);
                        long offset = h.getInt(0) + h.getInt(76) * 12L;
                        if (width != image.getWidth() || height != image.getHeight() || h.getInt(28) != 0)
                            throw new IllegalStateException("Probe source layout mismatch");
                        Image.Plane plane = image.getPlanes()[0];
                        java.nio.ByteBuffer pixels = plane.getBuffer();
                        long error = 0, channels = 0;
                        for (int y = 32; y < height - 32; y += 53) for (int x = 32; x < width - 32; x += 61) {
                            source.seek(offset + (long)y * stride + x * 4L);
                            int b = source.readUnsignedByte(), g = source.readUnsignedByte(), red = source.readUnsignedByte();
                            int at = y * plane.getRowStride() + x * plane.getPixelStride();
                            error += Math.abs(red - (pixels.get(at) & 255));
                            error += Math.abs(g - (pixels.get(at+1) & 255));
                            error += Math.abs(b - (pixels.get(at+2) & 255));
                            channels += 3;
                        }
                        colorError.set(error); comparedChannels.set(channels);
                    } catch (Exception error) { android.util.Log.e("DirectFrameProbe", "Pixel comparison failed", error); }
                }
            }
        }, new Handler(drain.getLooper()));
        DirectFrameRenderer renderer = new DirectFrameRenderer(
                new File(context.getFilesDir(), "linux"), reader.getSurface());
        try {
            Thread.sleep(10000);
            org.json.JSONObject result = new org.json.JSONObject();
            result.put("received_frames", received.get()).put("passed", received.get() >= 100)
                    .put("compared_channels", comparedChannels.get())
                    .put("mean_channel_error_255", colorError.get() < 0 ? -1 :
                            colorError.get() / (double)Math.max(1, comparedChannels.get()))
                    .put("limits", "10-second offscreen Surface sink; excludes VR rendering and inference.");
            try (java.io.FileOutputStream output = new java.io.FileOutputStream(
                    new File(context.getFilesDir(), "linux/direct-frame-probe.json"))) {
                output.write(result.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        } catch (Exception error) {
            android.util.Log.e("DirectFrameProbe", "Probe failed", error);
        } finally {
            renderer.stop(); reader.close(); drain.quitSafely(); active.set(false);
        }
    }
}
