package com.godot.game;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.PersistableBundle;
import org.json.JSONObject;

/** Explicit text transfers only. Never resolve clipboard URIs or log content. */
final class BrowserClipboard {
    private static final String REMOTE = "nightfall_host_clipboard";
    static String read(Context context) {
        JSONObject result = new JSONObject();
        try {
            if (context == null || (context instanceof android.app.Activity && !((android.app.Activity)context).hasWindowFocus())) return "{\"ok\":false}";
            ClipboardManager manager = context.getSystemService(ClipboardManager.class);
            ClipData clip = manager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0)
                return "{\"ok\":true,\"text\":\"\",\"stamp\":0,\"local\":false}";
            CharSequence text = clip.getItemAt(0).getText();
            if (text == null || text.length() > 65536) return "{\"ok\":false}";
            PersistableBundle extras = clip.getDescription().getExtras();
            result.put("ok", true).put("text", text.toString())
                .put("stamp", clip.getDescription().getTimestamp())
                .put("local", extras == null || !extras.getBoolean(REMOTE, false));
            return result.toString();
        } catch (RuntimeException | org.json.JSONException unavailable) {
            return "{\"ok\":false}";
        }
    }
    static boolean write(Context context, String text, long expectedStamp) {
        if (context == null || text == null || text.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 65536) return false;
        try {
            if (context instanceof android.app.Activity && !((android.app.Activity)context).hasWindowFocus()) return false;
            ClipboardManager manager = context.getSystemService(ClipboardManager.class);
            ClipData previous = manager.getPrimaryClip();
            long stamp = previous == null ? 0 : previous.getDescription().getTimestamp();
            if (stamp != expectedStamp) return false; // A newer user copy wins.
            ClipData clip = ClipData.newPlainText("Nightfall host", text);
            PersistableBundle extras = new PersistableBundle();
            extras.putBoolean(REMOTE, true);
            clip.getDescription().setExtras(extras);
            manager.setPrimaryClip(clip);
            return true;
        } catch (RuntimeException unavailable) { return false; }
    }
}
