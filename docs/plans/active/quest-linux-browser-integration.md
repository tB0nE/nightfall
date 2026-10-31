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

No multi-view, touch-input backend, hardware decoder or direct-frame transport has
been implemented yet. Their design and tests are the next phase after resuming.
