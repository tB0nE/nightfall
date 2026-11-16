package com.godot.game;

import android.app.Activity;
import android.content.Intent;
import android.graphics.SurfaceTexture;
import android.view.Surface;
import android.webkit.PermissionRequest;
import android.webkit.WebView;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Run ONLY against app.nightfall.quest.instrumented, not the installed user app. */
@RunWith(AndroidJUnit4.class)
public class BrowserWebViewIntegrationTest {
    private Activity activity;
    private SurfaceTexture texture;
    private static Object field(String name) throws Exception {
        return field(0, name);
    }
    private static Object session(int id) throws Exception {
        Method method = BrowserPrototype.class.getDeclaredMethod("session", int.class);
        method.setAccessible(true);
        return method.invoke(null, id);
    }
    private static Object field(int id, String name) throws Exception {
        Object session = session(id);
        Field field = session.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(session);
    }
    private static void invoke(String name, Class<?>[] types, Object... args) throws Exception {
        invoke(0, name, types, args);
    }
    private static void invoke(int id, String name, Class<?>[] types, Object... args) throws Exception {
        Object session = session(id);
        Method method = session.getClass().getDeclaredMethod(name, types);
        method.setAccessible(true);
        method.invoke(session, args);
    }
    @Before public void open() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        assertTrue("Never run against a user profile", instrumentation.getTargetContext().getPackageName().endsWith(".instrumented"));
        Intent intent = new Intent(instrumentation.getTargetContext(), BrowserTestActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        activity = instrumentation.startActivitySync(intent);
        texture = new SurfaceTexture(false);
        texture.setDefaultBufferSize(640, 360);
        BrowserPrototype.open(activity, new Surface(texture), texture, 640, 360);
        instrumentation.waitForIdleSync();
        assertNotNull(field("web"));
    }
    @After public void close() {
        BrowserPrototype.closeAll();
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        if (activity != null) activity.finish();
        if (texture != null) texture.release();
    }
    private String javascript(String expression) throws Exception {
        java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.atomic.AtomicReference<String> result = new java.util.concurrent.atomic.AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try {
                ((WebView) field("web")).evaluateJavascript(expression, value -> { result.set(value); done.countDown(); });
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
        assertTrue("WebView JavaScript timed out", done.await(3, java.util.concurrent.TimeUnit.SECONDS));
        return result.get();
    }

    @Test public void editMenuQueuesActionsInsideBrowserSurface() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        BrowserPrototype.navigationAction(0, "context:620,340");
        instrumentation.waitForIdleSync();
        instrumentation.runOnMainSync(() -> {
            try {
                android.widget.FrameLayout overlay = (android.widget.FrameLayout) field("editOverlay");
                assertNotNull(overlay);
                android.widget.LinearLayout menu = (android.widget.LinearLayout) overlay.getChildAt(0);
                assertEquals(4, menu.getChildCount());
                assertTrue(menu.getLeft() + menu.getWidth() <= 640);
                assertTrue(menu.getTop() + menu.getHeight() <= 360);
                assertFalse(menu.getChildAt(3).isFocusable());
                menu.getChildAt(3).performClick();
                assertNull(field("editOverlay"));
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
        org.json.JSONObject snapshot = new org.json.JSONObject(BrowserPrototype.tabs(0));
        assertEquals("paste", snapshot.getJSONObject("navigation").getString("editAction"));
        assertTrue(snapshot.getJSONObject("navigation").getInt("editSequence") > 0);
        BrowserPrototype.navigationAction(0, "context:10,10");
        instrumentation.waitForIdleSync();
        BrowserPrototype.focus(-1);
        instrumentation.waitForIdleSync();
        assertNull(field("editOverlay"));
    }

    @Test public void fractionalWheelScrollReachesWebPage() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        instrumentation.runOnMainSync(() -> {
            try {
                ((WebView) field("web")).loadDataWithBaseURL("https://nightfall.invalid/scroll-test",
                    "<html><head><meta name='viewport' content='width=device-width'></head>"
                    + "<body style='margin:0;height:4000px'><div id='ready'>Scroll test</div>"
                    + "<script>window.wheels=[];addEventListener('wheel',e=>wheels.push(e.deltaY));</script></body></html>",
                    "text/html", "UTF-8", null);
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
        long deadline = android.os.SystemClock.uptimeMillis() + 5000;
        while (!"true".equals(javascript("!!document.getElementById('ready')"))
                && android.os.SystemClock.uptimeMillis() < deadline) Thread.sleep(50);
        assertEquals("true", javascript("!!document.getElementById('ready')"));
        // Isolate event routing from Chromium's optional compositor scrolling.
        BrowserPrototype.scroll(0, 320f, 180f, -0.5f);
        instrumentation.waitForIdleSync();
        deadline = android.os.SystemClock.uptimeMillis() + 3000;
        while ("0".equals(javascript("wheels.length"))
                && android.os.SystemClock.uptimeMillis() < deadline) Thread.sleep(50);
        assertNotEquals("Wheel event must reach the page", "0", javascript("wheels.length"));
        assertEquals("true", javascript("wheels[0] > 0"));
        BrowserPrototype.scroll(0, 320f, 180f, 0.5f);
        instrumentation.waitForIdleSync();
        deadline = android.os.SystemClock.uptimeMillis() + 3000;
        while ("1".equals(javascript("wheels.length"))
                && android.os.SystemClock.uptimeMillis() < deadline) Thread.sleep(50);
        assertEquals("true", javascript("wheels.length >= 2 && wheels[wheels.length-1] < 0"));
    }

    @Test public void permissionsAreDenied() throws Exception {
        boolean[] denied = {false};
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try {
                WebView web = (WebView) field("web");
                web.getWebChromeClient().onPermissionRequest(new PermissionRequest() {
                    public android.net.Uri getOrigin() { return android.net.Uri.parse("https://example.org"); }
                    public String[] getResources() { return new String[]{RESOURCE_AUDIO_CAPTURE}; }
                    public void grant(String[] resources) { fail("Unexpected permission grant"); }
                    public void deny() { denied[0] = true; }
                });
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertTrue(denied[0]);
    }

    @Test public void twoBrowsersHaveIndependentTabsFramesFocusAndLifetime() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        SurfaceTexture secondTexture = new SurfaceTexture(false);
        secondTexture.setDefaultBufferSize(640, 360);
        try {
            BrowserPrototype.open(1, activity, new Surface(secondTexture), secondTexture, 640, 360);
            instrumentation.waitForIdleSync();
            assertNotSame(field(0, "web"), field(1, "web"));
            assertNotSame(field(0, "display"), field(1, "display"));
            assertNotSame(field(0, "generation"), field(1, "generation"));
            instrumentation.runOnMainSync(() -> {
                android.content.SharedPreferences preferences = null;
                String saved = null;
                try {
                    preferences = (android.content.SharedPreferences) field(0, "browserPreferences");
                    saved = preferences.getString("bookmarks_v1", "");
                    preferences.edit().remove("bookmarks_v1").apply();
                    invoke(0, "reloadBookmarks", new Class<?>[]{});
                    invoke(1, "reloadBookmarks", new Class<?>[]{});
                    ((BrowserBookmarks) field(0, "bookmarks")).save(null, "First screen", "https://one.example/");
                    invoke(0, "persistBookmarks", new Class<?>[]{});
                    // Screen 1 held an old snapshot: refresh-before-mutation
                    // must retain screen 0's edit rather than overwrite it.
                    invoke(1, "reloadBookmarks", new Class<?>[]{});
                    ((BrowserBookmarks) field(1, "bookmarks")).save(null, "Second screen", "https://two.example/");
                    invoke(1, "persistBookmarks", new Class<?>[]{});
                    invoke(0, "reloadBookmarks", new Class<?>[]{});
                    assertEquals(2, ((BrowserBookmarks) field(0, "bookmarks")).entries().size());
                } catch (Exception failure) { throw new AssertionError(failure); }
                finally { if (preferences != null) preferences.edit().putString("bookmarks_v1", saved == null ? "" : saved).apply(); }
            });
            BrowserPrototype.tabAction(1, "new", 0);
            instrumentation.waitForIdleSync();
            assertEquals(1, new org.json.JSONObject(BrowserPrototype.tabs(0)).getJSONArray("pages").length());
            assertEquals(2, new org.json.JSONObject(BrowserPrototype.tabs(1)).getJSONArray("pages").length());
            instrumentation.runOnMainSync(() -> {
                try {
                    java.util.concurrent.atomic.AtomicBoolean firstFrame = (java.util.concurrent.atomic.AtomicBoolean) field(0, "frame");
                    java.util.concurrent.atomic.AtomicBoolean secondFrame = (java.util.concurrent.atomic.AtomicBoolean) field(1, "frame");
                    firstFrame.set(true); secondFrame.set(true);
                    assertTrue(BrowserPrototype.consumeFrame(0));
                    assertTrue(secondFrame.get());
                    assertFalse(BrowserPrototype.consumeFrame(0));
                    assertTrue(BrowserPrototype.consumeFrame(1));
                } catch (Exception failure) { throw new AssertionError(failure); }
            });
            BrowserPrototype.focus(0);
            instrumentation.waitForIdleSync();
            instrumentation.runOnMainSync(() -> {
                try {
                    Field quest = session(0).getClass().getDeclaredField("questPad");
                    quest.setAccessible(true);
                    quest.set(session(0), "held-input");
                } catch (Exception failure) { throw new AssertionError(failure); }
            });
            BrowserPrototype.navigationAction(1, "home");
            instrumentation.waitForIdleSync();
            assertNull(field(0, "questPad"));
            BrowserPrototype.close(1);
            instrumentation.waitForIdleSync();
            assertEquals(0, BrowserPrototype.poll(1));
            assertEquals(2, BrowserPrototype.poll(0));
            assertNotNull(field(0, "web"));
            assertNull(field(1, "web"));
        } finally {
            BrowserPrototype.close(1);
            instrumentation.waitForIdleSync();
            secondTexture.release();
        }
    }

    @Test public void externalToolbarLeavesContentCleanAndEditsAddress() throws Exception {
        assertEquals(android.view.View.GONE, ((android.view.View) field("navigationBar")).getVisibility());
        BrowserPrototype.navigationAction("address");
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        BrowserPrototype.key(android.view.KeyEvent.KEYCODE_A, true, 0);
        BrowserPrototype.key(android.view.KeyEvent.KEYCODE_A, false, 0);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals("a", ((android.widget.EditText) field("address")).getText().toString());
        org.json.JSONObject snapshot = new org.json.JSONObject(BrowserPrototype.tabs());
        assertEquals("a", snapshot.getJSONObject("navigation").getString("address"));
        assertTrue(snapshot.getJSONObject("navigation").getBoolean("editing"));
        BrowserPrototype.key(android.view.KeyEvent.KEYCODE_ESCAPE, true, 0);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(Boolean.FALSE, field("editingAddress"));
        assertEquals(android.view.View.GONE, ((android.view.View) field("navigationBar")).getVisibility());
    }
    @Test public void explicitlyEnteredHttpIsPermitted() {
        assertTrue(android.security.NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted("10.0.0.13"));
        assertEquals("http://10.0.0.13:32400/web",
            BrowserNavigation.destination("http://10.0.0.13:32400/web"));
    }
    @Test public void liveResizeKeepsWebViewAndTabs() throws Exception {
        Object original = field("web");
        BrowserPageTabs pages = (BrowserPageTabs) field("pageTabs");
        int selected = pages.selected;
        for (int[] size : new int[][] {{2560,1440},{1920,1080},{2560,1440}}) {
            BrowserPrototype.resize(0, size[0], size[1]);
            InstrumentationRegistry.getInstrumentation().waitForIdleSync();
            assertSame("Resize must retain the live page", original, field("web"));
            assertEquals(selected, pages.selected);
            org.json.JSONObject metadata = new org.json.JSONObject(BrowserPrototype.tabs());
            assertEquals(size[0], metadata.getInt("width"));
            assertEquals(size[1], metadata.getInt("height"));
            android.hardware.display.VirtualDisplay display = (android.hardware.display.VirtualDisplay) field("display");
            android.graphics.Point actual = new android.graphics.Point();
            display.getDisplay().getRealSize(actual);
            assertEquals(size[0], actual.x);
            assertEquals(size[1], actual.y);
        }
        BrowserPrototype.resize(0, 8192,8192);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(2560, new org.json.JSONObject(BrowserPrototype.tabs()).getInt("width"));
        BrowserPrototype.close();
        BrowserPrototype.resize(0,1920,1080);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNull(field("web"));
    }
    @Test public void monitorTabSuspendsBrowserWithoutClosingTabs() throws Exception {
        BrowserPrototype.tabAction("new", 0);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        BrowserPageTabs pages = (BrowserPageTabs) field("pageTabs");
        int selected = pages.selected;
        Object outgoing = field("web");
        BrowserPrototype.contentVisible(0, false);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertSame("Monitor switches retain the page rather than reconstructing it", outgoing, field("web"));
        assertEquals(android.view.View.INVISIBLE, ((android.view.View) outgoing).getVisibility());
        assertEquals(2, pages.pages.size());
        assertEquals(selected, pages.selected);
        BrowserPrototype.contentVisible(0, true);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNotNull(field("web"));
        assertSame(outgoing, field("web"));
        assertEquals(android.view.View.VISIBLE, ((android.view.View) outgoing).getVisibility());
        assertEquals(selected, pages.selected);
        assertEquals(2, pages.pages.size());
        BrowserPrototype.close();
        BrowserPrototype.contentVisible(0, true);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNull("A late resume must never reopen a closed session", field("web"));
    }
    @Test public void newSelectCloseKeepsOneLivePage() throws Exception {
        BrowserPageTabs pages = (BrowserPageTabs) field("pageTabs");
        int first = pages.selected;
        WebView original = (WebView) field("web");
        BrowserPrototype.tabAction("new", 0);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(2, pages.pages.size());
        assertNotSame(original, field("web"));
        int second = pages.selected;
        BrowserPrototype.tabAction("select", first);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(first, pages.selected);
        assertSame("Recently used tabs must resume their existing document", original, field("web"));
        assertEquals(2, pages.pages.size());
        BrowserPrototype.tabAction("close", second);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(1, pages.pages.size());
        assertEquals(first, pages.selected);
        assertTrue(((java.util.Map<?, ?>)field("retainedPages")).isEmpty());
    }
    @Test public void staleCleanupCannotRestoreClosedBrowser() throws Exception {
        int old = ((java.util.concurrent.atomic.AtomicInteger) field("generation")).get();
        BrowserPrototype.close();
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try { invoke("finishDataClear", new Class<?>[]{int.class, String.class}, old, "Late completion"); }
            catch (Exception failure) { throw new AssertionError(failure); }
        });
        assertNull(field("web"));
    }
    @Test public void locationAndFileRequestsRemainDenied() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try {
                WebView web = (WebView) field("web");
                boolean[] locationCalled = {false}, chooserCalled = {false};
                web.getWebChromeClient().onGeolocationPermissionsShowPrompt("https://example.org",
                    (origin, allow, retain) -> { locationCalled[0] = true; assertFalse(allow); assertFalse(retain); });
                assertTrue(web.getWebChromeClient().onShowFileChooser(web,
                    files -> { chooserCalled[0] = true; assertNull(files); }, null));
                assertTrue(locationCalled[0]);
                assertTrue(chooserCalled[0]);
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
    }
    @Test public void unsupportedNavigationCannotLaunchExternalApps() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try {
                WebView web = (WebView) field("web");
                android.webkit.WebResourceRequest request = new android.webkit.WebResourceRequest() {
                    public android.net.Uri getUrl() { return android.net.Uri.parse("intent://example.org"); }
                    public boolean isForMainFrame() { return true; }
                    public boolean isRedirect() { return false; }
                    public boolean hasGesture() { return true; }
                    public String getMethod() { return "GET"; }
                    public java.util.Map<String, String> getRequestHeaders() { return java.util.Collections.emptyMap(); }
                };
                assertTrue(web.getWebViewClient().shouldOverrideUrlLoading(web, request));
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
    }
    @Test public void settingsAndBookmarksSurviveBrowserReopen() throws Exception {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try {
                android.content.SharedPreferences prefs = (android.content.SharedPreferences) field("browserPreferences");
                BrowserBookmarks bookmarks = new BrowserBookmarks();
                bookmarks.save(null, "Test", "https://example.org/");
                assertTrue(prefs.edit().putBoolean("save_history", true).putString("bookmarks_v1", bookmarks.encode()).commit());
            } catch (Exception failure) { throw new AssertionError(failure); }
        });
        BrowserPrototype.close();
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        BrowserPrototype.open(activity, new Surface(texture), texture, 640, 360);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(true, field("saveHistory"));
        assertEquals("https://example.org/", ((BrowserBookmarks) field("bookmarks")).entries().get(0).url);
    }

    private int waitForTransfer(int ticket) throws Exception {
        long deadline = android.os.SystemClock.uptimeMillis() + 5000;
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            org.json.JSONObject result = new org.json.JSONObject(BrowserPrototype.transferResult(ticket));
            if (result.optBoolean("done")) return result.optInt("page");
            Thread.sleep(25);
        }
        BrowserPrototype.cancelTransfer(ticket);
        fail("Browser transfer timed out");
        return 0;
    }

