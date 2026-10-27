package com.godot.game;

public final class BrowserNavigationTest {
    private static void equal(Object actual, Object expected) {
        if (!java.util.Objects.equals(actual, expected)) throw new AssertionError("Unexpected navigation result");
    }

    public static void main(String[] args) {
        equal(BrowserNavigation.destination(""), BrowserNavigation.HOME_URL);
        equal(BrowserNavigation.destination(null), BrowserNavigation.HOME_URL);
        equal(BrowserNavigation.destination(" youtube.com/watch?v=abc "), "https://youtube.com/watch?v=abc");
        equal(BrowserNavigation.destination("https://example.com/a?q=1#b"), "https://example.com/a?q=1#b");
        equal(BrowserNavigation.destination("http://localhost:8000/"), "http://localhost:8000/");
        equal(BrowserNavigation.destination("http://10.0.0.13:32400/web"), "http://10.0.0.13:32400/web");
        equal(BrowserNavigation.destination("localhost:8000/"), "https://localhost:8000/");
        equal(BrowserNavigation.destination("[::1]:8080/"), "https://[::1]:8080/");
        equal(BrowserNavigation.destination("nightfall VR & video"), "https://duckduckgo.com/?q=nightfall+VR+%26+video");
        equal(BrowserNavigation.destination("café videos"), "https://duckduckgo.com/?q=caf%C3%A9+videos");
        for (String value : new String[] { "javascript:alert(1)", "data:text/html,test", "file:///tmp/a",
                "content://anything", "intent://anything", "blob:https://example.com/a", "about:blank",
                "ftp://example.com/", "https://", "https://example.com/a b", "https://user:password@example.com/",
                "https://example.com:99999/" }) {
            equal(BrowserNavigation.destination(value), null);
            equal(BrowserNavigation.allowed(value), false);
        }
        equal(BrowserNavigation.allowed("https://www.xbox.com/play"), true);
        equal(BrowserNavigation.allowed("HTTP://example.com"), true);
        equal(BrowserNavigation.allowed(null), false);
        equal(BrowserNavigation.drmService("https://www.netflix.com/browse"), "Netflix");
        equal(BrowserNavigation.drmService("https://NETFLIX.com/"), "Netflix");
        equal(BrowserNavigation.drmService("https://www.disneyplus.com/home"), "Disney+");
        equal(BrowserNavigation.drmService("https://tv.apple.com/"), "Apple TV+");
        equal(BrowserNavigation.drmService("https://www.apple.com/"), null);
        equal(BrowserNavigation.drmService("https://tubitv.com/home"), "Tubi");
        equal(BrowserNavigation.drmService("https://www.crunchyroll.com/"), "Crunchyroll");
        equal(BrowserNavigation.drmService("https://open.spotify.com/"), "Spotify");
        equal(BrowserNavigation.drmService("https://music.apple.com/us/browse"), "Apple Music");
        equal(BrowserNavigation.drmService("https://notnetflix.com/"), null);
        equal(BrowserNavigation.drmService("https://www.youtube.com/tv"), null);
        equal(BrowserNavigation.drmService("not a url"), null);
        equal(BrowserNavigation.drmService(null), null);
        equal(BrowserNavigation.drmNotice("Netflix").startsWith("Netflix uses DRM"), true);
        equal(BrowserNavigation.drmNotice(null).startsWith("This site's video uses DRM"), true);
        equal(BrowserNavigation.userAgent("https://www.youtube.com/tv").contains("SMART-TV"), true);
        equal(BrowserNavigation.userAgent("https://www.youtube.com/tv#/watch?v=x").contains("SMART-TV"), true);
        equal(BrowserNavigation.userAgent("https://YOUTUBE.com/tv/"), BrowserNavigation.userAgent("https://www.youtube.com/tv"));
        equal(BrowserNavigation.userAgent("https://www.youtube.com/"), null);
        equal(BrowserNavigation.userAgent("https://www.youtube.com/tvshows"), null);
        equal(BrowserNavigation.userAgent("https://evil.example/tv"), null);
        equal(BrowserNavigation.userAgent(null), null);
        for (String[] app : BrowserNavigation.WEB_APPS) {
            equal(app.length, 2);
            equal(BrowserNavigation.allowed(app[1]) && app[1].startsWith("https://"), true);
            equal(BrowserNavigation.drmService(app[1]), null);
        }
        System.out.println("All browser navigation tests passed");
    }
}
