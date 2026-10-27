package com.godot.game;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.AtomicFile;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.ServiceWorkerController;
import android.webkit.ServiceWorkerClient;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import javax.net.ssl.HttpsURLConnection;

/** One app-owned blocker; never wraps/replaces the GPU-backed WebView. */
final class BrowserAdblock {
    private static BrowserAdblock instance;
    static synchronized BrowserAdblock get(Context context) {
        if (instance == null) instance = new BrowserAdblock(context.getApplicationContext());
        return instance;
    }
    private static native boolean nativeInstall(String rules);
    private static native void nativeRelease();
    private static native boolean nativeBlocked(String url, String source, String kind, String method);
    private static native String nativeSelectors(String url);
    private final SharedPreferences preferences;
    private final AtomicFile cache;
    private final ExecutorService worker = Executors.newSingleThreadExecutor(r -> {
        Thread thread = new Thread(r, "Nightfall-blocker"); thread.setPriority(Thread.MIN_PRIORITY); return thread;
    });
    private final AtomicInteger epoch = new AtomicInteger();
    private final AtomicBoolean busy = new AtomicBoolean();
    private final AtomicLong blocked = new AtomicLong();
    private volatile boolean enabled, ready;
    private boolean loaded;
    private volatile Set<String> exceptions;
    private volatile String page = "", status = "Off";
    private volatile long updatedAt;

    private BrowserAdblock(Context context) {
        preferences = context.getSharedPreferences("nightfall_browser_blocking", Context.MODE_PRIVATE);
        exceptions = Collections.unmodifiableSet(new HashSet<>(preferences.getStringSet("exceptions", Collections.emptySet())));
        cache = new AtomicFile(new File(context.getFilesDir(), "browser-blocking-lists-v1.txt"));
        ServiceWorkerController.getInstance().setServiceWorkerClient(new ServiceWorkerClient() {
            @Override public WebResourceResponse shouldInterceptRequest(WebResourceRequest request) {
                return intercept(request, true);
            }
        });
        enabled = preferences.getBoolean("enabled", false);
        if (enabled) load(false);
    }
    boolean enabled() { return enabled; }
    boolean busy() { return busy.get(); }
    String status() {
        return status + " · blocked " + blocked.get() + (updatedAt <= 0 ? ""
                : "\nCached filters: " + java.text.DateFormat.getDateTimeInstance().format(new Date(updatedAt)));
    }
    String currentHost() { return BrowserBlockingPolicy.host(page); }
    boolean siteDisabled() { return exceptions.contains(currentHost()); }
    void page(String value) { page = BrowserBlockingPolicy.origin(value); }
    void setEnabled(boolean value) {
        enabled = value;
        preferences.edit().putBoolean("enabled", value).apply();
        epoch.incrementAndGet();
        if (value) load(false);
        else {
            ready = false;
            status = "Off";
            worker.execute(() -> { if (!enabled && loaded) nativeRelease(); });
        }
    }
    void toggleSite() {
        String host = currentHost();
        if (host.isEmpty() || host.equals("nightfall.invalid")) return;
        Set<String> copy = new HashSet<>(exceptions);
        if (!copy.remove(host)) {
            if (copy.size() >= 200) return;
            copy.add(host);
        }
        exceptions = Collections.unmodifiableSet(copy);
        preferences.edit().putStringSet("exceptions", copy).apply();
    }
    void resetExceptions() {
        exceptions = Collections.emptySet();
        preferences.edit().remove("exceptions").apply();
    }
    private boolean filtering(String source) {
        return BrowserBlockingPolicy.shouldFilter(enabled, ready, source, exceptions);
    }
    WebResourceResponse intercept(WebResourceRequest request, boolean serviceWorker) {
        String source = page;
        if (!filtering(source) || request.isForMainFrame()) return null;
        Map<String, String> headers = request.getRequestHeaders();
        String referrer = header(headers, "Referer");
        // Android does not identify the owning document for every SW request.
        // Fail open when attribution is unknown or belongs to an older page.
        if (serviceWorker && (referrer == null || !BrowserBlockingPolicy.host(referrer).equals(currentHost()))) return null;
        String url = request.getUrl().toString();
        if (!BrowserNavigation.allowed(url)) return null;
        String kind = BrowserBlockingPolicy.kind(url, header(headers, "Sec-Fetch-Dest"), false);
        if (!nativeBlocked(url, source, kind, request.getMethod())) return null;
        blocked.incrementAndGet();
        return new WebResourceResponse("text/plain", "UTF-8", 403, "Blocked by Nightfall",
                Collections.singletonMap("Cache-Control", "no-store"), new ByteArrayInputStream(new byte[0]));
    }
    private static String header(Map<String, String> headers, String key) {
        for (Map.Entry<String, String> entry : headers.entrySet())
            if (key.equalsIgnoreCase(entry.getKey())) return entry.getValue();
        return null;
    }
    void cosmeticCss(String url, java.util.function.Consumer<String> result) {
        worker.execute(() -> {
            StringBuilder css = new StringBuilder();
            if (filtering(url)) {
                try {
                    org.json.JSONArray selectors = new org.json.JSONArray(nativeSelectors(url));
                    for (int i = 0; i < Math.min(selectors.length(), 2048); i++) {
                        String selector = selectors.optString(i);
                        if (selector.isEmpty() || selector.length() > 1024 || selector.contains("{") || selector.contains("}")) continue;
                        if (css.length() + selector.length() > 65500) break;
                        css.append(selector).append("{display:none!important;}\n");
                    }
                } catch (org.json.JSONException | RuntimeException ignored) { /* Cosmetic filtering is optional. */ }
            }
            result.accept(css.toString());
        });
    }
    void update() { if (enabled) load(true); }

