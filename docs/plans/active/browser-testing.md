# Standalone browser verification

Screens now offers Browser Res: 1080p (default, 1920 × 1080) or 1440p
(2560 × 1440), including toolbar/page content. Close the browser before changing
this saved setting, then reopen it; no live session is restarted or discarded.
Verify persistence, pointer alignment at all corners, fullscreen video and AI 3D
at both sizes. This does not force a service to supply 1440p video. The larger
surface contains about 78% more pixels.

## Headset feedback — 2026-10-15

Tab-strip feedback on 2026-10-16: position was good, but captions/icons were
blank and selecting tabs felt unreliable. Replaced nested panel/label layout
with self-drawing buttons and explicit caption colours/browser icons. Reuse
existing buttons/physics targets across title and popup updates, and retain UI
press capture while held. Added real-GPU rendering and physics-ray regression
tests (flat and curved layouts), plus action-only logs without page titles/URLs.
Headset confirmation of the rendering change is still required.

Confirmed by user: standalone opening, address/search/invalid input, navigation,
virtual keyboard, YouTube audio/fullscreen, bookmark editing/reordering/removal
and persistence, blocking lists/download/status, on/off comparison, per-site
exceptions and blocking preference persistence.

Later confirmed: Fortnite streams through Xbox Cloud Gaming, Nightfall's Quest
gamepad mode works, and the connected Xbox controller works with the physical
pad compatibility adapter. This is a tested checkpoint, not completed browser
validation. Full cleanup/history, standby/resume, repeated lifecycle stress,
other controllers/services and isolated Android instrumentation remain pending.

Failed: closing the browser with AI 3D enabled removed the screen instead of
restoring welcome. The mono-capture policy incorrectly used the saved stereo
preference even when no primary media remained. Fixed to keep the welcome mono
viewport updating; covered by `test/test_depth_welcome_restore.gd`. Headset
retest pending. The HTTP/Plex fix also requires a rebuilt APK and headset test.

Still unconfirmed: repeated close/reopen, headset standby/resume, AI 3D/depthmap
and model-switch checks, history behavior and cleanup, gamepad diagnostic and
cloud gaming. Do not treat these as passed merely because adjacent features work.

## Host checks

Run `bash test/run_browser_navigation_tests.sh`. The integration case connects
real navigation, bookmarks and history serialization, checks that a history clear
preserves bookmarks, and verifies the local diagnostic contains no network code.
These are not WebView, Android SharedPreferences or permission callback tests.

## Android integration tests (prepared, not yet run)

The real WebView suite is in
`android/src/androidTest/java/com/godot/game/BrowserWebViewIntegrationTest.java`.
It checks protected permission denial, stale cleanup completion after close,
and settings/bookmark persistence across reopening. No cookie deletion is invoked.

After a normal `./build.sh --dev` has prepared `android/build/`, run
`bash test/prepare_browser_instrumentation.sh`. Use that generated Gradle project's
**instrumented** product flavor and `connectedInstrumentedReleaseAndroidTest`
(or its debug equivalent solely for correctness tests). Do not run the standard
flavor against the installed app. The suite asserts a `.instrumented` target
package before opening any browser. The empty test Activity exists only in that
flavor; it is not included in regular release/DEV builds.

The existing test orchestrator clears this isolated package between tests.
Never point it at `app.nightfall.quest`: that would destroy the user's settings.
The tests require working WebView/VirtualDisplay support; they cannot run on a
plain JVM. Rendering, actual cookie/cache deletion and timing remain device tests.

## HTTP / LAN servers

The application permits cleartext HTTP for user-selected sites, including local
Plex servers. Use an explicit address such as `http://10.0.0.13:32400/web`;
scheme-less addresses still default to HTTPS. HTTP is unencrypted, so prefer
HTTPS where available and only use trusted networks for local HTTP services.
This app-wide Android permission does not bypass HTTPS certificate validation
or change WebView's mixed-content policy. The Android integration suite checks
the effective platform policy; loading a real Plex server remains a device test.

