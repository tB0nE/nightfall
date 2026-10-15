package com.godot.game;

import android.app.Activity;
import android.app.Presentation;
import android.content.Context;
import android.graphics.SurfaceTexture;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.webkit.WebView;
import android.webkit.WebChromeClient;
import android.webkit.WebViewClient;
import android.webkit.RenderProcessGoneDetail;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.FrameLayout;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/** Opt-in GPU feasibility experiment, not a general protected-video browser. */
public final class BrowserPrototype {
    private static final Handler UI = new Handler(Looper.getMainLooper());
    private static final AtomicInteger generation = new AtomicInteger();
    private static final AtomicBoolean frame = new AtomicBoolean();
    // 0 closed, 1 opening, 2 rendering, -1 failed. Read from Godot's thread.
    private static volatile int state;
    private static VirtualDisplay display;
    private static Presentation presentation;
    private static Surface surface;
    private static SurfaceTexture texture;
    private static WebView web;
    private static LinearLayout root;
    private static FrameLayout content;
    private static View customView;
    private static WebChromeClient.CustomViewCallback customViewCallback;
    private static View navigationBar;
    private static long downTime;

    private BrowserPrototype() {}

    public static void open(Activity activity, Surface target, SurfaceTexture source, int width, int height) {
        final int token = generation.incrementAndGet();
        state = 1;
        UI.post(() -> {
            if (token != generation.get()) { target.release(); return; }
            dispose();
            surface = target;
            texture = source;
            try {
                if (activity == null || activity.isFinishing()) throw new IllegalStateException("No activity");
                texture.setOnFrameAvailableListener(st -> {
                    if (token == generation.get()) frame.set(true);
                }, UI);
                DisplayManager manager = (DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
                display = manager.createVirtualDisplay("Nightfall browser prototype", width, height, 160,
                        surface, DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
                                | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION);
                if (display == null) throw new IllegalStateException("No virtual display");
                presentation = new Presentation(activity, display.getDisplay());
                presentation.getWindow().addFlags(WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED);
                root = new LinearLayout(presentation.getContext());
                root.setOrientation(LinearLayout.VERTICAL);
                LinearLayout bar = new LinearLayout(presentation.getContext());
                navigationBar = bar;
                EditText address = new EditText(presentation.getContext());
                address.setSingleLine(true);
                address.setShowSoftInputOnFocus(false);
                address.setText("https://www.youtube.com");
                bar.addView(address, new LinearLayout.LayoutParams(0, 64, 1));
                Button go = new Button(presentation.getContext());
                go.setText("Go");
                go.setOnClickListener(v -> {
                    String url = address.getText().toString().trim();
                    if (!url.contains(":")) url = "https://" + url;
                    if (allowed(url)) web.loadUrl(url);
                });
                bar.addView(go);
                Button back = new Button(presentation.getContext());
                back.setText("Back");
                back.setOnClickListener(v -> { if (customView != null) hideCustomView(); else if (web.canGoBack()) web.goBack(); });
                bar.addView(back);
                Button exit = new Button(presentation.getContext());
                exit.setText("Close browser");
                exit.setOnClickListener(v -> close());
                bar.addView(exit);
                root.addView(bar);
                web = new WebView(presentation.getContext());
                web.getSettings().setJavaScriptEnabled(true);
                web.getSettings().setDomStorageEnabled(true);
                web.getSettings().setAllowFileAccess(false);
                web.getSettings().setAllowContentAccess(false);
                web.setWebChromeClient(new WebChromeClient() {
                    @Override public void onShowCustomView(View view, CustomViewCallback callback) {
                        if (token != generation.get() || content == null || customView != null) {
                            callback.onCustomViewHidden();
                            return;
                        }
                        // Keep Chromium's video view on our GPU virtual display,
                        // never in a separate Activity/OS window outside AI capture.
                        customView = view;
                        customViewCallback = callback;
                        web.setVisibility(View.GONE);
                        navigationBar.setVisibility(View.GONE);
                        content.addView(view, new FrameLayout.LayoutParams(-1, -1));
                        view.requestFocus();
                        DiagnosticLog.info("BrowserPrototype", "Video fullscreen entered");
                    }
                    @Override public void onHideCustomView() {
                        if (token == generation.get()) hideCustomView();
                    }
                });
                web.setWebViewClient(new WebViewClient() {
                    @Override public boolean shouldOverrideUrlLoading(WebView view, android.webkit.WebResourceRequest request) {
                        return !allowed(request.getUrl().toString());
                    }
                    @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                        // A destroyed/replaced WebView may report its crash
                        // late. Never let it dispose the newer browser.
                        if (token != generation.get() || view != web) return true;
                        DiagnosticLog.info("BrowserPrototype", "Renderer lost; crashed=" + detail.didCrash());
                        generation.incrementAndGet();
                        dispose();
                        state = -1;
                        return true;
                    }
                });
                content = new FrameLayout(presentation.getContext());
                content.addView(web, new FrameLayout.LayoutParams(-1, -1));
                root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
                presentation.setContentView(root);
                presentation.show();
                presentation.getWindow().setLayout(-1, -1);
                web.loadDataWithBaseURL("https://nightfall.invalid/", "<html><meta name='viewport' content='width=device-width'><body style='background:#182438;color:white;font:32px sans-serif'><h1>Nightfall browser GPU test</h1><p>No PC connection required. Use the address bar above to open a website.</p><button style='font-size:32px' onclick='this.innerText=\"Clicked!\"'>Test click</button><p><input placeholder='Test keyboard' style='font-size:32px'></p><div style='height:1600px;background:linear-gradient(#276ab0,#253)'>Scroll test</div></body></html>", "text/html", "UTF-8", null);
                state = 2;
                DiagnosticLog.info("BrowserPrototype", "GPU virtual display opened " + width + "x" + height);
            } catch (RuntimeException | LinkageError e) {
                dispose();
                state = -1;
                DiagnosticLog.error("BrowserPrototype", "GPU display creation failed", e);
            }
        });
    }

