# Quest Linux browser experiment — session handoff

> Current checkpoint: [2026-11-02 status and resume notes](QUEST_COMPATIBILITY_BROWSER_STATUS_2026-11-02.md).
> Working software baseline retained; experimental Linux GPU mode disabled.


> Activity-reporting correction (2026-11-02): earlier claims that Horizon was
> blocking launches are not established. The test reporter selected the last
> resumed activity across multiple displays, often the taskbar even when
> Nightfall was resumed. Reporter corrected; a plain GPU-experiment-off launch
> reached XR-ready in ~2.65s. GPU hangs remain independently confirmed.


> **Latest status (2026-11-02): GPU mode disabled after confirmed device-wide GPU hangs during interactive use. See the CRITICAL incident section at the end before running graphics tests.**

Date: 2026-10-31. The user is rebooting into Windows for other development and
wants to return to this experiment later.

## Resume update — 2026-11-01

Continued on `codex/quest-linux-browser-spike`. New work is currently uncommitted.
Read the updated integration plan and lab README: a direct CPU-copy framebuffer
path is now implemented, built and installed in release-optimized DEV Nightfall.
Controlled video through VNC reached only 11–13 picture updates/s despite ~30 fps
decode and 60 fps app rendering. The direct path measured about 26–30 posts/s,
and AI inference remained around 29–31 ms / 19–20 Hz. These are generated-clip
results, not Netflix performance or visual correctness confirmation.

The helper maps Xvfb's private `-fbdir` XWD file and draws to the existing
Nightfall browser Surface via an explicit Binder service restricted to Nightfall's
UID. Only DEV builds can activate it. Android package visibility required an
explicit helper query in the DEV manifest. A Linux Browser Lab shortcut is now
on the DEV browser home page (not a persisted user bookmark).

Latest APKs installed in place: `Nightfall-Android-arm64-v8a-dev.apk` and
`.build-cache/browser-quest-linux/lab-build/Nightfall-Browser-Lab.apk`.
Final stop/restore/re-attach check reported `stopped`, restored **Nightfall Home**,
and reattached successfully. Browser policy/data/gamepad suite passed again.
The optional offscreen probe has not completed and is not a passed check.

At this checkpoint the helper/runtime and Nightfall are running, the generated
clip is playing through direct display, and AI 3D is enabled. ADB forwards include
47950, 5902, 6082 and 6083. Temporarily forced worn/Guardian properties were used
for desk checks; run `quest.py sleep` when ending testing. User-visible visual
quality, colors, tearing, A/V sync, sustained thermals and standby remain to test.
Controller clicks into Linux are not routed yet in direct mode; input still goes
to the normal WebView. Use RFB desk input for now. The direct path targets 30 Hz,
uses CPU copies and lacks source frame fences. Never claim zero-copy or readiness
for production. No Chrome/CDM/profile was exported and no pairing data was reset.

Detailed raw measurements live in ignored
`.build-cache/browser-quest-linux/performance-20261101/`, including
`foreground-polling-ab.json`, `direct-active-samples.json`,
`direct-active-ai-on.json`, `direct-final-installed.json` and
`direct-final-roundtrip.json`.

Later in the same session, GPU drawing was implemented and installed as the
direct renderer default. XWD bytes take a native bitmap copy; GPU canvas handles
scaling and color-channel correction. The successful offscreen probe delivered
299 frames in ten seconds and had zero error across 780 sampled RGB channels on
a synthetic chart. This supersedes the earlier pending-probe status above.

Live 720p60 generated-video tests with AI enabled reached producer rates 60.0,
71.6 and 90.0 at corresponding app targets, with source non-dropped rates about
59–60/s. CPU submission/copy work dropped to around 2–3 ms per frame. Not isolated
GPU timing, Netflix performance, zero-copy or hardware decode. The helper follows
XR refresh bounded by app render cap, and exposes posting-interval jitter.
Source-frame fences and true vsync pacing remain outstanding.

Latest state: GPU direct path at 72 Hz, AI on, 60 fps generated clip playing.
The original host FPS preference observed was 120; session testing changed the
in-memory value to 72 without calling save. Both controllers last reported
inactive tracking; user was told to wake them, no mappings changed. Source changes
remain uncommitted and private models/profiles remain excluded from Git; no new
commit or push was requested.
Additional artifacts: `gpu-color-probe.json`, `gpu-refresh-sweep.json`,
`gpu-final-72.json`, and GPU build/test logs under the existing ignored cache.

Latest follow-up: the user fixed the controller by removing/reinserting its
battery and restored Primary Hand to Right. Do not keep treating this as an app
controller regression. Netflix was then opened in the existing Chrome profile
via RFB input. The user confirmed it looked good even with AI enabled and then
turned AI off for the baseline. AI-off: 25 seconds, 72.0 posts/s, no missed slots.
AI was re-enabled for a completed 300-second run: 31 samples, 71.98 posts/s,
seven missed producer slots, no bridge errors, advancing nonzero audio, and
changing sampled framebuffer hashes. Final inference: 31.8 ms / 19.9 Hz.
Battery temperature 41–43 C; final Android thermal status 0. Lip sync and fan-noise
feedback remain pending; decoded Netflix fps was not measured.

Netflix is currently playing with the direct GPU path, 72 Hz and AI enabled.
The five-minute measurement process finished; no measurement terminal remains
running. Numeric-only sampling tool: `measure-playback.py`. Results are in
`.build-cache/browser-quest-linux/playback/` and
`performance-20261101/netflix-comparison-summary.json`. No media/profile captured.

Latest 1080p follow-up: user confirmed lip sync fine and fans much better, but
picture soft. Changed lab Xvfb/Chrome default to 1920×1080, with a validated
`/tmp/nightfall-display-size` 720p fallback. Helper APK rebuilt/installed in place;
main APK unchanged. GPU renderer reports 1920×1080 source and output. Netflix's
normal playback statistics initially showed 1280×720 / 30 fps / ~1024 kbps video,
~234s buffered and ~14Mbps throughput. Do not claim 1080p Netflix stream delivery.
Fullscreen adaptation not reverified. Performance attempts were invalid because
Nightfall paused behind ClearActivity; need a worn, foreground 30-second sample.

Keyboard diagnostics briefly navigated away and changed player state; corrected
by paced RFB control, restoring the same Netflix title and fullscreen, unmuted
playback. Diagnostics/extra tab closed. Temporary screenshots deleted; only
numeric stats retained in `netflix-1080-resolution-check.json`. No credentials,
profile files or DRM internals accessed. `rfb-control.py` is input-only and uses
Alt+D for navigation. Long console input was unreliable; don't repeat blindly.

Latest input work: user complained screen clicks did nothing. Implemented direct
pointer and virtual-keyboard forwarding in BrowserPrototype/LinuxFrameLabClient,
through the existing UID-restricted helper Binder service. LinuxRfbInput sends
only input, with no framebuffer requests; GPU display remains unchanged. Input
coordinates normalize from the Android Surface to actual Linux dimensions.
Modifier/special-key handling and held-state cleanup are included. No saved
controller preference or mappings were changed.

Both APKs built and installed, browser regressions passed, and the helper input
socket reported `ready` at 1920×1080. Exact end-to-end native-input test is pending:
the first test timed out when Nightfall paused. A user-input request is pending
to reopen Nightfall for ~30 seconds. Current source page should be
`http://127.0.0.1:6082/input-probe.html`. It reports only numeric counters to the
existing metrics server. Test through `browserPointerFor` / `browserKeyFor`, not
the separate PC rfb-control tool (that would bypass the new path). Target button
at Surface pixels (960,350), text field at (960,700), for the current 1920×1080
layout. Verify clicks, held drag, A/Shift+B, Insert and released modifiers.
Then restore the original Netflix video using the paced RFB tool. Do not claim
the native input fix verified until this test actually completes.

Input verification update: user opened the temporary test page, and the native
path test passed. Counters: clicks=2, downs=ups=3, held-move=1, keydowns=keyups=4,
input length=2 (A/Shift+B), Insert=1, Shift released. The test used the same
`browserPointerFor`/`browserKeyFor` entry points as controller/virtual-keyboard
input, not the separate RFB driver. Saved `native-input-probe.json`.
Netflix then restored with paced RFB navigation. Short active 1080p reload sample:
57.3 producer posts/s, 24 missed slots, six samples without bridge errors. Audio
PCM/head advanced but no nonzero samples in that short window, so do not claim
audible playback; user can now click Play/unmute. A settled 1080p Netflix run,
physical hit alignment and focus-loss cleanup remain to check. Do not confuse
this short reload sample with the earlier healthy five-minute 720p run.

Latest performance rollback: user confirmed pause/fullscreen clicks worked but
reported worse performance. Restored source/default to 1280×720 and kept input.
1080p remains opt-in via guest `/tmp/nightfall-display-size`. Added a DEV-only
direct-start timing fix: boot had applied default 60 app fps / 120 Hz before
loading saved 72 fps; first direct activation now reapplies loaded timing. Exact
fresh-boot test passed from `[72,120,60]` to `[72,72,72]`, saved as
`direct-startup-timing-fix.json`. New release-optimized DEV main APK installed;
helper APK unchanged from input-enabled version, profiles/pairings retained.

Native pointer/typing rechecked at 720p source with the same 1080p Surface and
passed (`native-input-720-rollback.json`). Latest producer status: ~72 posts/s,
~0.56 ms copy + ~1.21 ms submission, source1280×720/output1920×1080. Not a matched
active-video performance result: the attempted 20-second Netflix window had only
bridge timeouts after the headset was put down. Netflix is restored, controls
enabled, intended target 72 Hz. Ask user to press Play and compare; do not claim
the post-rollback Netflix performance is already confirmed. No measurement task
remains running. User's Right primary-hand preference remains untouched.

## Branch and scope

- Resume branch: `codex/quest-linux-browser-spike`.
- Based on `codex/bundled-host-testing`, commit `fd5629c`.
- Main checkout: `/var/home/tyrone/Development/Personal/moonlight-quest`
  (`/home/tyrone/Development/Personal/moonlight-quest` resolves to the same place).
- README/controls edits were pending user review. They are saved in their own
  commit as a checkpoint, not a claim that the review is finished.
- No PR or release is requested for this experiment. Do not merge these lab
  assumptions into the shipping browser or lower Nightfall's Android target SDK.

## What works, and what does not

The user confirmed **Netflix video, sound and AI 3D work inside Nightfall**.
This runs official ARM64 Linux Chrome locally on Quest 3 through Ubuntu userspace
and PRoot, using Android's existing kernel. It is not a VM or CPU emulation.

Performance is poor and the user heard high fan activity. This is the main
outstanding engineering issue, not DRM feasibility. The user paused playback
before the last resource sample, so those idle numbers cannot diagnose the
active video bottleneck. Lip sync and sustained performance remain unverified.

Native Android WebView: DEV-only protected-media grants plus a desktop Netflix
UA bypassed the app prompt, but playback failed with a session-expired M7111
family code; the full suffix was not supplied. That is separate from the working
Linux Chrome path. YouTube now uses its regular desktop site instead of TV/mobile.

Desktop experiments:

- x86 Ubuntu/Chrome KVM VM played Netflix through noVNC. Its files are retained.
- ARM64 QEMU/TCG desktop VM was far too slow to test usefully. Its container and
  cache were deleted at the user's request. Source scripts remain as reference.
- Quest Linux was bootstrapped from official Ubuntu Base ARM64 instead of copying
  the slow VM filesystem. No VM browser profile or login was transferred.

## Current implementation

Source: `tools/experiments/browser-quest-linux/`.

- Official Ubuntu Base 24.04.5 ARM64, Chrome 156.0.8078.79, Termux PRoot
  5.1.107.101 plus its Android libraries. Observed package hashes are in
  `tested-packages.json`; downloaded binaries are not committed.
- Separate Android package: `app.nightfall.browserlab`, title
  **Nightfall Linux Browser Lab**, with a foreground media service.
- Chrome -> Xvfb -> x11vnc -> threaded websockify/noVNC -> existing Nightfall
  browser WebView/canvas -> existing uploader/renderer/inference pipeline.
- PulseAudio monitor -> `parec` PCM16 stereo 48 kHz -> process stdout pipe ->
  Android AudioTrack. No microphone permission/capture. Audio focus is handled;
  GAME usage and no-spatialization are requested. System volume was not changed.
- Main Nightfall APK was not rebuilt for the localhost integration. The earlier
  desktop-UA/permission change was built as a release-optimized DEV APK using
  BUILD.md. Installed version observed: `0.9.0-preview.1-dev+fd5629c-dirty`.
- Browser URL: `http://127.0.0.1:6082/vnc.html?autoconnect=true&resize=scale`.
  The PC can view the same Quest browser through an ADB forward. It does not
  receive audio; audio plays on Quest.

The companion intentionally targets SDK 28 and currently requires Chrome
`--no-sandbox`. Those are lab limitations, not a shippable design. PRoot is not a
security boundary. Loopback endpoints are unauthenticated lab interfaces; proper
private/authorized IPC is required before production integration.

## Crash investigation and verification

Android's log explicitly recorded the original PRoot tracer being killed with
`Trimming phantom processes`. The device's configured limit is 32. Subsequent
ENOSYS thread/socket errors and a PulseAudio assertion followed the tracer kill;
do not misdiagnose those secondary errors as a Netflix rejection.

The lab now uses a threaded proxy, fewer Chrome background/extension processes
and a renderer-process limit. Chrome retains its standard launcher: bypassing it
or using `--no-zygote` caused FD ownership/GPU-process failures in this setup.
No global Android child-process setting was changed.

- Seven-minute monitored clear-video test retained the same tracer, HTTP 200 and
  at most 22 app child processes. At 476 seconds the video counters showed
  14,059 frames, zero drops and no error.
- Audio-enabled run had about 25 children, delivered non-zero PCM and showed
  advancing Android playback-head frames. The service retained focus and ran
  in the background with Nightfall foreground.
- EME Widevine access and `createMediaKeys()` succeeded on the local probe page.
- Browser Java policy/data/gamepad test suite passed; shell syntax checks and
  lab APK compilation/signature checks passed. The newly added isolated Android
  instrumentation test was **not run**; do not claim otherwise.
- User later confirmed Netflix sound and AI 3D inside Nightfall, but poor speed.
- A system screenshot of Nightfall was black even while the user confirmed the
  page was visible. Do not equate that capture with a black-content regression.
- After the user returned, Nightfall had closed and both XR controllers initially
  reported inactive. Relaunching Nightfall and waking the controllers restored
  input; the user confirmed controllers work. No controller code/pairing changed.

## Preserve these files and data

Host cache, ignored by Git, is deliberately under the project rather than /tmp:

- `.build-cache/browser-quest-linux/` — downloaded packages, provenance, controlled
  test MP4, logs, screenshots and JSON summaries.
- `.build-cache/browser-quest-linux/lab-build/Nightfall-Browser-Lab.apk`.
- **`.build-cache/browser-quest-linux/lab-build/lab.keystore`** — keep this key for
  future in-place companion updates. A new key will not update the installed lab.
  Do not uninstall to bypass a signing mismatch: that deletes its browser profile.
- `.build-cache/browser-drm-research/` — initial device capability evidence and
  Nightfall DEV build log.
- `.build-cache/browser-drm-vm/` — retained x86 VM disk/profile/key and tooling.
- `.build-cache/session-handoffs/quest-linux-browser-2026-10-31/` — local snapshot
  of the tested APKs, lab signing key and non-account diagnostic summaries.

