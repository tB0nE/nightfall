# Quest Linux browser experiment — session handoff

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
