# Quest Linux browser: audio and Nightfall integration

> Current checkpoint: [2026-11-02 status and resume notes](../../handoffs/QUEST_COMPATIBILITY_BROWSER_STATUS_2026-11-02.md).
> Working software baseline retained; experimental Linux GPU mode disabled.


> Activity-reporting correction (2026-11-02): earlier claims that Horizon was
> blocking launches are not established. The test reporter selected the last
> resumed activity across multiple displays, often the taskbar even when
> Nightfall was resumed. Reporter corrected; a plain GPU-experiment-off launch
> reached XR-ready in ~2.65s. GPU hangs remain independently confirmed.


> **Latest status (2026-11-02): GPU mode disabled after confirmed device-wide GPU hangs during interactive use. See the CRITICAL incident section at the end before running graphics tests.**

Date: 2026-10-31. Experimental work on `codex/bundled-host-testing`.
Implementation and reproduction: [headset lab](../../../tools/experiments/browser-quest-linux/README.md).

## Established results

- The user confirmed Netflix video plays in official ARM64 Chrome on Quest 3.
  This is Ubuntu userspace through PRoot on Android's kernel, not a VM.
- Ordinary Widevine API initialization succeeds. No Meta Browser DRM components,
  device secrets, license responses or existing VM login profiles were copied.
- Android killed the original tracer while trimming phantom child processes.
  A threaded viewer proxy and less Chrome background activity reduced the lab
  to 22 child processes during a seven-minute controlled video test. The final
  counters at 476 seconds showed 14,059 frames, zero drops and no playback error.
  The user subsequently reported stable Netflix viewing with this configuration.
- The audio prototype captures only `nightfall_lab.monitor`, a PulseAudio sink
  monitor. It forwards stereo PCM16 at 48 kHz through a process stdout pipe into
  Android AudioTrack. There is no microphone capture or microphone permission.
- Android telemetry establishes non-zero PCM delivery, an advancing hardware
  playback head and granted audio focus. The user subsequently confirmed Netflix sound works inside Nightfall; lip sync
  and listening comfort still require more testing. The PC noVNC viewer does not receive audio.

## Current prototype architecture

```text
Official Chrome ARM64 (in companion app's Linux userspace)
  picture -> Xvfb -> x11vnc -> threaded websockify/noVNC
  sound   -> PulseAudio sink -> parec monitor -> stdout pipe -> Android AudioTrack

Companion Android foreground media service
  owns Linux runtime + audio bridge; remains active when Activity is backgrounded
  Activity supplies start/stop controls and optional local noVNC viewer
```

The audio bridge aligns partial reads to stereo frames, bounds its output buffer,
handles focus loss/ducking, and reports counters without saving PCM content.
It uses the same GAME audio usage as Nightfall and requests no spatialization.
Sleep can suspend Android audio output even if Linux processes remain alive.
The service does not hold a permanent wake lock or change system volume.

## Phase 1: audio verification

1. Verify the controlled H.264/AAC loop produces non-zero monitor samples and
   increasing Android playback frames; check focus and process count.
2. Keep the browser alive while switching from its Activity to Nightfall. Confirm
   that audio remains routed and the Linux tracer remains alive.
3. User checks Netflix audio, stereo sides, volume and lip sync. Test pause,
   seeking and returning from headset standby. Do not infer sync from counters.
4. Verify explicit stop removes audio and Linux children; preserve profile and
   normal Quest media-volume settings. Never clear browser data for recovery.

## Phase 2: first integration using the existing Nightfall browser

Prototype status: the viewer URL was opened through Nightfall's existing browser
input path without rebuilding its APK. The user confirmed the Linux Chrome test
page is visible in VR. H-AI3D telemetry reports normal depth updates; the separate
foreground audio service retains focus and continues consuming PCM. The combined
Netflix picture, sound and AI 3D were subsequently confirmed by the user, who
reported poor frame rate and loud fan activity. The remaining checks concern
input quality, lip sync, sustained cadence and performance.