Headset data persists independently of rebooting the PC:

- `/data/user/0/app.nightfall.browserlab/files/linux/` — actual app-owned runtime.
- Its `rootfs/home/browser/chrome-lab/` is the working Chrome profile/login.
  **Do not read/export/commit this profile or remove it during setup.**
- `audio-status.json`, `audio-process.log`, `desktop.log`, `desktop.previous.log`
  are inside the app-owned runtime directory.
- `/data/local/tmp/nightfall-browser-linux/` is the initial staging copy. It is
  not the current profile. `install-lab.sh` preserves the companion's home/profile
  when copying from staging.

These caches/keys/profiles must stay out of Git. APKs are not release assets.
Shutdown completed before the Windows reboot: Chrome was closed normally; the
lab service and Nightfall were stopped; normal headset proximity/sleep behavior
was restored and test ADB forwards removed. The x86 VM powered off cleanly and
its container exited with code 0. All profiles, VM disks and caches were retained.

## Resume without reinstalling or resetting anything

Read AGENTS.md, `docs/guides/agent-testing.md`, BUILD.md and the lab README first.
Do not use desktop Gamescope/Vulkan UI tests: a previous test reset this desktop.
Use `/usr/bin/python3` and the real host tools, not container Python.

On this Linux machine, the usable SDK is
`/home/linuxbrew/.linuxbrew/share/android-commandlinetools`, and JDK 17 is
`/home/linuxbrew/.linuxbrew/opt/openjdk@17`.

```sh
git switch codex/quest-linux-browser-spike
git pull --ff-only
export ANDROID_HOME=/home/linuxbrew/.linuxbrew/share/android-commandlinetools
export JAVA_HOME=/home/linuxbrew/.linuxbrew/opt/openjdk@17
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
adb devices

# Start the installed companion; this explicitly selects the existing lab-only
# sandbox-disabled configuration. The default UI checkbox remains off.
adb shell am start -n app.nightfall.browserlab/.BrowserLabActivity \
  --ez start_lab true --ez unsafe_no_sandbox true
adb forward tcp:6082 tcp:6082
```

Wait for HTTP 200 at port 6082. If needed, open the PC viewer at the full URL above.
Wear the headset/confirm any boundary dialog and open Nightfall. Open a browser
screen and enter that same localhost URL. Use the normal primary-browser AI 3D
controls. No connection to Sunshine, Meteor or a PC stream is needed for this test.

If an ADB launch reports success but Nightfall is not visible, open it from the
Quest app library. `quest.py status` helps distinguish library/Guardian focus.
When controllers are inactive, wake them with a button and check tracking before
editing mappings. For desk-side checks `quest.py awake` temporarily simulates
being worn; undo with `quest.py sleep` when done. Sleep can stall the Android
hardware audio counter even while the Linux audio bus is running.

For an in-place lab update:

```sh
bash tools/experiments/browser-quest-linux/build-lab.sh
adb install -r .build-cache/browser-quest-linux/lab-build/Nightfall-Browser-Lab.apk
```

Changes to `start-desktop.sh`, `forward-audio.sh` or the static lab pages must also
be copied into the companion's app-private runtime; see `install-lab.sh`. A Java
APK update does not automatically update those external Linux files. Do not rerun
`deploy.sh`/full setup unless rebuilding the Linux environment is actually needed.
The optional full setup installs its packages in the staging directory first.

Stop the lab with its button/notification, or:

```sh
adb shell am force-stop app.nightfall.browserlab
```

## Next work, as requested by the user

Detailed plan: `docs/plans/active/quest-linux-browser-integration.md`.

1. Measure an **active** controlled clip with AI 3D off/on. Distinguish Chrome
   decode, Xvfb capture, RFB encoding, canvas/upload and XR presentation rates.
   Do not call a paused sample a playback benchmark. Hardware video decoding on
   Quest is unestablished; the lab explicitly uses software graphics.
2. Replace the VNC/canvas presentation path with a measured direct local frame
   path. Do not promise this alone solves software video-decoding cost.
3. One shared Linux environment/browser runtime, with Nightfall managing tabs and
   independent views for visible screens. Do not start a runtime per screen.
   Ordinary background Chrome tabs are not ready-made independent live surfaces;
   prove two views and manage hidden-tab rendering/audio deliberately.
4. Touch-style controller input, with mouse fallback. Hide the inner mouse cursor
   but retain Nightfall's aiming indicator. Keep desktop website identity; touch
   support must not trigger Netflix's mobile-app requirement again.
5. Keep official Chrome initially; custom browser chrome/UI is realistic. A new
   embedded engine/custom CDM integration must re-establish service compatibility
   and licensing rather than assuming the working Chrome result transfers.
6. Preserve one on-headset inference target. Profile combined GPU/memory/process
   costs instead of estimating from number of tabs. The earlier raw-buffer memory
   figures were calculations, not measured total browser memory.
7. Resolve sandboxing, modern executable packaging/target SDK, component terms,
   authorized private IPC, background lifecycle and A/V sync before release.

Windows work is separate. The browser lab has not been ported or packaged for a
Windows host, and is not an intended part of the upcoming normal release yet.

## Update: desktop pointer stalls, not confirmed video regression (2026-11-01)

User clarified the video looked smooth but the Linux Chrome desktop cursor
stuck; Nightfall's aiming dot was not the reported problem. A fresh 15-second
playback sample had changing source hashes, nonzero audio and ~71.8 producer
posts/s (`playback/cursor-report-playback-20261101T130152Z.json`). This does not
establish movie decoded FPS. Do not pursue CPU scheduling changes based solely
on the earlier paused-state samples.

Measured hover-only native events against guest XQueryPointer: 9–227 ms before,
25–50 ms after live `-nofb`, and 10–32 ms after deploying a dedicated input-only
x11vnc listener on localhost:5903. Ordinary idle-sleep tuning alone did not help.
Normal VNC/noVNC stays on 5902; GPU display is unchanged. Updated start-desktop.sh
and rebuilt companion installed in place, preserving Chrome profile and data.
The main Nightfall APK was not rebuilt. See lab README for configuration and
numeric artifacts. Physical-controller feel still needs user confirmation.

Post-install native input probe passed: click, matching button down/up, typing,
Insert and matching key down/up. Both the normal VNC navigation path and new
5903 input path worked. Netflix was restored for the next physical test.

User confirmed desktop cursor is much smoother. At their request, switched the
runtime override back to `1920x1080` for comparison, restarted Chrome gracefully
and reattached direct display. Verified source/output1920×1080 and input listener
5903 reporting matching1920×1080 dimensions. Improved input path retained; default
start-desktop.sh stays720p with the per-device override selecting1080p. Netflix
watch page restored. This changes browser rendering resolution, not a guarantee
of Netflix's encoded video resolution. Initial startup counters are not a settled
playback benchmark.

## Quest Browser output investigation (2026-11-01)

User asked whether the native Meta browser could replace Linux Chrome. Added a
separate disposable probe under tools/experiments/quest-browser-display/, with
its own APK/package; Nightfall and Linux companion were not replaced. A readable
Presentation works; a same-UID activity also works once explicitly opted into
embedding. Installed Quest Browser's normal launcher is denied on both private
and public own-content-only displays; direct ChromeTabbedActivity is denied too.
All26 exported browser activities lack the Android14 allowEmbedded opt-in.
This is an activity-launch gate, not a demonstrated DRM/capture failure. No
Netflix page, secure surface, browser profile or DRM material was examined.
See the probe README and ignored numeric summaries for reproduction and limits.
The straightforward native-browser app-owned-display route isn't currently
usable with ordinary app privileges on this tested browser version. User-consented
MediaProjection would be a separate, unproven route, with protected-content and
window/input/lifecycle limitations. The working Linux runtime remains1080p with
the dedicated low-latency input endpoint on5903.

## Latest: content-only/touch compatibility tab — NOT DEPLOYED (2026-11-01)

User agreed to one compatibility tab and requested no inner cursor, touch
scrolling and no Chrome UI. Implemented LinuxBrowserControl.java (CDP touch,
coalesced moves/scroll, cached URL/title/history and page navigation), app/kiosk
Chrome flags and Xvfb-nocursor. Keyboard stays on input-only RFB5903. Main DEV
integration adds a globally single compatibility-tab slot, normal-tab suspend/
return, native address/navigation routing, and a DEV menu entry gated on the
companion package being installed. Ordinary WebView tabs remain the default.
This is not production runtime installation/startup or settings integration.

Release-optimized main DEV build and companion build completed. Browser Java
regressions and headless screen-tab-strip test pass; latter covers fifth menu
row hover/artwork coverage. ADB has NO DEVICES: deployment attempt stopped at
its initial port-forward step, BEFORE modifying the headset. User was asked to
reconnect. Therefore headset still has previous working1080p/cursor-input build.
No physical touch, kiosk/full-viewport, Netflix or tab round-trip validation yet.

Next: reconnect, detach direct display, gracefully close Chrome, deploy updated
start-desktop.sh/input-probe.html/frame-metrics.py; install both APKs in place;
restart lab service and main app, wait for CDP9222 and marked neutral app target,
then activate direct display. Run verify-touch.py --restore-netflix (new tool,
not yet run on device). Inspect summary and touch-status.json. Verify Netflix
still plays with desktop identity and touch emulation. See active plan/README
for remaining security/lifecycle/integration limits. Changes remain uncommitted.

## Latest deployment update: touch/content-only build INSTALLED and smoke-tested

Quest reconnected. Both updated APKs installed in place; runtime scripts/probe
page/metrics deployed and lab restarted. Nightfall running at72Hz, direct source
1920×1080. First test caught a scrollbar-coordinate mismatch: CDP LayoutViewport
reported1904px whereas innerWidth is1919px. Helper now reads only numeric window
innerWidth/innerHeight for mapping; rebuilt and installed that correction too.

Native generated-page check PASSED:
`.build-cache/browser-quest-linux/touch-check-20261101T151104Z/summary.json`.
Taps, typing, Insert, touch lifecycle, touch scrolling and ordinary-tab round trip
passed. Viewport1919×1079 within1920×1080 source: one-pixel border, no Chrome
toolbar. Home/Back/Forward/Reload checks PASSED in touch-navigation-check.json.
Netflix is selected again. User still needs to confirm physical touch feel and
Netflix playback/AI3D under this new mode; do not claim movie playback proven by
page-navigation checks. Code changes remain uncommitted.

## Latest fixes after touch feedback — deployed, generated-page checks passed

User heard playback after closing compatibility tab, couldn't drag-scroll, and
Netflix profile controls didn't activate. Found touch-status.json error:
SocketTimeoutException. Controller previously closed permanently on error;
Surface close didn't stop independent LinuxAudioPlayer.

Helper changes: BrowserLabService.suspendAudio/resumeAudio invoked from Surface
lifecycle; control.close best-effort pauses HTML media. Both tab switching and
closing now suspend audio; no background-audio continuation for now. Vertical
10px drag threshold cancels native touch and applies pixel wheel scroll, avoiding
website touch-action restrictions. Emulation hides scrollbars. Invisible mouse
hover supports desktop menus. Controller retries transient failures and reports
operation/reconnect count; periodic metadata uses history without Runtime.eval
on every poll. No main APK rebuild was needed for these follow-up fixes.

Installed rebuilt helper + updated generated probe and metrics collector.
Verification PASSED: `.build-cache/browser-quest-linux/touch-check-20261101T152717Z/summary.json`.
237px drag-only scroll, profile-style hover menu activated, scrollbar width0,
input/Insert, normal-tab round trip, known active generated audio stopped after
switch and after close-last-tab; reopen succeeded. Netflix restored afterwards.
Netflix-specific profile behavior and playback still require user confirmation;
reconnect logic wasn't fault-injected. All current changes remain uncommitted.

## Navigation/low-quality investigation and obsolete shortcut (2026-11-01)

User reports slow/stuttery drag/navigation and low movie quality. Added
browser-diagnostics.py to read allowlisted CDP GPU features/decoder/video counters
without exporting URLs, media or account data. Captured
browser-diagnostics-20261101T153939Z.json: Chrome confirms gpu_compositing,
rasterization and video_decode are software; no accelerated decode capabilities.
The Android hardware Canvas only accelerates final copy/presentation, not Chrome.
Last loaded video960×540 with31s buffer; cumulative237 dropped/762 total frames,
but ALL samples paused. These are NOT active-playback drop measurements and do
not establish why Netflix selected540p.

Generic HTTPS test (network-comparison-20261101*.json): three3MB downloads inside
Quest Linux~30/52/77Mbps; host~65/72/60Mbps. No proxy configured. Does not measure
Netflix CDN, Wi-Fi local GameStream throughput or rule out CDN-specific issues.

User then reported opening Browser → Linux Lab, seeing the desktop cursor again
and very stuttery video. Source confirms the old homepage Linux Browser Lab link
still opened performance-viewer.html (VNC), not direct compatibility mode. ADB
had disconnected, so live route couldn't be verified. User was directed to
three-line menu → Compatibility browser and asked to reconnect USB. Replaced
homepage link with Compatibility Browser and intercepted both new/legacy lab
shortcut URLs to activate direct display. Native regression tests pass; a new
release-optimized DEV build is being prepared under
.build-cache/browser-quest-linux/direct-shortcut-main-build.log. NOT yet installed
at this note. Keep explicit vnc.html as desk-side diagnostic fallback, not primary
user entry. New code remains uncommitted.

Next: install shortcut correction once USB reconnects; verify route before
comparing video or navigation. Fresh ACTIVE playback stats still needed.
GPU-driver work is a separate unimplemented investigation: rootless Adreno Linux
Mesa/Turnip/KGSL or Android graphics bridging may be possible, but driver access,
Chrome compositor/surface interoperability and video decode need separate proof.
Do not just remove --disable-gpu and claim hardware acceleration.

## Shortcut correction installed and verified after reconnect

Quest reconnected; battery38%, status charging, Android flags Weak Charger=true
(max charging values reported5V/2A, not a measurement of delivered power).
Installed release-optimized direct-shortcut-main-build APK in place. Horizon
ClearActivity initially paused app; user reopened it. Both legacy address entry
and a real WebView hyperlink now activate direct compatibility mode:
`.build-cache/browser-quest-linux/direct-shortcut-check.json` PASSED. Netflix
selected and automation's virtual keyboard hidden afterwards. No VNC entry is
advertised on the updated homepage.

Read-only guest inspection: /dev/kgsl-3d0 exists and os.access reports read/write;
no /dev/dri nodes or Vulkan ICD JSONs in /usr/share/vulkan/icd.d. Mesa DRI filenames
exist, including kgsl_dri.so, but filenames/permission checks alone do not prove
usable acceleration, SELinux allowance for required ioctls or driver compatibility.
Saved linux-gpu-interfaces.json. No driver/GPU configuration changed.

## Confirmed ACTIVE direct-path playback sample

After installing/verifying the corrected shortcut, a15–16s sample captured active
Netflix throughout (9/9 active samples): browser-diagnostics-20261101T164532Z.json.
960×540→768×432,336 total frames advanced and53 dropped (~15.8%); buffer grew
30.6→32.8s. This is real player-side dropping/low rendition with healthy buffered
content, not just an old cumulative counter or a VNC capture rate. Chrome still
reports software compositing/rasterization/video decode. Generic HTTPS throughput
previously30–77Mbps does not rule out Netflix-specific CDN/adaptation effects.