    private void load(boolean download) {
        // A single worker owns compilation/cache changes. No network on request,
        // render or UI threads. Enabling again queues behind a cancelled update.
        int token = epoch.get();
        if (!busy.compareAndSet(false, true)) {
            worker.execute(() -> { if (enabled && token == epoch.get() && !ready) load(download); });
            return;
        }
        status = download ? "Updating filters (existing rules remain active)" : "Loading filters";
        worker.execute(() -> {
            try {
                if (!enabled || token != epoch.get()) return;
                if (!loaded) { System.loadLibrary("nightfall_browser_adblock"); loaded = true; }
                if (!download) {
                    try (InputStream in = cache.openRead()) {
                        String text = read(in, 16 * 1024 * 1024, token);
                        if (!text.startsWith("! Nightfall EasyList + EasyPrivacy cache v1\n")
                                || !text.contains("! Title: EasyList\n") || !text.contains("! Title: EasyPrivacy\n")) throw new IOException();
                        install(text, token);
                        updatedAt = cache.getBaseFile().lastModified();
                        return;
                    } catch (IOException | IllegalArgumentException missing) { /* Fetch on explicit enable. */ }
                }
                String easylist = fetch("easylist", "EasyList", token);
                String privacy = fetch("easyprivacy", "EasyPrivacy", token);
                String combined = "! Nightfall EasyList + EasyPrivacy cache v1\n" + easylist + "\n" + privacy;
                if (!enabled || token != epoch.get()) return;
                install(combined, token);
                if (!enabled || token != epoch.get()) return;
                FileOutputStream out = null;
                try {
                    out = cache.startWrite();
                    out.write(combined.getBytes(StandardCharsets.UTF_8));
                    cache.finishWrite(out);
                    updatedAt = cache.getBaseFile().lastModified();
                } catch (IOException failure) {
                    if (out != null) cache.failWrite(out);
                    status = "On; filters active but cache could not be saved";
                }
            } catch (IOException | RuntimeException | LinkageError failure) {
                if (enabled && token == epoch.get())
                    status = ready ? "Update failed; keeping previous filters" : "Filters unavailable; browsing without blocking";
                // No exception messages, URLs or request details in diagnostics.
            } finally { busy.set(false); }
        });
    }
    private void install(String text, int token) throws IOException {
        if (!enabled || token != epoch.get()) throw new IOException();
        long start = System.nanoTime();
        if (!nativeInstall(text)) throw new IOException();
        if (!enabled || token != epoch.get()) { nativeRelease(); throw new IOException(); }
        ready = true;
        status = "On · EasyList + EasyPrivacy";
        DiagnosticLog.info("BrowserAdblock", "Compiled filters in " + ((System.nanoTime() - start) / 1000000) + "ms");
    }
    private String fetch(String file, String title, int token) throws IOException {
        // Fixed official HTTPS sources; no cookies, Referer or arbitrary URLs.
        HttpsURLConnection connection = (HttpsURLConnection) new URL("https://easylist.to/easylist/" + file + ".txt").openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(10000);
        connection.setReadTimeout(10000);
        connection.setRequestProperty("User-Agent", "Nightfall-filter-updater/1");
        try {
            if (connection.getResponseCode() != 200 || connection.getContentLengthLong() > BrowserBlockingPolicy.MAX_LIST_BYTES)
                throw new IOException();
            try (InputStream in = connection.getInputStream()) {
                String text = read(in, BrowserBlockingPolicy.MAX_LIST_BYTES, token);
                BrowserBlockingPolicy.validateList(text, title);
                return text;
            }
        } finally { connection.disconnect(); }
    }
    private String read(InputStream in, int limit, int token) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[16384];
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
        int count;
        while ((count = in.read(buffer)) != -1) {
            if (!enabled || token != epoch.get() || bytes.size() + count > limit || System.nanoTime() > deadline) throw new IOException();
            bytes.write(buffer, 0, count);
        }
        return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
    }
}