No new renderer, screen layout or model is needed for this proof:

1. Start the companion runtime and leave its foreground service active.
2. In Nightfall, open a normal browser screen, then navigate to
   `http://127.0.0.1:6082/vnc.html?autoconnect=true&resize=scale`.
3. The existing WebView receives the desktop as a canvas; the existing
   SurfaceTexture/uploader, screen controls and controller input remain in use.
   The outer Nightfall browser's DRM permission is irrelevant to the local canvas;
   ordinary DRM playback occurs inside Linux Chrome.
4. Confirm pointer mapping, keyboard input, Netflix navigation and fullscreen.
   A local stream's extra coordinate transforms must be measured, not patched by
   adding a guessed cursor offset.
5. Select the browser as primary, enable normal headset AI 3D and check the final
   depthmap against the picture. Only one on-headset inference target remains.
6. Verify companion audio continues while Nightfall is foreground, with explicit
   policy for whether desktop/PCVR sound should coexist, pause or mute.

Relevant existing code: `src/browser_prototype.gd`, `src/screen_sources.gd`,
`android/src/main/java/com/godot/game/BrowserPrototype.java`, and
`android/src/main/java/com/godot/game/AudioOutput.java`.

This is a development test, not the final browser UI. There will be nested browser
controls and VNC overhead. It establishes the existing picture/input/inference
path can consume this source before building a dedicated integration.

## Phase 3: replace the remote-desktop presentation path

Measure independently before selecting a transport:

- Chrome's decoded/total/dropped video frames and frame cadence.
- Xvfb capture cadence and cost, RFB encoding, WebSocket transfer and canvas draws.
- Nightfall surface uploads, presentation cadence and inference cost.
- Audio buffering and output timestamps versus displayed video timestamps.

Then prototype a local frame producer that sends frames directly into an Android
Surface or AHardwareBuffer consumer, plus a small input/control channel. Reuse
Nightfall's browser content-provider contract and existing primary-screen logic.
Account for explicit ownership, synchronization and teardown of producer buffers.
Do not assume that removing VNC also provides hardware video decoding; Chromium's
Linux decoding backend and access to Quest codec hardware are separate work.

Avoid adding an encode/decode step solely to move local pictures. A CPU-copy
prototype may be useful, but choose it based on measured cost and cadence. Keep
the reliable viewer as a diagnostic fallback until the direct path is verified.

## Phase 4: deliberate UI and lifecycle integration

- Keep the normal lightweight browser as default. Add a clearly experimental
  Linux-browser backend only after the end-to-end proof succeeds.
- Fit it into existing screens/tabs rather than introducing another overlay or
  parallel layout system. Initially support one Linux browser runtime/screen.
- Provide download/setup progress, storage requirements, start/stop state,
  permission boundaries, errors and a clear way to recover without losing logins.
- Keep service ownership outside the Activity. Track start generations, process
  exit, standby and buffer lifetimes; never spawn duplicate runtimes on resize.
- Maintain child-process headroom as tabs/media/AI 3D and other apps are used.
  A foreground service does not remove Android's global phantom-process limit.
- Coordinate media focus with Nightfall. Do not add volume boosts or positional
  sound as an accidental side effect of using a separate Android window.

## Gates before calling this shippable

1. **Sandbox:** Chrome currently needs `--no-sandbox`; PRoot is not a security
   boundary. Android app isolation alone does not replace browser renderer/site
   isolation. Keep the helper isolated from Nightfall data and investigate a
   supported containment design before offering arbitrary browsing.
2. **Modern Android packaging:** the helper deliberately targets API 28 to test
   downloaded executable Linux files. This does not establish support under
   Nightfall's modern target SDK or store requirements. Prove a permitted native
   execution/packaging design rather than lowering Nightfall's target SDK.