Read-only active CPU allocation confirms helper, PRoot, Xvfb and all Chrome
children limited to cpuset foreground / CPUs0–2 while Nightfall is active.
active-browser-cpu-allocation.json records the snapshot. Chrome's software GPU
process used~65% CPU in the short top sample, helper~29%, tracer~12%; doesn't
establish exact bottleneck. No scheduling changes made yet. Main
LinuxFrameLabClient still binds via Application context + AUTO_CREATE only;
legitimate IMPORTANT/ADJUST_WITH_ACTIVITY binding and Activity context is a
possible separate scheduling experiment, requiring parent/child cpuset checks
and potentially restarting the Linux children while the boosted binding is live.
Do not claim that boosts or GPU support have been implemented or measured.

## Latest: scheduling optimization implemented/deployed; GPU probes isolated

User authorized proceeding with CPU scheduling and GPU investigation. Changed
LinuxFrameLabClient to bind using the supplied Activity context (not Application)
and BIND_AUTO_CREATE | BIND_IMPORTANT | BIND_ADJUST_WITH_ACTIVITY. Standard
release-optimized --dev build succeeded (scheduling-main-build.log) and installed
in place. User reopened Nightfall after Horizon paused it. Measured helper moves
from foreground CPUs0–2 to top-app CPUs0–5. Existing Linux children needed a
restart **while that binding stayed alive**; after graceful Chrome close/runtime
restart and Surface reattach, all Chrome/PRoot/Xvfb children were verified0–5.
Evidence: scheduling-bound-helper.json and scheduling-restarted-children.json.
Normal-tab/close/media/touch checks passed in touch-check-20261101T175008Z.

Active playback after scheduling change: browser-diagnostics-20261101T175156Z.json
contains20s,600 total frames advanced,0 dropped (~29.9fps),1280×720 throughout,
buffer~32s. Earlier sample had~16% drops and540→432p. These are short separate
runs, not a rigorously matched sustained benchmark; promising, not proof all
navigation/quality problems are solved. Netflix restored; user should assess
scrolling and movie playback. Browser GPU/decode remains software.

Startup caveat: the Activity-aware binding promotes the helper; Linux children
inherit its group when spawned. A headless BrowserLabService started BEFORE the
binding can still create foreground-only children. This session explicitly
restarted them under the live binding. Production automatic bootstrap/scheduling
inheritance remains to be integrated; don't claim headless cold-start fixed.
Launching the companion through its own visible Activity is a different startup
path. Preserve current six-core runtime for user testing.

GPU probe: added probe-linux-egl.py, a32×32 pbuffer/readback probe inside guest.
Installed libegl1/libgles2/libegl-mesa0 via guest apt only (gpu-libraries-install.log).
Stock guest driver override kgsl successfully renders using **llvmpipe**, so
passed readback does NOT mean hardware acceleration.

Staged a separate, verified driver under /opt/mesa-freedreno, preserving stock
Mesa and Chrome flags. Upstream package provenance:
https://github.com/sabamdarif/termux-desktop/releases/tag/mesa-freedreno-27.0.0-devel-20261025
asset mesa-freedreno-27.0.0-devel-20261025-aarch64.zip,
SHA2567258d559c72b1127542c4fe5ee2a216b214f6e35c3fdeef044e1f2f2c54004dc.
Release metadata/archive/tar remain in ignored cache; binaries not committed.
KGSL OpenGL isolated probe: GPUMEM_ALLOC_ID Permission denied, guest process
SIGSEGV. Turnip/Zink probe: VkDevice allocation failure (reported
VK_ERROR_OUT_OF_DEVICE_MEMORY), EGL_NOT_INITIALIZED. No corresponding AVC found
in the sampled Android log. Do NOT assert physical VRAM exhaustion or definite
SELinux cause. Driver source uses GPUMEM_ALLOC_ID for both normal allocation
paths; GPUOBJ_ALLOC appears in its sparse paths. Compatibility of allocation
ioctls is an investigation lead, not an implemented fix.

Both GPU candidates are **inactive in Chrome**. Chrome still --disable-gpu.
No Android graphics driver, cgroup policy, system permissions or device settings
were changed for GPU tests. Only app-private guest packages/prefix added.
Probe results: linux-egl-kgsl-probe.json (stock llvmpipe),
linux-egl-isolated-kgsl-probe.json, linux-egl-isolated-zink-probe.json.
All new session changes remain uncommitted.

## Latest request: bounded tests and precise GPU allocation investigation

User reported headset battery drained after unattended playback. User authorized
proceeding with cleanup and GPU investigation. No device currently on ADB; no
video/awake override launched this turn.

Implemented test_guard.py + test-watchdog.sh, integrated into browser-diagnostics,
measure-playback and verify-touch. They capture serial, arm an on-device detached
nohup watchdog, stop companion/Nightfall on test completion/failure and restore
automation_disable + Guardian property. Ctrl+C/finally cleanup and a device-side
deadline cover lost USB/host process. Default sample20/30s, max120s +20s allowance;
verify-touch90s. No timeout added to production application. Four local tests of
the actual shell script with fake am/setprop pass (expiry, cleanup, stale token,
invalid inputs). Device validation still pending. Future automatic tests stop the
apps even if --restore-netflix was used; don't promise playback left running.

GPU investigation: both Mesa candidates use older GPUMEM_ALLOC_ID for normal
allocations; GPUOBJ_ALLOC is available in UAPI and used for sparse paths. Prepared
kgsl-allocation-probe.c: static NDK Android28/ARM64 binary, exact48-byte allocation
layouts,4KB allocations, three cache flags per API, immediate free,3s alarm.
Records actual SELinux domain. Important: previous run-as-launched EGL probes may
have run under a different domain from service-launched Chrome. Can't conclude
Android app access is blocked until context-matched comparison.

Added non-exported GpuAllocationService to the lab APK (shortService FGS): runs
same binary directly and through enter.sh/PRoot in actual app process context,
5s child limits, writes only controlled numeric output. run-allocation-probe.py
uploads binary, launches service and collects results under20s watchdog. It
never starts Chrome or calls quest.py awake. Helper APK rebuilt successfully;
binary compiled NDK29 static -O2 -Wall -Wextra -Werror. Neither new helper nor
watchdog installed on device yet; ADB absent, user asked to reconnect after
charging. Next: install rebuilt helper in place, run bounded allocation probe,
inspect native/proot domains and errno results, verify cleanup. No GPU-result
claim yet. Raw EGL probe now also has a5s process alarm.

### 2026-11-01: hardware EGL proof via KGSL ABI adapter

Context-matched allocation tests completed in native companion and PRoot, both
SELinux domain `untrusted_app_27`: legacy GPUMEM_ALLOC_ID returns EACCES for all
three tested cache flags; GPUOBJ_ALLOC, GPUOBJ_INFO and GPUOBJ_FREE all succeed,
including a valid GPU address. Each allocation is 4 KB and immediately freed.
Artifact: `.build-cache/browser-quest-linux/kgsl-allocations-20261101T185541Z.json`.

`kgsl-compat.c` is an isolated guest LD_PRELOAD experiment adapting denied legacy
allocation/free calls to the newer public KGSL ABI. No system policy changes,
Chrome configuration changes or hardware video decoding claims. It is not yet a
production driver integration. Build with NDK clang, shared/PIC/nostdlib; unresolved
symbols are glibc `syscall` and `__errno_location`, with no bionic dependencies.

`run-egl-compat-probe.py` runs the actual companion service with a five-second
limit per driver and a 20-second cleanup watchdog. First result:
`.build-cache/browser-quest-linux/egl-compat-20261101T185845Z.json`.
- Native Freedreno KGSL: GLES 3.2, renderer FD740v3, 32x32 clear/readback correct.
- Zink/Turnip: readback correct but DEVICE LOST logged; NOT a reliable candidate.
- No Chrome/video launched; apps stopped and forced-worn settings cleared.

Next: validate the native KGSL path repeatedly with a slightly richer offscreen
render, then determine a supported accelerated Chrome window/output path. Xvfb
and direct shared-memory capture do not automatically become GPU composited just
because surfaceless EGL works. Preserve software rollback, input and audio; use
short bounded runs. GPU video decoding remains separate and unproven. Actual
watchdog expiry after USB loss has not been exercised on-device; normal device
cleanup and four local watchdog tests passed.

### 2026-11-01: animated GPU gate FAILED — do not enable Chrome GPU yet

The real 120-frame shader/geometry test ran on the reconnected Quest. Artifact:
`.build-cache/browser-quest-linux/egl-compat-20261101T194229Z.json`.
Adreno FD740v3 initialized, but 22 frame checks failed in ~1939 ms, with
`flush_submit_list: submit failed (Resource deadlock avoided)`. Kernel log at
20:42:31–32 explicitly attributes GPU hangs to the probe Python process and
reports three faults in 2000 ms. glGetError returned zero: it is insufficient
as a reliability gate. Both apps and power overrides were confirmed cleared.

This supersedes the single-clear success as an integration readiness assessment:
allocation ABI translation works, sustained hardware rendering is NOT reliable.
No Chrome acceleration or video decode enabled. Avoid further device GPU draws
until reviewing allocation mapping/cache semantics and this Mesa snapshot's
Adreno 740v3 command-generation compatibility. Do not mask EDEADLK or retry
faulted submissions. Probe now stops after the first mismatched frame; runner
also rejects submission-error diagnostics even if pixel/GL checks claim success.
Next should be source-level driver investigation, not browser benchmarking.

### 2026-11-01: corrected legacy address semantics — animated gate PASSED

Source comparison identified a missing semantic in our adapter. The reference
kernel's `kgsl_ioctl_gpumem_alloc_id` ORs `KGSL_MEMFLAGS_FORCE_32BIT` into flags;
`kgsl_ioctl_gpuobj_alloc` does not. The initial shim copied only the caller's
32-bit flags, omitting this implicit bit 32. Earlier GPU fault addresses were
above 4 GB. Reference (not the exact installed Quest kernel source):
https://android.googlesource.com/kernel/msm/+/0dee0d1411e4ba837089a769a5bcce57a5a14df2/drivers/gpu/msm/kgsl.c

`kgsl-compat.c` now preserves the legacy FORCE_32BIT contract on translated
allocations. Host-only `kgsl-compat-test.c` validates flag propagation, output
fields, cleanup on info-query failure, free translation and unrelated errors.
Build/run: `cc -Wall -Wextra -Werror tools/experiments/browser-quest-linux/kgsl-compat-test.c -o /tmp/nightfall-kgsl-compat-test && /tmp/nightfall-kgsl-compat-test`.

Corrected hardware run:
`.build-cache/browser-quest-linux/egl-compat-20261101T194902Z.json`:
120/120 animated shader frames, zero mismatches, zero GL errors, 151.18 ms,
FD740v3 hardware renderer, no submission errors. The timestamp-bounded kernel
check (matching `-kernel.json`) succeeded with no new GPU fault lines. Apps were
stopped and power override/lease cleared. This strongly supports the address
semantic as the probe fault cause; it does not establish general Mesa stability.

Native KGSL is again a candidate for isolated Chrome testing. Do not infer
browser FPS from this 32x32 microtest or hardware video decode support. Zink is
still excluded by default and has not been retested with the corrected shim.
Remaining: temporary-profile Chrome acceleration/display integration and actual
frame export cost, followed by bounded baseline comparisons. Production Chrome
software settings and the user's profile remain untouched.

### 2026-11-01: Chrome GPU and shared framebuffer proof PASSED

Temporary-profile Chrome works via ANGLE OpenGL/EGL on FD740v3 in both headless
and X11/Xvfb modes. SystemInfo reports GPU compositing, rasterization and WebGL
enabled. Correct generated WebGL red pixel read back. First headless result:
`.build-cache/browser-quest-linux/chrome-gpu-20261101T195649Z.json`.
Definitive X11 plus shared framebuffer result:
`.build-cache/browser-quest-linux/chrome-gpu-20261101T195928Z.json`.
The 640x360 XWD mmap has the expected 32-bit/2560-stride layout and correct red
canvas pixel. Earlier XWD checks sampled Chrome's replacement startup page; the
probe now explicitly navigates to a generated data page and waits for readiness.

`probe-chrome-gpu.py` uses a temporary profile and fixed generated content, no
accounts/media, with child process-group cleanup. Companion caps it at 20s;
runner device watchdog is 35s. No main APK change needed. PNG screenshot exports
were tens of milliseconds (not suitable live transport); retain existing XWD mmap.
Feature-status video_decode enabled is NOT proof of actual hardware decoding.

`start-desktop.sh` now has opt-in `/tmp/nightfall-chrome-renderer` with values
`software` (default) or `gpu`. GPU uses isolated Mesa and corrected shim at
`/opt/nightfall-kgsl/libnightfall-kgsl-compat.so`, scoped ONLY to Chrome. These files
were staged on the Quest; GPU mode has NOT been selected for the user's browser.
Enable by writing `gpu` to the guest toggle file, then restart the helper under
live Activity binding; software rollback is `software` or removing the toggle.
Preserve user's profile. Next: bounded real-browser scrolling/video comparison,
input/audio checks and CPU/power measurement, then decide default. Headless/X11
proof is not an end-to-end Netflix or sustained browser stability benchmark.

### 2026-11-02: matched software/GPU scrolling comparison

Extended temporary-profile Chrome probe with a four-second generated scrolling
workload at 1280x720, requestAnimationFrame intervals, live XWD marker changes,
and Chrome process-session CPU ticks. `run-chrome-gpu-probe.py --x11 --software`
selects the existing disabled-GPU baseline; omit --software for corrected KGSL.
No saved profile or media accessed. Both apps stopped after each measurement.

Valid matched runs (unbuffered framebuffer reads):
- Software: chrome-gpu-20261102T051127Z.json — 240 observed changes/4.005s
  (~59.9/s), median/p95 rAF 16.7/16.7 ms, Chrome CPU 0.854 core equivalents.
- GPU: chrome-gpu-20261102T051135Z.json — 239 observed changes/4.003s
  (~59.7/s), median/p95 rAF 16.7/16.7 ms, Chrome CPU 0.879 core equivalents.
All artifacts under `.build-cache/browser-quest-linux/`. Kernel check
`scroll-gpu-kernel.json` succeeded, no new GPU hang/fault/submission errors.
An earlier pair sampled through Python buffered reads and incorrectly reported
zero XWD changes; disregard its frame-delivery counters. Probe now opens the
live XWD stream unbuffered. The final static red presentation check passed both.

Conclusion: accelerated Chrome works with the existing transport, but this short
60Hz synthetic scrolling workload shows NO demonstrated performance/CPU benefit.
The small CPU difference is not meaningful from one short run. These samples
exclude Xvfb, Android/Nightfall and CPU outside Chrome's process session; do not
infer battery life, thermal effects, 1080p/video performance, or in-headset FPS.
Service-only launch may inherit a different CPU set from Activity-bound playback.
Software remains default. Next meaningful gate is a bounded real video playback
comparison (decoder name, actual media resolution/dropped frames, input/audio,
and end-to-end app/texture counters); video decoding is still unproven on GPU.
No reason to switch the default solely from this scrolling result.

### 2026-11-02: generated 720p60 video comparison

Added `--video` to run-chrome-gpu-probe.py and fixed companion intent; plays only
an eight-second host-generated H.264 testsrc2 clip, muted, from guest-local file,
in a temporary Chrome profile. Four-second counter sample after playback starts.
Generated clip command:
`ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=60 -t 8 -an -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -movflags +faststart generated-720p60.mp4`.
Place under `.build-cache/browser-quest-linux/`; runner stages it only for --video.

