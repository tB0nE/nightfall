# Research spike: streaming PC VR to Nightfall

> Superseded 2026-10-18 by [the managed Monado plan](meteor-xr-monado-spike.md).
> ALVR-first material below is historical, not the current architecture.

> Status: Spike started (2026-10-17), branch `feat/meteor-xr-streaming`.
> Phase 1 of [meteor-host.md](meteor-host.md). Start from ALVR, Linux first.
> The exclusive-mode decision below supersedes the earlier desktop/VR
> coexistence scope for this spike; blending is deferred.
>
> Related: [wivrn-nightfall-overlay-experiment.md](wivrn-nightfall-overlay-experiment.md)
> (Nightfall *inside* a WiVRn stream), [nightfall-gateway-experiment.md](nightfall-gateway-experiment.md)
> (the gateway idea Meteor grew out of), [meteor-host-depth.md](meteor-host-depth.md).

## Question

Can Nightfall play PC VR games (SteamVR and OpenXR apps rendered on the PC,
tracked by the headset) the way Virtual Desktop, ALVR or WiVRn do, without
leaving Nightfall? And what part should Meteor play?

Today Nightfall streams a 2D desktop (GameStream) onto a screen in VR. PC VR
streaming is a different loop: the headset sends its pose about 90 times a
second, the PC renders both eyes for that pose, encodes them, and the headset
shows them with reprojection to hide the round trip. Getting that loop right
(pose prediction, frame timing, reprojection, encoder tuning) is most of what
those projects are.

## Agreed first milestone: exclusive XR mode (2026-10-17)

The remote experience visually replaces Nightfall's background, but is a
tracked stereo **projection layer**, not a desktop video on an equirect sphere.
Nightfall remains the Quest OpenXR application. Meteor manages a pinned ALVR
host/driver; the initial XR video transport is ALVR, not GameStream.

Entering XR is an explicit, developer-only action until the manual path works.
Before the XR decoder starts:

1. Reject duplicate entry; release held browser/host/controller input.
2. Disable reconnect and invalidate pending connect/model/source-switch timers
   for this transition without changing saved preferences.
3. Disconnect GameStream and await decoder/audio shutdown, not just its UI
   signal. Close every browser producer and drain its rendering consumers.
4. Stop local inference, Meteor depth delivery and microphone transport. Use
   ALVR's game audio for the spike; microphone support is deferred.
5. Stop native screen presentation and hide/unregister legacy screen, keyboard,
   UI, tooltip, pointer/ray/dot, ambient, backdrop and passthrough layers.
6. Keep Godot's existing OpenXR session and **single** wait/begin/end-frame loop.
   Only the remote projection layer may be submitted while XR is running.

Settings are preserved. Exit, stream loss, host failure or initialization
failure stops the XR consumer first, drains resources, restores welcome with
saved display settings and does **not** reopen a browser or desktop stream.
The Meta system menu must remain available. Reserve a deliberate local exit
gesture before disabling Nightfall's normal controls. Headset removal/pause
must release input and resume safely, or fail back to welcome.

## Implementation sequence and acceptance gates

### A. Reproducible dependency and feasibility probe

- Pin one official ALVR release and immutable source revision for both ends;
  never build client headers against a different server protocol version.
- Cache source/downloads/build output under ignored `.build-cache/meteor-xr/`.
  Record source revision, artifact hashes, toolchain, C API symbols and licences.
- Check local SteamVR, Vulkan/encoder, Android toolchain and device availability
  read-only. Do not replace the active OpenXR runtime or register a SteamVR
  driver silently. Record any baseline setup still requiring user approval.
- Build the Android arm64 **release** client core and generate its matching C
  header. Check ELF architecture, dependencies and required exported symbols.
- Inspect the pinned API, not master: JNI context, lifecycle, decoding, render
  context ownership, swapchain formats, pose/time units and frame reporting.
- Gate: a reproducible client-library build plus a documented integration
  boundary. A built library is not proof of functioning PCVR streaming.

