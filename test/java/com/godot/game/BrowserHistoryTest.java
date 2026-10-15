package com.godot.game;

public final class BrowserHistoryTest {
    private static void check(boolean value) { if (!value) throw new AssertionError("History test failed"); }
    private static void rejected(String value) {
        try { BrowserHistory.decode(value); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Expected corrupt history rejection");
    }
    public static void main(String[] args) {
        BrowserHistory history = BrowserHistory.decode("");
        history.visit("Test", "https://example.com/a%20b?token=secret#private", 123);
        check(history.entries().get(0).url.equals("https://example.com/a%20b"));
        check(!new String(java.util.Base64.getDecoder().decode(history.encode()),
                java.nio.charset.StandardCharsets.UTF_8).contains("secret"));
        history.visit("Other", "https://example.com/other", 124);
        history.visit("Updated", "https://example.com/a%20b?different=query", 125);
        check(history.entries().size() == 2 && history.entries().get(0).title.equals("Updated"));
        BrowserHistory loaded = BrowserHistory.decode(history.encode());
        check(loaded.entries().get(0).time == 125 && loaded.entries().get(1).time == 124);
        for (String invalid : new String[] {BrowserNavigation.HOME_URL, "https://nightfall.invalid", "about:blank",
                "javascript:alert(1)", "https://user:password@example.com/"}) history.visit("Invalid", invalid, 130);
        check(history.entries().size() == 2);
        history.clear();
        check(history.entries().isEmpty());
        for (int i = 0; i < BrowserHistory.LIMIT + 10; i++) history.visit("Test", "https://example.com/" + i, i);
        check(history.entries().size() == BrowserHistory.LIMIT);
        check(history.entries().get(0).url.endsWith("/209"));
        check(BrowserHistory.decode(history.encode()).entries().size() == BrowserHistory.LIMIT);
        rejected("not-base64");
        rejected("AAAAAgAAAAA=");
        rejected(history.encode() + "AAAA");
        System.out.println("All browser history tests passed");
    }
}