    private static boolean allowed(String url) {
        android.net.Uri uri = android.net.Uri.parse(url);
        return "https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme());
    }

    public static int poll() { return state; }
    public static boolean consumeFrame() { return frame.getAndSet(false); }

    public static void close() {
        final int token = generation.incrementAndGet();
        state = 0;
        UI.post(() -> { if (token == generation.get()) dispose(); });
    }

    private static void dispose() {
        frame.set(false);
        if (texture != null) { texture.setOnFrameAvailableListener(null); texture = null; }
        hideCustomView();
        if (web != null) {
            web.stopLoading();
            // Detach before destroy: the presentation must never draw a
            // destroyed WebView while its virtual display is being retired.
            if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
            web.destroy();
            web = null;
        }
        if (presentation != null) { presentation.dismiss(); presentation = null; }
        root = null;
        content = null;
        navigationBar = null;
        if (display != null) { display.release(); display = null; }
        if (surface != null) { surface.release(); surface = null; }
    }

    private static void hideCustomView() {
        View previous = customView;
        WebChromeClient.CustomViewCallback callback = customViewCallback;
        customView = null;
        customViewCallback = null;
        if (previous != null && previous.getParent() instanceof ViewGroup) {
            ((ViewGroup) previous.getParent()).removeView(previous);
        }
        if (web != null) web.setVisibility(View.VISIBLE);
        if (navigationBar != null) navigationBar.setVisibility(View.VISIBLE);
        if (callback != null) callback.onCustomViewHidden();
        if (previous != null) DiagnosticLog.info("BrowserPrototype", "Video fullscreen exited");
    }

    public static void pointer(float x, float y, int action) {
        final int token = generation.get();
        UI.post(() -> {
            if (token != generation.get() || root == null || state != 2) return;
            long now = SystemClock.uptimeMillis();
            if (action == MotionEvent.ACTION_DOWN) downTime = now;
            MotionEvent event = MotionEvent.obtain(downTime, now, action, x, y, 0);
            if (action == MotionEvent.ACTION_HOVER_MOVE) {
                event.setSource(android.view.InputDevice.SOURCE_MOUSE);
                root.dispatchGenericMotionEvent(event);
            } else {
                root.dispatchTouchEvent(event);
            }
            event.recycle();
        });
    }

    public static void key(int code, boolean pressed, int modifiers) {
        final int token = generation.get();
        UI.post(() -> {
            if (token != generation.get() || root == null || state != 2) return;
            if (pressed && customView != null && (code == android.view.KeyEvent.KEYCODE_ESCAPE
                    || code == android.view.KeyEvent.KEYCODE_BACK)) {
                hideCustomView();
                return;
            }
            android.view.View focus = root.findFocus();
            if (focus == null) return;
            long now = SystemClock.uptimeMillis();
            focus.dispatchKeyEvent(new android.view.KeyEvent(now, now, pressed ? 0 : 1,
                    code, 0, modifiers));
        });
    }

    public static void pause(boolean paused) {
        final int token = generation.get();
        UI.post(() -> { if (token == generation.get() && web != null) { if (paused) web.onPause(); else web.onResume(); } });
    }
}
