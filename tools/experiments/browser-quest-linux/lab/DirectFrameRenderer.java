package app.nightfall.browserlab;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.Paint;
import android.graphics.Rect;
import android.view.Surface;
import org.json.JSONObject;
import java.io.File;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;

/** CPU-copy spike: Xvfb's mmap framebuffer directly to an Android Surface.
 * Xvfb does not provide frame fences: tearing remains possible in this experiment.
 */
final class DirectFrameRenderer implements FrameRenderer {
    private final File base;
    private final Surface surface;
    private volatile boolean running = true;
    private final Thread worker;
    private final boolean hardwareCanvas;
    private volatile int targetHz = 30;
    private long lateSlots;
    private boolean rawCopy;
    private final long[] postIntervals = new long[240];
    private int intervalCount, intervalIndex;
    private int sourceWidth, sourceHeight, outputWidth, outputHeight;

    DirectFrameRenderer(File base, Surface surface) {
        this.base = base;
        this.surface = surface;
        boolean requestedHardware = true;
        try {
            byte[] config = java.nio.file.Files.readAllBytes(new File(base, "direct-frame-config.json").toPath());
            JSONObject settings = new JSONObject(new String(config, java.nio.charset.StandardCharsets.UTF_8));
            requestedHardware = settings.optBoolean("hardware_canvas", true);
            setTargetHz(settings.optInt("target_hz", 30));
        } catch (Exception ignored) { /* GPU default; explicit false selects the CPU comparison path. */ }
        hardwareCanvas = requestedHardware;
        worker = new Thread(this::run, "LinuxDirectFrames");
        worker.start();
    }

    @Override public void setTargetHz(int hz) {
        if (hz < 30 || hz > 120)
            throw new IllegalArgumentException("Unsupported frame target");
        targetHz = hz;
    }