3. **Component licensing and updates:** review Chrome/CDM distribution and update
   terms. The lab downloads official packages locally; its existence is not
   permission to redistribute them inside an APK. Record versions and integrity.
4. **Private transport:** current loopback ports are unauthenticated lab endpoints.
   Other Android apps may reach loopback. Production needs authenticated control,
   authorized callers and private frame/audio transport, preferably UID/signature
   protected IPC or explicitly granted file descriptors. Do not expose CDP.
5. **Sustained performance:** verify resolution, browser decode cadence, final
   presentation rate, A/V sync, memory, process budget, battery and thermal load
   on actual content. The controlled 720p test is not a Netflix benchmark.
6. **Service authorization:** check actual supported playback per service. One
   Netflix success is not a promise for all DRM services or future policy changes.

Until these gates are resolved, retain this as a separate sideloaded lab. Do not
enable it in ordinary releases or silently replace the existing browser.

## Latest direction before pausing for Windows work

The user wants one shared Linux environment and browser runtime, not a VM or
runtime per screen. Nightfall should own tabs/navigation and display individual
browser views without Chrome's desktop chrome. Retain official Chrome initially,
since it is the tested DRM implementation. An embedded/custom browser engine is
an option to investigate, not a guaranteed equivalent for Netflix.

- Map Nightfall tabs to browser targets and visible screens to independent views.
  Normal background tabs are not automatically continuously rendered surfaces.
- Prototype two independently updating views before expanding. Reuse the same
  browser infrastructure/profile; account for per-renderer memory and Android's
  shared child-process limit. The current renderer limit of three is only a lab
  setting and will need deliberate review for multiple screens.
- Keep on-headset inference on the primary screen only; do not multiply inference
  work when a user opens another browser screen.
- Offer touch input for controller taps/drags/scrolling, retaining a mouse fallback.
  Hide the inner browser cursor but keep Nightfall's aiming indicator. Touch
  capability must not silently switch the UA back to mobile and reintroduce the
  Netflix app requirement.
- Prefer private control IPC. CDP can manage targets and inject touch for a spike,
  but must not be exposed as an unauthenticated debugging endpoint.
- Suspend hidden pages where appropriate; background audio is an explicit choice.
- Measure active video with inference off/on, then isolate decoding, capture,
  canvas/upload and final presentation. The last snapshot was taken **paused**:
  Nightfall 60 fps, inference about 20 Hz at ~32 ms, battery API reporting 44 C,
  thermal status 0. It cannot identify the active playback bottleneck. Hardware
  video decoding is not established; software graphics is explicit in the lab.

No multi-view, touch-input backend or hardware decoder has been implemented yet.

## 2026-11-01: direct-frame CPU-copy spike

Controlled foreground playback measured about 30 decoded/non-dropped frames/s,
but only 11 VNC updates/s reaching Nightfall. Faster polling improved that to
about 13/s, so the conservative settings were restored. App rendering stayed
at 60 fps; it is not the video cadence.

A DEV-only direct-frame prototype is now implemented and builds:

- Xvfb exposes its XWD framebuffer using `-fbdir` in the helper's private files.
- The helper validates the layout, memory maps it read-only, copies into a
  reusable Bitmap and posts to an Android Surface at a target 30 Hz.
- Nightfall explicitly binds the helper's DirectFrameService and hands over
  its existing browser Surface. The service validates the calling UID belongs
  to the installed Nightfall package. Binder death stops that producer.
- The old virtual-display producer is detached first; the VNC page is blanked
  and paused. Disabling the test restores the old display and viewer URL.
- Activation is through the DEV Java bridge only, gated by the existing DEV
  manifest metadata. No normal UI/default backend or extra XR layer changes.
- An offscreen ImageReader smoke probe measures Surface deliveries separately
  from VR presentation. It reports counters only, not media frames.