Artifacts under `.build-cache/browser-quest-linux/`:
- Software chrome-gpu-20261102T054946Z.json: 4.053s, 246 total-frame increments,
  one dropped-frame increment, 0.957 Chrome CPU core equivalents.
- GPU chrome-gpu-20261102T054958Z.json: 4.048s, 245 total-frame increments,
  zero dropped-frame increments, 0.973 Chrome CPU core equivalents.
Both 1280x720, advancing media clock, no media error; static presentation check
also passed. Kernel query video-gpu-kernel.json succeeded with no GPU fault lines.
Cleanup confirmed both apps stopped, no Guardian override or watchdog lease.
Four local watchdog tests and Python syntax checks passed.

Crucial: BOTH report FFmpegVideoDecoder and kIsPlatformVideoDecoder=false.
GPU rendering/compositing is functional, but video decoding remains on CPU. This
short local H.264 clip shows no meaningful throughput/CPU gain from GPU rendering
alone. Do not infer Netflix/CDN/DRM behavior, 1080p stability, battery improvement,
72/90Hz presentation, or end-to-end Nightfall latency. These tests do not run the
main XR app, audio or inference, and CPU samples exclude Xvfb and Android.

Software remains default. Next investigation: identify a viable bridge to the
Android hardware video decoder (or supported guest decode backend) before
expecting a large playback power improvement. Separately compare real playback
under visible Activity binding with AI3D, audio and input. Avoid another series
of synthetic render-only tests: they already established the compositor path.

### 2026-11-02: Android hardware decode bridge proof PASSED

