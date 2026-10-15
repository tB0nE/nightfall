package com.godot.game;

import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;

// The Android class is present for type resolution only. This test invokes
// actual JNI filtering, never stub Android UI, preferences or network methods.
public final class BrowserAdblockNativeTest {
    private static Method method(String name, Class<?>... args) throws Exception {
        Method method = BrowserAdblock.class.getDeclaredMethod(name, args);
        method.setAccessible(true);
        return method;
    }
    private static void check(boolean value) { if (!value) throw new AssertionError("Native blocker test failed"); }
    public static void main(String[] args) throws Exception {
        System.load(Path.of(args[0]).toAbsolutePath().toString());
        Method install = method("nativeInstall", String.class);
        Method blocked = method("nativeBlocked", String.class, String.class, String.class, String.class);
        Method selectors = method("nativeSelectors", String.class);
        Method release = method("nativeRelease");
        String rules = "||ads.example^\n@@||ads.example/allowed^\nsite.example##.sponsor";
        check((Boolean) install.invoke(null, rules));
        check((Boolean) blocked.invoke(null, "https://ads.example/banner", "https://site.example/", "script", "GET"));
        check(!(Boolean) blocked.invoke(null, "https://ads.example/allowed", "https://site.example/", "script", "GET"));
        check(((String) selectors.invoke(null, "https://site.example/")).contains(".sponsor"));
        check(!(Boolean) install.invoke(null, "x".repeat(17 * 1024 * 1024)));
        check((Boolean) blocked.invoke(null, "https://ads.example/banner", "https://site.example/", "script", "GET"));
        release.invoke(null);
        check(!(Boolean) blocked.invoke(null, "https://ads.example/banner", "https://site.example/", "script", "GET"));
        if (args.length > 1) {
            String lists = Files.readString(Path.of(args[1]));
            if (args.length > 2) {
                String privacy = Files.readString(Path.of(args[2]));
                BrowserBlockingPolicy.validateList(lists, "EasyList");
                BrowserBlockingPolicy.validateList(privacy, "EasyPrivacy");
                lists += "\n" + privacy;
            }
            long start = System.nanoTime();
            check((Boolean) install.invoke(null, lists));
            System.out.println("Official lists host compile: " + (System.nanoTime() - start) / 1000000 + "ms");
            check((Boolean) blocked.invoke(null, "https://googleads.g.doubleclick.net/pagead/ads", "https://example.com/", "script", "GET"));
            start = System.nanoTime();
            for (int i = 0; i < 10000; i++)
                blocked.invoke(null, "https://googleads.g.doubleclick.net/pagead/ads", "https://example.com/", "script", "GET");
            System.out.println("Host JNI + reflection matching: " + (System.nanoTime() - start) / 10000 / 1000 + "us/request (not Quest timing)");
        }
        System.out.println("All browser native JNI tests passed");
    }
}

// Standalone compile-time substitute only; the APK uses its real DiagnosticLog.
final class DiagnosticLog { static void info(String tag, String message) {} }