Both the helper and release-optimized DEV main APK built, and the existing
browser policy/data/gamepad tests passed. Both APKs were installed in place.
Initial tests were affected by Guardian/ClearActivity and a missing Android
package-visibility declaration. The DEV manifest now explicitly queries the
helper package, and a status-returning Java method diagnoses the handoff.

The direct producer then posted about 29.4 frames/s during active generated-video
playback, with about 26 changed framebuffer samples/s. Nightfall measured about
29.5 texture updates/s, versus the earlier VNC path's 11–13. These are short,
sequential lab runs, not Netflix benchmarks or unique-frame/presentation proof.
With AI enabled, inference reported 29.1 ms / 19.8 Hz while the producer retained
about 29.5 posts/s. Stopping and reattaching the producer worked; final cleanup
fixes restore home correctly and report normal interruption as a stop.

The offscreen probe has not completed successfully and must not be reported as
passed. Visual correctness, colors, tearing, audio sync, sustained performance
and standby recovery remain user/device validation. Measurements are in ignored
`.build-cache/browser-quest-linux/performance-20261101/direct-active-*.json`.

This is a CPU-copy prototype, not zero-copy. Xvfb's mapped framebuffer has no
frame-completion fences, so tearing is possible. Input still targets the normal
WebView, not Linux; use the existing RFB desk-side input for controlled tests.
Before calling it usable, validate pixel layout, frame cadence, stop/reconnect,
standby, producer ownership/teardown, audio and inference; then build proper
Linux input and synchronized buffering. Never infer production readiness from
the code compiling.

### GPU follow-up, completed in the same session

GPU canvas drawing and color conversion now replace software scaling, while a
native bitmap copy replaces the per-pixel Java conversion for the validated
little-endian layout. Normal release activation remains disabled. The same screen
Surface is used, and no additional XR composition layer was introduced.

The helper follows actual refresh bounded by the app render cap. Measured live
producer rates with a generated 720p60 clip and AI enabled: 60.0 at a 60 fps app
target, 71.6 at 72, and 90.0 at 90. Source non-dropped rates stayed about 59–60/s.
The GPU offscreen probe subsequently passed: 299 deliveries in ten seconds at
30 Hz, zero sampled channel error against a synthetic Xvfb color chart.

Posting jitter remains (p95 approximately 21.4/17.8/16.4 ms at 60/72/90 targets).
The scheduler is deadline-based, not a proven display-vsync-aligned capture or
source-frame fence. Preserve explicit GPU/CPU comparison configuration. Remaining
work is source synchronization, input, sustained real-service tests, A/V sync,
standby/teardown and the production gates already listed. Do not equate producer
posts with unique source video frames or final compositor presentation.

Real Netflix playback follow-up: user confirmed the picture looked good with AI.
An AI-off 25-second window held 72.0 producer posts/s. A subsequent five-minute
AI-on check completed with 31 samples, 71.98 posts/s, seven missed producer slots,
no bridge errors and advancing audio. Final inference was 31.8 ms / 19.9 Hz.
Battery temperature was 41–43 C; final Android thermal status 0. This is encouraging
real-service evidence, not a decoded-fps, lip-sync or production-readiness proof.
Lip-sync/fan feedback remains pending. Next functional work is Linux input routing
and usable navigation while keeping this direct display path.

Direct input is now implemented and installed. The Binder link forwards normalized
pointer positions and Android key events to the helper's input-only RFB client;
no framebuffer data is requested on that connection. A controlled native-entry
point test passed for clicks, dragging, typing, Shift, Insert and normal release.
Physical pointer alignment and standby/focus-loss behavior still need user tests.
Nightfall's own address/bookmark UI still belongs to the normal WebView; this
first step enables interaction with the Linux Chrome screen rather than a fully
integrated Linux navigation/tabs UI. Netflix quality selection remains controlled
by Netflix and is independent of the chosen desktop capture resolution.