Found upstream Termux:VA, a MediaCodec daemon + Mesa VA-API bridge suitable for
PRoot (https://github.com/lfdevs/termux-va). Source cloned ONLY into ignored cache
`.build-cache/browser-quest-linux/termux-va-source`, pinned revision
`ae14813d77dbf107273b410a32f4ade34ba56313`. Upstream is GPL-3.0; retain upstream
license/notices and corresponding source if distributing its binaries. No
third-party daemon binary is committed or bundled into the main APK.

Reproduce daemon/probe build with NDK29:
`ANDROID_NDK_HOME=/home/linuxbrew/.linuxbrew/share/android-commandlinetools/ndk/29.0.14206865 bash .build-cache/browser-quest-linux/termux-va-source/scripts/build-ndk.sh`.
Apply tracked `tools/experiments/browser-quest-linux/termux-va-decoder-name.patch`
with git apply in the source checkout first to log actual selected decoder.
This patch adds identity-only diagnostics, no decoding behavior changes.

`run-mediacodec-probe.py` stages source-built native binaries and calls the
companion's fixed media_probe mode. Daemon socket is app-private under guest
`/tmp/nightfall-va/probe.sock`; no system services, root, network listener or
protected media involved. Native built-in AVC probe timeout3s, child5s, overall
20s watchdog; daemon killed in finally/onDestroy as well as force-stop cleanup.
Artifact `.build-cache/browser-quest-linux/mediacodec-20261102T055432Z.json`:
selected decoder `c2.qti.avc.decoder`, 96x96 NV12 output, 5 decoded frames returned,
probe exit0. This establishes actual Qualcomm hardware decode through the socket,
not throughput or browser integration. Original uninstrumented probe also passed.

Isolated guest VA package staged at `/opt/mesa-va/usr/...`; original Mesa bundle
and Chrome flags remain unchanged. Upstream release metadata in
`.build-cache/browser-quest-linux/mesa-va-release.json`, tag
`mesa-27.0.0-devel-20261025-r1`, asset Ubuntu Noble ARM64 tar.gz (guest24.04),
SHA256 `17e594d4b0a1b7a484a548054977992342b604195798080b95a36fbafa009f69`
matched GitHub asset digest. Archive paths/links checked before extraction.
Contains termuxva_drv_video.so, libgallium, and libtva_drm_shim_wayland.so.

NEXT: load/enumerate the isolated guest VA driver with daemon active, then test
FFmpeg and Chrome generated720p60 decoding through it. Chromium may require DRM
shim/VA flags and output import compatibility; Xvfb lacks the Termux:X11 DRI3 path
used by upstream examples. Do not assume compatibility or zero-copy from the
native proof. Confirm decoder properties AND daemon frames before claiming
Chrome hardware decode. Keep software fallback and bounded cleanup. Both apps
were confirmed stopped and no wake override/lease remained after these probes.

### 2026-11-02: Linux VA enumeration passes; Chrome decode integration NOT ready

Companion supports fixed va_probe and chrome_va test modes; both start the native
MediaCodec daemon in the real app domain and kill it in finally/onDestroy.
`run-mediacodec-probe.py --va` runs guest ctypes capability enumeration against
isolated `/opt/mesa-va` with DRM shim and the corrected KGSL adapter.
`.build-cache/browser-quest-linux/mediacodec-20261102T060105Z.json` proves VA1.20
initialization and VLD(decode) entrypoint1 on profiles13,6,7,17,19,32; encoding6
also on all but32. Vendor Mesa Gallium FD740v3 termux-va bridge. These advertised
profiles alone do NOT establish tested decode support for each codec.

`run-chrome-gpu-probe.py --x11 --video --va` starts daemon + temporary-profile
Chrome with VA driver and render-node override. Chrome loads VA driver and
queries successful decode configs (entrypoint1) as well as encode configs, but
SystemInfo's videoDecoding list remains empty and actual clip uses
FFmpegVideoDecoder / kIsPlatformVideoDecoder=false. Daemon sees NO clients/frames.
Artifacts chrome-gpu-20261102T055925Z.json (GL-EGL) and
chrome-gpu-20261102T060127Z.json (upstream-recommended GLES-EGL) under cache.
Hardware rendering remains FD740v3; generated720p60 still plays normally.
Earlier initial attempt `...055845Z.json` incorrectly had generic passed=true
based only on rendering; do NOT interpret as VA decode success. Probe now
requires hardware_decode_confirmed for VA mode and runner ALSO requires decoded
frames in daemon log. No successful Chrome hardware decoding yet.

Installed Chrome is156.0.8078.79. Matching source inspection cached under
/tmp/nf-vaapi-wrapper-installed.cc; upstream:
https://github.com/chromium/chromium/blob/156.0.8078.79/media/gpu/vaapi/vaapi_wrapper.cc
Full generated-test initialization log cached as chrome-va-initialization.log.
Contains EGL configuration warnings; causality not established. No more blind
feature-flag retries: inspect Chromium's supported-decode-config selection/output
pipeline or first validate a full generated clip through guest FFmpeg VAAPI.
Xvfb lacks Termux:X11 DRI3 support assumed by upstream examples; determine whether
that matters before changing window backend. Working rendering libraries,
production Chrome flags, saved profile and media accounts unchanged.

### 2026-11-02: direct FFmpeg VA decoding isolates low-delay/reordering issue

Installed FFmpeg6.1.1 only in the Ubuntu guest (no host/main APK changes).
`run-mediacodec-probe.py --ffmpeg` drives fixed guest probe-ffmpeg-va.py: require
VA hardware surfaces, decode60 generated H.264 frames, hwdownload NV12 and
 discard; no automatic software fallback. Native daemon uses c2.qti.avc.decoder.

Original generated720p60 H.264 (B-frames) stalls after one daemon output frame:
- SHM default: mediacodec-20261102T060606Z.json, four-second deadline.
- Inline DMD_WANT_SHM=0: ...060713Z.json, six-second deadline; same stall.
Thus SHM alone is NOT the cause. Client waits on decoder fence after feeding
~seven picture units; daemon records nine units total and one frame out.
"failed to send format descriptor" happens during timeout cleanup; not proven
as the initial cause. Verbose trace shows pending reordered-picture fence.

Separate low-delay generated clip (--tune zerolatency --bf0):
`run-mediacodec-probe.py --ffmpeg --low-delay`, artifact
mediacodec-20261102T060748Z.json: PASS60 downloaded NV12 frames, zero decode errors,
~536ms process wall including launch, FFmpeg rtime~258ms/speed3.81x. Daemon
reported63 decoded frames (pipeline prefetch); do not equate process-wall rate
with sustained playback or end-to-end Nightfall performance. This strongly
implicates reorder/decoder buffering, but zerolatency also changes encoder
settings, so B-frames alone are not a rigorously isolated variable yet.

Tested original clip with documented DMD_NO_PICTURE_ORDER=1 via explicit
--display-order test flag: ...060830Z.json, still stalls; do NOT set this as a
fix/default. Upstream already enables decoder low-latency and Qualcomm
picture-order extension; don't propose these as missing. No EOS/flush workarounds
applied (upstream warns they can destroy references). Inline transport and verbose
VA diagnostics are currently scoped to the direct VA test mode only.

Probe's6s child deadline/8s service cap/20s watchdog bound the test. Native bridge
and GPU rendering are functional; general reordered video through VA remains
unreliable. Chrome still CPU-decoding and unchanged. Next: inspect reconstructed
AVC SPS/DPB and PTS/fence mapping using original vs no-B-only encoded sample,
then full elementary-stream client test to separate daemon from VA reconstruction.
Current prebuilt Mesa is eb3e7fd4f0; source dev branch has related bootstrap/drain
fixes, but no newly published post-Oct25 reorder fix found. Avoid calling a
Chrome flag change the solution while direct reordered VA decode is failing.

### 2026-11-02: isolated AVC PPS reconstruction bug with pixel-exact offline proof

`--elementary` test sends60 original generated AnnexB frames using upstream
Termux:VA test_decode.py directly from PRoot. Result
mediacodec-20261102T061451Z.json: c2.qti.avc.decoder,60/60 returned, no VA involved.
Therefore this Qualcomm decoder can handle the original B-frame clip.

Generated-only daemon diagnostic added to tracked upstream patch: optional
NF_GENERATED_TEST_DUMP writes received encoded input to a fixed app-private file.
Companion enables it ONLY for explicit ffmpeg_probe generated-clip tests; it is
not enabled for Chrome, user playback, native tiny probe or production app.
Never enable this diagnostic for user/account/protected media. Patch retains
upstream licensing and marks local modifications. No third-party binary committed.

Captured failing reconstructed stream: generated-reconstructed.h264 (7 picture
NALs plus synthesized SPS/PPS),72,866 bytes. Header comparison shows original
num_ref_idx_l0_default_active_minus1=0, reconstructed=2. Bridge source uses a
heuristic three-reference default (MIN2(max_references,3)-1) rather than the actual
PPS default. Reference-list default is NOT the same as SPS DPB capacity.
Original and reconstructed both have max_num_reorder_frames=2/max_dec_buffering=4.
Reconstruction also drops timing/SAR and changes level32->31; those were not
changed by the following proof.

Added offline `compare-generated-avc.py`, which requires the known original
clear test stream, copies ONLY its PPS L0/L1 defaults into the captured PPS,
and preserves slice payloads. This is a diagnostic repair, NOT a generic driver
fix or production transform. Artifacts under .build-cache/browser-quest-linux:
- pps-repair-validation.json: original capture has missing references/invalid
  references/corrupt frames; PPS-repaired capture decodes7 frames without errors.
- pps-repair-pixel-comparison.json: repaired7 frames have identical framemd5 pixel
  hashes to original stream truncated to the same7 input pictures.
- generated-reconstructed-pps-repaired.h264 and headers-{original,reconstructed}.txt.

NEXT actual fix belongs in Mesa tva_bridge.c H.264 CSD synthesis. Recover real
PPS reference-list defaults from raw slice headers plus VA effective list counts
when num_ref_idx_active_override_flag=0, or preserve original PPS earlier in the
pipeline. Must handle multiple slices/PPS ids and explicit overrides; never just
hardcode0 globally. Validate no-override and override P/B cases, low-delay and
reordered clips, pixel fidelity and full60-frame VA decode before Chrome work.
A rebuilt isolated Mesa bridge is needed; the installed binary is unchanged.
Chrome's separate empty capability/output integration remains unproven even
after a future PPS fix. No reason to repeat flag experiments before fixing this.

### 2026-11-02: rebuilt experimental PPS driver fixes reordered AVC sample

Built pinned Mesa source eb3e7fd4f009cab04b1482aad4843c0bde28a786 (same revision
as installed VA bundle) using the tracked Ubuntu Noble cross-container recipe
MesaVa.Containerfile, mesa-va-cross.ini and build-mesa-va.sh. Dependencies/build
stay in an isolated Podman image/cache; no host system package changes.
Compilation1443 targets succeeded, release ARM64 libgallium built.
Tracked patch mesa-h264-pps-defaults.patch includes h264-reference-defaults.h.

Experimental logic: use raw single-slice override bit to distinguish actual PPS
default list counts from per-slice overrides in VA metadata. Do not guess PPS
counts from SPS DPB size. Parser bounded to256 header bytes, supports relevant
POC/field paths, rejects malformed/unsupported headers; scoped to PPS0 and
single-slice pictures for now. Provisional defaults0 are not proof of learned
counts. Multi-slice/PPS switching/bootstrap cases need more work before general
rollout. This is NOT yet a production-quality general H.264 fix.
Seven host tests pass, including agreement with FFmpeg's independent parser on
all60 slices in original clip; four watchdog tests pass.

Staged rebuilt libgallium and termuxva_drv_video.so symlink separately under
`/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu/`. Direct test explicit --pps-driver
selects it; original VA/render bundles and browser defaults unchanged.
Initial attempt ...064007Z failed BEFORE decoding due mixed GL lib symbols.
Direct VA test now prefers system GL loader libraries after experimental VA lib
path to avoid that unrelated loader conflict (not a decoder fix).

Results under .build-cache/browser-quest-linux:
- mediacodec-20261102T064104Z.json: original B-frame clip PASS60 output frames,
  c2.qti.avc.decoder,65 hardware-decoded frames including prefetch,~429ms FFmpeg
  process wall,~227ms FFmpeg rtime. No software fallback requested.
- mediacodec-20261102T064135Z.json: low-delay clip regression PASS60,~436ms wall.
- rebuilt-pps-pixel-validation.json: all65 reconstructed picture NALs decode
  without errors; CPU framemd5 equals original65-picture prefix exactly.
This validates reconstructed-bitstream pixel fidelity, NOT bit-exact comparison
of MediaCodec NV12 output versus CPU, nor sustained throughput/thermal power.

NEXT: Chrome integration with the fixed driver, keeping its empty hardware
capability/output path as a separate issue. Don't assume a fixed reconstruction
automatically enables Chrome decoding. For release readiness, expand multi-slice,
PPS-ID switching and long-reference coverage and validate actual output pixels,
then SHM transport. All hardware tests remained bounded and apps stopped.

### 2026-11-02: Chrome reaches hardware decoding; Xvfb import is now the blocker

Added --pps-driver to the isolated Chrome runner. Companion starts the same
native MediaCodec daemon and selects matching corrected VA driver in guest.
A minimal/headless libgallium mixed with older presentation libraries made GL
initialization fail (chrome-gpu-20261102T064648Z.json). Do not reuse that mix.

Extended MesaVa.Containerfile with ARM64 X11/GLVND dependencies (including
libxxf86vm-dev). Reconfigured build: platforms=x11,glx=dri,glvnd=enabled,
libdir=lib/aarch64-linux-gnu. Built matching EGL/GLX/GBM/libgallium/VA components
and installed to cache mesa-va-source/stage-x11-nightfall. Packed as
mesa-pps-x11.tar.gz and staged ONLY under guest /opt/mesa-va-pps. Corrected
build-mesa-va.sh defaults reflect matching build. Original bundles/defaults
remain intact. Separate upstream DRM shim reused; no Wayland compositor built.

Chrome result chrome-gpu-20261102T065105Z.json: FD740v3 hardware rendering restored,
GaneshGL; actual Qualcomm AVC decoder selected,4 SHM frames returned. Chrome
media pipeline disconnected before test video became ready. Full generated-test
log chrome-pps-x11-initialization.log identifies:
`Could not find SharedImageBackingFactory ... BGRA_8888 ... gmb_type: platform ... MailboxVideoFrameConverter`.
GPU process exits with an unrecoverable context error. Kernel has NO new GPU
hang/fault/submission errors (chrome-pps-kernel.json). This is not the prior KGSL
address-space fault, and not proof of kernel instability.

Upstream docs/termux-va.rst explain this import error when DRI3/GBM is absent.
Enabled documented TERMUX_VA_X11_DRI3=1 in the isolated probe and checked actual
server extensions: Present exists, DRI3 DOES NOT. Result
chrome-gpu-20261102T065255Z.json:5 hardware-decoded frames but same failure. Shim
only replaces failed DRI3 Open replies on a DRI3-capable server; it cannot add
server-side imports to stock Xvfb. Therefore no more decoder flag retries.

Current status: hardware rendering works; direct FFmpeg hardware VA decoding
works after PPS fix; Chrome now attempts/executes hardware decode but CANNOT
present decoded native buffers through stock Xvfb. Not ready for user playback.
Next choose a DRI3-capable offscreen X server or a linux-dmabuf-capable Wayland
backend, while preserving efficient Nightfall display delivery/touch/audio.
Prefer investigate a bounded DRI3 X-server spike first to avoid rewriting input
and XWD transport unnecessarily; if unavailable, plan Wayland frame export
explicitly. Upstream Termux:X11 has imports but its Android-window lifecycle
cannot be assumed compatible with our app-private server. Keep software default
and original frame transport until a generated-video presentation test passes.
Seven parser tests/four watchdog tests pass; all apps/override/lease cleared.

### 2026-11-02: DRI3 Xvfb spike — decoder works, presentation still FAILS

Source reference: https://github.com/linuxserver/docker-xvfb at
75a2023964f3d4f12867ba6588e9d2d500436aed, patches/21-xvfb-dri3.patch.
Source archive xorg-server21.1.19 SHA512
f3b10c8c3aac849c889e0cd58f82c25b371d28702a93ad0bbb83a46c73d8079eec306f22e7441a1a2b53b6e29cb279d6203f03a2f0a80c9f39b1d134768806b6
verified against Alpine3.22-stable packaging. Apply its missing-files.patch too
(SHA51263018fcedccf116fa6d37abd5799116221544d132452ead364211db681e7f92233986bf64f0489ac3c4840ba01373c1887b374db339ce23e61fccd17d4088437).
All downloaded source/patches cached; tracked XvfbDri3.Containerfile and
build-xvfb-dri3.sh rebuild isolated ARM64 binary. No system X server replacement.

Staged binary ONLY at guest /opt/nightfall-xvfb/Xvfb. Explicit Chrome test flag
--dri3-server requires --x11 --pps-driver (and --va --video). Child uses matching
Mesa env, -vfbdevice /dev/kgsl-3d0, and crucially GBM_BACKENDS_PATH pointing to the
isolated matching Mesa /gbm directory. Without it GBM creation fails. With it,
xdpyinfo confirms DRI3; Present also available. -noreset keeps server alive when
capability-check client disconnects.

First DRI3 server crashed in glamor_pixmap_destroy_fbo during reset/teardown.
Tracked incremental xvfb-dri3-nightfall.patch (on top of LinuxServer patch):
- Keep root pixmap alive until glamor has released its FBO/image.
- Keep EGL context/GBM alive through inner screen CloseScreen callbacks.
- Add bounded (~60Hz max) GetImage readback into existing mmap XWD buffer while
  processing frames (prototype only; not optimized dirty-region transport).
Rebuilt server now shuts down without the recorded segmentation fault.

Chrome hardware decoding IS now confirmed: artifact
chrome-gpu-20261102T074102Z.json reports VaapiVideoDecoder/platform=true,
720p60 clip advances4.1s,250 total-frame increments,zero additional dropped
frames,Chrome CPU~0.452 cores; daemon c2.qti.avc.decoder returns270 frames incl
buffering/prefetch. Later runs ~0.40-0.45 Chrome cores and0-3 drops/sample.
NOT an end-to-end or total-device power comparison: excludes X server, daemon,
Nightfall, XR/audio and sustained heat. Prior software Chrome alone ~0.95 cores.

OVERALL TEST STILL FAILS: shared XWD and actual XGetImage root both show a static
pixel (0xf6f5f4) instead of final generated red. Scroll marker change count0.
Thus not merely stale host-side file buffering. Explicit Page.bringToFront and
viewport-coordinate correction do NOT fix it. Disabling raster zero-copy/GPU
rasterization also does NOT fix it. Last result ...074835Z.json has visible-page
geometry x10,y10,outer/inner1279x719; no titlebar offset explains missing pixels.
No kernel GPU hang/fault/submission errors (xvfb-dri3-kernel.json); cleanup passes.
Do NOT enable this in start-desktop.sh or call it working headset playback.

NEXT: debug DRI3 pixmap import/Present and root composition in patched Xvfb.
First compare a plain X11 drawing client versus a DRI3-presenting client, capture
actual root contents, inspect buffer/cache/tiling and damage/Present handling.
Readback shim itself remains unproven for moving GPU content. If this server
patch proves unsuitable, prefer a proven DRI3 server or linux-dmabuf Wayland
backend rather than more Chrome feature flags. Decoder and PPS fixes are
separately demonstrated. Working software browser/default server untouched.
Seven parser tests/four watchdog tests pass; all test processes stopped.

### 2026-11-02: standalone DRI3/Present/fence gates all pass; Chrome EGL still static

Added generated-only diagnostics to the isolated Chrome probe, no saved profile.
Plain X11 root drawing: three primary colours read back correctly through X11;
first immediate mmap sample can lag, later colours match. This demonstrates
basic drawing/readback; it is not a reliable timed frame-export test yet.

New probe-dri3-buffer.py constructs a128x128 linear XRGB GBM buffer, CPU-fills
red, exports a dma-buf, imports through xcb DRI3, copies it to root, then Presents
it to a mapped window (normal and forced-copy modes), and finally Presents it
with a DRI3 imported xshmfence wait fence. All expected pixels pass.
paint-generated-dmabuf.py additionally imports the buffer into GLES, clears it
blue on GPU, finishes, and reads correct blue pixels before the exact same DRI3
copy/Present/fence sequence. All GPU-produced-buffer pixel checks pass too.
Definitive combined artifact chrome-gpu-20261102T080337Z.json under cache.
Helper passed condition now includes Present/fence results, not just first copy.
These tests cover linear XRGB, not all Chrome modifier/format paths.

Chrome failure remains specific to its native-window rendering/presentation:
- actual controlled test window is the only large mapped window;
- Page.bringToFront and explicit XRaiseWindow do not fix output;
- XGetImage of that window itself remains0xf6f5f4, same as root/mmap;
- viewport-origin correction does not fix it (outer/inner1279x719 at10,10);
- saved Chrome Page.captureScreenshot is correct red/black generated content,
  inspected locally (chrome-dri3-current-page.png); native window is static;
- unsetting inherited EGL_PLATFORM=surfaceless for Chrome (server retains its
  offscreen env) does not fix it;
- GL-EGL and GLES-EGL both fail to present the changed content;
- vblank_mode=0 did not fix it (...080558Z.json); removed that failed override.
Chrome still reports hardware VaapiVideoDecoder and ~0.38-0.40 CPU cores in short
720p60 sample, but DO NOT call this usable playback or a proven power win.

NEXT: standalone EGL native-X11 window/swap diagnostic using the same stack to
separate Mesa's window-surface/swap path from Chrome Ozone/ANGLE compositor.
Inspect native buffer format/modifiers and swap/completion events if that fails;
if native EGL succeeds, trace Chrome compositor presentation. Avoid repeating
already-passing generic buffer import/Present/fence tests or more unrelated flags.
No production settings changed; failed experiments remain opt-in dev probes.


### Native EGL window isolation — 2026-11-02

Added `run-chrome-gpu-probe.py --native-egl-only`: no Chrome, decoder daemon,
accounts or media; generated RGB window clears, native X11 readback, swap
intervals 0/1, five-second child limit and existing automatic cleanup.
Artifact: `.build-cache/browser-quest-linux/chrome-gpu-20261102T081301Z.json`.
EGL 1.5 initializes on FD740v3, but Mesa reports
`dri3_alloc_render_buffer: xcb_dri3_pixmap_from_buffer[s] failed`, X error 11
(BadAlloc). All six native samples remain black; internal reads are also zero.
Successful eglSwapBuffers return values alone do not establish rendering.
This reproduces the presentation failure independently of Chrome/ANGLE and
media decoding. Next inspect the native EGL allocation/export parameters and
server DRI3 import rejection, especially formats/modifiers versus the already
passing linear XRGB producer tests. Software browser remains the default.
Native-only reports now omit stale Chrome/VA logs and do not require a decoder.


### Native X11 presentation blocker fixed — 2026-11-02

Root cause: pinned Mesa's `loader_dri3_helper.c` rewrites the valid linear
modifier zero to private value 1274 when sending PixmapFromBuffers. Native
X11 cannot import that layout. Preserve the actual modifier instead. Tracked
patch `mesa-native-x11-linear-modifier.patch`, applied idempotently by
`build-mesa-va.sh`; no global system or security changes. The helper is linked
into libgallium as well as EGL/GLX, so deploy the matching rebuilt stack, not
just libEGL. Earlier partial library deployment did not resolve the failure.

Native test artifact `chrome-gpu-20261102T081700Z.json`: six of six RGB
window samples correct, internal and native X11 pixels agree, swap intervals
0/1 both work, renderer FD740v3. Temporary server import logging was removed
from source after diagnosis (diagnostic binary may still contain that logging).

Complete Chrome artifact `chrome-gpu-20261102T081722Z.json`: GPU rendering,
VaapiVideoDecoder and actual Qualcomm daemon output confirmed; generated red
patch correct in native window AND mapped XWD framebuffer; 110 observed
framebuffer changes during four-second scroll. This resolves the static-image
blocker, but is NOT a smooth playback pass: 248 total video frames, 111 dropped
in 4.072 seconds, approximately 34 non-dropped frames/s. Chrome process-group
CPU ~0.332 core equivalents, excluding X server/daemon/Nightfall. Do not infer
total power or headset quality from this. Software remains production default.
Next isolate synchronous X server GPU-to-CPU readback and presentation pacing
before integration or user playback testing. Wayland remains an alternative,
but is not needed to resolve this protocol mismatch and would require a new
compositor/capture/input integration. All device tests bounded with cleanup.


### Accelerated presentation performance investigation — 2026-11-02

All runs are generated 720p60 clear content, temporary Chrome profiles and
short automatic cleanup. Main browser/default untouched. Decode confirms
VaapiVideoDecoder plus Qualcomm daemon output throughout. Approximate displayed
rate below is (total video frames - dropped frames) / observation duration,
not the Android Surface posting rate or a headset perception measurement.

| Isolated capture experiment | Non-dropped video frames/s | Artifact |
| --- | ---: | --- |
| Synchronous capture, 16 ms interval | ~34 | 20261102T081722Z |
| Capture disabled (diagnostic, no mapped output) | 52.46 | 20261102T082006Z |
| Synchronous capture, 33 ms interval | 35.91 | 20261102T082035Z |
| Two PBOs + nonblocking fence polling | 33.84 | 20261102T082210Z |
| Foreground lab Activity requested | 33.49 | 20261102T082418Z |
| PBO capture with split timing | 34.87 | 20261102T082644Z |
| Server untiled/sysmem rendering | 34.11 | 20261102T082739Z |
| Coherent staging experiment | 34.84 | 20261102T083119Z |

Artifacts use prefix `.build-cache/browser-quest-linux/chrome-gpu-` and suffix
`.json`. Background restrictions still applied even after requesting the lab
Activity: guest affinity [0,1,2] in both runs. Do not claim that requesting an
Activity achieved the six-core scheduling of the real Nightfall-bound service.

`glamor-async-capture.c` is an opt-in experimental implementation included by
`xvfb-dri3-nightfall.patch`. Two bounded per-screen PBOs; submission ordering,
fence polling with zero timeout; cleanup on screen close and size change.
`--async-readback`, `--readback-ms 0/16/33`, `--foreground`, and
`--server-sysmem` expose the diagnostic comparisons. No production default
change. PBO correctness passes generated native/mapped pixel checks, but does
NOT improve fps on this configuration.

Split timing over 382 copies: read submission 24,023 us total (~0.063 ms each),
mapping 1,034,079 us (~2.71 ms each), CPU memcpy 1,441,702 us (~3.77 ms each).
These are aggregate across the generated diagnostic phases, not video-only.
The server spends ~6.5 ms mapping/copying each captured frame. Repeated
GPU-to-CPU capture is a demonstrated major bottleneck, not the sole one:
bypassing it still falls short of clean 60 fps in this background test.

A further opt-in `mesa-kgsl-coherent-readback.patch` honors FD_BO_CACHED_COHERENT
and advertises it only with NF_KGSL_COHERENT_READBACK. Native allocation flags
were already probed earlier, but full cache-coherency portability is NOT
validated. `--coherent-readback` requests immutable coherent read staging when
available. Actual tested EGL context exposes neither GL_ARB_buffer_storage nor
GL_EXT_buffer_storage, so it fell back to ordinary PBOs; this test does NOT
demonstrate cached-buffer performance or correctness. Keep it experimental.

Next substantial direction: investigate a native Android GPU-buffer handoff
(AHardwareBuffer/EGLImage or compatible dma-buf import), with fences and bounded
lifetime, to avoid Linux framebuffer readback and the subsequent Android
upload. Before integrating, independently test buffer format/import capability
and generated changing RGB pixels. Re-check real Activity-bound scheduling.
Avoid promising faster playback solely from hardware decoder counters.


### Android-owned GPU buffer handoff proven — 2026-11-02

Native capability artifact `gpu-buffer-20261102T083947Z.json`: Adreno 740, EGL
1.5; EGL_ANDROID_image_native_buffer and EGL_ANDROID_native_fence_sync exposed;
EGL_EXT_image_dma_buf_import absent. GL_EXT_memory_object_fd exposed, but this
does NOT imply that an arbitrary Mesa dma-buf is an interoperable opaque FD.
Both attempted bare-FD texture storage and buffer storage were rejected with
GL_INVALID_VALUE (1281). Keep `gpu-memory-fd-import-probe.c` as the failed
reference; it is not the active probe or a production path.

Successful reverse-ownership route:

1. Native Android allocates an AHardwareBuffer (RGBA8, GPU render/sample, CPU
   read rarely to request a linear-compatible allocation). No CPU lock/copy.
2. Native EGL imports the buffer through EGL_NATIVE_BUFFER_ANDROID. Android
   retains its complete gralloc metadata for its GPU image.
3. A private, same-UID-checked SOCK_SEQPACKET endpoint sends the generated buffer
   using AHardwareBuffer_sendHandleToUnixSocket. Linux retains/closes all FDs,
   selects the sole allocation large enough for the fixed validated layout,
   and keeps the remaining flattened metadata opaque. This single-plane
   allocation-size selection is a Quest 3 experiment, not a portable gralloc ABI.
4. Linux Mesa imports the pixel dma-buf as linear ABGR8888 (RGBA byte order),
   binds its EGLImage to a GLES framebuffer, and clears red/green/blue in turn.
5. After producer glFinish, Android reads each colour correctly through its
   original GPU EGLImage. Android finishes its read before acknowledging reuse.

Both sides sample ONE diagnostic pixel per colour. There is no full-frame CPU
readback, memcpy, encoding or decoding. This is an offscreen generated-content
correctness probe, NOT Chrome integration, a Nightfall Surface presentation test,
a fence-performance test, a sustained fps test or a claim of 60/72/90 fps.

Passed artifacts:
- `gpu-buffer-20261102T084729Z.json`: 128x128, 512-byte stride, pixel fd 65536
  bytes plus metadata fd 32768 bytes; both processes exit 0, exact RGB samples.
- `gpu-buffer-20261102T085050Z.json`: 1280x720, 5120-byte stride, pixel fd
  3686400 bytes plus metadata fd 32768 bytes; both processes exit 0, exact RGB.

Active files: `gpu-buffer-probe.c`, `probe-gpu-buffer-share.py`,
`run-gpu-buffer-probe.py`, and `build-gpu-buffer-probe.sh`. The paint helper now
accepts optional colour/fourcc, preserving the old XRGB/blue defaults. The
companion service has bounded gpu_buffer_probe / gpu_shared_probe modes.
Build with `ANDROID_HOME=... bash tools/experiments/browser-quest-linux/build-gpu-buffer-probe.sh`,
build/install the companion in-place, then run the host Python runner with
`--share` (128 square) or `--hd` (720p). Default probes native AHB capabilities.
The shared test uses a five-second guest alarm, eight-second native alarm,
service waits and twenty-second device watchdog. No playback/awake override.

Next integration work (still outstanding):
- Add a bounded Android-owned buffer pool and a Linux GPU capture/blit path
  into those buffers, replacing the XWD readback for the accelerated renderer.
  X11 root BGRA versus AHB RGBA needs explicit conversion/swizzle on the GPU.
- Extend the native companion renderer via JNI to sample these AHB EGLImages
  directly into Nightfall's existing supplied Surface; preserve input/audio/IPC
  caller validation, Binder death handling and browser lifecycle.
- Probe native fence FD export/import on BOTH drivers; replace serial glFinish
  handshakes with acquire/release ownership, bounded latest-frame queue, and
  never reuse a buffer until Android has finished sampling it.
- Check resize, stop, detach, standby and GPU context loss cleanup. Validate
  checkerboard/edges/orientation/stride, then generated 720p60 dropped frames
  and total-device CPU with the real Activity binding. Keep the working
  software browser default until integration passes.


### Chrome GPU capture to Android AHB integrated in isolated test — 2026-11-02

New `gpu-x11-capture.py` captures only the uniquely identified generated-test
Chrome window on isolated X display :9. XComposite names its backing pixmap;
DRI3 exports a single-plane, 32-bpp GPU buffer. Linux EGL imports that source
and the Android-owned RGBA hardware buffer, then GLES3 blits between them.
No X11 root-buffer replacement and no full-frame XWD readback/memcpy.
`run-chrome-gpu-probe.py --gpu-capture` enables this path and disables mapped
framebuffer capture, with a temporary Chrome profile and generated 720p60 clip.

The companion runs the AHB exporter alongside the existing Qualcomm decoder
daemon, with independent process handles and cleanup. Parent Python EGL MUST
start with the same PPS Mesa library/shim environment as its children: changing
only the subprocess env left the parent using a mismatched EGL configuration.
This was corrected in the bounded service test mode.

Synchronization now demonstrated for actual Chrome capture:
- A four-byte XGetImage read serializes source X server rendering for the spike.
  This is not a full-frame readback, but is still a CPU round trip.
- After the GPU blit, Linux creates an EGL native fence, flushes, exports its
  sync FD, sends it with the frame command through SCM_RIGHTS and closes its
  duplicate. Android imports that FD into EGLSync and inserts eglWaitSyncKHR.
- Android reads one diagnostic output pixel (or four for the final quadrant
  check), completes that read, then acknowledges ownership release.
- The single AHB is not reused until that acknowledgement. This is safe serial
  ownership for the diagnostic, not an asynchronous production buffer pool.
- Q ends capture; FDs, GL objects, XComposite resources, child processes and
  watchdog lease are cleaned up. Native/guest/service/device deadlines remain.

Artifacts under `.build-cache/browser-quest-linux/chrome-gpu-*.json`:
- 20261102T085947Z: first full Chrome capture, red patch correct, 801 captured
  diagnostic frames; ~53.48 non-dropped video frames/s. Capture oversampled
  at ~100/s.
- 20261102T090105Z: pace generated capture at 60/s; ~54.35 non-dropped frames/s.
- 20261102T090234Z: native fences passed (480 captured frames, 480 imported
  fences); ~55.33 non-dropped frames/s; median capture operation ~2.93 ms.
- 20261102T090354Z: conic-gradient quadrant fixture failed (three black corners).
  Do not treat the earlier one-patch validation as complete geometry proof.
- 20261102T090552Z: explicit solid-colour quadrant divs, source/native all match.
- 20261102T090642Z: repeat with native quadrant sampling BEFORE CPU source
  diagnostic quadrant reads: all four colours match exactly, red patch correct,
  481 captures and 481 imported fences, both processes exit zero, no cleanup
  error. ~53.54 non-dropped frames/s (27 drops / 242 total in 4.016 seconds),
  capture median ~3.75 ms, p95 ~12.93 ms. Hardware VaapiVideoDecoder confirmed.

Native output quadrant pixels are red, green, blue and yellow in the expected
positions. Actual exported test window 1279x719 is GPU-scaled to 1280x720 AHB;
this is a diagnostic window border difference, not a general content crop
implementation. CPU percentages in the report still cover Chrome only.

Status: capability and pixel correctness pass; smooth playback candidate is
FALSE (8–11% video drops in these short background probes). These are not
headset playback/comfort results. The native renderer samples the AHB offscreen;
it does NOT yet present into Nightfall's Surface. Main app browser/default and
profiles remain untouched. All runs stop automatically.

Next: JNI-backed native EGL renderer in the companion to sample the AHB into
the existing Binder-supplied Surface; integrate capture process lifecycle and
real Activity binding, replace diagnostic read/ack with bounded pool/release
fences, validate resize/stop/standby, then measure actual headset playback.
Keep software browser default until that path passes.


### Native EGL output Surface renderer and release fences — 2026-11-02

Implemented the native window-output stage in `gpu-surface-renderer.c` and
`lab/GpuFrameRenderer.java`. `build-lab.sh` compiles a release-optimized JNI
library (O2, 16 KB ELF page alignment), packages it into the companion and
retains the existing signing key. Main Nightfall APK was not rebuilt/changed.

The renderer imports an Android-owned AHardwareBuffer as EGLImage, waits for
Linux's native acquire fence, draws with a GLES3 texture shader into the
supplied Android Surface, swaps, exports a release-fence FD and sends it back
to Linux. Linux imports that fence and inserts eglWaitSyncKHR before reusing
the one shared buffer. There is no full-frame CPU memcpy in the renderer.
Normal F frames do not read pixels; R/P are generated-test diagnostics only.
The shader's vertical orientation was validated AFTER real Surface delivery.

Native lifetime: the worker owns EGL/context/window/GL resources; stop uses an
atomic flag and synchronized socket shutdown to interrupt receive. JNI state
freeing is serialized with Java stop/Hz updates. One active GPU renderer per
companion prevents a late old worker unlinking a replacement's socket. The
process-wide default EGL display is initialized once and not terminated by a
session, so framework rendering is not invalidated. Session resources are
released; blocked Surface-dequeue/standby behavior with a real paused VR
consumer still needs testing. The generated ImageReader always drains.

`FrameRenderer` preserves the old CPU renderer and adds the new backend at the
existing caller-validated Binder Surface entry point. The native library loads
only when the GPU backend is instantiated. The configuration reader remains
in DirectFrameService, so the CPU default does not initialize the GPU class.
GPU selection is explicit `gpu_renderer: true` in the dev direct-frame config;
DO NOT enable for normal browser use yet: its live capture producer/bootstrap
is not wired up. The controlled probe supplies that producer. Input/audio
handlers and the Binder interface are unchanged.

`GpuSurfaceProbe` drains a real ImageReader Surface and checks four sparse
colour samples on delivered images. Its CPU plane mapping is diagnostic only;
these timings do not represent the final Nightfall SurfaceTexture/VR consumer.
`--surface-capture` selects this test. `--surface-stop-early` deliberately
interrupts it; its expected-stop result is separate from complete video/colour
validation, which is intentionally false for an interrupted run.

Successful artifacts (same chrome-gpu JSON prefix under .build-cache):
- 20261102T133528Z: 480 posted/received frames, 480 acquire and release fences,
  exact red/green/blue/yellow Surface quadrants; mean draw/post wall time
  ~0.745 ms. Chrome video ~53.57 non-dropped frames/s, smoothness still false.
- 20261102T134054Z: deliberate stop in 12 ms; worker exited, 250 posted and
  acquired/released fences, no cleanup error. Producer BrokenPipe is expected.
- 20261102T134316Z: after lifecycle hardening, 481 posted AND received frames;
  481 acquire/release fences and Linux release waits; all source, AHB and
  delivered Surface quadrants agree; `surface_fences_balanced=true`. Mean
  draw/post wall time ~0.690 ms; video ~53.31 non-dropped frames/s.
- 20261102T134329Z: final intentional stop in 3 ms; worker no longer alive,
  262 posted and received frames, balanced 262 acquire/release fences.
  `expected_stop_test.passed=true`; ordinary complete-test pass is false by
  design because it was interrupted before the final quadrant fixture.

Python syntax, shell syntax, JNI/Java optimized build, diff whitespace checks
and all four watchdog unit tests pass. No accounts, saved profiles, protected
content or host desktop GPU tests were involved.

Next outstanding: normal Linux-browser startup must opt into the matched DRI3
X server, Mesa/VA codec daemon and a bounded capture producer for the live
browser on :1. The present GPU capture module only discovers the generated
window on isolated :9. Wire that lifecycle to Surface attach/detach without
reading URLs/profile data; honor browser resolution/Hz, test reattach/resize
and standby against Nightfall itself, and measure under its actual Activity
binding before enabling this as a user-facing option. Software stays default.


### Live browser startup/attach integration — 2026-11-02

Implemented normal-runtime GPU capture, still a dev-only opt-in:
- `start-desktop.sh` selects the matched DRI3 Xvfb, PPS Mesa and VA flags with
  NF_GPU_DIRECT=1, disables full-frame XWD readback, and records Chrome's PID.
  Chrome unsets EGL_PLATFORM while the X server uses surfaceless EGL.
- BrowserLabService owns a separate browser MediaCodec daemon, starts/stops it
  with Linux, and passes NF_GPU_DIRECT as an explicit `/usr/bin/env` argument.
  Inheriting it from Java was insufficient: enter.sh clears the environment,
  which the first generated lifecycle test correctly caught.
- `gpu-browser-capture.py` finds the mapped window by _NET_WM_PID, without
  inspecting titles/URLs/profile data. It uses the shared GPU capture module on
  :1, follows the native Surface socket lifetime, and honors target Hz changes.
  Supports the existing 720p and 1080p Linux display sizes.
- GpuFrameRenderer owns the live producer process, reads dimensions from the
  XWD HEADER only, and stops/joins the producer with Surface teardown.
- Binder attachment now starts Linux asynchronously if needed, preserves Hz
  and navigation requests during startup, and uses generation/lifetime tokens
  to cancel pending attachment when the tab closes. The UI transaction does
  not wait for Linux boot. Runtime startup retires active renderers without
  cancelling its first pending attachment. Existing caller checks remain.

Generated normal-runtime test (`run-gpu-runtime-probe.py`): uses a temporary
Chrome profile, generated video followed by quadrant colours, a real Surface
sink and two attach/stop cycles in ONE companion process with Chrome kept
running between cycles. A 70-second device watchdog and host cleanup restore
the original config. No production session timeout was added.

Artifact `.build-cache/browser-quest-linux/gpu-runtime-20261102T140631Z.json`:
- 1080p native output, source window 1919x1079 scaled to 1920x1080.
- Cycle 1: 537 posted/received frames, 537 acquire/release fences and waits;
  exact Surface quadrants; worker and producer stopped cleanly.
- Cycle 2 after reattach: 223 posted/received frames, 223 balanced fences; all
  223 Surface samples match quadrants; no stale socket/buffer/worker.
- Native post rate ~59/s is NOT unique video fps. The generated video daemon
  selected c2.qti.avc.decoder (358 decoded frames from 360 submitted units).
  Capture subprocess still restricted to efficiency cores [0,1,2] in this
  headless service check. No user comfort, real-account playback or UI input
  claims are made from this generated test.

`run-gpu-nightfall-probe.py` additionally attempts a bounded cold attach through
real Nightfall using a temporary fixture/profile. The bridge timed out at
`browser_state` AFTER opening ordinary WebView and BEFORE enabling compatibility
mode (artifact gpu-nightfall-20261102T141934Z.json). No native GPU renderer or
producer status was created. Crash buffer empty. Thus final live XR presentation
remains UNVERIFIED; do not attribute that bridge timeout to GPU capture. Both
apps, playback, watchdog lease and awake overrides were cleaned up afterward.

Current device prepared for manual testing: `gpu_renderer=true` in companion
dev config, generated_gpu_test removed, original other settings preserved.
Previous config backup: `.build-cache/browser-quest-linux/pre-live-gpu-config.json`.
No app or playback left running. Code default remains the original backend.
Main APK unchanged; the optimized companion APK and live scripts are deployed.

Next manual checks: open Nightfall's Compatibility Browser (Linux should now
start automatically), play video, check sound and AI 3D, close/reopen the tab,
and check recovery after removing/re-wearing the headset. Investigate any
remaining input/viewport alignment and actual foreground playback performance
before making GPU rendering the default. The normal-runtime fixture passed
before the final Binder auto-start addition; that addition compiled cleanly,
but its actual Nightfall route awaits the manual check above.


