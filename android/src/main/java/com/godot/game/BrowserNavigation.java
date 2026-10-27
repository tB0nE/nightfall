package com.godot.game;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLEncoder;
import java.io.UnsupportedEncodingException;

/** Pure navigation policy: no Android objects, UI work or browsing diagnostics. */
final class BrowserNavigation {
    static final String HOME_URL = "https://nightfall.invalid/";
    // Services whose video or music is Widevine-protected. Protected media only
    // plays on a secure display, and the browser draws into a texture, so it can't.
    private static final String[][] DRM_SERVICES = {
        {"netflix.com", "Netflix"}, {"disneyplus.com", "Disney+"}, {"primevideo.com", "Prime Video"},
        {"max.com", "Max"}, {"hulu.com", "Hulu"}, {"tv.apple.com", "Apple TV+"},
        {"paramountplus.com", "Paramount+"}, {"peacocktv.com", "Peacock"},
        {"tubitv.com", "Tubi"}, {"crunchyroll.com", "Crunchyroll"}, {"spotify.com", "Spotify"},
        {"music.apple.com", "Apple Music"},
    };
    private BrowserNavigation() {}

    /** The DRM streaming service `value` belongs to, or null. */
    static String drmService(String value) {
        if (value == null) return null;
        try {
            String host = new URI(value).getHost();
            if (host == null) return null;
            host = host.toLowerCase(java.util.Locale.ROOT);
            for (String[] service : DRM_SERVICES)
                if (host.equals(service[0]) || host.endsWith("." + service[0])) return service[1];
        } catch (URISyntaxException e) {
            return null;
        }
        return null;
    }

    static String drmNotice(String service) {
        return (service == null ? "This site's video" : service) + " uses DRM copy protection, so it can't play in the "
                + "Nightfall browser. Use its own app or the Meta Quest Browser instead.";
    }

    static boolean allowed(String value) {
        if (value == null) return false;
        try {
            URI uri = new URI(value);
            String scheme = uri.getScheme();
            return ("https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme))
                    && uri.getHost() != null && uri.getRawUserInfo() == null
                    && uri.getPort() >= -1 && uri.getPort() <= 65535;
        } catch (URISyntaxException e) {
            return false;
        }
    }

    // Empty -> Home; null -> rejected. Search uses DuckDuckGo, explicitly named
    // in the address hint/start page. Never interpret an unsupported URI as code.
    static String destination(String input) {
        String value = input == null ? "" : input.trim();
        if (value.isEmpty()) return HOME_URL;
        if (value.matches("(?is)^https?://.*")) return allowed(value) ? value : null;
        boolean hostPort = value.matches("(?i)^(?:[a-z0-9.-]+|\\[[0-9a-f:]+\\]):[0-9]+(?:[/\\?#].*)?$");
        if (!hostPort && value.matches("(?s)^[a-zA-Z][a-zA-Z0-9+.-]*:.*")) return null;
        boolean host = value.matches("(?i)^(?:localhost|[a-z0-9-]+(?:\\.[a-z0-9-]+)+|\\[[0-9a-f:]+\\])(?::[0-9]+)?(?:[/\\?#].*)?$");
        if (host || hostPort) return allowed("https://" + value) ? "https://" + value : null;
        try {
            return "https://duckduckgo.com/?q=" + URLEncoder.encode(value, "UTF-8");
        } catch (UnsupportedEncodingException impossible) {
            throw new AssertionError(impossible);
        }
    }
}
