# Quest Linux browser experiment — session handoff

Date: 2026-10-31. The user is rebooting into Windows for other development and
wants to return to this experiment later.

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