### CRITICAL: interactive use caused device-wide GPU hangs — 2026-11-02

CURRENT STATUS: GPU MODE DISABLED ON HEADSET. Do not interpret the prior short
generated tests as stability validation. User reports stutter on drag/scroll,
UI freezes and passthrough cameras standing still. Capture/export evidence
first; no playback or GPU stress test was run during this investigation.

Evidence preserved in `.build-cache/browser-quest-linux/freeze-20261102/`:
- User export Nightfall-diagnostics-20261102-153514.txt -> export.txt.
- Android logcat including kernel buffer -> logcat.txt; structured summary.json.
- 35 `adreno-gen7-gmu ... GPU hang detected` events, 15:31:50.917 through
  15:33:15.055. KGSL names Xvfb, Chrome GPU process and gpu-browser-capture.py.
  This is system-wide graphics failure, not merely UI latency.
- Capture reports `Native fence FD export failed` and Mesa reports submission
  failure `Resource deadlock avoided`. Do NOT infer a proven circular-fence
  deadlock: KGSL can also return EDEADLK for an already invalidated context.
- Last saved native counters: 3188 posts/acquires/releases, state closed.
  Producer failed after the same 3188 frames, ~49.5 s, with CPU affinity all
  six cores [0,1,2,3,4,5]. Balanced counters do not prove GPU command correctness.
