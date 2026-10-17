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
import android.view.Gravity;
import android.view.inputmethod.EditorInfo;
import android.webkit.WebView;
import android.webkit.WebChromeClient;
import android.webkit.WebViewClient;
import android.webkit.RenderProcessGoneDetail;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.ScrollView;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Bitmap;
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
    private static EditText address;
    private static Button backButton, forwardButton, reloadButton, fullscreenExit;
    private static TextView pageStatus;
    private static boolean loading;
    private static Runnable fullscreenHide;
    private static boolean editingAddress;
    private static long fullscreenHoverStart, fullscreenLastHover;
    private static SharedPreferences browserPreferences;
    private static BrowserBookmarks bookmarks;
    private static View bookmarkPanel;
    private static boolean bookmarkLoadFailed;
    private static BrowserAdblock blocker;
    private static View blockingPanel;
    private static int navigationGeneration;
    private static BrowserHistory history;
    private static View privacyPanel;
    private static boolean saveHistory, historyLoadFailed, mainFrameFailed;
    private static int skipHistoryNavigation = -1;
    private static boolean dataClearing, clearingCookies, clearBackHistoryAfterHome;
    private static String pendingClear, completionNotice;
    private static String pageNotice;
    private static long downTime;
    private static boolean paused, gamepadInputEnabled = true;
    private static String questPad;
    private static long questPadTime;
    private static final java.util.Map<Long, android.view.KeyEvent> padKeys = new java.util.HashMap<>();
    private static final java.util.Map<Integer, MotionEvent> padMotions = new java.util.HashMap<>();
    private static boolean questBridgeReady;
    private static final BrowserPageTabs pageTabs = new BrowserPageTabs();
    private static final java.util.Map<Integer, android.os.Bundle> pageHistory = new java.util.HashMap<>();
    private static Activity ownerActivity;
    private static volatile String pageSnapshot = "{\"selected\":0,\"pages\":[]}";
    private static BrowserPhysicalGamepad physicalPad;
    private static final java.util.Set<String> padRouteDiagnostics = new java.util.HashSet<>();
    private static android.hardware.input.InputManager padInputManager;
    private static final android.hardware.input.InputManager.InputDeviceListener padDevices = new android.hardware.input.InputManager.InputDeviceListener() {
        public void onInputDeviceAdded(int id) {}
        public void onInputDeviceChanged(int id) { releasePhysicalGamepad(); }
        public void onInputDeviceRemoved(int id) { releasePhysicalGamepad(); }
    };

    private BrowserPrototype() {}

    public static void open(Activity activity, Surface target, SurfaceTexture source, int width, int height) {
        final int token = generation.incrementAndGet();
        state = 1;
        UI.post(() -> {
            if (token != generation.get()) { target.release(); return; }
            if (clearingCookies) {
                target.release();
                state = -1;
                DiagnosticLog.info("BrowserPrototype", "Open deferred: cookie cleanup still running");
                return;
            }
            dispose();
            surface = target;
            texture = source;
            try {
                if (activity == null || activity.isFinishing()) throw new IllegalStateException("No activity");
                browserPreferences = activity.getApplicationContext().getSharedPreferences("nightfall_browser", Context.MODE_PRIVATE);
                blocker = BrowserAdblock.get(activity);
                saveHistory = browserPreferences.getBoolean("save_history", false);
                historyLoadFailed = false;
                try { history = BrowserHistory.decode(browserPreferences.getString("history_v1", "")); }
                catch (IllegalArgumentException corrupt) { history = new BrowserHistory(); historyLoadFailed = true; }
                bookmarkLoadFailed = false;
                try { bookmarks = BrowserBookmarks.decode(browserPreferences.getString("bookmarks_v1", "")); }
                catch (IllegalArgumentException corrupt) {
                    bookmarks = new BrowserBookmarks();
                    bookmarkLoadFailed = true;
                }
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
                LinearLayout chrome = new LinearLayout(presentation.getContext());
                chrome.setOrientation(LinearLayout.VERTICAL);
                chrome.setBackgroundColor(Color.rgb(24, 32, 45));
                navigationBar = chrome;
                LinearLayout bar = new LinearLayout(presentation.getContext());
                chrome.addView(bar);
                backButton = button(bar, "Back", () -> { hidePrivacyPanel(); hideBlockingPanel(); hideBookmarks(false); if (web.canGoBack()) web.goBack(); });
                forwardButton = button(bar, "Forward", () -> { hidePrivacyPanel(); hideBlockingPanel(); hideBookmarks(false); if (web.canGoForward()) web.goForward(); });
                reloadButton = button(bar, "Reload", () -> {
                    hidePrivacyPanel();
                    hideBlockingPanel();
                    hideBookmarks(false);
                    if (loading) { web.stopLoading(); loading = false; updateNavigation(); }
                    else if (BrowserNavigation.HOME_URL.equals(web.getUrl())) loadHome();
                    else web.reload();
                });
                button(bar, "Home", () -> loadHome());
                button(bar, "Bookmarks", () -> showBookmarks(null));
                button(bar, "Blocking", () -> showBlocking());
                button(bar, "Privacy", () -> showPrivacy());
                address = new EditText(presentation.getContext());
                address.setSingleLine(true);
                address.setShowSoftInputOnFocus(false);
                address.setSelectAllOnFocus(true);
                address.setTextColor(Color.WHITE);
                address.setHintTextColor(Color.LTGRAY);
                address.setTextSize(20);
                address.setHint("Address or search DuckDuckGo");
                address.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
                address.setImeOptions(EditorInfo.IME_ACTION_GO);
                address.setOnEditorActionListener((v, action, event) -> {
                    if (action == EditorInfo.IME_ACTION_GO || (event != null
                            && event.getKeyCode() == android.view.KeyEvent.KEYCODE_ENTER)) {
                        if (event == null || event.getAction() == android.view.KeyEvent.ACTION_DOWN) navigateAddress();
                        return true;
                    }
                    return false;
                });
                bar.addView(address, new LinearLayout.LayoutParams(0, 64, 1));
                button(bar, "Go", () -> navigateAddress());
                button(bar, "Close", () -> close());
                pageStatus = new TextView(presentation.getContext());
                pageStatus.setTextColor(Color.LTGRAY);
                pageStatus.setTextSize(16);
                pageStatus.setSingleLine(true);
                pageStatus.setPadding(16, 2, 16, 6);
                chrome.addView(pageStatus);
                root.addView(chrome);
                // Navigation is painted above the screen by the existing
                // corner-controls atlas. Keep its native editing/model state,
                // but devote every captured pixel to web content.
                chrome.setVisibility(View.GONE);
                createPageWebView(activity, token);
                ownerActivity = activity;
                pageTabs.add();
                publishPages();
                content = new FrameLayout(presentation.getContext());
                content.addView(web, new FrameLayout.LayoutParams(-1, -1));
                root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
                presentation.setContentView(root);
                presentation.show();
                presentation.getWindow().setLayout(-1, -1);
                loadHome();
                state = 2;
                DiagnosticLog.info("BrowserPrototype", "GPU virtual display opened " + width + "x" + height);
            } catch (RuntimeException | LinkageError e) {
                dispose();
                state = -1;
                DiagnosticLog.error("BrowserPrototype", "GPU display creation failed", e);
            }
        });
    }

    public static String tabs() { return pageSnapshot; }

    private static void publishPages() {
        BrowserPageTabs.Page selected = pageTabs.find(pageTabs.selected);
        if (selected != null && web != null && web.getTitle() != null) {
            String title = web.getTitle().replaceAll("[\\p{Cntrl}]", " ");
            selected.title = title.substring(0, Math.min(title.length(), 120));
        }
        try {
            org.json.JSONArray entries = new org.json.JSONArray();
            for (BrowserPageTabs.Page page : pageTabs.pages)
                entries.put(new org.json.JSONObject().put("id", page.id).put("title", page.title));
            org.json.JSONObject navigation = new org.json.JSONObject()
                    .put("address", address == null ? "" : address.getText().toString())
                    .put("back", web != null && web.canGoBack())
                    .put("forward", web != null && web.canGoForward())
                    .put("editing", editingAddress)
                    .put("loading", loading);
            pageSnapshot = new org.json.JSONObject().put("selected", pageTabs.selected)
                    .put("pages", entries).put("navigation", navigation).toString();
        } catch (org.json.JSONException failure) { DiagnosticLog.info("BrowserPrototype", "Tab metadata unavailable"); }
    }

    // Only one WebView is alive. Suspended tabs keep back/forward state in RAM,
    // not live video, audio or game contexts. Returning to a tab may reload it.
    private static void retirePage(boolean save) {
        hideCustomView(); hidePrivacyPanel(); hideBlockingPanel(); hideBookmarks(false);
        releasePhysicalGamepad(); questPad = null;
        if (web == null) return;
        publishPages();
        if (save && pageTabs.selected != 0) {
            android.os.Bundle saved = new android.os.Bundle();
            if (web.saveState(saved) != null) {
                saved.putString("nightfall_current_url", web.getUrl());
                pageHistory.put(pageTabs.selected, saved);
            }
        }
        navigationGeneration++;
        pageNotice = null;
        web.stopLoading();
        if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
        WebView outgoing = web;
        web = null; // Invalidate callbacks before destroy can report a renderer loss.
        outgoing.destroy();
    }
    private static void resumePage(int token) {
        boolean inputEnabled = gamepadInputEnabled;
        createPageWebView(ownerActivity, token);
        gamepadInputEnabled = inputEnabled;
        content.addView(web, new FrameLayout.LayoutParams(-1, -1));
        android.os.Bundle saved = pageHistory.get(pageTabs.selected);
        String url = saved == null ? null : saved.getString("nightfall_current_url");
        if (BrowserGamepadProbe.URL.equals(url)) navigateTo(url);
        else if (saved != null && saved.getBoolean("nightfall_url_only") && BrowserNavigation.allowed(url)
                && !BrowserNavigation.HOME_URL.equals(url)) navigateTo(url);
        else if (saved == null || BrowserNavigation.HOME_URL.equals(url) || web.restoreState(saved) == null) loadHome();
        else {
            blocker.page(web.getUrl());
            address.clearFocus(); web.requestFocus();
            updateNavigation();
        }
        publishPages();
    }
    public static void tabAction(String action, int id) {
        int token = generation.get();
        UI.post(() -> {
            if (token != generation.get() || web == null || dataClearing || paused || ownerActivity == null) return;
            if ("select".equals(action) && (pageTabs.find(id) == null || pageTabs.selected == id)) return;
            if ("close".equals(action) && pageTabs.find(id) == null) return;
            if ("new".equals(action) && pageTabs.pages.size() >= BrowserPageTabs.LIMIT) {
                pageStatus.setText("Browser tab limit reached (8)."); return;
            }
            try {
                if ("new".equals(action)) { retirePage(true); pageTabs.add(); resumePage(token); }
                else if ("select".equals(action)) { retirePage(true); pageTabs.select(id); resumePage(token); }
                else if ("close".equals(action)) {
                    boolean current = pageTabs.selected == id;
                    if (current) retirePage(false);
                    pageHistory.remove(id); pageTabs.remove(id);
                    if (pageTabs.pages.isEmpty()) close();
                    else if (current) resumePage(token);
                }
                publishPages();
                DiagnosticLog.info("BrowserPrototype", "Tab action=" + action + " count=" + pageTabs.pages.size() + " selected=" + pageTabs.selected);
            } catch (RuntimeException | LinkageError failure) {
                DiagnosticLog.error("BrowserPrototype", "Tab change failed; closing browser safely", failure);
                close();
            }
        });
    }

    public static void navigationAction(String action) {
        final int token = generation.get();
        UI.post(() -> {
            if (token != generation.get() || web == null || state != 2 || paused || dataClearing) return;
            if ("address".equals(action)) {
                hidePrivacyPanel(); hideBlockingPanel(); hideBookmarks(false);
                editingAddress = true;
                releasePhysicalGamepad(); questPad = null;
                address.selectAll();
            } else {
                editingAddress = false;
                if ("back".equals(action)) { hideCustomView(); hidePrivacyPanel(); hideBlockingPanel(); hideBookmarks(false); if (web.canGoBack()) web.goBack(); }
                else if ("forward".equals(action)) { hideCustomView(); hidePrivacyPanel(); hideBlockingPanel(); hideBookmarks(false); if (web.canGoForward()) web.goForward(); }
                else if ("reload".equals(action)) {
                    if (loading) { web.stopLoading(); loading = false; }
                    else if (BrowserNavigation.HOME_URL.equals(web.getUrl())) loadHome();
                    else web.reload();
                }
                else if ("home".equals(action)) loadHome();
                else if ("go".equals(action)) navigateAddress();
                else if ("bookmarks".equals(action)) showBookmarks(null);
                else if ("blocking".equals(action)) showBlocking();
                else if ("privacy".equals(action)) showPrivacy();
            }
            updateNavigation(); publishPages();
        });
    }

    private static void createPageWebView(Activity activity, int token) {
    web = new WebView(presentation.getContext());
    final WebView pageView = web;
    web.getSettings().setJavaScriptEnabled(true);
    web.getSettings().setDomStorageEnabled(true);
    web.getSettings().setAllowFileAccess(false);
    web.getSettings().setAllowContentAccess(false);
    web.getSettings().setJavaScriptCanOpenWindowsAutomatically(false);
    web.getSettings().setGeolocationEnabled(false);
    installQuestGamepadBridge();
    web.setOnFocusChangeListener((view, focused) -> {
        if (!focused) { releasePhysicalGamepad(); questPad = null; }
    });
    if (padInputManager == null) {
        padInputManager = (android.hardware.input.InputManager) activity.getSystemService(Context.INPUT_SERVICE);
        if (padInputManager != null) padInputManager.registerInputDeviceListener(padDevices, UI);
    }
    web.setDownloadListener((url, agent, disposition, mime, length) ->
            siteNotice(token, "Downloads are not supported yet. No file was downloaded."));
    web.setWebChromeClient(new WebChromeClient() {
        @Override public void onPermissionRequest(android.webkit.PermissionRequest request) {
            UI.post(() -> {
                try { request.deny(); } catch (IllegalStateException cancelled) { return; }
                siteNotice(token, "Camera/microphone and other protected site permissions are not supported yet; request denied.");
            });
        }
        @Override public void onGeolocationPermissionsShowPrompt(String origin,
                android.webkit.GeolocationPermissions.Callback callback) {
            callback.invoke(origin, false, false);
            siteNotice(token, "Location access is disabled.");
        }
        @Override public boolean onShowFileChooser(WebView view,
                android.webkit.ValueCallback<android.net.Uri[]> callback, FileChooserParams parameters) {
            callback.onReceiveValue(null);
            siteNotice(token, "File uploads are not supported yet; no file access was granted.");
            return true;
        }
        @Override public void onProgressChanged(WebView view, int progress) {
            if (token != generation.get() || view != web) return;
            if (loading && progress < 100) setPageStatus("Loading " + progress + "%");
            updateNavigation();
        }
        @Override public void onReceivedTitle(WebView view, String title) {
            if (token == generation.get() && view == web && !loading) setPageStatus(title);
            if (token == generation.get() && view == web) publishPages();
        }
        @Override public void onShowCustomView(View view, CustomViewCallback callback) {
            if (token != generation.get() || pageView != web || content == null || customView != null) {
                callback.onCustomViewHidden();
                return;
            }
            hideBookmarks(false);
            hidePrivacyPanel();
            hideBlockingPanel();
            editingAddress = false;
            // Keep Chromium's video view on our GPU virtual display,
            // never in a separate Activity/OS window outside AI capture.
            customView = view;
            customViewCallback = callback;
            web.setVisibility(View.GONE);
            navigationBar.setVisibility(View.GONE);
            content.addView(view, new FrameLayout.LayoutParams(-1, -1));
            fullscreenExit = new Button(presentation.getContext());
            fullscreenExit.setText("Exit fullscreen");
            fullscreenExit.setAlpha(0.8f);
            fullscreenExit.setOnClickListener(v -> hideCustomView());
            FrameLayout.LayoutParams exitParams = new FrameLayout.LayoutParams(-2, 64, Gravity.TOP | Gravity.RIGHT);
            content.addView(fullscreenExit, exitParams);
            revealFullscreenExit();
            view.requestFocus();
            DiagnosticLog.info("BrowserPrototype", "Video fullscreen entered");
        }
        @Override public void onHideCustomView() {
            if (token == generation.get() && pageView == web) hideCustomView();
        }
    });
    web.setWebViewClient(new WebViewClient() {
        @Override public android.webkit.WebResourceResponse shouldInterceptRequest(WebView view,
                android.webkit.WebResourceRequest request) {
            if (token != generation.get()) return null;
            return blocker.intercept(request, false);
        }
        @Override public boolean shouldOverrideUrlLoading(WebView view, android.webkit.WebResourceRequest request) {
            if (token != generation.get() || view != web) return true;
            String destination = request.getUrl().toString();
            if (dataClearing) return true;
            if (request.isForMainFrame() && BrowserGamepadProbe.URL.equals(destination)) {
                navigateTo(destination);
                return true;
            }
            if (!BrowserNavigation.allowed(destination)) {
                if (request.isForMainFrame()) siteNotice(token, "This link requires an unsupported scheme or external app. Nothing was opened.");
                return true;
            }
            if (request.isForMainFrame()) blocker.page(destination);
            return false;
        }
        @Override public void onPageStarted(WebView view, String url, Bitmap icon) {
            if (token != generation.get() || view != web) return;
            navigationGeneration++;
            pageNotice = null;
            mainFrameFailed = false;
            blocker.page(url);
            loading = true;
            updateNavigation();
        }
        @Override public void onPageFinished(WebView view, String url) {
            if (token != generation.get() || view != web) return;
            loading = false;
            if (dataClearing && pendingClear != null && "about:blank".equals(url)) {
                performDataClear(token);
                return;
            }
            if (!dataClearing && saveHistory && !mainFrameFailed && navigationGeneration != skipHistoryNavigation
                    && BrowserHistory.address(url) != null) {
                history.visit(view.getTitle(), url, System.currentTimeMillis());
                browserPreferences.edit().putString("history_v1", history.encode()).apply();
                historyLoadFailed = false;
            }
            if (clearBackHistoryAfterHome && BrowserNavigation.HOME_URL.equals(url)) {
                web.clearHistory();
                clearBackHistoryAfterHome = false;
            }
            setPageStatus(view.getTitle());
            if (completionNotice != null && BrowserNavigation.HOME_URL.equals(url)) {
                pageStatus.setText(completionNotice);
                completionNotice = null;
            }
            updateNavigation();
            applyCosmetics(view, url, token, navigationGeneration);
            publishPages();
        }
        @Override public void doUpdateVisitedHistory(WebView view, String url, boolean reload) {
            if (token == generation.get() && view == web) updateNavigation();
        }
        @Override public void onReceivedError(WebView view, android.webkit.WebResourceRequest request,
                android.webkit.WebResourceError error) {
            if (token != generation.get() || view != web || !request.isForMainFrame()) return;
            loading = false;
            mainFrameFailed = true;
            updateNavigation();
            pageStatus.setText("Page could not load. Check the address or connection, then Reload.");
        }
        @Override public void onReceivedHttpError(WebView view, android.webkit.WebResourceRequest request,
                android.webkit.WebResourceResponse response) {
            if (token == generation.get() && view == web && request.isForMainFrame()) mainFrameFailed = true;
        }
        @Override public void onReceivedSslError(WebView view, android.webkit.SslErrorHandler handler,
                android.net.http.SslError error) {
            handler.cancel();
            if (token == generation.get() && view == web) {
                mainFrameFailed = true;
                siteNotice(token, "Secure connection failed. The certificate was rejected; no bypass is available.");
            }
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
    }

    private static Button button(LinearLayout bar, String label, Runnable action) {
        Button button = new Button(bar.getContext());
        button.setText(label);
        button.setTextSize(18);
        final int token = generation.get();
        button.setOnClickListener(v -> { if (token == generation.get() && !dataClearing) action.run(); });
        bar.addView(button, new LinearLayout.LayoutParams(-2, 64));
        return button;
    }

    private static void navigateAddress() {
        hidePrivacyPanel();
        String destination = BrowserNavigation.destination(address.getText().toString());
        if (destination == null) {
            pageStatus.setText("Enter an HTTP(S) address or search text; other link types are not supported.");
            return;
        }
        editingAddress = false;
        address.clearFocus();
        hideBlockingPanel();
        hideBookmarks(false);
        web.requestFocus();
        if (BrowserNavigation.HOME_URL.equals(destination)) loadHome();
        else navigateTo(destination);
    }

    private static void navigateTo(String url) {
        blocker.page(url);
        if (BrowserGamepadProbe.URL.equals(url)) {
            web.loadDataWithBaseURL(url, BrowserGamepadProbe.html(), "text/html", "UTF-8", url);
            web.requestFocus();
            return;
        }
        web.loadUrl(url);
    }

    private static void loadHome() {
        hidePrivacyPanel();
        blocker.page(BrowserNavigation.HOME_URL);
        hideCustomView();
        hideBlockingPanel();
        hideBookmarks(false);
        address.clearFocus();
        address.setText("");
        web.loadDataWithBaseURL(BrowserNavigation.HOME_URL,
                "<!doctype html><html><head><meta name='viewport' content='width=device-width'>"
                + "<title>Nightfall Home</title><style>body{background:#182438;color:#edf2ff;font:26px sans-serif;"
                + "padding:48px}a{display:inline-block;background:#294b76;color:white;padding:26px 38px;"
                + "border-radius:16px;margin:12px;text-decoration:none}p{color:#b6c5da}</style></head>"
                + "<body><h1>Nightfall Browser</h1><p>Browse and watch in 3D. No PC required.</p>"
                + "<a href='https://www.youtube.com/'>YouTube</a>"
                + "<a href='https://www.xbox.com/play'>Xbox Cloud Gaming</a>"
                + "<a href='" + BrowserGamepadProbe.URL + "'>Gamepad diagnostic</a>"
                + "<h2>Your bookmarks</h2>" + bookmarks.homeLinks()
                + (bookmarks.entries().isEmpty() ? "<p>Use Bookmarks above to save your favourite sites.</p>" : "")
                + (bookmarkLoadFailed ? "<p>Saved bookmarks could not be read. They have not been overwritten.</p>" : "")
                + "<p>Enter a website or search with DuckDuckGo using the address bar above.</p>"
                + "<p>Enable AI 3D in Nightfall's menu. Xbox compatibility is experimental.</p>"
                + "</body></html>", "text/html", "UTF-8", BrowserNavigation.HOME_URL);
        web.requestFocus();
        updateNavigation();
    }

    private static void persistBookmarks() {
        // SharedPreferences writes one versioned snapshot atomically off the UI
        // thread. Preserve unreadable data privately before explicit replacement.
        SharedPreferences.Editor edit = browserPreferences.edit();
        if (bookmarkLoadFailed) {
            edit.putString("bookmarks_recovery_v1", browserPreferences.getString("bookmarks_v1", ""));
            bookmarkLoadFailed = false;
        }
        edit.putString("bookmarks_v1", bookmarks.encode()).apply();
    }

    private static EditText bookmarkInput(LinearLayout parent, String hint, String value) {
        EditText input = new EditText(parent.getContext());
        input.setSingleLine(true);
        input.setShowSoftInputOnFocus(false);
        input.setSelectAllOnFocus(true);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(Color.LTGRAY);
        input.setHint(hint);
        input.setText(value);
        parent.addView(input, new LinearLayout.LayoutParams(-1, 64));
        return input;
    }

    private static void showBookmarks(BrowserBookmarks.Entry selected) {
        releasePhysicalGamepad();
        questPad = null;
        hidePrivacyPanel();
        hideCustomView();
        hideBlockingPanel();
        hideBookmarks(false);
        web.setVisibility(View.GONE);
        ScrollView scroll = new ScrollView(content.getContext());
        scroll.setBackgroundColor(Color.rgb(24, 36, 56));
        scroll.setFillViewport(true);
        LinearLayout panel = new LinearLayout(content.getContext());
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(24, 16, 24, 24);
        scroll.addView(panel);
        bookmarkPanel = scroll;
        content.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        TextView heading = new TextView(panel.getContext());
        heading.setText("Bookmarks — stored only on this headset");
        heading.setTextColor(Color.WHITE);
        heading.setTextSize(24);
        panel.addView(heading);
        String current = web.getUrl();
        if (!BrowserNavigation.allowed(current) || BrowserNavigation.HOME_URL.equals(current)) current = "";
        EditText name = bookmarkInput(panel, "Bookmark name", selected == null ? web.getTitle() : selected.title);
        name.setFilters(new android.text.InputFilter[] { new android.text.InputFilter.LengthFilter(120) });
        EditText url = bookmarkInput(panel, "https://example.com", selected == null ? current : selected.url);
        url.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        TextView message = new TextView(panel.getContext());
        message.setTextColor(Color.LTGRAY);
        message.setTextSize(18);
        message.setText(bookmarkLoadFailed
                ? "Saved data could not be read. Saving will keep a private recovery copy before replacing it."
                : "Check the address before saving: links can contain private login tokens. Nothing is sent to your PC.");
        panel.addView(message);
        LinearLayout actions = new LinearLayout(panel.getContext());
        panel.addView(actions);
        button(actions, "Save", () -> {
            try {
                String destination = BrowserNavigation.destination(url.getText().toString());
                // A bookmark is an explicit website, not an accidental search.
                String raw = url.getText().toString().trim();
                if (destination == null || !(BrowserNavigation.allowed(raw)
                        || BrowserNavigation.allowed("https://" + raw)))
                    throw new IllegalArgumentException("Enter an HTTP(S) website address, not search text.");
                bookmarks.save(selected == null ? null : selected.url, name.getText().toString(), destination);
                persistBookmarks();
                showBookmarks(null);
                pageStatus.setText("Bookmark saved");
            } catch (IllegalArgumentException invalid) { message.setText(invalid.getMessage()); }
        });
        if (selected != null) {
            Button remove = button(actions, "Remove", () -> {});
            remove.setOnClickListener(v -> {
                if (!"Confirm remove".contentEquals(remove.getText())) {
                    remove.setText("Confirm remove");
                    message.setText("Press Confirm remove to delete this bookmark, or Close to cancel.");
                } else {
                    bookmarks.remove(selected.url);
                    persistBookmarks();
                    showBookmarks(null);
                }
            });
        }
        button(actions, "Close bookmarks", () -> hideBookmarks(true));
        int index = 0;
        for (BrowserBookmarks.Entry entry : bookmarks.entries()) {
            LinearLayout row = new LinearLayout(panel.getContext());
            panel.addView(row);
            TextView label = new TextView(panel.getContext());
            label.setText(entry.title);
            label.setSingleLine(true);
            label.setTextColor(Color.WHITE);
            label.setTextSize(20);
            row.addView(label, new LinearLayout.LayoutParams(0, 64, 1));
            button(row, "Open", () -> { hideBookmarks(false); navigateTo(entry.url); web.requestFocus(); });
            button(row, "Edit", () -> showBookmarks(entry));
            Button up = button(row, "Up", () -> { bookmarks.move(entry.url, -1); persistBookmarks(); showBookmarks(null); });
            Button down = button(row, "Down", () -> { bookmarks.move(entry.url, 1); persistBookmarks(); showBookmarks(null); });
            up.setEnabled(index > 0);
            down.setEnabled(index < bookmarks.entries().size() - 1);
            index++;
        }
    }

    private static void showBlocking() {
        releasePhysicalGamepad();
        questPad = null;
        hidePrivacyPanel();
        hideCustomView();
        hideBookmarks(false);
        hideBlockingPanel();
        web.setVisibility(View.GONE);
        ScrollView scroll = new ScrollView(content.getContext());
        scroll.setBackgroundColor(Color.rgb(24, 36, 56));
        LinearLayout panel = new LinearLayout(content.getContext());
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(24, 24, 24, 24);
        scroll.addView(panel);
        blockingPanel = scroll;
        content.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        TextView title = new TextView(panel.getContext());
        title.setText("Ad and tracker blocking · Brave adblock-rust");
        title.setTextColor(Color.WHITE);
        title.setTextSize(24);
        panel.addView(title);
        TextView status = new TextView(panel.getContext());
        status.setTextColor(Color.LTGRAY);
        status.setTextSize(20);
        panel.addView(status);
        TextView explanation = new TextView(panel.getContext());
        explanation.setText("Optional: downloads EasyList and EasyPrivacy from easylist.to when enabled without cached filters. "
                + "No Acceptable Ads subscription or browsing telemetry. Cached filters work offline. "
                + "Reload after changing settings or updating filters. Some ads may remain: WebView interception is limited, "
                + "and scriptlets, resource replacements and generic cosmetic discovery are not enabled.");
        explanation.setTextColor(Color.LTGRAY);
        explanation.setTextSize(18);
        panel.addView(explanation);
        LinearLayout actions = new LinearLayout(panel.getContext());
        panel.addView(actions);
        button(actions, blocker.enabled() ? "Turn Off" : "Turn On / load filters", () -> {
            blocker.setEnabled(!blocker.enabled());
            if (!blocker.enabled()) removeCosmetics();
            showBlocking();
        });
        String host = blocker.currentHost();
        Button site = button(actions, blocker.siteDisabled() ? "Enable for this hostname" : "Disable for this hostname", () -> {
            blocker.toggleSite();
            if (blocker.siteDisabled()) removeCosmetics();
            showBlocking();
        });
        site.setEnabled(!host.isEmpty() && !host.equals("nightfall.invalid"));
        Button update = button(actions, "Update filters", () -> { blocker.update(); showBlocking(); });
        update.setEnabled(blocker.enabled() && !blocker.busy());
        LinearLayout nextRow = new LinearLayout(panel.getContext());
        panel.addView(nextRow);
        button(nextRow, "Clear site exceptions", () -> { blocker.resetExceptions(); showBlocking(); });
        button(nextRow, "Reload page", () -> { hideBlockingPanel(); if (BrowserNavigation.HOME_URL.equals(web.getUrl())) loadHome(); else web.reload(); });
        button(nextRow, "Close", () -> hideBlockingPanel());
        final int token = generation.get();
        UI.post(new Runnable() {
            @Override public void run() {
                if (token != generation.get() || blockingPanel != scroll) return;
                status.setText(blocker.status() + (host.isEmpty() ? "" : "\nHostname: " + host
                        + (blocker.siteDisabled() ? " (excluded)" : "")));
                update.setEnabled(blocker.enabled() && !blocker.busy());
                UI.postDelayed(this, 500);
            }
        });
    }

    private static void hideBlockingPanel() {
        if (blockingPanel != null && blockingPanel.getParent() instanceof ViewGroup)
            ((ViewGroup) blockingPanel.getParent()).removeView(blockingPanel);
        blockingPanel = null;
        if (web != null) web.setVisibility(View.VISIBLE);
    }

    private static void siteNotice(int token, String message) {
        final int navigation = navigationGeneration;
        UI.post(() -> {
            if (token == generation.get() && navigation == navigationGeneration && pageStatus != null) {
                pageNotice = message;
                pageStatus.setText(message);
            }
        });
    }

    private static void setPageStatus(String message) {
        pageStatus.setText(pageNotice == null ? message : pageNotice);
        publishPages();
    }

    private static void privacyText(LinearLayout panel, String text, int size) {
        TextView label = new TextView(panel.getContext());
        label.setText(text);
        label.setTextSize(size);
        label.setTextColor(Color.LTGRAY);
        label.setPadding(0, 8, 0, 8);
        panel.addView(label);
    }

    private static void confirmAction(LinearLayout panel, String label, String description, Runnable action) {
        privacyText(panel, description, 18);
        LinearLayout row = new LinearLayout(panel.getContext());
        panel.addView(row);
        Button confirm = button(row, label, () -> {});
        final int token = generation.get();
        confirm.setOnClickListener(v -> {
            if (token != generation.get() || dataClearing) return;
            if (!confirm.isSelected()) {
                confirm.setSelected(true);
                confirm.setText("Confirm: " + label);
            } else action.run();
        });
    }

    private static void showPrivacy() {
        releasePhysicalGamepad();
        questPad = null;
        hideCustomView();
        hideBookmarks(false);
        hideBlockingPanel();
        hidePrivacyPanel();
        web.setVisibility(View.GONE);
        ScrollView scroll = new ScrollView(content.getContext());
        scroll.setBackgroundColor(Color.rgb(24, 36, 56));
        LinearLayout panel = new LinearLayout(content.getContext());
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(24, 16, 24, 24);
        scroll.addView(panel);
        privacyPanel = scroll;
        content.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        privacyText(panel, "Browser privacy, history and engine", 26);
        android.content.pm.PackageInfo provider = WebView.getCurrentWebViewPackage();
        privacyText(panel, provider == null ? "WebView provider information unavailable"
                : "System WebView: " + provider.packageName + " · " + provider.versionName, 18);
        privacyText(panel, "Not Horizon Browser and not private browsing. Cookies may keep you signed in. "
                + "History is opt-in and stored only inside Nightfall; it can still contain sensitive titles/paths. "
                + "Saved history omits URL queries and fragments, so some pages (such as individual videos) cannot be restored exactly.", 18);
        LinearLayout actions = new LinearLayout(panel.getContext());
        panel.addView(actions);
        button(actions, saveHistory ? "Save history: On" : "Save history: Off", () -> {
            saveHistory = !saveHistory;
            browserPreferences.edit().putBoolean("save_history", saveHistory).apply();
            showPrivacy();
        });
        button(actions, "Close privacy", () -> hidePrivacyPanel());
        confirmAction(panel, "Clear history", "Remove the saved visit list and this browser's Back/Forward history. "
                + "The current page, bookmarks, logins, host pairings and blocker settings are kept. "
                + "Switching Save history off stops recording but does not remove existing visits.", () -> {
            history.clear();
            historyLoadFailed = false;
            skipHistoryNavigation = navigationGeneration;
            browserPreferences.edit().remove("history_v1").apply();
            // Keep each open tab's current location, but no suspended tab may
            // resurrect its old Back/Forward history after a history clear.
            for (java.util.Map.Entry<Integer, android.os.Bundle> entry : pageHistory.entrySet()) {
                android.os.Bundle currentOnly = new android.os.Bundle();
                currentOnly.putString("nightfall_current_url", entry.getValue().getString("nightfall_current_url"));
                currentOnly.putBoolean("nightfall_url_only", true);
                entry.setValue(currentOnly);
            }
            web.clearHistory();
            updateNavigation();
            showPrivacy();
            pageStatus.setText("Saved history cleared");
        });
        confirmAction(panel, "Clear cookies + DOM storage", "Global to Nightfall's WebViews, not just this site; signs you out and returns Home. "
                + "Clears cookies and requests framework WebStorage cleanup. This older API does NOT guarantee removal of IndexedDB, "
                + "service workers or every other profile artifact. Saved history/bookmarks, blocker rules and PC pairings are kept.",
                () -> beginDataClear("cookies"));
        confirmAction(panel, "Clear web cache", "Request removal of Nightfall's WebView HTTP memory/disk cache, then return Home and reset Back/Forward history. "
                + "Cookies/logins, saved visit list, bookmarks and downloaded ad-block filter rules are kept. This does not promise to remove service-worker caches.",
                () -> beginDataClear("cache"));
        privacyText(panel, "Site permissions: camera, microphone, location and file uploads are currently disabled/denied. "
                + "External-app links and downloads are not launched automatically. No certificate-error bypass is offered.", 18);
        privacyText(panel, "Saved visits (newest first; maximum " + BrowserHistory.LIMIT + ")"
                + (historyLoadFailed ? " — saved data was unreadable; new visits will replace it" : ""), 22);
        for (BrowserHistory.Entry entry : history.entries()) {
            LinearLayout row = new LinearLayout(panel.getContext());
            panel.addView(row);
            TextView label = new TextView(panel.getContext());
            label.setText(entry.title + "\n" + entry.url + " · "
                    + java.text.DateFormat.getDateTimeInstance().format(new java.util.Date(entry.time)));
            label.setTextColor(Color.WHITE);
            label.setTextSize(18);
            row.addView(label, new LinearLayout.LayoutParams(0, -2, 1));
            button(row, "Open path", () -> { hidePrivacyPanel(); navigateTo(entry.url); web.requestFocus(); });
        }
    }

    private static void hidePrivacyPanel() {
        if (privacyPanel != null && privacyPanel.getParent() instanceof ViewGroup)
            ((ViewGroup) privacyPanel.getParent()).removeView(privacyPanel);
        privacyPanel = null;
        if (web != null) web.setVisibility(View.VISIBLE);
    }

    private static void beginDataClear(String kind) {
        releasePhysicalGamepad();
        questPad = null;
        hideCustomView();
        hidePrivacyPanel();
        hideBlockingPanel();
        hideBookmarks(false);
        dataClearing = true;
        pendingClear = kind;
        int token = generation.get();
        web.stopLoading();
        blocker.page(null);
        // Retire the active document before clearing; Home never fetches a site.
        web.loadUrl("about:blank");
        pageStatus.setText("Preparing browser data cleanup…");
        UI.postDelayed(() -> {
            if (token != generation.get() || !dataClearing) return;
            if (clearingCookies) pageStatus.setText("Cookie cleanup is still running. You can close the browser and retry later.");
            else finishDataClear(token, "Cleanup could not be confirmed; please retry.");
        }, 15000);
    }

    private static void performDataClear(int token) {
        String kind = pendingClear;
        pendingClear = null;
        try {
            if ("cache".equals(kind)) {
                web.clearCache(true);
                finishDataClear(token, "WebView HTTP cache cleanup requested.");
            } else {
                android.webkit.WebStorage.getInstance().deleteAllData();
                clearingCookies = true;
                android.webkit.CookieManager.getInstance().removeAllCookies(removed -> {
                    clearingCookies = false;
                    String notice = "Cookies cleared; supported DOM storage cleanup requested.";
                    try { android.webkit.CookieManager.getInstance().flush(); }
                    catch (RuntimeException failure) { notice = "Cookie removal completed, but persistence could not be confirmed."; }
                    if (token == generation.get() && dataClearing)
                        finishDataClear(token, notice);
                });
            }
        } catch (RuntimeException failure) {
            clearingCookies = false;
            finishDataClear(token, "Browser cleanup failed or was incomplete; please retry.");
        }
    }

    private static void finishDataClear(int token, String notice) {
        if (token != generation.get() || web == null) return;
        dataClearing = false;
        pendingClear = null;
        clearBackHistoryAfterHome = true;
        completionNotice = notice;
        loadHome();
        pageStatus.setText(notice);
    }

    private static void removeCosmetics() {
        if (web != null) web.evaluateJavascript("document.getElementById('nightfall-blocking-css')?.remove()", null);
    }

    private static void applyCosmetics(WebView target, String url, int token, int navigation) {
        blocker.cosmeticCss(url, css -> UI.post(() -> {
            if (token != generation.get() || target != web || navigation != navigationGeneration
                    || !url.equals(web.getUrl()) || !blocker.enabled() || blocker.siteDisabled()) return;
            // Only local fixed code plus a JSON-quoted CSS string; never execute
            // scriptlets or arbitrary JavaScript from downloaded filter lists.
            web.evaluateJavascript("(()=>{let s=document.getElementById('nightfall-blocking-css');"
                    + "if(!s){s=document.createElement('style');s.id='nightfall-blocking-css';"
                    + "(document.head||document.documentElement).appendChild(s);}s.textContent="
                    + org.json.JSONObject.quote(css) + ";})()", null);
        }));
    }

    private static void hideBookmarks(boolean refreshHome) {
        if (bookmarkPanel != null && bookmarkPanel.getParent() instanceof ViewGroup)
            ((ViewGroup) bookmarkPanel.getParent()).removeView(bookmarkPanel);
        bookmarkPanel = null;
        if (web != null) {
            web.setVisibility(View.VISIBLE);
            if (refreshHome && BrowserNavigation.HOME_URL.equals(web.getUrl())) loadHome();
            else web.requestFocus();
        }
    }

    private static void updateNavigation() {
        if (web == null || address == null) return;
        backButton.setEnabled(web.canGoBack());
        forwardButton.setEnabled(web.canGoForward());
        reloadButton.setText(loading ? "Stop" : "Reload");
        if (!editingAddress && !address.hasFocus()) {
            String url = web.getUrl();
            address.setText(url == null || BrowserNavigation.HOME_URL.equals(url) ? "" : url);
        }
        publishPages();
    }

    private static void revealFullscreenExit() {
        if (fullscreenExit == null || customView == null) return;
        fullscreenExit.setVisibility(View.VISIBLE);
        if (fullscreenHide != null) UI.removeCallbacks(fullscreenHide);
        final int token = generation.get();
        final View current = customView;
        fullscreenHide = () -> {
            if (token == generation.get() && customView == current && fullscreenExit != null)
                fullscreenExit.setVisibility(View.GONE);
        };
        UI.postDelayed(fullscreenHide, 300);
    }

    private static void updateFullscreenHover(float x, float y, int action) {
        long now = SystemClock.uptimeMillis();
        boolean corner = customView != null && content != null
                && x >= content.getWidth() - 240 && y >= 0 && y < 80
                && action != MotionEvent.ACTION_CANCEL && action != MotionEvent.ACTION_HOVER_EXIT;
        if (!corner) { fullscreenHoverStart = fullscreenLastHover = 0; return; }
        // Continuous hover samples, not a delayed callback: leaving the screen
        // cannot reveal an exit at a stale pointer location.
        if (fullscreenLastHover == 0 || now - fullscreenLastHover > 250) fullscreenHoverStart = now;
        fullscreenLastHover = now;
        if (now - fullscreenHoverStart >= 600) revealFullscreenExit();
    }

    public static int poll() { return state; }
    public static boolean consumeFrame() { return frame.getAndSet(false); }

    public static void close() {
        if (blocker != null) blocker.page(null);
        final int token = generation.incrementAndGet();
        state = 0;
        UI.post(() -> { if (token == generation.get()) dispose(); });
    }

    private static void dispose() {
        pageHistory.clear();
        pageTabs.clear();
        ownerActivity = null;
        publishPages();
        padRouteDiagnostics.clear();
        if (padInputManager != null) { padInputManager.unregisterInputDeviceListener(padDevices); padInputManager = null; }
        releasePhysicalGamepad();
        questPad = null;
        questBridgeReady = false;
        frame.set(false);
        if (texture != null) { texture.setOnFrameAvailableListener(null); texture = null; }
        hideCustomView();
        hidePrivacyPanel();
        hideBlockingPanel();
        hideBookmarks(false);
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
        address = null;
        pageStatus = null;
        backButton = forwardButton = reloadButton = null;
        loading = false;
        bookmarks = null;
        history = null;
        dataClearing = false;
        pendingClear = completionNotice = null;
        pageNotice = null;
        clearBackHistoryAfterHome = false;
        browserPreferences = null;
        content = null;
        navigationBar = null;
        if (display != null) { display.release(); display = null; }
        if (surface != null) { surface.release(); surface = null; }
    }

    private static void hideCustomView() {
        editingAddress = false;
        fullscreenHoverStart = fullscreenLastHover = 0;
        if (fullscreenHide != null) { UI.removeCallbacks(fullscreenHide); fullscreenHide = null; }
        if (fullscreenExit != null && fullscreenExit.getParent() instanceof ViewGroup)
            ((ViewGroup) fullscreenExit.getParent()).removeView(fullscreenExit);
        fullscreenExit = null;
        View previous = customView;
        WebChromeClient.CustomViewCallback callback = customViewCallback;
        customView = null;
        customViewCallback = null;
        if (previous != null && previous.getParent() instanceof ViewGroup) {
            ((ViewGroup) previous.getParent()).removeView(previous);
        }
        if (web != null) web.setVisibility(View.VISIBLE);
        if (navigationBar != null) navigationBar.setVisibility(View.GONE);
        if (callback != null) callback.onCustomViewHidden();
        if (previous != null) DiagnosticLog.info("BrowserPrototype", "Video fullscreen exited");
    }

    public static void pointer(float x, float y, int action) {
        final int token = generation.get();
        UI.post(() -> {
            if (token != generation.get() || root == null || state != 2 || dataClearing) return;
            if (action == MotionEvent.ACTION_DOWN && editingAddress) {
                editingAddress = false;
                web.requestFocus();
                updateNavigation();
            }
            updateFullscreenHover(x, y, action);
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
            if (token != generation.get() || root == null || state != 2 || dataClearing) return;
            if (pressed && privacyPanel != null && (code == android.view.KeyEvent.KEYCODE_ESCAPE
                    || code == android.view.KeyEvent.KEYCODE_BACK)) {
                hidePrivacyPanel();
                return;
            }
            if (pressed && blockingPanel != null && (code == android.view.KeyEvent.KEYCODE_ESCAPE
                    || code == android.view.KeyEvent.KEYCODE_BACK)) {
                hideBlockingPanel();
                return;
            }
            if (pressed && bookmarkPanel != null && (code == android.view.KeyEvent.KEYCODE_ESCAPE
                    || code == android.view.KeyEvent.KEYCODE_BACK)) {
                hideBookmarks(true);
                return;
            }
            if (pressed && customView != null && (code == android.view.KeyEvent.KEYCODE_ESCAPE
                    || code == android.view.KeyEvent.KEYCODE_BACK)) {
                hideCustomView();
                return;
            }
            if (editingAddress) {
                if (code == android.view.KeyEvent.KEYCODE_ENTER) { if (pressed) navigateAddress(); }
                else if (code == android.view.KeyEvent.KEYCODE_ESCAPE || code == android.view.KeyEvent.KEYCODE_BACK) {
                    if (pressed) { editingAddress = false; web.requestFocus(); updateNavigation(); }
                } else {
                    android.view.KeyEvent event = new android.view.KeyEvent(pressed ? 0 : 1, code);
                    event = new android.view.KeyEvent(event.getDownTime(), event.getEventTime(),
                            event.getAction(), code, 0, modifiers);
                    if (pressed) address.onKeyDown(code, event); else address.onKeyUp(code, event);
                }
                publishPages();
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
        UI.post(() -> { if (token == generation.get() && web != null) {
            BrowserPrototype.paused = paused;
            if (paused) { releasePhysicalGamepad(); questPad = null; web.onPause(); }
            else web.onResume();
        } });
    }

    // These entry points run on Android's UI thread, directly from Activity
    // dispatch. Never strip device IDs/sources or turn controller buttons into keys.
    private static boolean gamepadTarget() {
        return web != null && state == 2 && !paused && !dataClearing && !editingAddress && gamepadInputEnabled
            && privacyPanel == null && blockingPanel == null && bookmarkPanel == null
            && (address == null || !address.hasFocus()) && (web.hasFocus() || customView != null);
    }
    public static boolean physicalGamepadKey(android.view.KeyEvent event) {
        if (!BrowserPhysicalGamepad.accepts(event)) return false;
        if (!gamepadTarget()) { logPadRoute("blocked", event.getDeviceId()); releasePhysicalGamepad(); return false; }
        android.view.InputDevice device = event.getDevice();
        if (device != null) {
            if (physicalPad == null || physicalPad.deviceId != event.getDeviceId()) physicalPad = new BrowserPhysicalGamepad(device);
            physicalPad.key(event);
        }
        long key = ((long) event.getDeviceId() << 32) | (event.getKeyCode() & 0xffffffffL);
        if (event.getAction() == android.view.KeyEvent.ACTION_DOWN) padKeys.put(key, new android.view.KeyEvent(event));
        else padKeys.remove(key);
        boolean handled = web.dispatchKeyEvent(event);
        logPadRoute("key nativeHandled=" + handled + " bridge=" + questBridgeReady, event.getDeviceId());
        return true; // Browser owns this event, even if the provider declines it.
    }
    public static boolean physicalGamepadMotion(MotionEvent event) {
        if (!event.isFromSource(android.view.InputDevice.SOURCE_JOYSTICK)) return false;
        if (!gamepadTarget()) { logPadRoute("blocked", event.getDeviceId()); releasePhysicalGamepad(); return false; }
        android.view.InputDevice device = event.getDevice();
        if (device != null) {
            if (physicalPad == null || physicalPad.deviceId != event.getDeviceId()) physicalPad = new BrowserPhysicalGamepad(device);
            physicalPad.motion(event);
        }
        MotionEvent previous = padMotions.put(event.getDeviceId(), MotionEvent.obtain(event));
        if (previous != null) previous.recycle();
        boolean handled = web.dispatchGenericMotionEvent(event);
        logPadRoute("motion nativeHandled=" + handled + " bridge=" + questBridgeReady, event.getDeviceId());
        return true;
    }
    private static void releasePhysicalGamepad() {
        physicalPad = null;
        if (web != null) {
            for (android.view.KeyEvent event : padKeys.values())
                web.dispatchKeyEvent(android.view.KeyEvent.changeAction(event, android.view.KeyEvent.ACTION_UP));
            for (MotionEvent event : padMotions.values()) {
                MotionEvent.PointerProperties property = new MotionEvent.PointerProperties();
                property.id = 0;
                MotionEvent.PointerCoords coordinates = new MotionEvent.PointerCoords();
                android.view.InputDevice device = event.getDevice();
                if (device != null) for (android.view.InputDevice.MotionRange range : device.getMotionRanges()) {
                    int axis = range.getAxis();
                    if (axis == MotionEvent.AXIS_LTRIGGER || axis == MotionEvent.AXIS_RTRIGGER
                            || axis == MotionEvent.AXIS_BRAKE || axis == MotionEvent.AXIS_GAS)
                        coordinates.setAxisValue(axis, range.getMin());
                }
                // Sticks/hats centered, triggers released. Preserve device/source.
                MotionEvent neutral = MotionEvent.obtain(event.getDownTime(), SystemClock.uptimeMillis(),
                    MotionEvent.ACTION_MOVE, 1, new MotionEvent.PointerProperties[]{property},
                    new MotionEvent.PointerCoords[]{coordinates}, 0, 0, 1, 1,
                    event.getDeviceId(), 0, event.getSource(), 0);
                web.dispatchGenericMotionEvent(neutral);
                neutral.recycle();
            }
        }
        padKeys.clear();
        for (MotionEvent event : padMotions.values()) event.recycle();
        padMotions.clear();
    }
    private static void logPadRoute(String route, int device) {
        // Log transitions only, not button values, browsing URLs or every tick.
        String value = "device=" + device + " " + route + " state=" + state + " paused=" + paused
            + " input=" + gamepadInputEnabled + " webFocus=" + (web != null && web.hasFocus())
            + " addressFocus=" + (address != null && address.hasFocus());
        if (padRouteDiagnostics.size() < 64 && padRouteDiagnostics.add(value)) {
            DiagnosticLog.info("BrowserGamepad", value);
        }
    }
    public static void setGamepadInputEnabled(boolean enabled) {
        int token = generation.get();
        UI.post(() -> { if (token == generation.get()) {
            gamepadInputEnabled = enabled;
            if (!enabled) { releasePhysicalGamepad(); questPad = null; }
        } });
    }
    public static void questGamepad(int buttons, int lt, int rt, int lx, int ly, int rx, int ry) {
        int token = generation.get();
        String snapshot = BrowserGamepadState.json(buttons, lt, rt, lx, ly, rx, ry, SystemClock.uptimeMillis());
        UI.post(() -> { if (token == generation.get() && gamepadTarget() && questBridgeReady) {
            questPad = snapshot;
            questPadTime = SystemClock.uptimeMillis();
        } });
    }
    public static void clearQuestGamepad() {
        int token = generation.get();
        UI.post(() -> { if (token == generation.get()) questPad = null; });
    }
    private static void installQuestGamepadBridge() {
        paused = false;
        gamepadInputEnabled = true;
        if (!androidx.webkit.WebViewFeature.isFeatureSupported(androidx.webkit.WebViewFeature.DOCUMENT_START_SCRIPT)
                || !androidx.webkit.WebViewFeature.isFeatureSupported(androidx.webkit.WebViewFeature.WEB_MESSAGE_LISTENER)) {
            DiagnosticLog.info("BrowserPrototype", "Quest gamepad bridge unavailable in this WebView provider");
            return;
        }
        java.util.Set<String> origins = java.util.Collections.singleton("*");
        int token = generation.get();
        androidx.webkit.WebViewCompat.addWebMessageListener(web, "NightfallQuestPad", origins,
            (view, message, origin, mainFrame, reply) -> {
                // Read-only state: no page can send keys, invoke OS actions or
                // mutate the controller. Validate even with wildcard injection.
                String scheme = origin.getScheme();
                if (token != generation.get() || view != web || !"poll".equals(message.getData())
                        || !("https".equals(scheme) || "http".equals(scheme))) return;
                String value = null;
                if (gamepadTarget()) {
                    if (questPad != null && SystemClock.uptimeMillis() - questPadTime < 350) value = questPad;
                    else if (physicalPad != null) value = physicalPad.json();
                }
                reply.postMessage(value == null ? "null" : value);
            });
        androidx.webkit.WebViewCompat.addDocumentStartJavaScript(web, BrowserGamepadScript.source(), origins);
        questBridgeReady = true;
        DiagnosticLog.info("BrowserPrototype", "Physical gamepad routing and experimental Quest Gamepad API bridge ready");
    }
}
