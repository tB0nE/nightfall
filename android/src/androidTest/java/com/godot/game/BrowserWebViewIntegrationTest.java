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
        Field field = BrowserPrototype.class.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(null);
    }
    private static void invoke(String name, Class<?>[] types, Object... args) throws Exception {
        Method method = BrowserPrototype.class.getDeclaredMethod(name, types);
        method.setAccessible(true);
        method.invoke(null, args);
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
        BrowserPrototype.close();
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
