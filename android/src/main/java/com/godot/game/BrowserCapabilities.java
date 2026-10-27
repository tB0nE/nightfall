package com.godot.game;

import android.content.pm.PackageInfo;
import android.webkit.WebView;
import org.json.JSONObject;

/** Read-only feasibility probe. Does not create a browser or claim DRM support. */
public final class BrowserCapabilities {
    private BrowserCapabilities() {}

    public static String describe() {
        JSONObject result = new JSONObject();
        try {
            PackageInfo provider = WebView.getCurrentWebViewPackage();
            result.put("available", provider != null);
            if (provider != null) {
                result.put("package", provider.packageName);
                result.put("version", provider.versionName);
            }
            result.put("gpu_surface_validated", false);
            result.put("video_playback_validated", false);
            result.put("drm_validated", false);
        } catch (Exception | LinkageError e) {
            try {
                result.put("available", false);
                result.put("error", e.getClass().getSimpleName());
            } catch (Exception ignored) {}
        }
        return result.toString();
    }
}