- Last codec log only captures an AV1 portrait session (720x1280, selected
  c2.qti.av1.decoder, 6 units/1 frame), not proof of sustained main-video
  resolution/backend. Browser canvas 1920x1080 is not proof of 1080p video.

Immediate actions: saved diagnostics, stopped both apps, set gpu_renderer=false.
Normal software browser remains available; all app data/profiles preserved.

Prepared containment (not a confirmed fix for the original GPU fault):
- Unexpected live producer exit or native renderer error now stops the GPU
  runtime, records gpu-runtime-failure.json and disables GPU mode for next
  launch. This avoids leaving Chrome/Xvfb running after capture fails.
- GPU Chrome/Xvfb launch in dedicated setsid process groups. Cleanup signals
  only those owned groups, then escalates after 150 ms to include remaining
  descendants. `gpu-process-groups.sh` must be staged alongside start-desktop.
- JNI consumer and Linux producer now use bounded 100 ms CPU sync-file polls
  for cross-driver ownership, instead of enqueueing cross-driver GPU waits.
  No full-frame CPU pixel copy is added. Timeout/error aborts the path. Native
  EINTR retries respect an absolute deadline. This is an UNVERIFIED diagnostic
  candidate; it does not establish that fencing caused the hangs or that the
  driver is stable. Offscreen C reference probe remains a reference.

Validation performed without GPU use: optimized JNI/Java companion builds;
4 poll/readiness/timeout/error tests; 2 real process-group isolation/descendant
cleanup tests; Python/shell syntax and git diff whitespace checks pass. No
new graphics tests. Latest optimized companion and live helper files staged;
GPU remains off. Main Nightfall APK unchanged.

Relevant primary research for further offline driver audit:
- KGSL invalid-context EDEADLK: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-redbull-4.19-s-beta-3/drivers/gpu/msm/adreno_drawctxt.c
- Freedreno on Android, XDC 2023 (Lucas Fryzek), slides 24 and 32–33:
  https://indico.freedesktop.org/event/4/contributions/198/attachments/128/188/XDC_2023_Lucas_Fryzek_Freedreno_on_Android.pdf
  Documents KGSL BO lifetime constraints and gralloc/blit alignment failures
  that can affect Android UI. These are candidate audit areas, NOT proof of
  this incident's cause. Inspect cross-driver fences, BO retirement and actual
  imported stride/allocation alignment before scheduling another bounded
  generated interactive test. Input/CDP queue latency should be measured
  separately only after device-wide graphics stability is established.


### GPU handoff audit follow-up — 2026-11-02

GPU remains disabled; no headset graphics or playback test was run.

The Linux producer previously accepted an acknowledgement with no release
fence. It now requires exactly one release FD, waits for it before buffer
reuse, and closes all received FDs even on malformed/truncated packets.
Import now rejects invalid dimensions, short/misaligned row strides, and
allocations smaller than stride * height (both DRI3 metadata and actual FD
size checked). These are defensive fixes, not a confirmed cause of the hangs.

Ten local GPU helper tests pass without using a GPU: poll behavior, process
group cleanup, malformed/valid handoffs, FD ownership, and allocation bounds.
Unix socket tests required execution outside the sandbox because its policy
blocked a socket send. Python compilation and git diff whitespace checks pass.
These latest Python changes are local only, not staged to the headset yet.

Offline Mesa audit: the pinned KGSL backend already waits for BO fences on
bo_destroy and keeps merged submit references alive until submission assigns
its timestamp. Do not propose those existing safeguards as new fixes. Its
bo_cpu_prep explicitly treats implicit synchronization as a no-op. Therefore
source-side ownership (Chrome -> Xvfb -> imported Composite pixmap) remains
an audit target separate from the Android destination release handshake.
The one-pixel XGetImage is not yet proven to serialize every external writer.
Next isolate generated Chrome animation without hardware video decode, then
with decode, using bounded watchdog tests only after checking source ownership
and stride/alignment. Do not re-enable GPU for an unbounded user session.


### Bounded fence-handoff hardware checks — 2026-11-02

Optimized companion rebuilt and installed in place. Two watchdog-bounded
runtime probes passed at 1920x1080, with temporary generated-only profiles:
- CSS animation (no video element): 534 then 225 posts, ~59 posts/s.
- Generated AVC video: 534 then 226 posts, ~59 posts/s; hardware decoder
  c2.qti.avc.decoder selected, 359 input units / 357 output frames.
Each run used two attach/stop cycles (10s/4s), correct final quadrant colours,
balanced fences and no surviving renderer worker. Neither recent log capture
contains GPU-hang messages. Artifacts: freeze-20261102/followup-summary.json
and gpu-runtime-20261102T160014Z.json / gpu-runtime-20261102T160053Z.json.

LIMITS: posted frames are not unique video FPS; animation motion was not
frame-count validated. ImageReader sink, not Nightfall XR surface; three
little cores only. These short checks do not reproduce the earlier ~49s
interactive incident, do not prove the fault fixed and do not clear GPU
mode for ordinary use. Source XGetImage routes through glamor_download_boxes
and glReadPixels, establishing Xvfb-side completion but not proven coverage
of every independent Chrome writer. Next: bounded generated interactive
load (scroll/resize) with actual Nightfall Surface, and source ownership
investigation if reproduced. Do not request real Netflix playback yet.

Final device checks: both apps stopped, watchdog lease removed, awake override
cleared, gpu_renderer=false restored. Local helper tests: 10 pass; Python
syntax/diff whitespace checks pass. New --animation-only runner option retains
existing watchdog and cleanup behavior. All changes remain uncommitted.


### Real Nightfall generated scrolling repro — 2026-11-02

IMPORTANT: revised fence handoff DOES NOT FIX the GPU fault. The bounded real
Nightfall test reproduced it immediately; runtime auto-aborted at the first
observed GPU-hang log and restored gpu_renderer=false. Both apps stopped,
lease absent, awake override cleared. No further hardware test was run.

Evidence: freeze-20261102/interactive-summary.json, interactive-logcat.txt,
and gpu-nightfall-20261102T161136Z.json. Generated CSS scrolling/layout fixture
contains no video. Native renderer posted 6 frames (6 acquire/release exports);
producer completed 5 release waits then timed out on the next release fence.
Kernel reports hang at 17:11:35.681, Android GL context in app.nightfall.browserlab;
second hang at 17:11:36.525 during recovery. Naming a context does not establish
root cause. Host/device clocks differ by an hour; do not confuse filename UTC
16:11 with device log timestamps 17:11.

Critical confound: actual Nightfall was loading ZipDepth-Wide-512x288-EdgePad
OpenCL from existing preferences during the test. Unlike passing ImageReader
runs, this includes XR and depth inference and six-core foreground scheduling.
Thus Linux video decoding is not required for this repro, but neither source
pixmap synchronization nor output Surface alone is proven to be the culprit.

Added generated-only scrolling/layout fixture and --interactive runner mode;
runner waits for WebView readiness, monitors kernel diagnostics during active
capture, aborts on GPU-hang detection, preserves focus/failure status. Latest
local runner also records initial/test AI3D settings and logs, and provides
--disable-ai3d (in-memory setting plus apply_stereo, no settings save). This
option is PREPARED, NOT YET RUN. Next narrow with AI3D disabled before browser
start, then compare identical fixture with ImageReader if needed. Do not run
unbounded playback or declare stability from headless smoke tests.

Local Python syntax and git diff whitespace checks pass. Main APK unchanged;
companion latest optimized build from previous turn remains installed.


### AI 3D disabled real-Surface retry — 2026-11-02

User manually opened Nightfall after Horizon blocked the earlier cold launch.
Ran --interactive --disable-ai3d --already-open with watchdog. Initial speed=3;
test speed=0, applied in memory only. Reproduced GPU hang after 2 posts, not a
successful stability check. Kernel 17:16:31.665 identifies python3
/tmp/gpu-browser-capture.py context 59 ts4. Native aborted acquire_timeout;
producer last reports stopped with 2 completed release waits. No GPU inference
startup appears in this run's captured log (only CPU configuration messages).
Thus active AI3D/OpenCL inference is not necessary for this reproduction.
Does not prove a specific source/target ownership or cache-coherency cause.

Artifacts: freeze-20261102/interactive-no-ai3d-retry.json;
gpu-nightfall-20261102T161628Z.json and corresponding -logcat.txt.
Producer stderr includes os_same_file_description unable to compare DRM FDs,
falling back to assuming matching file nodes share a description. This is a
candidate audit point, not a confirmed fault.

Cleanup verified: no Nightfall/companion PID, no watchdog lease, no guardian
pause override, config gpu_renderer=false. No saved user preference changed.
Next offline comparison: why the same Linux import/blit works with generated
ImageReader tests but fails with real XR Surface; audit DMA-BUF cache ownership,
output handoff, and driver FD/context identity. Do not repeat uncontrolled
interactive playback. GPU mode remains disabled.


### Source-copy isolation and startup-race correction — 2026-11-02

Added experimental capture modes composite (unchanged default) and solid.
Solid still imports both buffers and keeps Chrome/Xvfb running, but skips
per-frame XGetImage and source blit, writing generated colours into the AHB
instead. It is NOT a source-import-free test. gpu-browser-capture reads the
app-private /tmp/nf-gpu-capture-mode; real-Surface runner stages/restores that
file via --capture-mode. Three additional mocked-graphics tests verify the
operations actually differ; all 13 helper tests pass without a GPU.

First solid run (gpu-nightfall-20261102T162030Z.json) also hung, before its
first completed frame. HOWEVER this run's AI3D-off precondition was invalid:
runner observed default speed=0 before startup finished, then saved host
settings loaded and initialized EdgePad/OpenCL. Do NOT use this run to claim
source-copy-free + AI3D-free failure. It does show a hang without per-frame
X11 reads/blits while XR, Chrome/Xvfb and inference initialization coexist.
Earlier manually-opened no-AI3D run at 16:16 had initial speed=3 and only CPU
configuration logs; its evidence remains separate.

Runner now waits for main._startup_ready before reading/modifying AI3D and
checks its speed during active capture. Main code confirms the dev bridge
starts BEFORE asynchronous XR startup and saved-host preferences load;
therefore ping != readiness. New corrected solid retry at 16:22
(gpu-nightfall-20261102T162239Z.json) stalled at startup_ready with Horizon's
ActiveTaskBarActivity in front. It did NOT reach GPU capture.

File-description audit: warning is from u_screen.c's process-local screen
cache when kcmp/F_DUPFD_QUERY cannot establish FD identity under PRoot. It
cannot itself merge screen state across Linux and Android processes. Distinct
same-node FD aliasing inside one process remains unproven; no cache patch or
system policy change made merely to suppress the warning.

Cleanup after all attempts verified: both apps stopped, no lease or guardian
pause override, GPU config false, diagnostic capture-mode file absent.
No additional GPU tests until Nightfall is manually foregrounded again.
Next command with user app open:
ADB=... PATH=... /usr/bin/python3 tools/experiments/browser-quest-linux/run-gpu-nightfall-probe.py --interactive --disable-ai3d --capture-mode solid --already-open
Python compilation/diff checks pass; changes uncommitted; main APK unchanged.


### Corrected solid + AI3D-off result — 2026-11-02

User manually foregrounded app; --already-open waited for _startup_ready.
Artifact gpu-nightfall-20261102T173638Z.json and corresponding -logcat.txt;
summary copied to freeze-20261102/solid-corrected-retry.json.
Initial AI3D=3, test=0, last checked during capture=0. Only CPU configuration
messages appear; no GPU inference initialization in captured interval.
Capture mode solid confirmed by producer. Reproduced GPU hang before first
posted frame, with native acquire_timeout. Kernel at device 18:36:42.347 names
Xvfb context49 ts3 (ANY). No per-frame XGetImage/source blit in this mode.
Chrome/Xvfb still run, source imports still occur; not proof those can be
removed from the fault. This narrows toward Linux Mesa/KGSL GPU activity
coexisting with real XR, not video decode or AI inference as prerequisites.
Kernel context naming alone is not proof of cause. No claim of a fix.

available=false came from the asynchronous frontend navigation snapshot;
the explicit compatibility action nevertheless attached the renderer and
started generated capture, as native/producer status confirms. Do not use
that snapshot alone to infer the test never reached GPU.

No more hardware tests in this turn. Verified apps stopped, GPU false,
watchdog lease removed and awake override cleared. Next offline audit:
KGSL context setup/submission and mixed vendor/Mesa context state when VR
compositor is active; isolate Mesa clear/import from GPU Xvfb/Chrome before
another risky interactive session. Retain GPU-off default and watchdog.


### Driver audit and untiled diagnostic — 2026-11-02

See docs/plans/active/quest-linux-gpu-xr-audit-2026-11-02.md for evidence,
ruled-out missing safeguards, test limits and next minimal isolation.
All-process sysmem diagnostic failed (GPU hang persists); not a fix.
Prepared independent kernel-log monitor so a blocked dev bridge cannot hold
up the host's abort loop. 17 local helper tests pass; monitor hardware use
still unverified. No more hardware tests this turn. GPU off and apps stopped.


### Minimal private-pbuffer baseline — 2026-11-02

Added probe-minimal-gpu-clear.py: GLES3 32x32 private pbuffer, changing GPU
clears and 1-pixel correctness checks, 120 frames paced at60/s, four-second
local alarm. No X11/Chrome/video/imports/sharing. GpuAllocationService's new
minimal_clear option uses the same matched Mesa bundle/preloads as the failed
browser route, with its existing five-second subprocess deadline. Optimized
companion rebuilt and installed in place; main APK unchanged.

run-minimal-gpu-xr-probe.py wraps standalone then real-XR comparison in70s
on-device watchdog plus independent kernel-log monitor. Baseline passed:
FD740v3,120 correct frames,2.0s; the OFD warning still appears despite success.
Artifact minimal-gpu-xr-20261102T175950Z.json. XR phase did not run: Nightfall
launch was held by Horizon and hit12s command deadline. Both apps stopped,
no watchdog lease/awake override;GPUfalse. No additional graphics stress.

Runner now offers --already-open to skip baseline and preserve a manually
foregrounded Nightfall. XR preconditions require startup ready, OpenXR
initialized, no browser and no stream. This avoids modifying AI3D preferences.
Next: user opens Nightfall, then run minimal runner --already-open. Cannot
claim XR coexistence pass/failure from the baseline alone.17 local helper
tests pass; shell/Python syntax and diff checks pass. Work uncommitted.


### Minimal XR coexistence comparisons passed — 2026-11-02

Private clear WITH active Nightfall XR passed:120 correct frames in2.0s on
FD740v3. Artifact minimal-gpu-xr-20261102T180212Z.json. First retry aborted
before GPU work because Expression cannot resolve XRServer as a singleton;
fixed precondition to main.get_viewport().use_xr. Corrected run confirmed
[XR viewport=true,browser active=false,streaming=false]. No saved settings
were modified. Both standalone and XR private clears now have passing evidence.

Advanced the same runner with --share (128x128) and --hd (1280x720), reusing
the established Android-owned AHB sharing probe. BOTH passed alongside XR:
three RGB clears written with Linux Mesa and exact corresponding Android
readback colours;guest_exit=0,native_exit=0. No Xvfb,Chrome,video or actual XR
output Surface in these sharing tests. Synchronization is glFinish/ack, not
the continuous frame fence protocol. Thus these are correctness checks, not
sustained throughput/stability validation.
Artifacts minimal-gpu-xr-20261102T190109Z.json (128) and
minimal-gpu-xr-20261102T190216Z.json (720p); combined summary in
freeze-20261102/minimal-xr-comparison-summary.json. Their kernel logs contain
zero GPU-hang messages. The descriptor warning remains in passing probes.

