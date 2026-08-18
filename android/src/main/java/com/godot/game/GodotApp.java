package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.util.Log;

import androidx.activity.EdgeToEdge;
import androidx.core.splashscreen.SplashScreen;

public class GodotApp extends GodotActivity {
	public static native void initializeMoonlightJNI();
	public static native void setAndroidContext(Object context);

	public static String jniResult = "NOT_RUN";
	public static DepthEstimator depthEstimator;
	public static WifiManager.MulticastLock multicastLock;

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
				Log.i("GODOT", "MulticastLock acquired for mDNS discovery");
			}
		} catch (Exception e) {
			Log.e("GODOT", "Failed to acquire MulticastLock: " + e.getMessage());
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

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);
		setAndroidContext(getApplicationContext());
		acquireMulticastLock(getApplicationContext());
		depthEstimator = new DepthEstimator();
		depthEstimator.initialize(getApplicationContext());
		Log.i("GODOT", "DepthEstimator initialized: " + depthEstimator.isInitialized());
		try {
			java.io.FileOutputStream fos = openFileOutput("jni_result.txt", MODE_PRIVATE);
			fos.write(jniResult.getBytes());
			fos.close();
		} catch (Exception ignored) {}
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

	@Override
	public void onResume() {
		super.onResume();
		updateWindowAppearance.run();
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
