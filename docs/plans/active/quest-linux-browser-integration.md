# Quest Linux browser: audio and Nightfall integration

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