## Single compatibility tab and touch-first prototype (2026-11-01)

Decision: retain Android WebView for ordinary tabs. Permit one Linux Chrome
compatibility tab globally, rather than replacing all browsing with Linux.
Nightfall owns its tab identity, address/navigation controls and content surface.
The first content-only iteration keeps the proven Xvfb→GPU Surface video path.

Implemented, **not yet verified on headset** (device disconnected before install):

- Chrome app/kiosk window, no desktop cursor (`Xvfb -nocursor`). Desktop UA and
  existing Chrome profile retained. Lab-only test-type switch suppresses Chrome's
  unsupported-command-line banner; sandboxing remains unresolved.
- Direct touch start/move/end/cancel via CDP with desktop layout. Hover doesn't
  move a Linux mouse; Nightfall's aiming indicator remains independent.
- Coalesced drag moves, bounded/coalesced touch-scroll gestures for PageUp/Down
  controller-scroll input. Keyboard keys still use the verified input-only RFB
  server on5903.
- Cached title/address/history state and native Back/Forward/Reload/Home/address
  navigation. One marked compatibility tab can suspend its Surface while another
  ordinary WebView tab is selected and reattach on return. Closing it releases
  the ownership slot. Browser-engine choice is not persisted across app restarts.
- DEV-only Compatibility browser / Standard browser item, exposed only when the
  separate lab companion is installed. This is not automatic runtime installation
  or a production one-click launcher: the Linux service must already be running.
- Page target identity is retained in app-private storage for reattachment; the
  initial target must be our marked neutral app page, never an arbitrary restored
  account tab. No page scripts, cookies, credentials or media are exported.

Builds and existing browser Java tests passed; the headless screen-tab-strip
regression test also passes, including the expanded dropdown hover/artwork area.
Both APKs must still be installed in place and updated Linux files deployed.
`verify-touch.py --restore-netflix` is prepared to exercise actual native input,
scrolling, full-viewport output and ordinary-tab round trip on a generated page.
**It has not run on the headset yet.** Then test Netflix playback and touch UX.

CDP uses a loopback9222 endpoint for this lab only. Loopback isn't an Android
per-app security boundary; a production version needs private/authenticated
control, resolved Chrome sandbox/packaging/update requirements and lifecycle
policy. Linux privacy/bookmark/blocking integration, popup/download handling,
automatic startup/stop and fresh-install setup remain separate work. Do not
claim WebView's blocking/privacy settings apply inside Linux Chrome.

### Deployment and generated-page validation completed

Headset reconnected. Installed both APKs in place and deployed updated Linux
files. CDP connected to the marked app target. The generated-page native-input
test passed (touch-check-20261101T151104Z): taps, typing/Insert, touch lifecycle,
scrolling, full-viewport output and normal-tab/compatibility-tab round trip.
Native Home, Back, Forward and Reload also passed. Fixed an observed coordinate
issue: LayoutViewport excludes scrollbars; pointer mapping now uses a fixed
numeric innerWidth/innerHeight expression.1919×1079 inner window within1920×1080
source confirms only a one-pixel border remains. Netflix selected for user test.
No claim of successful Netflix playback under touch mode until user confirms.

### User feedback follow-up

Corrected audio lifetime (detaching/closing stops Android audio and best-effort
pauses HTML media), transient control failures (retry instead of permanently
losing input), drag-to-scroll (explicit pixel-wheel scrolling after vertical
threshold) and desktop menus (invisible hover, with true touch taps). Hide Chrome
scrollbars. Stronger generated-page checks now verify independent drag scrolling,
hover-menu selection and active-audio shutdown on closing the last tab, not only
frame delivery. Deployed helper passes these checks; see latest handoff/README.

### Performance investigation: software Chrome vs accelerated presentation

