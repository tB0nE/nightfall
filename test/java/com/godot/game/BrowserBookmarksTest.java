package com.godot.game;

public final class BrowserBookmarksTest {
    private static void check(boolean condition) { if (!condition) throw new AssertionError("Bookmark test failed"); }
    private static void rejected(Runnable action) {
        try { action.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Expected validation failure");
    }
    public static void main(String[] args) {
        BrowserBookmarks data = BrowserBookmarks.decode("");
        data.save(null, "YouTube", "https://youtube.com/");
        data.save(null, "New label", "https://youtube.com/");
        check(data.entries().size() == 1);
        data.save(null, "Xbox", "https://xbox.com/play");
        data.move("https://xbox.com/play", -1);
        check(data.entries().get(0).title.equals("Xbox"));
        data.save("https://youtube.com/", "Video", "https://youtube.com/watch?v=test");
        BrowserBookmarks loaded = BrowserBookmarks.decode(data.encode());
        check(loaded.entries().get(1).url.equals("https://youtube.com/watch?v=test"));
        rejected(() -> data.save("https://xbox.com/play", "Duplicate", "https://youtube.com/watch?v=test"));
        rejected(() -> data.save(null, "", "https://example.com"));
        rejected(() -> data.save(null, "Bad", "javascript:alert(1)"));
        rejected(() -> data.save(null, "Bad", "https://user:password@example.com"));
        rejected(() -> data.save(null, "Home", BrowserNavigation.HOME_URL));
        rejected(() -> BrowserBookmarks.decode("not base64"));
        rejected(() -> BrowserBookmarks.decode("AAAAAgAAAAA=")); // Future version.
        rejected(() -> BrowserBookmarks.decode(data.encode() + "AAAA"));
        data.save(null, "<script> & \"test\"", "https://example.com/?x=1&y=2");
        check(!data.homeLinks().contains("<script>"));
        check(data.homeLinks().contains("&amp;y=2"));
        check(data.homeLinks().contains("&quot;test&quot;"));
        data.remove("https://xbox.com/play");
        check(data.entries().size() == 2);
        BrowserBookmarks full = new BrowserBookmarks();
        for (int i = 0; i < BrowserBookmarks.LIMIT; i++) full.save(null, "Site", "https://example.com/" + i);
        rejected(() -> full.save(null, "Overflow", "https://example.com/overflow"));
        check(BrowserBookmarks.decode(full.encode()).entries().size() == BrowserBookmarks.LIMIT);
        System.out.println("All browser bookmark tests passed");
    }
}