This narrows the fault: neither basic Linux hardware GLES alongside XR nor
simple synchronous Android/Linux AHB sharing necessarily hangs. Next add the
continuous fence handoff without X11/Chrome, followed by the actual output
Surface. Keep those variables separate; do not attribute prior failures to
all Linux/XR coexistence. Do not re-enable ordinary accelerated playback yet.

Cleanup verified after all runs: apps stopped,no lease,no awake override,
gpu_renderer=false. Main APK unchanged; optimized companion from minimal-clear
build installed. Python compilation/diff checks pass. Changes uncommitted.


### Continuous ownership handoff passed; no-X11 real Surface prepared — 2026-11-02

Added GpuCapture mode generated, which skips all X11/Composite/DRI3 setup and
source imports, creating only the Android-owned destination EGLImage/FBO.
This differs from solid mode, which retained X11 source setup. Guest
probe-gpu-fence-loop.py uses generated GPU colours for120 paced frames.
Native reference exporter now waits acquire sync-files with a100ms CPU poll
and sends a native release fence per acknowledgement, matching the strict
producer protocol. Old3-colour glFinish/ack route remains separate.

run-minimal-gpu-xr-probe.py --fences PASSED baseline AND XR welcome-screen
phases:120 frames,120 acquire fences,120 release fences each,correct changing
pixel values,guest_exit=0,native_exit=0. Artifact
minimal-gpu-xr-20261102T190630Z.json, copied to
freeze-20261102/continuous-fence-comparison.json. No detected kernel GPU hangs.
Limits:1280x720,~2seconds,Android1-pixel diagnostic reads/glFinish;no native
Nightfall output Surface,Chrome,Xvfb orvideo. Not a sustained playback claim.

Next stage prepared: --surface-only on run-gpu-nightfall-probe.py. Private
config generated_minimal_gpu_test bypasses BrowserLabService and all Chrome,
Xvfb,audio/input/runtime readiness setup. GpuFrameRenderer launches bounded
probe-gpu-surface-generated.py with generated mode into the REAL Binder-supplied
Nightfall Surface;120 frames,5s producer alarm. NoXWD header needed;1280x720
diagnostic dimensions. Normal runtime unchanged when privateflag absent.
Expected completion of this generated producer is not treated as a live
browser crash. GPU config and temporary files restored by runner.

Optimized companion/native reference probe rebuilt and installed.18 local
helper tests pass,shell/Python syntax/diff checks pass. MainAPK unchanged.
First actual Surface attempt gpu-nightfall-20261102T190836Z.json blocked at
bridge because Horizon taskbar paused Nightfall;NO graphics test ran. Need
user to foreground Nightfall, then run:
run-gpu-nightfall-probe.py --surface-only --disable-ai3d --already-open

All apps stopped by cleanup;GPU mode remains false. Work uncommitted.


### Actual Nightfall Surface, no X11/Chrome: PASS — 2026-11-02

After user foregrounded Nightfall, ran --surface-only --disable-ai3d
--already-open. Artifact gpu-nightfall-20261102T192136Z.json and matching
kernel log; copied summary freeze-20261102/generated-real-surface-retry.json.
AI3D initial3/test0/last0;browser active and direct_active true. Native actual
Binder-supplied Surface posted120 frames,120 acquire fences,120 release fences,
state stopped/closed,1280x720,~59.15 posts/s,~0.691ms mean draw/post wall time.
Producer120 frames in2.0s,120 release waits,passed. No full-frame CPU copy.
Kernel monitor reported no hangs. This is a SHORT generated-path pass, not
ordinary browser playback stability or a performance/comfort guarantee.

No Chrome,Xvfb,video,audio or Linux input service was started in this route.
Together with prior private-clear and repeated shared-buffer checks,this shows
the basic XR/interop/display route can work. Next isolate adding Xvfb without
Chrome,then Chrome separately. Do not attribute the old fault to general
LinuxGPU/XR coexistence or declare the browser repaired. GPU default stays off.

Both apps stopped;watchdog and awake override cleared;GPUfalse verified after
this test. MainAPK unchanged. All experiment work remains uncommitted.


### Xvfb-only addition reproduces; GLES fallback also fails — 2026-11-02

Extended generated real-Surface probe with X11 modes off/idle/capture and
idle-gles/capture-gles. Idle starts private GPU Xvfb :9, creates a1280x720
window and fills it with changing X11 colours, while the Android Surface still
receives INDEPENDENT generated AHB colours (no X11 imports/copies). No Chrome,
VNC,video,audio,input services. Existing watchdog/kernel monitor retained.

idle mode reproduced GPU hang after17 posts,balanced17 fences. Kernel names
Xvfb context56 ts20 at21:06:47.810. Artifact
gpu-nightfall-20261102T200640Z.json. Thus adding Xvfb accelerated drawing can
reproduce WITHOUT consuming its image or running Chrome; not proof of exact
root cause, nor a claim the server alone fails without XR.

Compared desktop GL against Xvfb's existing GLES fallback. Added app-private
opt-in NF_XVFB_GLES (default unchanged),reproducible patches/build script and
explicit GL_VERSION/renderer/glamor-ready diagnostics. Rebuilt isolated Xvfb
and optimized companion;staged privately. Original binary retained at
files/linux/rootfs/opt/nightfall-xvfb/Xvfb.before-gles-test.
GLES test verified OpenGL ES3.2 Mesa27 FD740v3 +GLAMOR_READY=1,then also hung
after17 posts. Artifact gpu-nightfall-20261102T201009Z.json. Kernel first names
vrshell;context naming is not proof of root fault. No GLES mitigation claimed.

Next candidate: resource layout. Passing probes use linear buffers;Xvfb can
allocate internally tiled/UBWC-compressed pixmaps. Added driver-policy linear
(FD_MESA_DEBUG=notile,noubwc),applied before EGL loading and inherited by
isolated Xvfb,still GPU rendering/no full CPU copy. This is separate from
sysmem rendering (which does not itself disable texture tiling/compression).
No hardware claim: first linear attempt gpu-nightfall-20261102T201133Z.json
blocked at bridge by Horizon taskbar BEFORE GPU capture.

Next requested manual-foreground command:
run-gpu-nightfall-probe.py --surface-x11 idle --driver-policy linear --disable-ai3d --already-open
If it passes,validate Xvfb image capture separately,then add Chrome.
If it hangs,stop and investigate source draw/driver state;do not blindly
repeat full playback. No Chrome-added test run this turn.

18 local helper tests pass,shell/Python syntax/diff checks pass. Both apps
stopped,watchdog/awake override cleared,GPUfalse restored. No system driver,
security policy or mainAPK changes. Work remains uncommitted.


### Linear-buffer Xvfb retry: still GPU hangs — 2026-11-02

User foregrounded Nightfall. Ran --surface-x11 idle --driver-policy linear
--disable-ai3d --already-open. Artifact gpu-nightfall-20261102T203232Z.json,
matching kernel log,copy freeze-20261102/xvfb-linear-idle-retry.json.
Initial AI3D3,test0,last0. Kernel monitor detected a GPU hang and aborted.
Native stopped/closed after16 posts with16 acquire/release fences. Producer
was killed before final status. This is NOT a fix; requested notile,noubwc
policy does not resolve this reproducer. No claim every allocation modifier
was independently measured; imports can impose their own layouts.

No additional hardware tests this turn. Next offline investigation should
focus on Xvfb GLAMOR draw submission/state/resource lifetime under concurrent
XR. Compare Xvfb startup-only against its first XFillRectangle draws,then
examine affected command emission and batching. Chrome/video/AI inference
and consuming Xvfb's image are not prerequisites for this isolated repro.
Avoid a string of further ungrounded debug-flag hardware attempts.


### Breakthrough: tiny shader draw reproduces without Xvfb — 2026-11-02

See docs/plans/active/quest-linux-minimal-triangle-reproducer.md. Added --draw
to the private clear comparison. Standalone passed120 triangle frames in2.0s;
same tiny shader draw with XR active hung. Kernel names the probe's own Mesa
context46 timestamp1. No Xvfb,Chrome,video,imported image or Surface handoff.
The old Xvfb-specific interpretation is superseded: shader drawing in the
Mesa/KGSL path alongside XR is enough for this reproducer. Exact cause remains
unconfirmed. No need to keep reproducing full-browser freezes.

Artifact minimal-gpu-xr-20261102T204039Z.json and kernel log. Driver recovery
caused Triangle centre mismatch; first-bad-frame/pixel diagnostics were added
locally afterward,not yet deployed/retested. Startup-only Xvfb test mode also
prepared (no window map/fill) but not run; lower priority now.

18 helper tests passed;optimized companion compiled/installed for minimal
triangle. No driver patch from speculative command offsets or missing common
BO waits. Both apps stopped,no lease/awake override,GPUfalse verified. MainAPK
unchanged. No more hardware tests this turn;all work uncommitted.


### Generated shader diagnostics and arithmetic control — 2026-11-02

Added --standalone-only / --diagnostics to minimal runner. Diagnostics uses
ONE generated frame and IR3 vs/fs/disasm/nocache flags with XR stopped;
saves only our generated shader code locally. No website/media/profile data.
Artifacts: minimal-gpu-xr-20261102T204557Z.json and generated-shaders.txt.
Default array-position VS has a constant-table UBO load and early preamble.
Internal helper shaders also appear in this log;don't attribute every
preamble count to the application's actual VS/FS.

Tested --no-early-preamble: standalone diagnostic confirmed all reported
preamble early flags0. Artifact204714. Full120-frame standalone passed but
XR still hung (minimal-gpu-xr-20261102T204728Z.json). Not a fix. Tested
--no-preamble only in standalone compiler diagnostic (artifact204923): it
still emits10-instruction ordinary preambles. Do not call this preamble-free;
no XR test was run for that option.

Added --arithmetic-vertex: generate positions using gl_VertexID arithmetic,
with centre/background correctness checks and no position table. Standalone
compiler output confirms no UBO loads/preamble in actual application
VS/BVERT; red FS also has no preamble. Artifact205121 and shader log.
Standalone120 frames passed in2.0s in artifact205137. XR phase blocked by
Horizon before probe start. A retry using normal MAIN+LAUNCHER intent flags
also failed to foreground/complete startup (artifact205257);no GPU work in
that retry. Do not report arithmetic-control XR success or failure yet.

Next pending manual-foreground test:
run-minimal-gpu-xr-probe.py --already-open --draw --arithmetic-vertex
If this passes,constant-data/preamble path is narrower candidate. If it hangs,
the generic graphics state/context coexistence issue remains. No browser or
Xvfb tests needed until this minimal comparison is understood.

Optimized companion updated in place;mainAPK and normal browser/driver
configuration unchanged. Shader diagnostics are opt-in and probe-local.
Both apps stopped,lease/awake override cleared,GPUfalse verified. Python
compilation/diff checks pass. Work remains uncommitted.


### Arithmetic triangle fails too; launch-reporting bug corrected — 2026-11-02

User manually opened Nightfall; arithmetic-only XR retry reproduced GPU hang.
Artifact minimal-gpu-xr-20261102T205507Z.json;kernel21:55:09.660 identifies
probe python3 context51 ts3. Application VS/BVERT have no table UBO/preamble,
so that particular shader feature is not necessary for the failure. Do not
infer every internal helper shader is preamble-free. Monitor killed apps
before the probe wrote final numeric failure fields;no failed-frame claim.

User questioned repeated Horizon launch-block explanations. Found an actual
reporting bug: run-gpu-nightfall-probe.py selected split(...)[-1],the LAST
resumed activity across multiple Android displays. TaskBar can remain listed
while Nightfall itself is resumed. Snapshots after hang errors can also be
after the monitor already stopped Nightfall,so they cannot establish the
cause of a launch failure. Old Horizon-cause claims are withdrawn pending
proper lifecycle evidence. Startup timeouts themselves were real.

Added android_activity_state.py;report all resumed activities,prefer the app
record for display,explicitly state limits,and preserve original test errors
if snapshot collection fails. Three regression tests cover app+taskbar,
absent app and duplicate/empty records;21 total local tests pass. Both test
runners use the structured snapshot now. No mainAPK/runtime changes for this.

Ran one plain Nightfall launcher check with LinuxGPU config=false and no
companion process. Ready at~2.65s;OpenXR viewporttrue. Android listed BOTH
Nightfall and taskbar as top-resumed on their separate displays. Artifact
plain-launch-20261102T205725Z.json and log. This demonstrates the taskbar
observation alone was misleading,not a new confirmed Horizon restriction.
It does not explain every earlier intermittent startup timeout.

Final cleanup verified: apps stopped,no lease/awake override,GPUfalse.
Recorded findings;no further GPU tests this turn. Next driver work should use
the arithmetic triangle for a minimal shader/context coexistence reproducer.
All work remains uncommitted;mainAPK unchanged.


### Earlier software-browser baseline revalidated — 2026-11-02

User correctly asked why the previously working browser became unstable.
Two GPU boundaries must be distinguished: the earlier route renders Linux
Chrome/Xvfb in software,then uses Android hardware Canvas to scale/post to
Nightfall's Surface. The new accelerated route additionally runs Linux Mesa
shader workloads;the isolated XR hang is in that experimental addition.

Compared CPU Canvas renderer against commit151f5cd: only FrameRenderer
interface/visibility annotations changed,no pixel-copy implementation change.
Device config GPUfalse,hardwareCanvastrue,1920x1080;no legacy renderer/policy
file override found. Added explicit service NF_GPU_DIRECT=0 ->software
selection so a future stale manual GPU renderer file cannot override failure
shutdown. This is defensive,not the cause found on this headset. NF_GPU_DIRECT
unset retains manual lab overrides;1 selectsgpu-direct. Shell syntax checked.

Added --software-baseline to existing real-Surface runner:GPUfalse,software
Chrome renderer pinned temporarily,temporary generated-only browser profile,
Android Canvas path,original renderer/config restored afterward. First launch
blocked with actual GuardianDialogActivity/ClearActivity records (unlike the
previous erroneous taskbar-last attribution);no browser capture ran then.
User foregrounded app for retry.

PASS artifact gpu-nightfall-20261102T210458Z.json,copy
freeze-20261102/software-browser-baseline-retry.json:
- source/output1920x1080,hardware_canvas,rawbitmapcopytrue;
-814 posts over11.40s,71.42 posted/s,target72Hz;
-247 changed samples,7late slots;
-meanCPUcopy1.18ms,meanCanvasdraw/post2.35ms;
-post intervalp50~13.89ms,p95~14.61ms;
-appbrowseractive/directtrue,renderer stoppedcleanly;
-no detected GPU hangs.

Limits:short generated video/UI fixture,not Netflix authentication/playback,
unique decoded video FPS,manual touchcomfort or long-session validation. Do
not equate the1920x1080canvas with Netflix video resolution. Baseline working
does not make Linux GPU route stable. Preserve this route before further
acceleration changes. Candidate next strategy:separate hardware decode from
Linux GPU compositing,provided Chrome/backend supports it;research and test
rather than claim compatibility. Kernel/Mesa draw reproduction remains valid.

Normal browser profile/sign-ins untouched. Both apps stopped,lease/awake
override cleared,GPUfalse verified. MainAPK unchanged;all work uncommitted.
