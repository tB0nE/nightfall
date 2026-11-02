# Quest Browser on a readable virtual display

Capability investigation, 2026-11-01. This is a separate tiny Android APK;
Nightfall and the working Linux browser companion are unchanged.

## Question and method

Can an ordinary app put the installed Meta Quest Browser on its own non-secure
virtual display, then read that display for Nightfall rendering/inference?

The probe creates a 1280×720 ImageReader-backed VirtualDisplay, with
OWN_CONTENT_ONLY and PRESENTATION (optionally PUBLIC). It never mirrors the
system display. A green Presentation proves the output is readable; dismissing
it proves the reader sees black before the browser launch. It then uses
ActivityOptions.setLaunchDisplayId and an explicit exported browser activity to
request a fixed neutral page on localhost:6082/color-probe.html. The Linux lab's
web server supplies that page; its browser/profile isn't involved in this test.

Only sparse pixel aggregates, activity metadata and launch results are saved.
No screenshots, browser profiles, cookies, account pages, media or DRM material
are read or exported. No MediaProjection, secure-display flag, root, hidden APIs,
app modification or privileged permission grant is used. ADB launches the probe
and reads its app-private numeric report; the **probe app's own UID** makes the
browser launch request, avoiding a false success from shell privileges.

The self mode tests a non-exported activity in the probe APK. That control
explicitly declares allowEmbedded=true and allowUntrustedActivityEmbedding=true.
The test closes automatically within20 seconds and cleans up its own control
activity, ImageReader and virtual display. Rejected launches finish early.

## Tested result

Quest3, Android14/API34, installed com.oculus.browser
version154.1.0.32.54.1101200317 (code570800940, targetSDK36).

| Test | Result |
| --- | --- |
| Own Presentation | Readable nonblack frame, followed by black on dismissal |
| Own activity without embedding opt-in | Activity launch denied |
| Own activity with embedding opt-in | Launch allowed; readable nonblack activity frame |
| Quest Browser OculusLauncherActivity, private display | Launch denied with SecurityException |
| Quest Browser OculusLauncherActivity, public own-content-only display | Launch denied with SecurityException |
| Direct Chromium ChromeTabbedActivity, public own-content-only display | Launch denied with SecurityException |
| Meta BrowserActivity, private display | Launch denied with SecurityException |

Runtime PackageManager inspection found26 exported Quest Browser activities,
**none** with the legacy allowEmbedded flag used by Android14's untrusted-display
launch check. Public doesn't mean trusted: an app-owned readable display remains
untrusted. The successful explicitly opted-in control distinguishes this from
an ImageReader failure or a blanket lack of secondary-display support.

This blocks the straightforward app-owned-display path **before Netflix/DRM**.
It does not establish whether Netflix capture would succeed through a different
supported mechanism, nor whether a future browser version might opt into
embedding. Do not describe this as Netflix returning a black video rectangle:
we didn't reach Netflix in this experiment.

Primary references:

- [Android ActivityOptions.setLaunchDisplayId](https://developer.android.com/reference/android/app/ActivityOptions#setLaunchDisplayId(int))
- [Android virtual-display flags](https://developer.android.com/reference/android/hardware/display/DisplayManager)
- [Android14 launch policy, ActivityTaskSupervisor](https://github.com/aosp-mirror/platform_frameworks_base/blob/android14-release/services/core/java/com/android/server/wm/ActivityTaskSupervisor.java)
  (`isCallerAllowedToLaunchOnDisplay`: untrusted display requires FLAG_ALLOW_EMBEDDED)
- [Android secure windows](https://developer.android.com/security/fraud-prevention/activities)

## Reproduce

Host JDK17, Android SDK36/build-tools36.1.0, host /usr/bin/python3 and connected
Quest. This standalone APK is dex-compiled with --release; it isn't a performance
benchmark and doesn't replace the release-optimized Nightfall DEV APK.

```sh
export ANDROID_HOME=/path/to/android-sdk
export ADB=/path/to/adb
bash tools/experiments/quest-browser-display/build.sh
"$ADB" install -r .build-cache/quest-browser-display/Nightfall-Browser-Display-Probe.apk
/usr/bin/python3 tools/experiments/quest-browser-display/run.py --mode private
/usr/bin/python3 tools/experiments/quest-browser-display/run.py --mode public
/usr/bin/python3 tools/experiments/quest-browser-display/run.py --mode public \
  --component org.chromium.chrome.browser.ChromeTabbedActivity
/usr/bin/python3 tools/experiments/quest-browser-display/run.py --mode private \
  --component com.oculus.browser.BrowserActivity
/usr/bin/python3 tools/experiments/quest-browser-display/run.py --mode self
```

Each run saves `.build-cache/quest-browser-display/results/<timestamp>-<case>/summary.json`.
The initial diagnostic results are also saved as private-result.json,
public-result.json, self-no-embedding-result.json and self-embedding-result.json
in the same cache root. No keys, APKs or device identifiers are committed.

## Remaining alternatives

- An official Meta surface-sharing/embedding integration would avoid needing
  our own Linux userspace; no such working integration was established here.
- A user-consented MediaProjection capture of the browser's normal window is a
  different experiment. It has foreground/lifecycle, screen selection, input,
  capture scope and protected-video constraints. No capture consent was requested
  in this investigation; do not assume it can supply Netflix frames for AI3D.
- Packaging Quest Browser in an Android container doesn't automatically change
  its embedding policy or carry over its platform services/DRM provisioning.
  It is not a supported fix established by this test.
- Keep the demonstrated Linux Chrome path available while investigating those
  possibilities. Its sandboxing and shipping integration remain separate work.
