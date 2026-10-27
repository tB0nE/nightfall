package com.godot.game;

/** Real data-layer integration, without Android preferences or a user's profile. */
public final class BrowserIntegrationTest {
    private static void check(boolean value) { if (!value) throw new AssertionError("Browser integration failed"); }
    public static void main(String[] args) {
        String target = BrowserNavigation.destination("example.org/watch?token=secret#position");
        check(BrowserNavigation.allowed(target));
        BrowserBookmarks bookmarks = new BrowserBookmarks();
        bookmarks.save(null, "Watch <film>", target);
        BrowserHistory history = new BrowserHistory();
        history.visit("Watch", target, 1234);
        // Simulate independent persisted snapshots and a fresh session.
        String savedBookmarks = bookmarks.encode(), savedHistory = history.encode();
        bookmarks = BrowserBookmarks.decode(savedBookmarks);
        history = BrowserHistory.decode(savedHistory);
        check(bookmarks.entries().get(0).url.equals(target));
        check(history.entries().get(0).url.equals("https://example.org/watch"));
        check(bookmarks.homeLinks().contains("&lt;film&gt;"));
        history.clear();
        check(BrowserHistory.decode(history.encode()).entries().isEmpty());
        check(BrowserBookmarks.decode(savedBookmarks).entries().size() == 1);
        check(!BrowserNavigation.allowed("intent://example.org"));
        check(BrowserGamepadProbe.html().contains("navigator.getGamepads"));
        check(!BrowserGamepadProbe.html().contains("fetch("));
        check(!BrowserGamepadProbe.html().contains("XMLHttpRequest"));
        System.out.println("Browser data integration and probe checks passed");
    }
}
