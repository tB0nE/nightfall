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
        System.out.println("All browser navigation tests passed");
    }
}