CDP confirms Chrome compositing/rasterization/video decode are software-only;
only final Android Canvas presentation is GPU-backed. Generic Quest Linux HTTPS
throughput measured30–77Mbps, not a Netflix CDN test. A paused movie snapshot
shows540p/31s buffer; no active playback inference can be drawn from its old
cumulative drop counters. User also reopened the obsolete VNC homepage link;
fix that entry and confirm direct mode before evaluating performance again.

Potential next GPU spike (not implemented): prove an isolated rootless Linux GPU
renderer on the actual Quest; evaluate compatible Mesa Turnip/KGSL or an Android
GPU bridge, then verify Chrome reports accelerated compositing/rasterization and
that output still reaches our readable Surface efficiently. Xvfb/window-system
interoperability is part of that proof. Hardware video decoding is separate from
GPU page rendering and cannot be assumed from a working GL/Vulkan test. Preserve
the working Chrome profile and software baseline throughout.

Active direct-path measurement after shortcut correction confirms low rendition
and frame drops:540p→432p,~16% dropped during a16s interval, buffer31→33s.
Software decode/compositing confirmed. Active helper/Chrome CPU allocation is
also restricted to cores0–2. Next performance experiments should separately
measure appropriate Android service binding/scheduling (including child CPU-set
inheritance) and a compatible Linux GPU rendering path. Neither has been changed
yet; do not interpret this as a demonstrated DRM limit or pure bandwidth issue.

### Scheduling change verified; GPU allocation remains unresolved

Activity-aware IMPORTANT/ADJUST_WITH_ACTIVITY binding is implemented and deployed.
Helper and Linux children restarted under it were measured on all6 cores instead
of3. A20s active sample stayed720p/~30fps with zero drops; confirm sustained
quality/scrolling with the user. Headless cold-start child inheritance remains
an integration issue; current experiment restart was explicit under live binding.

Isolated stock EGL probe renders via llvmpipe. A checksum-verified app-private
Mesa KGSL/Turnip candidate was staged separately: native KGSL and Vulkan/Zink
probes both failed allocation. Leave Chrome's software baseline selected. Next
GPU investigation should resolve driver/kernel allocation compatibility before
attempting Chrome compositing or changing its window/output backend. No hardware
video-decoding support was established by these tests.

### Test power budget and context-matched allocation diagnostics

Automatic tests must stop playback/apps and undo forced-worn/Guardian overrides
at the end. Implemented host finally cleanup plus a tokenized on-device watchdog;
local shell tests pass, device validation pending connection. No production
session timeout. Stop leaving Netflix playing after sampling.

Before patching Mesa allocation paths, compare tiny old/new allocation ioctls
inside the actual companion service, directly versus PRoot, with recorded SELinux
domains. Previous shell run-as probes may not match Chrome's service domain.
Static allocation binary and bounded service/runner are built; no headset result
yet. Next device test requires only a few seconds and no video playback.

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

### Next GPU gate: animated GLES correctness (prepared)

The EGL probe now compiles vertex/fragment shaders, draws 120 moving triangles,
and checks both triangle and changing background pixels on every frame. It
reports mismatches, GL errors and elapsed time (not a browser FPS benchmark).
KGSL is now the default; the previously device-lost Zink path requires explicit
`run-egl-compat-probe.py --include-zink`. Rebuild/install the companion first.
Four local watchdog checks pass. Device run is pending USB reconnection; ADB
reported no devices on the first attempt. Chrome flags remain unchanged.

Chromium's Ozone architecture separates compositor surfaces from the window
backend (https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md).
Next isolate a temporary-profile Chrome headless/ANGLE EGL experiment and verify
actual GPU identity and compositing status before changing the production lab
window. If headless acceleration works, measure frame export/presentation cost;
otherwise investigate a compatible X11/Wayland output backend. Surfaceless EGL
success alone does not establish Xvfb acceleration, DMA-BUF sharing, accelerated
video decoding or end-to-end browser acceleration. Do not enable Zink implicitly.

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
