package app.nightfall.browserdisplayprobe;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.app.Presentation;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ActivityInfo;
import org.json.JSONArray;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.widget.TextView;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;

/** Ordinary, non-secure virtual-display capability probe. No MediaProjection,
 * shell identity, DRM access, screenshots or permissions grants are used. */
public final class BrowserDisplayProbe extends Activity {
    private final Handler ui = new Handler();
    private final JSONObject result = new JSONObject();
    private HandlerThread drain;
    private ImageReader reader;
    private VirtualDisplay display;
    private Presentation control;
    private String phase = "setup";
    private boolean ended;
    private int images, nonblack, changes, lastHash;
    private String mode;
    private String component;

    private synchronized void put(String key, Object value) {
        try { result.put(key, value); } catch (Exception ignored) { }
    }
    private synchronized void save() {
        try {
            File temp = new File(getFilesDir(), "probe.tmp");
            try (FileOutputStream out = new FileOutputStream(temp)) {
                out.write(result.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            temp.renameTo(new File(getFilesDir(), "probe.json"));
        } catch (Exception ignored) { }
    }
    private synchronized void phase(String name) {
        phase = name; images = nonblack = changes = lastHash = 0;
        put("phase", name); save();
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView message = new TextView(this);
        message.setText("Nightfall Quest Browser display probe\n\nTesting ordinary pages on an app-owned display.\nNo secure capture requested.\nCloses automatically after 20 seconds.");
        message.setPadding(24, 24, 24, 24); setContentView(message);
        mode = getIntent().getStringExtra("mode");
        if (!"public".equals(mode) && !"self".equals(mode)) mode = "private";
        component = getIntent().getStringExtra("component");
        if (component == null) component = "com.oculus.browser.OculusLauncherActivity";
        try {
            JSONArray routes = new JSONArray();
            for (ActivityInfo info : getPackageManager().getPackageInfo("com.oculus.browser", PackageManager.GET_ACTIVITIES).activities) {
                if (!info.exported) continue;
                routes.put(new JSONObject().put("name", info.name).put("enabled", info.enabled)
                        .put("permission", info.permission == null ? "" : info.permission).put("flags", info.flags));
            }
            put("browser_routes", routes);
        } catch (Exception error) { put("route_inspection_error", error.toString()); }
        put("mode", mode); put("complete", false);
        put("run_id", getIntent().getStringExtra("run_id"));
        put("secondary_activities", getPackageManager().hasSystemFeature(PackageManager.FEATURE_ACTIVITIES_ON_SECONDARY_DISPLAYS));
        try {
            drain = new HandlerThread("BrowserDisplayDrain"); drain.start();
            reader = ImageReader.newInstance(1280, 720, PixelFormat.RGBA_8888, 2);
            reader.setOnImageAvailableListener(r -> {
                try (Image image = r.acquireLatestImage()) {
                    if (image == null) return;
                    Image.Plane plane = image.getPlanes()[0]; ByteBuffer pixels = plane.getBuffer();
                    int hash = 1, lit = 0;
                    for (int y = 16; y < image.getHeight(); y += 32) for (int x = 16; x < image.getWidth(); x += 32) {
                        int at = y * plane.getRowStride() + x * plane.getPixelStride();
                        int red = pixels.get(at) & 255, green = pixels.get(at + 1) & 255, blue = pixels.get(at + 2) & 255;
                        hash = hash * 31 + red + (green << 8) + (blue << 16);
                        if (red + green + blue > 24) lit++;
                    }
                    synchronized (BrowserDisplayProbe.this) {
                        images++; if (lit > 0) nonblack++;
                        if (images == 1 || hash != lastHash) changes++; lastHash = hash;
                        JSONObject counters = new JSONObject();
                        counters.put("images", images).put("nonblack_images", nonblack).put("changed_samples", changes);
                        put(phase, counters); save();
                    }
                } catch (Exception error) { put("reader_error", error.getClass().getSimpleName()); save(); }
            }, new Handler(drain.getLooper()));
            int flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION;
            if ("public".equals(mode)) flags |= DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC;
            display = getSystemService(DisplayManager.class).createVirtualDisplay(
                    "Nightfall Browser Probe " + mode, 1280, 720, 160, reader.getSurface(), flags);
            if (display == null) throw new IllegalStateException("No virtual display returned");
            put("display_id", display.getDisplay().getDisplayId()); put("display_flags", display.getDisplay().getFlags());
            phase("control");
            control = new Presentation(this, display.getDisplay());
            TextView pattern = new TextView(control.getContext());
            pattern.setBackgroundColor(Color.GREEN); pattern.setTextColor(Color.BLUE);
            pattern.setText("Nightfall readable display control"); control.setContentView(pattern); control.show();
            ui.postDelayed(() -> {
                if (ended) return;
                control.dismiss(); control = null; phase("blank");
                ui.postDelayed(this::launchBrowser, 1000);
            }, 2000);
            ui.postDelayed(() -> finishProbe("timeout"), 20000);
        } catch (Exception error) {
            put("setup_error", error.toString()); finishProbe("setup_error");
        }
    }
    private void launchBrowser() {
        if (ended) return;
        // A fixed neutral page: don't open accounts or inspect existing tabs.
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("http://127.0.0.1:6082/color-probe.html"));
        if ("self".equals(mode)) intent.setComponent(new ComponentName(this, DisplayControlActivity.class));
        else intent.setComponent(new ComponentName("com.oculus.browser", component));
        put("component", intent.getComponent().flattenToShortString());
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_MULTIPLE_TASK);
        phase("browser");
        try {
            put("launch_allowed", getSystemService(ActivityManager.class).isActivityStartAllowedOnDisplay(this, display.getDisplay().getDisplayId(), intent));
            ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(display.getDisplay().getDisplayId());
            startActivity(intent, options.toBundle()); put("launch_requested", true);
        } catch (Exception error) { put("launch_error", error.toString()); finishProbe("launch_rejected"); }
        save();
    }
    private void finishProbe(String reason) {
        if (ended) return;
        ended = true; put("complete", true); put("end_reason", reason); save();
        ui.removeCallbacksAndMessages(null);
        if (control != null) { control.dismiss(); control = null; }
        for (ActivityManager.AppTask task : getSystemService(ActivityManager.class).getAppTasks()) {
            try {
                if (task.getTaskInfo().baseActivity != null && DisplayControlActivity.class.getName().equals(task.getTaskInfo().baseActivity.getClassName())) task.finishAndRemoveTask();
            } catch (Exception ignored) { }
        }
        if (display != null) { display.release(); display = null; }
        if (reader != null) { reader.setOnImageAvailableListener(null, null); }
        if (drain != null) {
            // Reader closes only after any in-flight image callback finishes.
            new Handler(drain.getLooper()).post(() -> { reader.close(); drain.quitSafely(); });
        } else if (reader != null) reader.close();
        finish();
    }
    @Override protected void onDestroy() { finishProbe("activity_destroyed"); super.onDestroy(); }
}