## Gamepad investigation

Android reports controller buttons as KeyEvents and axes as generic MotionEvents:
[Android controller input](https://developer.android.com/games/sdk/game-controller/controller-input).
Chromium's WebView implementation includes GamepadList integration:
[AwContents source](https://chromium.googlesource.com/chromium/src/+/main/android_webview/java/src/org/chromium/android_webview/AwContents.java).
That does not prove the installed Quest WebView exposes it correctly in a
VirtualDisplay, nor that Xbox accepts this browser.

Physical gamepad events now go directly from the Activity to the focused WebView,
preserving source/device IDs, corrected buttons and analog MotionEvents. They do
not also go to Godot. Outside browser focus, the existing Godot path remains.
Held buttons and axes are released on pause, focus loss, panel opening, device
removal and close. Nightfall's own menu/keyboard also blocks gameplay input.

The user confirmed Quest PAD mode works in Fortnite, but the physical Xbox pad
still did not appear. Android logged button A from Xbox Wireless Controller
(vendor 045e/product 0b13), ruling out a basic pairing failure. Native WebView
acceptance versus routing focus was not proven by that old log. Added bounded
`BrowserGamepad` route diagnostics plus a browser-local Android snapshot fallback
through the working adapter. It uses Android axis IDs/ranges, normalized analog
triggers, and both key/hat D-pad input. A matching native WebView pad is preferred
to avoid duplication; Quest input remains unchanged and takes priority while
Quest PAD mode is active. Initially only one physical fallback pad is supported.
Physical input remains held between Android change events until explicitly
released, unlike the periodically submitted Quest state. User retest confirmed
the Xbox controller works in Fortnite.

Quest PAD-HAND/PAD-ABXY now works without a PC connection and submits full state
through a separate, explicitly experimental JavaScript Gamepad API adapter. This
is not an Android virtual HID device. It preserves native physical pads, adds a
standard-layout software pad in a free slot, and dispatches synthetic connection
events. Sites that require native Gamepad objects/trusted events, haptics or other
browser-specific features may not accept it. No haptics are implemented here.

The adapter is installed before page scripts via AndroidX WebKit 1.12.1's
[document-start API](https://developer.android.com/reference/androidx/webkit/WebViewCompat#addDocumentStartJavaScript(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E)).
Unsupported providers log that the Quest bridge is unavailable. A read-only
WebMessage listener supplies state, with no webpage-to-OS input authority; frames
whose browser permissions policy disallows gamepads do not install the adapter.
Godot state expires after 350 ms, and the JavaScript snapshot has a 500 ms
watchdog. Menu opening, mode disable, pause and close also clear state explicitly.

Home now includes a local **Gamepad diagnostic**. Click Activate, then press a
Bluetooth/USB gamepad button and move both sticks/triggers. Record API availability,
secure context, focus, detected pad/mapping, button values and axes. It uses no
network, accounts or subscription. It can display both native and software pads.
The live display remains local; it is not automatically written to logs.

Next routing tests: browser closed -> unchanged Godot input; browser active but
menu/address focused -> no game input capture; browser page focused -> original
button down/up and joystick events reach WebView exactly once; browser pause,
close, device removal and resume -> no stuck controls or late queued events.
Host tests cover the actual adapter script, native-pad preservation, button and
axis mapping, expiration, software connection events, and Godot browser/menu/PC
routing. End-to-end Android input dispatch and Xbox acceptance still need testing.

The user confirmed Fortnite video streaming on Xbox Cloud Gaming, but neither
controller path worked before this wiring. Test physical Xbox first, then enable
Nightfall gamepad mode and test Quest controllers separately. Hide Nightfall's
menu/keyboard and focus the browser game. Do not infer controller compatibility
from the probe alone.
