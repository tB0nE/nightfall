package com.godot.game;

import java.net.URI;
import java.util.Locale;
import java.util.Set;

/** Testable request-policy glue; upstream Brave engine evaluates filter syntax. */
final class BrowserBlockingPolicy {
    static final int MAX_LIST_BYTES = 8 * 1024 * 1024;
    static String host(String url) {
        if (!BrowserNavigation.allowed(url)) return "";
        return URI.create(url).getHost().toLowerCase(Locale.ROOT);
    }
    static String origin(String url) {
        if (!BrowserNavigation.allowed(url)) return "";
        URI uri = URI.create(url);
        return uri.getScheme().toLowerCase(Locale.ROOT) + "://" + uri.getRawAuthority() + "/";
    }
    static boolean shouldFilter(boolean enabled, boolean ready, String page, Set<String> exceptions) {
        String host = host(page);
        return enabled && ready && !host.isEmpty() && !host.equals("nightfall.invalid") && !exceptions.contains(host);
    }
    static String kind(String url, String destination, boolean mainFrame) {
        if (mainFrame) return "document";
        if (destination != null) switch (destination.toLowerCase(Locale.ROOT)) {
            case "script": return "script";
            case "style": return "stylesheet";
            case "image": return "image";
            case "font": return "font";
            case "video": case "audio": return "media";
            case "iframe": case "frame": return "subdocument";
        }
        String path;
        try { path = URI.create(url).getPath().toLowerCase(Locale.ROOT); }
        catch (RuntimeException invalid) { return "other"; }
        if (path.endsWith(".js") || path.endsWith(".mjs")) return "script";
        if (path.endsWith(".css")) return "stylesheet";
        if (path.matches(".*\\.(png|jpg|jpeg|gif|webp|svg|ico|avif)$")) return "image";
        if (path.matches(".*\\.(woff2?|ttf|otf)$")) return "font";
        if (path.matches(".*\\.(mp4|webm|mp3|m4a|m3u8|mpd|ts)$")) return "media";
        return "other";
    }
    static void validateList(String text, String title) {
        if (text.length() > MAX_LIST_BYTES || !text.startsWith("[Adblock Plus")
                || !text.substring(0, Math.min(text.length(), 4096)).contains("! Title: " + title)
                || text.split("\n", 102).length < 101)
            throw new IllegalArgumentException("Invalid filter list");
        for (String line : text.split("\n"))
            if (line.length() > 16384) throw new IllegalArgumentException("Oversized filter rule");
    }
}
