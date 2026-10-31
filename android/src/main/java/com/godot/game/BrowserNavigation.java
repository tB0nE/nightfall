package com.godot.game;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLEncoder;
import java.io.UnsupportedEncodingException;

/** Pure navigation policy: no Android objects, UI work or browsing diagnostics. */
final class BrowserNavigation {
    static final String HOME_URL = "https://nightfall.invalid/";
    // Recognize services for contextual permission notices, not navigation blocks.
    // Playback and readable-texture support must be tested separately.
    private static final String[][] DRM_SERVICES = {
        {"netflix.com", "Netflix"}, {"disneyplus.com", "Disney+"}, {"primevideo.com", "Prime Video"},
        {"max.com", "Max"}, {"hulu.com", "Hulu"}, {"tv.apple.com", "Apple TV+"},
        {"paramountplus.com", "Paramount+"}, {"peacocktv.com", "Peacock"},
        {"tubitv.com", "Tubi"}, {"crunchyroll.com", "Crunchyroll"}, {"spotify.com", "Spotify"},
        {"music.apple.com", "Apple Music"},
    };
    // Web Apps on the home page: {name, address}. Each is the service's own
    // website; none needs DRM, so AI 3D works on all of them.
    static final String[][] WEB_APPS = {
        {"YouTube", "https://www.youtube.com/"},
        {"Plex", "https://app.plex.tv/desktop/"},
        {"Xbox Cloud Gaming", "https://www.xbox.com/play"},
        {"GeForce NOW", "https://play.geforcenow.com/"},
        {"webrcade", "https://play.webrcade.com/"},
    };
    private BrowserNavigation() {}

    /** Request YouTube's desktop layout using the installed WebView's Chrome version. */
    static String userAgent(String value, String defaultAgent) {
        return userAgent(value, defaultAgent, false);
    }

    /** Netflix desktop-site identity is limited to the protected-media DEV experiment. */
    static String userAgent(String value, String defaultAgent, boolean protectedMediaTest) {
        if (value == null) return null;
        try {
            String host = new URI(value).getHost();
            if (host == null) return null;
            host = host.toLowerCase(java.util.Locale.ROOT);
            boolean youtube = host.equals("youtube.com") || host.endsWith(".youtube.com");
            boolean netflix = host.equals("netflix.com") || host.endsWith(".netflix.com");
            if (!youtube && !(protectedMediaTest && netflix)) return null;
            java.util.regex.Matcher version = java.util.regex.Pattern.compile("Chrome/([0-9.]+)")
                    .matcher(defaultAgent == null ? "" : defaultAgent);
            String chrome = version.find() ? " Chrome/" + version.group(1) : "";
            return "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko)"
                    + chrome + " Safari/537.36";
        } catch (URISyntaxException e) {
            return null;
        }
    }

    static String desktopUrl(String value) {
        if (!allowed(value)) return value;
        try {
            URI uri = new URI(value);
            if (!"m.youtube.com".equalsIgnoreCase(uri.getHost())) return value;
            // Keep the original escaping, query and fragment intact.
            return value.replaceFirst("(?i)^(https?://)m\\.youtube\\.com(?=[:/\\?#]|$)", "$1www.youtube.com");
        } catch (URISyntaxException e) { return value; }
    }

    /** DEV-only normal EME permission: never grant camera, microphone or unknown resources. */
    static String[] protectedMediaResources(String origin, String[] requested, boolean enabled) {
        final String protectedId = "android.webkit.resource.PROTECTED_MEDIA_ID";
        if (!enabled || !allowed(origin) || !origin.regionMatches(true, 0, "https://", 0, 8)
                || requested == null) return new String[0];
        for (String resource : requested)
            if (protectedId.equals(resource)) return new String[]{protectedId};
        return new String[0];
    }

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
        return (service == null ? "This site's video" : service) + " uses protected media. Protected-media requests are disabled in this build; "
                + "playback support has not been verified.";
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
