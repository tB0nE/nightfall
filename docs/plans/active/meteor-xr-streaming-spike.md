# Research spike: streaming PC VR to Nightfall

> Status: Active proposal (2026-10-09). Phase 1 of [meteor-host.md](meteor-host.md),
> which records the decisions: start from ALVR, two streams for the desktop
> during VR, Linux first.
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
  2. on connection, `alvr_start_stream_opengl` into Nightfall's OpenXR
     swapchains;
  3. each frame, send tracking (`alvr_send_tracking`, `alvr_send_view_params`)
     from Nightfall's OpenXR poses, and render with
     `alvr_render_stream_opengl`;
  4. map the Quest controllers to `alvr_send_button`.
- While PC VR mode is active, Nightfall stops rendering its own scene (no
  GameStream screen, no Godot world) and submits only the stream.
- **Exit:** SteamVR Home tracked in the headset from inside Nightfall, with
  latency and stutter close to experiment 1. Measured, not judged by eye.

The main unknown is the OpenXR session. Nightfall's session belongs to Godot
plus `nightfall-xr`, and ALVR expects to own frame timing (when to render,
what predicted display time to use). Experiment 2 has to show the two can
share one session cleanly. The fallback is a dedicated mode where
`nightfall-xr` hands frame timing to ALVR and Godot pauses rendering.

### 3. Meteor orchestration

- Meteor installs and registers the pinned ALVR driver, replacing ALVR's
  dashboard for setup and settings.
- The discovery answer gains `"pcvr"` (driver installed, SteamVR running,
  version).
- The tray can start and stop SteamVR.
- In the headset, a "PC VR" entry appears when the PC offers it. Choosing it
  enters the experiment 2 mode; leaving returns to desktop streaming.
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
| ALVR's client core assumes it owns the OpenXR frame loop, conflicting with Godot | Experiment 2 tests this first; the fallback is a dedicated mode with Godot paused |
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