    @Test public void tabTransferUsesDestinationDisplayAndKeepsNavigation() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        SurfaceTexture second = new SurfaceTexture(false);
        second.setDefaultBufferSize(640,360);
        try {
            BrowserPrototype.open(1, activity, new Surface(second), second,640,360);
            instrumentation.waitForIdleSync();
            long deadline = android.os.SystemClock.uptimeMillis() + 4000;
            while (!"\"complete\"".equals(javascript("document.readyState")) && android.os.SystemClock.uptimeMillis() < deadline) Thread.sleep(30);
            int page = ((BrowserPageTabs) field("pageTabs")).selected;
            final WebView[] outgoing = new WebView[1];
            final String[] url = new String[1];
            instrumentation.runOnMainSync(() -> {
                try { outgoing[0]=(WebView)field("web");url[0]=outgoing[0].getUrl(); }
                catch (Exception error) { throw new AssertionError(error); }
            });
            int newPage = waitForTransfer(BrowserPrototype.transferTab(0,1,page,true));
            assertTrue(newPage > 0);
            instrumentation.waitForIdleSync();
            instrumentation.runOnMainSync(() -> {
                try {
                    assertTrue(((BrowserPageTabs)field("pageTabs")).pages.isEmpty());
                    assertNull(field("web"));
                    WebView incoming=(WebView)field(1,"web");
                    assertNotSame(outgoing[0],incoming);
                    assertEquals(1,((BrowserPageTabs)field(1,"pageTabs")).pages.size());
                    assertEquals(((android.hardware.display.VirtualDisplay)field(1,"display")).getDisplay().getDisplayId(), incoming.getContext().getDisplay().getDisplayId());
                    assertEquals(url[0],incoming.getUrl());
                } catch (Exception error) { throw new AssertionError(error); }
            });
        } finally { BrowserPrototype.close(1);instrumentation.waitForIdleSync();second.release(); }
    }

    @Test public void cancelledOrFullDestinationTransferKeepsSource() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        SurfaceTexture second = new SurfaceTexture(false);
        second.setDefaultBufferSize(640,360);
        try {
            BrowserPrototype.open(1,activity,new Surface(second),second,640,360);
            instrumentation.waitForIdleSync();
            int page=((BrowserPageTabs)field("pageTabs")).selected;
            int[] ticket=new int[1];
            instrumentation.runOnMainSync(() -> {
                ticket[0]=BrowserPrototype.transferTab(0,1,page,false);
                BrowserPrototype.cancelTransfer(ticket[0]);
            });
            instrumentation.waitForIdleSync();
            assertEquals(0,waitForTransfer(ticket[0]));
            assertEquals(1,((BrowserPageTabs)field("pageTabs")).pages.size());
            instrumentation.runOnMainSync(() -> {
                try {
                    BrowserPageTabs tabs=(BrowserPageTabs)field(1,"pageTabs");
                    while(tabs.pages.size()<BrowserPageTabs.LIMIT) tabs.add();
                } catch(Exception error) { throw new AssertionError(error); }
            });
            assertEquals(0,waitForTransfer(BrowserPrototype.transferTab(0,1,page,false)));
            assertNotNull(field("web"));
            assertEquals(1,((BrowserPageTabs)field("pageTabs")).pages.size());
        } finally { BrowserPrototype.close(1);instrumentation.waitForIdleSync();second.release(); }
    }

    @Test public void explicitClipboardSharesTextWithWebViewAndProtectsNewerCopy() throws Exception {
        android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        org.junit.Assume.assumeTrue("Requires the real app foreground; never change a clipboard we cannot read/restore",activity.hasWindowFocus());
        android.content.ClipboardManager clipboard = activity.getSystemService(android.content.ClipboardManager.class);
        android.content.ClipData original = clipboard.getPrimaryClip();
        try {
            instrumentation.runOnMainSync(() -> clipboard.setPrimaryClip(android.content.ClipData.newPlainText("test", "local test")));
            org.json.JSONObject first = new org.json.JSONObject(BrowserClipboard.read(activity));
            assertTrue(first.optBoolean("ok"));
            assertTrue(first.optBoolean("local"));
            assertTrue(BrowserClipboard.write(activity,"host test text",first.getLong("stamp")));
            org.json.JSONObject remote = new org.json.JSONObject(BrowserClipboard.read(activity));
            assertFalse(remote.getBoolean("local"));
            instrumentation.runOnMainSync(() -> {
                try {
                    WebView view=(WebView)field("web");
                    view.loadDataWithBaseURL("https://nightfall.invalid/clipboard-test", "<html><body><textarea id='clip'></textarea></body></html>","text/html","UTF-8",null);
                    view.requestFocus();
                } catch(Exception error) {throw new AssertionError(error);}
            });
            long deadline=android.os.SystemClock.uptimeMillis()+4000;
            while(!"true".equals(javascript("!!document.getElementById('clip')")) && android.os.SystemClock.uptimeMillis()<deadline) Thread.sleep(30);
            javascript("document.getElementById('clip').focus();true");
            BrowserPrototype.key(0,android.view.KeyEvent.KEYCODE_V,true,android.view.KeyEvent.META_CTRL_ON);
            BrowserPrototype.key(0,android.view.KeyEvent.KEYCODE_V,false,android.view.KeyEvent.META_CTRL_ON);
            instrumentation.waitForIdleSync();
            deadline=android.os.SystemClock.uptimeMillis()+3000;
            while(!"\"host test text\"".equals(javascript("document.getElementById('clip').value")) && android.os.SystemClock.uptimeMillis()<deadline) Thread.sleep(30);
            assertEquals("\"host test text\"",javascript("document.getElementById('clip').value"));
            Thread.sleep(20);
            javascript("var t=document.getElementById('clip');t.value='browser test text';t.focus();t.select();true");
            BrowserPrototype.key(0,android.view.KeyEvent.KEYCODE_C,true,android.view.KeyEvent.META_CTRL_ON);
            BrowserPrototype.key(0,android.view.KeyEvent.KEYCODE_C,false,android.view.KeyEvent.META_CTRL_ON);
            instrumentation.waitForIdleSync();
            deadline=android.os.SystemClock.uptimeMillis()+3000;
            org.json.JSONObject local;
            do {local=new org.json.JSONObject(BrowserClipboard.read(activity));if("browser test text".equals(local.optString("text")))break;Thread.sleep(30);} while(android.os.SystemClock.uptimeMillis()<deadline);
            assertEquals("browser test text",local.optString("text"));
            assertTrue(local.getBoolean("local"));
            assertFalse(BrowserClipboard.write(activity,"late host test",remote.getLong("stamp")));
            assertEquals("browser test text",new org.json.JSONObject(BrowserClipboard.read(activity)).getString("text"));
        } finally {
            instrumentation.runOnMainSync(() -> { if(original==null)clipboard.clearPrimaryClip();else clipboard.setPrimaryClip(original); });
        }
    }

    @Test public void clipboardRejectsUnfocusedActivityWithoutAccessingSystemData() throws Exception {
        org.junit.Assume.assumeFalse(activity.hasWindowFocus());
        assertFalse(new org.json.JSONObject(BrowserClipboard.read(activity)).optBoolean("ok"));
        assertFalse(BrowserClipboard.write(activity,"must not be written",0));
    }
}