### B. Stock baseline and exclusive-mode controller

- Run stock, matching ALVR with SteamVR Home before judging Nightfall latency.
  Record host GPU/driver, codec, eye resolution, refresh, encoder/decoder/network
  timings, dropped frames and motion-to-photon estimate. Headset testing is
  manual; building artifacts does not satisfy this gate.
- Add an isolated state machine: `idle -> preparing -> connecting -> running
  -> stopping -> idle/failed`. Test cancellation, duplicate entry, delayed
  callbacks, disconnect and repeated enter/exit without real XR hardware.
- Keep entry disabled unless the backend and matching host are usable. Do not
  advertise `pcvr` as available merely because SteamVR is installed.

### C. Tracked projection inside Nightfall

Synthetic precursor implemented on this branch: `NightfallXrProjectionTest`
registers before session startup and renders a tracked stereo floor and spheres
through the existing Godot session. Optimized DEV builds expose a welcome-screen
button, restricted to an idle single-screen workspace. Preparation waits for a
render drain; exit waits for native swapchain retirement before restoring welcome.
Hold B/Y for one second to exit; a 45-second timeout and standby exit are provided.
Lifecycle and preparation-generation tests pass, and the Android native renderer
compiles. The user confirmed the synthetic test succeeds on Quest 3. No ALVR
transport or decoder is connected to the synthetic entry.
Its public predicted-time snapshot is not proof of final streamed-frame timing.

The separate optional ALVR entry now has a core/decoder worker, explicit XR clock
conversion, head tracking, borrowed-buffer GPU fencing and decoded-pose projection.
It builds only with `NIGHTFALL_PCVR_ALVR=ON` on optimized DEV builds. Both enabled
and disabled native configurations compile; lifecycle and metadata checks pass.
The core is packaged under a portable library name, never a build-machine path.
Remote streaming remains unverified: next is explicit matching-host setup/trust,
then first decoded frame, orientation/range, motion, disconnect and repeated exit.
No SteamVR driver or active-runtime registration has been changed. See the
integration audit for current restrictions and upstream decoder failure behavior.

- Add a small ALVR adapter in the native XR extension. Register its projection
  provider during initial OpenXR setup, even though entry is later on demand.
- Godot owns frame timing; the adapter uses the existing predicted display
  time/reference space. Convert ALVR's timestamps explicitly; do not equate its
  nanosecond clock with OpenXR time without checking the pinned implementation.
- Decode directly to GPU-compatible images, render into owned OpenXR eye
  swapchains and submit correct render poses/FOVs for runtime reprojection.
- Start with SDR, fixed resolution/rate, no foveation or custom XR depth, and
  head tracking. Add controller poses/buttons/haptics and audio next.
- Gate: SteamVR Home visible and tracked inside Nightfall, no other submitted
  layers, reliable local exit and failure recovery, followed by one game.

### D. Meteor orchestration and automatic switching

- Add backward-compatible, versioned PCVR capability/state to discovery only
  after C works. Initially keep driver setup explicit and verified.
- Meteor controls the matching host through supported, verified interfaces;
  discovery metadata alone is not authenticated permission to launch software.
- Switch on an active XR application producing usable frames, not simply a
  SteamVR process. Debounce transitions; manual entry/exit always wins.
- Gate: welcome -> exclusive XR -> welcome through Meteor without touching the
  PC. Only then evaluate Windows and user-facing packaging.

### Deferred intentionally

- Desktop/browser overlays, wrist menus, passthrough, ambient and AI 3D in XR.
- Simultaneous GameStream/ALVR decoders and multi-screen XR composition.
- Meteor-native runtime/protocol, direct OpenXR host support and non-SteamVR
  compatibility beyond what the selected ALVR host supports.

## Spike evidence

- 2026-10-17: branch created from `7aa1d48`; no XR streaming implementation
  existed at start. SteamVR installation and Android arm64 Rust target found
  locally. Official latest-release API reports ALVR `v20.14.1`; pinning and
  client-core build are the first experiment. No host driver/runtime settings
  have been changed, and no functioning XR stream is claimed yet.