    @Override public void stop() {
        running = false;
        worker.interrupt();
        try { worker.join(2000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        // The worker alone releases its Surface and bitmap after posting ends.
    }

    private void writeStatus(String state, long frames, long changes, long started, long copyNs, long drawNs) {
        try {
            JSONObject result = new JSONObject();
            double elapsed = (System.nanoTime() - started) / 1e9;
            result.put("state", state).put("elapsed_s", elapsed).put("posted_frames", frames)
                    .put("changed_samples", changes).put("posted_fps", frames / Math.max(.001, elapsed))
                    .put("mean_copy_ms", frames == 0 ? 0 : copyNs / 1e6 / frames)
                    .put("mean_draw_ms", frames == 0 ? 0 : drawNs / 1e6 / frames)
                    .put("drawing", hardwareCanvas ? "hardware_canvas" : "software_canvas")
                    .put("raw_bitmap_copy", rawCopy).put("target_hz", targetHz).put("late_slots", lateSlots)
                    .put("source_width", sourceWidth).put("source_height", sourceHeight)
                    .put("output_width", outputWidth).put("output_height", outputHeight)
                    .put("limits", "Unfenced CPU-copy prototype; posted frames are not unique video frames.");
            if (intervalCount > 0) {
                long[] sorted = java.util.Arrays.copyOf(postIntervals, intervalCount);
                java.util.Arrays.sort(sorted);
                result.put("post_interval_p50_ms", sorted[intervalCount / 2] / 1e6)
                        .put("post_interval_p95_ms", sorted[Math.min(intervalCount - 1,
                                (int)Math.ceil(intervalCount * .95) - 1)] / 1e6)
                        .put("post_interval_max_ms", sorted[intervalCount - 1] / 1e6);
            }
            File temp = new File(base, "direct-frame-status.tmp");
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(temp)) {
                out.write(result.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            temp.renameTo(new File(base, "direct-frame-status.json"));
        } catch (Exception ignored) { /* Metrics must not interrupt playback. */ }
    }

    private void run() {
        Bitmap bitmap = null;
        long frames = 0, changes = 0, copyNs = 0, drawNs = 0;
        long started = System.nanoTime(), lastStatus = started;
        try (RandomAccessFile file = new RandomAccessFile(
                new File(base, "rootfs/tmp/nightfall-framebuffer/Xvfb_screen0"), "r")) {
            ByteBuffer header = ByteBuffer.allocate(100).order(ByteOrder.BIG_ENDIAN);
            file.readFully(header.array());
            int headerSize = header.getInt(0), version = header.getInt(4);
            int width = header.getInt(16), height = header.getInt(20);
            int order = header.getInt(28), bits = header.getInt(44), stride = header.getInt(48);
            int colors = header.getInt(76);
            if (version != 7 || header.getInt(8) != 2 || header.getInt(24) != 0
                    || width < 1 || height < 1 || width > 4096 || height > 4096
                    || bits != 32 || stride < width * 4 || stride > 65536 || stride % 4 != 0
                    || (order != 0 && order != 1) || colors < 0 || colors > 65536
                    || headerSize < 100 || headerSize > 1048576
                    || header.getInt(56) != 0xff0000 || header.getInt(60) != 0xff00
                    || header.getInt(64) != 0xff) throw new IllegalStateException("Unsupported XWD layout");
            long offset = headerSize + colors * 12L, length = (long)stride * height;
            if (offset + length > file.length()) throw new IllegalStateException("Incomplete framebuffer");
            sourceWidth = width; sourceHeight = height;
            MappedByteBuffer mapped = file.getChannel().map(FileChannel.MapMode.READ_ONLY, offset, length);
            mapped.order(order == 0 ? ByteOrder.LITTLE_ENDIAN : ByteOrder.BIG_ENDIAN);
            IntBuffer source = mapped.asIntBuffer();
            int[] pixels = hardwareCanvas && order == 0 && stride == width * 4 ? null : new int[width * height];
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
            // XWD is BGRX on this Quest. Copy bytes unchanged, then swizzle R/B
            // in the GPU shader instead of converting/setting alpha in Java.
            rawCopy = hardwareCanvas && order == 0 && stride == width * 4;
            if (rawCopy) {
                bitmap.setHasAlpha(false);
                paint.setColorFilter(new ColorMatrixColorFilter(new ColorMatrix(new float[] {
                        0,0,1,0,0, 0,1,0,0,0, 1,0,0,0,0, 0,0,0,0,255 })));
            }
            int previousHash = 0;
            long deadline = System.nanoTime();
            long previousPost = 0;
            while (running && surface.isValid()) {
                long begin = System.nanoTime();
                int hash = 1;
                if (rawCopy) {
                    mapped.position(0);
                    bitmap.copyPixelsFromBuffer(mapped);
                    for (int i = 0; i < width * height; i += 4096)
                        hash = hash * 31 + mapped.getInt(i * 4);
                } else {
                for (int row = 0; row < height; row++) {
                    source.position(row * (stride / 4));
                    source.get(pixels, row * width, width);
                }
                for (int i = 0; i < pixels.length; i++) {
                    pixels[i] |= 0xff000000;
                    if (i % 64 == 0) hash = hash * 31 + pixels[i];
                }
                bitmap.setPixels(pixels, 0, width, 0, 0, width, height);
                }
                if (frames == 0 || hash != previousHash) changes++;
                previousHash = hash;
                long copied = System.nanoTime();
                Canvas canvas = hardwareCanvas ? surface.lockHardwareCanvas() : surface.lockCanvas(null);
                try {
                    outputWidth = canvas.getWidth(); outputHeight = canvas.getHeight();
                    if (canvas.isHardwareAccelerated() != hardwareCanvas)
                        throw new IllegalStateException("Requested drawing backend unavailable");
                    canvas.drawColor(Color.BLACK);
                    canvas.drawBitmap(bitmap, null, new Rect(0, 0, canvas.getWidth(), canvas.getHeight()), paint);
                } finally { surface.unlockCanvasAndPost(canvas); }
                frames++;
                long now = System.nanoTime();
                if (previousPost != 0) {
                    postIntervals[intervalIndex] = now - previousPost;
                    intervalIndex = (intervalIndex + 1) % postIntervals.length;
                    intervalCount = Math.min(intervalCount + 1, postIntervals.length);
                }
                previousPost = now;
                copyNs += copied - begin;
                drawNs += now - copied;
                if (now - lastStatus > 1_000_000_000L) {
                    writeStatus("playing", frames, changes, started, copyNs, drawNs);
                    lastStatus = now;
                }
                long interval = 1_000_000_000L / targetHz;
                deadline += interval;
                long after = System.nanoTime();
                if (deadline <= after) {
                    long skipped = (after - deadline) / interval + 1;
                    lateSlots += skipped;
                    deadline += skipped * interval;
                }
                long remaining = deadline - System.nanoTime();
                if (remaining > 0) Thread.sleep(remaining / 1_000_000L, (int)(remaining % 1_000_000L));
            }
            writeStatus("stopped", frames, changes, started, copyNs, drawNs);
        } catch (InterruptedException interrupted) {
            writeStatus(running ? "interrupted" : "stopped", frames, changes, started, copyNs, drawNs);
            Thread.currentThread().interrupt();
        } catch (Exception error) {
            writeStatus("error: " + error.getClass().getSimpleName() + ": " + error.getMessage(),
                    frames, changes, started, copyNs, drawNs);
        } finally {
            surface.release();
            if (bitmap != null) bitmap.recycle();
        }
    }
}
