package com.godot.game;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLEncoder;
import java.io.UnsupportedEncodingException;

/** Pure navigation policy: no Android objects, UI work or browsing diagnostics. */
final class BrowserNavigation {
    static final String HOME_URL = "https://nightfall.invalid/";
    private BrowserNavigation() {}

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