- Dependency gate completed: pinned Android arm64 release core and generated
  C/C++ interface verified, including layout/export checks and a stripped
  11.2 MB candidate. Pure exclusive-mode policy and regression tests added;
  the full suite passes. Exact hashes, limitations and the EGL-context finding
  are in [the integration audit](../../research/meteor-xr-alvr-integration.md).
  Synthetic projection, stock ALVR headset baseline and live integration are
  still pending. No test APK or driver configuration was deployed in this step.

## What exists (checked 2026-10-09)

| Project | Licence | PC side | Headset side | Reusable from Nightfall? |
| --- | --- | --- | --- | --- |
| [ALVR](https://github.com/alvr-org/ALVR) | MIT | A SteamVR driver (`server_openvr`), Windows and Linux | `client_openxr` app on top of **`alvr_client_core`**, a crate built as a C library (`staticlib`/`cdylib`) with a C API: connect, send tracking/buttons/view parameters, decode, and render the stream with OpenGL ES. Its README: "all major components for an ALVR client except the XR-API-related code" | **Yes**, by design. Nightfall would own the OpenXR session and drive `alvr_client_core` |
| [WiVRn](https://github.com/WiVRn/WiVRn) | GPL-3.0 | An OpenXR runtime built on Monado (BSL-1.0), Linux only | A complete OpenXR app; no library API. "The VR client and PC server need to be on the same version" | Only by porting its client code or reimplementing its protocol; tied to WiVRn's release cadence |
| Virtual Desktop | Proprietary | Streamer app plus SteamVR and VDXR runtimes | Quest app | No; a reference for features only |
| Meteor | GPL-3.0 (ours) | GameStream proxy, NVDEC, Vulkan/ncnn and TensorRT, encrypted side channels, discovery, tray | Nightfall's Meteor client | It's ours, but has no encoder, VR runtime or pose loop yet |

**First conclusion:** the realistic way to get PC VR into Nightfall is to
**embed ALVR's client core**. The SteamVR driver, encoder and protocol are
mature and run on both Windows and Linux, while Nightfall keeps its own app,
OpenXR session and UI. Building our own VR runtime in Meteor is a much larger
project, only worth doing if the embedding route fails.

## Where Meteor fits

ALVR's streamer is a SteamVR driver (`server_openvr`, a library SteamVR
loads, built on the `server_core` crate). ALVR's dashboard installs and
controls it from outside. **Meteor takes the dashboard's place**, so users
never install or see ALVR:

- **Install:** Meteor installs a pinned build of the driver (the version
  matching the Nightfall build's `alvr_client_core`), verified the same way
  it downloads VDA, and registers it with SteamVR.
- **Control:** settings and session control the way ALVR's dashboard does
  it.
- **Discovery:** report in its discovery answer whether VR is available,
  with the version, the same way it reports depth and the microphone
  (`"pcvr": {...}`).
- **Switching:** start SteamVR when the headset asks (the user picks a VR
  game in Nightfall), or notice when it starts.
- **Shared services:** the microphone and the encrypted channel are Meteor's
  already. ALVR has its own microphone and audio, so which one PC VR uses is
  an open question.

Host depth doesn't apply to PC VR: those apps render both eyes themselves.

## Experiments

Each has an exit gate. The spike stops at the first gate that fails, and
writes down why.

### 1. Baseline: stock ALVR

- Install ALVR (streamer and dashboard) on the PC (Linux first, the
  development machine; SteamVR is installed) and ALVR's own Quest app.
- Play SteamVR Home and one demanding game over Wi-Fi and over USB.
- Record ALVR's own statistics: latency, bitrate, encoder and decoder time,
  frame drops.
- **Exit:** a working baseline and numbers to compare against. This is the
  bar Nightfall has to meet.

### 2. `alvr_client_core` in Nightfall (the key experiment)

- Build `alvr_client_core` for Android arm64 at the pinned ALVR version (its
  `cbindgen.toml` generates the C header).
- Link it into the native renderer extension (`extensions/nightfall-xr`)
  behind a developer setting. Its OpenGL ES renderer matches Nightfall's
  GLES renderer on Quest.
- Minimal PC VR mode:
  1. `alvr_initialize` with Nightfall's display capabilities;
  2. on connection, initialize ALVR's decoder, retrieve hardware buffers via
     `alvr_get_frame`, and test importing those in Nightfall's GLES context;
  3. each frame, send tracking (`alvr_send_tracking`, `alvr_send_view_params`)
     from Nightfall's OpenXR poses, and render a projection layer through
     Nightfall's own native provider;
  4. map the Quest controllers to `alvr_send_button`.
- While PC VR mode is active, Nightfall stops rendering its own scene (no
  GameStream screen, no Godot world) and submits only the stream.
- **Exit:** SteamVR Home tracked in the headset from inside Nightfall, with
  latency and stutter close to experiment 1. Measured, not judged by eye.

The main unknown is safe graphics/timing integration. The pinned client core
does not own an OpenXR frame loop; Godot must remain its sole owner. ALVR's
optional wgpu GLES renderer creates its own EGL context, so calling its render
API with Godot-context swapchain IDs is not a proven integration path. Prefer
the decoder-only hardware-buffer bridge first. Pausing Godot's scene rendering
must not pause the session/frame loop. Detailed findings are recorded in
[the integration audit](../../research/meteor-xr-alvr-integration.md).

### 3. Meteor orchestration

- Meteor installs and registers the pinned ALVR driver, replacing ALVR's
  dashboard for setup and settings.
- The discovery answer gains `"pcvr"` (driver installed, SteamVR running,
  version).
- The tray can start and stop SteamVR.
- In the headset, a "PC VR" entry appears when the PC offers it. Choosing it
  enters the experiment 2 mode; leaving returns to welcome without restarting
  desktop or browser content.
- **Exit:** from Nightfall's welcome screen to SteamVR Home and back without
  touching the PC.

### 4. Windows

- The same with ALVR's Windows streamer. ALVR supports it, but Meteor's
  orchestration differs (SteamVR paths, the process model).
- **Exit:** experiment 3's flow works on Windows.

### 5. Written decision

One page in this file:
- whether to productise the ALVR route;
- the version-pairing approach;
- what it costs in APK size (a Rust library of a few MB) and maintenance
  (following ALVR releases);
- whether anything justifies a Meteor-native VR runtime instead.

## Risks

| Risk | Mitigation |
| --- | --- |
| ALVR's optional renderer owns a different EGL context; Godot owns XR timing | Test decoder-only hardware-buffer import and a projection provider on Godot's existing frame loop first |
| ALVR client and streamer versions must match | Pin one ALVR version per Nightfall release; Meteor installs or offers the matching streamer |
| `alvr_client_core`'s API changes between ALVR releases | Pin, and wrap it in one small C++ layer in `nightfall-xr` |
| Two video decoders on the headset (GameStream and ALVR) | Only one runs at a time: PC VR mode stops the GameStream session |
| ALVR's licence and attribution | MIT, compatible with GPL-3; add it to `licences/` and Settings → Licences |

## Not in this spike

- A Meteor-native OpenXR or SteamVR runtime.
- WiVRn protocol support (worth revisiting if WiVRn ever offers a client
  library, or for a Linux-only "compose Nightfall into WiVRn" route; see the
  overlay experiment).
- Host depth for PC VR (not applicable).

## Sources

- ALVR repository and `alvr/client_core` (README, `Cargo.toml`
  `crate-type = ["rlib", "staticlib", "cdylib"]`, `src/c_api.rs`), MIT,
  pushed 2026-10-07: https://github.com/alvr-org/ALVR
- WiVRn repository (GPL-3.0; client and server must be the same version):
  https://github.com/WiVRn/WiVRn
- Monado licence (BSL-1.0): https://gitlab.freedesktop.org/monado/monado/-/blob/main/LICENSE
