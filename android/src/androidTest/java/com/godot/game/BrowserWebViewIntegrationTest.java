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
        assertEquals(2, pages.pages.size());
        BrowserPrototype.tabAction("close", second);
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertEquals(1, pages.pages.size());
        assertEquals(first, pages.selected);
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
}
