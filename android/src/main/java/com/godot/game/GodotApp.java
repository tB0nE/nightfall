package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.util.Log;
import android.view.InputDevice;
import android.view.KeyEvent;

import androidx.activity.EdgeToEdge;
import androidx.core.splashscreen.SplashScreen;

public class GodotApp extends GodotActivity {
	private static native boolean initializePcvrContext(Object context);
	public static boolean preparePcvrContext() {
		try {
			GodotApp activity = browserActivity.get();
			if (activity == null) return false;
			for (String permission : new String[] {
					android.Manifest.permission.ACCESS_WIFI_STATE,
					android.Manifest.permission.WAKE_LOCK}) {
				if (activity.checkSelfPermission(permission) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
					DiagnosticLog.info("NightfallPCVR", "Missing required PCVR permission: " + permission);
					return false;
				}
			}
			// Catch WifiLock security failures in Java before upstream Rust unwraps them.
			WifiManager wifi = (WifiManager) activity.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
			if (wifi == null) return false;
			WifiManager.WifiLock probe = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "nightfall-pcvr-preflight");
			probe.setReferenceCounted(false);
			try { probe.acquire(); } finally { if (probe.isHeld()) probe.release(); }
			System.loadLibrary("nightfall-xr.android.template_release.arm64");
			// Upstream may call requestPermissions(), which requires an Activity.
			return initializePcvrContext(activity);
		} catch (UnsatisfiedLinkError error) {
			Log.e("NightfallPCVR", "DEV PCVR bridge unavailable", error);
			return false;
		} catch (RuntimeException error) {
			DiagnosticLog.error("NightfallPCVR", "PCVR preflight failed", error);
			return false;
		}
	}
	private static java.lang.ref.WeakReference<GodotApp> browserActivity = new java.lang.ref.WeakReference<>(null);
	public static void openBrowser(android.view.Surface surface, android.graphics.SurfaceTexture texture, int width, int height) {
		BrowserPrototype.open(browserActivity.get(), surface, texture, width, height);
	}
	public static int pollBrowser() { return BrowserPrototype.poll(); }
	public static String browserTabs() { return BrowserPrototype.tabs(); }
	public static void browserTabAction(String action, int id) { BrowserPrototype.tabAction(action, id); }
	public static void browserNavigationAction(String action) { BrowserPrototype.navigationAction(action); }
	public static boolean consumeBrowserFrame() { return BrowserPrototype.consumeFrame(); }
	public static void closeBrowser() { BrowserPrototype.close(); }
	public static void browserPointer(float x, float y, int action) { BrowserPrototype.pointer(x, y, action); }
	public static void browserKey(int code, boolean pressed, int modifiers) { BrowserPrototype.key(code, pressed, modifiers); }
	public static void browserGamepad(int buttons, int lt, int rt, int lx, int ly, int rx, int ry) {
		BrowserPrototype.questGamepad(buttons, lt, rt, lx, ly, rx, ry);
	}
	public static void browserClearGamepad() { BrowserPrototype.clearQuestGamepad(); }
	public static void browserInputEnabled(boolean enabled) { BrowserPrototype.setGamepadInputEnabled(enabled); }
	public static void openBrowserFor(int id, android.view.Surface surface, android.graphics.SurfaceTexture texture, int width, int height) { BrowserPrototype.open(id, browserActivity.get(), surface, texture, width, height); }
	public static int pollBrowserFor(int id) { return BrowserPrototype.poll(id); }
	public static boolean consumeBrowserFrameFor(int id) { return BrowserPrototype.consumeFrame(id); }
	public static void closeBrowserFor(int id) { BrowserPrototype.close(id); }
	public static void browserStartPageFor(int id, String url, String userAgent) { BrowserPrototype.setStartPage(id, url, userAgent); }
	public static String browserTabsFor(int id) { return BrowserPrototype.tabs(id); }
	public static void browserTabActionFor(int id, String action, int page) { BrowserPrototype.tabAction(id, action, page); }
	public static void browserNavigationActionFor(int id, String action) { BrowserPrototype.navigationAction(id, action); }
	public static void browserPointerFor(int id, float x, float y, int action) { BrowserPrototype.pointer(id, x, y, action); }
	public static void browserKeyFor(int id, int code, boolean pressed, int modifiers) { BrowserPrototype.key(id, code, pressed, modifiers); }
	public static void browserGamepadFor(int id, int buttons, int lt, int rt, int lx, int ly, int rx, int ry) { BrowserPrototype.questGamepad(id, buttons, lt, rt, lx, ly, rx, ry); }
	public static void browserClearGamepadFor(int id) { BrowserPrototype.clearQuestGamepad(id); }
	public static void browserInputEnabledFor(int id, boolean enabled) { BrowserPrototype.setGamepadInputEnabled(id, enabled); }
	public static void browserFocus(int id) { BrowserPrototype.focus(id); }
	private final java.util.Set<String> loggedPadKeys = new java.util.HashSet<>();

	@Override
	public boolean dispatchKeyEvent(KeyEvent event) {
		InputDevice device = event.getDevice();
		if (device != null && BrowserPhysicalGamepad.accepts(event)) {
			int corrected = GamepadInfo.correctedKeyCode(device, event);
			String signature = event.getDeviceId() + ":" + event.getScanCode() + ":" + event.getKeyCode();
			if (event.getAction() == KeyEvent.ACTION_DOWN && loggedPadKeys.add(signature)) {
				DiagnosticLog.info("GamepadInfo", "device=" + event.getDeviceId()
						+ " name=" + device.getName() + " vendor=" + device.getVendorId()
						+ " product=" + device.getProductId() + " scan=" + event.getScanCode()
						+ " key=" + event.getKeyCode() + " corrected=" + corrected);
			}
			if (corrected < 0) return true;
			if (corrected != event.getKeyCode()) {
				event = new KeyEvent(event.getDownTime(), event.getEventTime(), event.getAction(),
						corrected, event.getRepeatCount(), event.getMetaState(), event.getDeviceId(),
						event.getScanCode(), event.getFlags(), event.getSource());
			}
		}
		if (BrowserPrototype.physicalGamepadKey(event)) return true;
		return super.dispatchKeyEvent(event);
	}
	@Override public boolean dispatchGenericMotionEvent(android.view.MotionEvent event) {
		if (BrowserPrototype.physicalGamepadMotion(event)) return true;
		return super.dispatchGenericMotionEvent(event);
	}
	public static native void initializeMoonlightJNI();
	public static boolean openAudioTrack(int rate, int channels, int period) { return AudioOutput.open(rate, channels, period); }
	public static boolean writeAudioTrack(float[] data, int frames) { return AudioOutput.write(data, frames); }
	public static void closeAudioTrack() { AudioOutput.close(); }
	public static void pauseAudioTrack() { AudioOutput.pause(); }
	public static void resumeAudioTrack() { AudioOutput.resume(); }
	public static int audioTrackLatency() { return AudioOutput.latencyMs(); }
	public static void logAudioDiagnostics(String message) { DiagnosticLog.info("AudioRenderer", message); }
	public static native void setAndroidContext(Object context);

	public static String jniResult = "NOT_RUN";
	public static DepthEstimator depthEstimator;
	public static UsbLinkManager usbLinkManager;
	public static WifiManager.MulticastLock multicastLock;
	private static Context appContext;

	static {
		if (BuildConfig.FLAVOR.equals("mono")) {
			try {
				Log.v("GODOT", "Loading System.Security.Cryptography.Native.Android library");
				System.loadLibrary("System.Security.Cryptography.Native.Android");
			} catch (UnsatisfiedLinkError e) {
				Log.e("GODOT", "Unable to load System.Security.Cryptography.Native.Android library");
			}
		}
		try {
			System.loadLibrary("nightfall-stream.android.template_release.arm64");
			initializeMoonlightJNI();
			jniResult = "SUCCESS";
		} catch (Throwable e) {
			jniResult = "FAILED: " + e.getClass().getName() + ": " + e.getMessage();
		}
	}

	public static void acquireMulticastLock(Context context) {
		if (multicastLock != null) return;
		try {
			WifiManager wifi = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
			if (wifi != null) {
				multicastLock = wifi.createMulticastLock("nightfall-mdns");
				multicastLock.setReferenceCounted(false);
				multicastLock.acquire();
				DiagnosticLog.info("GODOT", "MulticastLock acquired for mDNS discovery");
			}
		} catch (Exception e) {
			DiagnosticLog.error("GODOT", "Failed to acquire MulticastLock", e);
		}
	}

	private final Runnable updateWindowAppearance = () -> {
		Godot godot = getGodot();
		if (godot != null) {
			godot.enableImmersiveMode(godot.isInImmersiveMode(), true);
			godot.enableEdgeToEdge(godot.isInEdgeToEdgeMode(), true);
			godot.setSystemBarsAppearance();
		}
	};

	// Public developer endpoint configuration only. The device private identity
	// stays in Godot's internal user directory and is never exported here.
	public static String getXrControlConfigPath() {
		java.io.File directory = appContext == null ? null : appContext.getExternalFilesDir(null);
		return directory == null ? "" : new java.io.File(directory, "meteor_xr_control.cfg").getAbsolutePath();
	}

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);
		appContext = getApplicationContext();
		browserActivity = new java.lang.ref.WeakReference<>(this);
		DiagnosticLog.initialize(appContext);
		DiagnosticLog.info("BrowserCapabilities", BrowserCapabilities.describe());
		DiagnosticLog.info("GODOT", "Native library initialization: " + jniResult);
		setAndroidContext(appContext);
		acquireMulticastLock(appContext);
		depthEstimator = new DepthEstimator();
		depthEstimator.initialize(appContext);
		DiagnosticLog.info("GODOT", "DepthEstimator initialized: " + depthEstimator.isInitialized());
		usbLinkManager = new UsbLinkManager(appContext);
		DiagnosticLog.info("GODOT", "UsbLinkManager created, supported=" + UsbLinkManager.isSupported());
		java.io.File profileDirectory = getExternalFilesDir(null);
		boolean debugBuild = (getApplicationInfo().flags
				& android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0;
		if (debugBuild) {
			String profileStage = getIntent().getStringExtra("nightfall_depth_profile");
			if (!DepthProfileRunner.isKnownStage(profileStage) && profileDirectory != null) {
				String[] stages = {"f1", "f_half", "direct", "mask", "softmax", "weighted", "standard", "softmax4", "conv4", "conv4_reduceconv", "conv4_zeropad", "conv4_edgepad"};
				for (String stage : stages) {
					java.io.File marker = new java.io.File(
							profileDirectory, "depth_profile_" + stage);
					if (!marker.exists()) continue;
					profileStage = stage;
					if (!marker.delete()) {
						DiagnosticLog.info("GODOT", "Could not remove depth benchmark marker: " + stage);
					}
					break;
				}
			}
			if (DepthProfileRunner.isKnownStage(profileStage)) {
				DiagnosticLog.info("GODOT", "Starting opt-in depth benchmark stage: " + profileStage);
				DepthProfileRunner.start(appContext, profileStage);
			}
		}
		// ADB-friendly one-shot recovery path for the private rotated log after
		// a release-build crash or headset reboot. The marker lives in external
		// app storage; export still uses the same permissionless MediaStore path
		// as the in-app Download Log button.
		if (profileDirectory != null) {
			java.io.File exportMarker = new java.io.File(
					profileDirectory, "export_diagnostics_on_start");
			if (exportMarker.exists()) {
				if (!exportMarker.delete()) {
					DiagnosticLog.info("GODOT", "Could not remove diagnostic export marker");
				}
				DiagnosticLog.info("GODOT", "Exporting diagnostics from one-shot startup marker");
				DiagnosticLog.export(appContext);
			}
		}
		try {
			java.io.FileOutputStream fos = openFileOutput("jni_result.txt", MODE_PRIVATE);
			fos.write(jniResult.getBytes());
			fos.close();
		} catch (Exception ignored) {}
	}

	public static String exportDiagnostics() {
		if (appContext == null) return "ERROR: Nightfall context unavailable";
		return DiagnosticLog.export(appContext);
	}

	public static void submitDepthFrame(byte[] pixels, int w, int h) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.submitFrame(pixels, w, h);
		}
	}

	public static byte[] getLatestDepthMap() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getLatestDepth();
		}
		return null;
	}

	public static void setDepthModel(int modelIndex) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.setActiveModel(modelIndex);
		}
	}

	public static void configureDepth(int modelIndex, int requestedBackend) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.configureDepth(modelIndex, requestedBackend);
		}
	}

	public static void setDepthGpuApi(int api) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.setGpuApi(api);
		}
	}

	public static int getDepthGpuApi() {
		return depthEstimator != null ? depthEstimator.getGpuApi() : 0;
	}

	public static void setDepthGpuPriority(int priority) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.setGpuPriority(priority);
		}
	}

	public static void setDepthHzCap(int hz) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.setHzCap(hz);
		}
	}

	public static int getDepthBackendCapabilities(int modelIndex) {
		return depthEstimator != null ? depthEstimator.getBackendCapabilities(modelIndex) : 1;
	}

	public static int getEffectiveDepthBackend() {
		return depthEstimator != null ? depthEstimator.getEffectiveBackend() : 1;
	}

	public static String getDepthBackendStatus() {
		return depthEstimator != null ? depthEstimator.getBackendStatus() : "Depth runtime unavailable; using CPU";
	}

	public static int getDepthModelSize() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getModelSize();
		}
		return 256;
	}

	public static int getDepthModelWidth() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getModelWidth();
		}
		return 256;
	}

	public static int getDepthModelHeight() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getModelHeight();
		}
		return 256;
	}

	public static int getDepthModelInputWidth() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getModelInputWidth();
		}
		return 256;
	}

	public static int getDepthModelInputHeight() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getModelInputHeight();
		}
		return 256;
	}

	public static float getDepthLastInferenceMs() {
		return depthEstimator != null ? depthEstimator.getLastInferenceMs() : 0f;
	}

	public static float getDepthLastInferenceHz() {
		return depthEstimator != null ? depthEstimator.getLastInferenceHz() : 0f;
	}

	public static float getDepthLastAgeMs() {
		return depthEstimator != null ? depthEstimator.getLastDepthAgeMs() : 0f;
	}

	public static int getDepthLastSkippedFrames() {
		return depthEstimator != null ? depthEstimator.getLastDepthSkippedFrames() : 0;
	}

	// Headset device codename (e.g. "hollywood" for Quest 2, "eureka" for
	// Quest 3) - used by settings_controller.gd to pick a per-device AI-3D
	// Auto table and resolution ceiling (2026-08-27, following a Quest 2
	// user report that AI-3D tanks performance there - the existing
	// AUTO_TABLE was hand-tuned entirely on Quest 3/3s hardware).
	// Build.MODEL is USELESS here - confirmed on a real Quest 3 that it
	// returns the generic "Quest" regardless of generation (likely a Meta
	// compatibility shim), not the marketing name. Build.DEVICE returns the
	// real internal codename instead (matches "ro.product.device"/
	// "ro.hardware" at the system-property level, confirmed "eureka" on
	// that same Quest 3) and is what's actually distinct per generation.
	public static String getDeviceModel() {
		return android.os.Build.DEVICE;
	}

	// One-off diagnostic for the H.264/HEVC hardware decoder dimension limits on this
	// device - queried directly from the platform instead of inferred from trial and error.
	public static String getCodecCapabilitiesInfo() {
		StringBuilder sb = new StringBuilder();
		String[] mimes = { android.media.MediaFormat.MIMETYPE_VIDEO_AVC, android.media.MediaFormat.MIMETYPE_VIDEO_HEVC };
		int[][] sizesToCheck = {
			{ 4480, 1440 }, // our current combined 2-monitor width, 100%
			{ 4032, 1296 }, // same, 90% (known-working H.264 case)
			{ 3840, 2160 }, // hypothetical 2x2 grid of 4x1080p
			{ 7680, 1080 }, // hypothetical 4x1080p horizontal strip
			{ 9600, 1080 }, // hypothetical 5x1080p horizontal strip
			{ 4096, 4096 },
		};
		android.media.MediaCodecList codecList = new android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS);
		for (String mime : mimes) {
			sb.append("=== ").append(mime).append(" ===\n");
			boolean found = false;
			for (android.media.MediaCodecInfo info : codecList.getCodecInfos()) {
				if (info.isEncoder()) continue;
				boolean supportsType = false;
				for (String t : info.getSupportedTypes()) {
					if (t.equalsIgnoreCase(mime)) { supportsType = true; break; }
				}
				if (!supportsType) continue;
				try {
					android.media.MediaCodecInfo.CodecCapabilities caps = info.getCapabilitiesForType(mime);
					android.media.MediaCodecInfo.VideoCapabilities vcaps = caps.getVideoCapabilities();
					if (vcaps == null) continue;
					found = true;
					sb.append("Decoder: ").append(info.getName())
						.append(" hw=").append(info.isHardwareAccelerated()).append("\n");
					sb.append("  supportedWidths=").append(vcaps.getSupportedWidths()).append("\n");
					sb.append("  supportedHeights=").append(vcaps.getSupportedHeights()).append("\n");
					int maxW = vcaps.getSupportedWidths().getUpper();
					int maxH = vcaps.getSupportedHeights().getUpper();
					int[] testWidths = { 1920, 3840, 4096, 4480, 5760, 7680, 9600, maxW };
					for (int w : testWidths) {
						try {
							android.util.Range<Integer> hRange = vcaps.getSupportedHeightsFor(w);
							sb.append("  heightsFor(").append(w).append(")=").append(hRange).append("\n");
						} catch (Exception e) {
							sb.append("  heightsFor(").append(w).append(")=UNSUPPORTED\n");
						}
					}
					for (int[] size : sizesToCheck) {
						boolean ok = vcaps.isSizeSupported(size[0], size[1]);
						sb.append("  isSizeSupported(").append(size[0]).append("x").append(size[1]).append(")=").append(ok).append("\n");
					}
				} catch (Exception e) {
					sb.append("  ERROR for ").append(info.getName()).append(": ").append(e).append("\n");
				}
			}
			if (!found) sb.append("  (no hardware/software decoder found for this mime)\n");
		}
		return sb.toString();
	}

	public static boolean isUsbLinkSupported() {
		return UsbLinkManager.isSupported();
	}

	public static boolean startUsbLink() {
		return usbLinkManager != null && usbLinkManager.start();
	}

	public static void stopUsbLink() {
		if (usbLinkManager != null) {
			usbLinkManager.stop();
		}
	}

	public static boolean isUsbLinkUp() {
		return usbLinkManager != null && usbLinkManager.isUp();
	}

	// Pipe-joined (no address can legally contain '|') since this crosses the
	// JNI boundary as a single jstring - simplest thing that works given
	// there's no JNI String[] round trip already plumbed anywhere else here.
	public static String getUsbLinkAddresses() {
		if (usbLinkManager == null) {
			return "";
		}
		return String.join("|", usbLinkManager.getLinkLocalAddresses());
	}

	public static String getUsbLinkInterfaceName() {
		return usbLinkManager != null ? usbLinkManager.getInterfaceName() : "";
	}

	public static String getActiveNetworkTransport() {
		return usbLinkManager != null ? usbLinkManager.getActiveTransport() : "";
	}

	public static String describeUsbLinkProperties() {
		return usbLinkManager != null ? usbLinkManager.describeLinkProperties() : "(no manager)";
	}

	@Override
	public void onResume() {
		super.onResume();
		BrowserPrototype.pause(false);
		updateWindowAppearance.run();
	}

	@Override
	public void onPause() {
		BrowserPrototype.pause(true);
		super.onPause();
	}

	@Override
	public void onDestroy() {
		BrowserPrototype.closeAll();
		super.onDestroy();
	}

	@Override
	public void onGodotMainLoopStarted() {
		super.onGodotMainLoopStarted();
		runOnUiThread(updateWindowAppearance);
	}

	@Override
	public void onGodotForceQuit(Godot instance) {
		if (!BuildConfig.FLAVOR.equals("instrumented")) {
			super.onGodotForceQuit(instance);
		}
	}
}
