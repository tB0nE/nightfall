package com.godot.game;
import java.util.*;

public final class BrowserBlockingPolicyTest {
    private static void check(boolean value) { if (!value) throw new AssertionError("Blocking policy test failed"); }
    public static void main(String[] args) {
        Set<String> exceptions = Collections.singleton("example.com");
        check(!BrowserBlockingPolicy.shouldFilter(false, true, "https://other.com/", exceptions));
        check(!BrowserBlockingPolicy.shouldFilter(true, false, "https://other.com/", exceptions));
        check(!BrowserBlockingPolicy.shouldFilter(true, true, "https://example.com/", exceptions));
        check(BrowserBlockingPolicy.shouldFilter(true, true, "https://other.com/", exceptions));
        check(BrowserBlockingPolicy.shouldFilter(true, true, "https://notexample.com/", exceptions));
        check(!BrowserBlockingPolicy.shouldFilter(true, true, BrowserNavigation.HOME_URL, exceptions));
        check(!BrowserBlockingPolicy.shouldFilter(true, true, "", exceptions));
        check(BrowserBlockingPolicy.host("HTTPS://EXAMPLE.COM/path?token=x").equals("example.com"));
        check(BrowserBlockingPolicy.origin("https://EXAMPLE.COM:8443/path?token=x").equals("https://EXAMPLE.COM:8443/"));
        check(BrowserBlockingPolicy.kind("https://example.com/a.js?x=1", null, false).equals("script"));
        check(BrowserBlockingPolicy.kind("https://example.com/a", "image", false).equals("image"));
        check(BrowserBlockingPolicy.kind("https://example.com/a", "iframe", false).equals("subdocument"));
        check(BrowserBlockingPolicy.kind("https://example.com/a", null, false).equals("other"));
        String valid = "[Adblock Plus 2.0]\n! Title: EasyList\n" + "||ads.example^\n".repeat(110);
        BrowserBlockingPolicy.validateList(valid, "EasyList");
        for (String invalid : new String[] {"<html>Bad gateway</html>", "[Adblock Plus 2.0]\n! Title: EasyList\n", valid.replace("EasyList", "Wrong")}) {
            boolean rejected = false;
            try { BrowserBlockingPolicy.validateList(invalid, "EasyList"); }
            catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected);
        }
        System.out.println("All browser blocking policy tests passed");
    }
}
