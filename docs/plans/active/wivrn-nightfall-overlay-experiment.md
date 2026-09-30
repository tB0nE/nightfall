# WiVRn Nightfall overlay experiment

> Status: Active proposal
>
> Date: 2026-09-30
>
> Initial platform: Linux host with Wayland, WiVRn, and a Quest 3
>
> Product decision under test: retain stock WiVRn for PCVR transport and make
> Nightfall a desktop/workspace OpenXR overlay that can replace WayVR.

## Decision summary

The first experiment must not fork WiVRn and must not send a Sunshine stream
through WiVRn. WiVRn continues to own the remote-headset runtime, tracking,
audio, frame timing, encoding, transport, decoding, and headset reprojection.
Nightfall runs on the Linux host as a transparent secondary OpenXR application
and owns desktop capture, screens, interaction, keyboard, workspace UI, and
eventually host-side AI 3D.

The intended steady-state frame path is:

```text
Local monitors ──► PipeWire/DMA-BUF ──► Nightfall screen overlays ─┐
                                                                  │
PC OpenXR application ─────────────────────────────────────────────┤
                                                                  ▼
                                                     WiVRn/Monado compositor
                                                                  │
                                                        one hardware encode
                                                                  │
                                                                  ▼
                                                        stock WiVRn Quest app
```

This replaces the current same-machine path:

```text
desktop ─► Sunshine encode ─► Nightfall decode/render ─► WiVRn encode ─► Quest
```

The experiment succeeds only if it removes that first encode/decode generation
without making WiVRn or the PCVR application less stable.

## Why this is the preferred first step

- WiVRn already solves the difficult remote-XR problems: virtual headset
  runtime, pose transport and prediction, stereo frame capture, hardware
  encoding, network transport, headset decoding, audio, and reprojection.
- Nightfall already has the desired screen interaction, settings, virtual
  keyboard, AI 3D, multi-monitor groundwork, and visual language.
- Monado/WiVRn can compose a primary XR application and an OpenXR overlay before
  the final encode, so monitors do not each require a Quest decoder.
- The approach can be proved without changing the WiVRn protocol or Quest app.
- If it works, the Linux client gains a clear purpose instead of duplicating
  Sunshine inside a streamed XR environment.

References:

- [WiVRn](https://github.com/WiVRn/WiVRn) is the Linux OpenXR streaming runtime.
- [WayVR](https://github.com/wayvr-org/wayvr) is the closest behavioral
  reference for an OpenXR desktop overlay running alongside WiVRn/Monado.
- [`XR_EXTX_overlay`](https://registry.khronos.org/OpenXR/specs/1.1/html/xrspec.html#XR_EXTX_overlay)
  is the provisional OpenXR extension used for secondary overlay sessions.

## Goals

1. Run Nightfall concurrently with a primary OpenXR application under stock
   WiVRn.
2. Show a transparent Nightfall panel over the primary application.
3. Capture one local Wayland monitor through PipeWire without Sunshine.
4. Preserve a GPU-resident path from capture to panel presentation.
5. Interact with the panel without leaking clicks into the XR application.
6. Measure whether the overlay changes application, compositor, encoder, or
   network timing materially.
7. Establish a safe foundation for multiple monitors, a wrist menu, keyboard,
   and host-side EdgePad inference.

## Non-goals for the first experiment

- Forking or rebranding the WiVRn Quest application.
- Supporting Windows, SteamVR overlays, or ALVR.
- Replacing WiVRn discovery, pairing, transport, codecs, or dashboard.
- Shipping a polished Nightfall home environment.
- Supporting X11 capture beyond a basic fallback.
- Implementing multi-monitor, AI 3D, HDR, hand tracking, or the wrist menu
  before the overlay and one-monitor paths are proven.
- Maintaining the normal Sunshine/Moonlight stream at the same time as the
  local overlay experiment.

## Component ownership

| Responsibility | Initial owner |
| --- | --- |
| Quest connection and pairing | WiVRn |
| Quest tracking and controller poses | WiVRn/Monado |
| Primary OpenXR application | WiVRn/Monado runtime |
| PCVR frame timing and prediction | WiVRn |
| XR composition and final video encode | WiVRn/Monado |
| Audio and microphone transport | WiVRn |
| Desktop permission portal | Nightfall |
| PipeWire monitor capture | Nightfall |
| Screen geometry, curvature, placement, and controls | Nightfall |
| Pointer, keyboard, and desktop input injection | Nightfall |
| Wrist menu and workspace state | Nightfall |
| AI depth inference and stereo screen warp | Nightfall host GPU |
| Normal remote desktop/GameStream mode | Existing Nightfall/Sunshine path |

## Existing Nightfall pieces to reuse

The repository already contains more of the required foundation than the
current Linux product path exposes:

- `DBusPortal` handles ScreenCast portal sessions and restore tokens.
- `PipeWireCapture` receives local Wayland frames.
- `DmaBufImporter` is the starting point for GPU-backed frame import.
- `AppSettings.pipewire_restore_token` and `SettingsPersistence` retain portal
  authorization.
- `ScreenManager`, `ScreenLayout`, `ScreenRegistry`, and the composition-layer
  modules own most screen placement and interaction behavior.
- `nightfall-xr` already implements a custom
  `OpenXRExtensionWrapperExtension` and chains data into OpenXR instance and
  session creation.
- The Linux depth engine already runs ZipDepth-384 through ncnn Vulkan.

The old local-capture experiment is not yet the final answer. Its conversion
and presentation path limited a 2560x1440/120 test to roughly 80 FPS. The new
overlay path must instrument every copy and must not claim success merely
because the desktop is visible.

## Required operating modes

Nightfall must retain its current behavior unless overlay mode is requested.
The experiment should introduce an explicit launch mode rather than infer it
from `localhost`:

```text
nightfall                         normal released behavior
nightfall --overlay               transparent WiVRn/Monado overlay
nightfall --overlay-probe         minimal diagnostic panel only
```

An environment variable may be useful for development, but the command-line
mode must be the durable interface. Android must never enter overlay mode.

Overlay-specific state should sit behind a narrow owner such as
`XrOverlaySession` rather than adding more global branches to `main.gd`.

## Phase 0: reproducible baseline

### Work

1. Create `experiment/wivrn-nightfall-overlay` from a clean current `main`.
2. Record WiVRn, Monado, Vulkan driver, desktop environment, kernel, Godot, and
   Nightfall commit versions.
3. Confirm stock WiVRn works with a small native OpenXR application and one
   representative game.
4. Record a 60-second baseline with no overlay:
   - application frame time and delivered FPS;
   - WiVRn compositor frame time;
   - encoder time and bitrate;
   - network latency/loss;
   - headset decode and reprojection statistics;
   - host GPU utilization and VRAM;
   - idle and active CPU utilization.
5. Capture the active OpenXR runtime JSON and launch environment so later
   failures can be separated from Flatpak/Steam runtime visibility problems.

### Exit gate

- The primary application runs repeatably through WiVRn.
- The captured metrics are sufficient to identify a regression after enabling
  an overlay.

## Phase 1: minimal OpenXR overlay probe

This is the decisive technical gate. Do not add monitor capture yet.

### Investigation

1. Confirm the active WiVRn/Monado runtime advertises `XR_EXTX_overlay`.
2. Confirm the custom Godot 4.7 OpenXR headers include the extension structures
   at the version exposed by the runtime.
3. Trace Godot's instance and session creation to determine whether
   `NightfallXrRenderer::_set_session_create_and_get_next_pointer()` can chain
   the overlay session structure without an engine patch.
4. Verify that the runtime supports the transparent environment blend mode
   required by a secondary overlay.

### Prototype

1. Add an overlay-only extension wrapper which:
   - requests `XR_EXTX_overlay`;
   - marks Nightfall's session as an overlay;
   - assigns a documented overlay placement/priority;
   - logs extension availability and the exact chained session configuration;
   - fails clearly instead of silently opening as the primary application.
2. Start with an otherwise empty transparent scene.
3. Submit one small static quad with a distinctive test pattern and build ID.
4. Start Nightfall both before and after the primary XR application.
5. Stop and restart the primary application while Nightfall remains open.
6. Disconnect and reconnect the headset once.

### Measurements

- Primary application continues presenting at its baseline refresh rate.
- WiVRn reports no layer, session, or swapchain errors.
- Transparent pixels reveal the primary application correctly.
- The diagnostic quad remains world-locked and does not jitter relative to its
  chosen reference space.
- Enabling the static panel adds no persistent frame drops and no unexplained
  encoder-resolution change.

### Exit gate

- A stock WiVRn installation displays the Nightfall test panel concurrently
  with a primary OpenXR application for at least ten minutes.
- Start-order, application restart, and headset reconnect tests pass.

### Fallback decision

If Godot cannot create a reliable overlay session without invasive lifecycle
changes, stop modifying application code and compare two alternatives:

1. Extend the pinned Godot OpenXR implementation with a small, reviewable
   overlay-session patch.
2. Build a lightweight native Vulkan/OpenXR overlay shell and render selected
   Nightfall UI surfaces into textures consumed by that shell.

Do not fork WiVRn to work around a Godot session-creation problem.

## Phase 2: one local monitor, correctness first

### Work

1. Reuse `DBusPortal` and `PipeWireCapture` to request exactly one monitor.
2. Persist and restore the portal token through the existing settings store.
3. Present the monitor on one flat Nightfall panel.
4. Disable all AI, ambient, sharpening, stats, keyboard, and extra controls.
5. Show the capture format, modifier, dimensions, refresh rate, and import path
   in logs and a small diagnostic status panel.
6. Preserve the source aspect ratio and map pointer coordinates from panel UV
   space to the selected monitor's logical coordinate space.

### GPU-path audit

For each frame, record whether it uses:

```text
PipeWire SPA buffer
  └─ DMA-BUF fd/modifier
      └─ Vulkan external-memory image
          └─ Nightfall panel sample
```

Any CPU map, color conversion, staging upload, or full-frame copy must be
logged explicitly. A CPU fallback may exist for diagnosis but must never be
reported as the successful zero-copy result.

The implementation must also use explicit synchronization. Importing a DMA-BUF
without respecting its fence/lifetime can produce intermittent corruption even
when a static test appears correct.

### Visual tests

- Small monochrome text at native desktop scaling.
- Thin one-pixel horizontal and vertical lines.
- Fast scrolling text.
- 60 FPS motion video.
- Desktop HDR disabled for the first experiment.
- Panel viewed flat and at several distances.

### Exit gate

- The desktop is visibly sharper than the current Sunshine-through-WiVRn path.
- No additional encode/decode process exists between PipeWire and the WiVRn
  compositor.
- At the baseline refresh rate, the panel does not introduce recurring missed
  frames.
- Capture recovers after monitor permission cancellation, monitor reselection,
  and headset reconnect.

## Phase 3: Nightfall screen behavior

Once capture is correct, connect it to Nightfall's existing screen model.

### Work

1. Adapt `VideoPresentation` so local-overlay textures are a first-class source
   rather than masquerading as a Moonlight stream.
2. Reuse screen placement, grab, resize, curvature, bezel, and recenter logic.
3. Preserve a single authoritative transform for visual geometry and hit
   testing.
4. Keep hidden screen controls out of composition submission rather than
   continuously rendering transparent layers.
5. Confirm whether quad/cylinder composition layers remain cheaper under the
   host compositor than rendering screen geometry into an overlay projection
   layer. Measure both if support differs between runtimes.

### Exit gate

- Flat and curved screens render correctly.
- Grab and resize do not leak clicks to the desktop or game.
- Screen visibility and transforms survive primary-application restarts.
- The overlay introduces no layer-limit or swapchain churn errors.

## Phase 4: input ownership

Input correctness is a release blocker, not polish.

### Required states

| Pointer target | Nightfall behavior | Primary application behavior |
| --- | --- | --- |
| Nothing | Ignore | Receives normal input |
| Desktop screen | Move/click/scroll desktop | Tracking may continue; buttons blocked |
| Nightfall controls | Operate Nightfall | Relevant buttons blocked |
| Wrist menu hidden | No interception | Receives normal input |

### Work

1. Determine which behavior is available through standard OpenXR focus and
   action-set priority.
2. Identify the minimum Monado-specific API needed for button blocking while
   retaining controller poses in the game.
3. Keep runtime-specific calls behind a small adapter; do not spread libmonado
   calls through UI code.
4. Route desktop pointer, wheel, keyboard, and clipboard operations through a
   dedicated Linux input service.
5. Clear all held state when focus changes, a panel hides, the headset sleeps,
   or either process exits.
6. Add logging for target changes and consumed buttons without logging typed
   text or clipboard contents.

### Exit gate

- Repeated clicking and grabbing never fires the same button in the game.
- Returning focus to the game leaves no stuck trigger, grip, key, or mouse
  button.
- Disconnect/reconnect and headset standby clear input state.

## Phase 5: wrist menu and workspace shell

The first wrist menu should remain deliberately small.

### Initial actions

- Show/hide all Nightfall screens.
- Show/hide keyboard.
- Select active monitor.
- Recenter workspace.
- Open the full Nightfall settings panel.
- Show WiVRn/Nightfall status and basic performance information.
- Exit the primary application.

### Behavior

- Attach to the non-primary wrist by default and honor primary-hand settings.
- Use a simple wrist-facing activation rule plus an explicit button fallback.
- Consume input only while visibly interactive.
- Allow detaching and repositioning later, but not in the first test.
- Keep the existing full menu rather than duplicating every setting on the
  watch.

### Exit gate

- The menu can be summoned and dismissed reliably during gameplay.
- It does not remain accidentally active when the hand rotates away.
- Opening it does not cause a primary-application frame-time spike.

## Phase 6: multiple monitors and keyboard

### Work

1. Request multiple PipeWire sources and bind each source to a stable monitor
   identity where the portal/runtime exposes one.
2. Create one `ScreenRegistry` entry per monitor.
3. Reuse existing layouts but allow independent placement and visibility.
4. Render inactive monitors only at the cadence required by their content, if
   PipeWire damage information is available.
5. Route pointer and keyboard focus to the most recently interacted screen.
6. Port the existing virtual keyboard and shortcut row.
7. Add a recovery flow for disconnected, reordered, or newly attached
   monitors.

### Exit gate

- Two monitors work without adding a second Quest video decoder.
- Pointer coordinates remain correct with mixed resolutions and scaling.
- Disconnecting one monitor does not destroy the other screen or overlay
  session.

## Phase 7: host-side AI 3D

AI 3D is intentionally late in the experiment. It must consume the proven
capture texture rather than introducing another readback path.

### Target path

```text
captured monitor image
  ├─► direct panel texture
  └─► Vulkan downscale ─► ncnn EdgePad ─► depth reconstruction
                                      └─► per-eye Nightfall screen warp
```

### Work

1. Start with Linux's existing ZipDepth-384 Vulkan model.
2. Keep inference, depth reconstruction, and stereo warp on the same Vulkan
   device used by the overlay wherever the APIs allow it.
3. Associate every depth result with its source capture sequence/timestamp.
4. Reuse temporal smoothing and separation/convergence defaults from Android,
   but retune only after the raw output is verified.
5. Compare 20, 40, 60, and uncapped depth cadence against PCVR application
   frame time.
6. Make Stream priority the default so monitor depth cannot starve the primary
   XR application.

### Exit gate

- AI 3D produces correct stereo monitor geometry inside the PCVR scene.
- No full-resolution CPU readback occurs.
- The primary application's delivered frame rate remains stable at the chosen
  depth cap.
- Disabling AI 3D releases its compute pressure without recreating the overlay
  session.

## Phase 8: WiVRn lifecycle integration and packaging

Only after the previous gates pass:

1. Add a WiVRn application entry for `Nightfall --overlay`.
2. Support `nightfall --overlay --wait` so Nightfall can start before the
   runtime and attach when WiVRn becomes available.
3. Investigate WiVRn's D-Bus interface for status, primary-application
   lifecycle, and clean disconnect controls; keep a process-level fallback.
4. Hide Nightfall's home environment while another primary XR application is
   active and restore it when none remains.
5. Package overlay mode in the Linux AppImage without changing Android or the
   normal Linux launch default.
6. Add a diagnostics export containing runtime versions, extension support,
   capture/import path, and timing without screen contents or typed input.

## Performance budget

The first measurements should use budgets rather than assuming that visible
output is acceptable.

| Operation | Initial target |
| --- | --- |
| Static overlay CPU cost | below measurement noise at idle |
| Static overlay GPU cost | less than 0.5 ms/frame |
| PipeWire capture-to-sample overhead | less than 1.0 ms excluding source wait |
| Additional full-frame CPU copies | zero |
| Additional video encode/decode generations | zero |
| Primary-app delivered-FPS loss | none at the baseline refresh rate |
| Input target-switch latency | within one displayed frame |

These are experiment targets, not release promises. Record actual values and
revise the budget with evidence.

## Test matrix

### Runtime/application

- WiVRn with a native OpenXR sample.
- WiVRn with one native OpenXR game.
- OpenVR game through xrizer/OpenComposite only after native OpenXR works.
- Nightfall started before and after the primary application.
- Primary application restarted while Nightfall remains running.

### Capture

- Wayland/PipeWire on the current desktop environment.
- One 1920x1080 monitor.
- One 2560x1440 monitor.
- 60, 90, and 120 Hz XR sessions where supported.
- Portal approval, denial, restored token, and source reselection.

### Lifecycle

- Headset standby and resume.
- WiVRn disconnect and reconnect.
- Primary application crash.
- Nightfall crash/restart while the game remains active.
- Monitor hotplug after multi-monitor support exists.

### Interaction

- Controller pointer.
- Hand tracking only after controller interaction is correct.
- Screen grab/resize versus desktop click.
- Wrist-menu focus versus game input.
- Keyboard focus transfer between two screens.

## Observability requirements

Every test build must make these facts visible in logs or a diagnostics panel:

- runtime name/version and active runtime JSON;
- requested and enabled OpenXR extensions;
- overlay-session creation result and placement priority;
- environment blend mode;
- submitted composition-layer count and types;
- PipeWire source dimensions, format, modifier, and cadence;
- DMA-BUF import result and fallback reason;
- number of full-frame copies and CPU mappings;
- capture, import, overlay render, AI inference, and warp timings;
- primary application and overlay session state transitions;
- input target and consumed-button transitions;
- WiVRn-visible compositor/encoder timing where available.

Do not log desktop pixels, typed keys, clipboard contents, or application
window titles by default.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Godot assumes it owns the primary XR session | Prove `XR_EXTX_overlay` in an isolated probe; use a small engine patch or native shell if necessary. |
| WiVRn/Monado overlay behavior changes between versions | Record tested versions and fail with a clear compatibility message. |
| Transparent overlay is flattened incorrectly | Test alpha and ordering before capture; retain a diagnostic checkerboard/alpha mode. |
| DMA-BUF import falls back to CPU silently | Log the exact path and reject fallback in performance acceptance tests. |
| Missing fence synchronization causes intermittent corruption | Carry acquire/release synchronization through the importer and stress moving video. |
| Overlay input leaks into the game | Centralize input ownership and clear held state on every target/lifecycle transition. |
| Godot overlay consumes too much GPU | Measure a static panel first; move submission/rendering into a lightweight native layer if required. |
| Too many OpenXR layers or swapchains | Start with one panel, consolidate decorative controls, and inventory submitted layers. |
| X11 capture is slow or blurry | Treat Wayland/PipeWire as the supported experimental baseline; keep X11 explicitly secondary. |
| AI inference steals game frame time | Keep Stream priority as default and cap inference independently. |
| Runtime-specific code spreads through the app | Put Monado/WiVRn integration behind narrow adapters and typed events. |
| WayVR code reuse creates license obligations | WayVR is GPL-3.0; retain attribution and source obligations for copied or derived code. |

## Stop conditions

Pause and reassess rather than expanding scope if any of these remains true
after the relevant phase:

- The primary application cannot coexist reliably with a Godot overlay.
- One static panel causes persistent missed frames or material compositor cost.
- The desktop path requires a full-frame CPU round trip at target refresh.
- Input cannot be intercepted without breaking tracking in the game.
- Runtime compatibility requires maintaining a broad WiVRn fork before the
  one-panel proof works.

These conditions do not necessarily end the product direction. They choose a
different implementation boundary, most likely a native Vulkan overlay shell
or selective reuse of WayVR's GPL capture/input components.

## Relationship to existing plans

- A successful overlay path supersedes
  [`sunshine-raw-frame-passthrough.md`](sunshine-raw-frame-passthrough.md) for
  same-machine Linux PCVR. Raw Sunshine transport may still be useful for other
  localhost consumers.
- The existing repository-cleanup rendering boundary remains relevant: overlay
  capture must enter through `VideoPresentation`, not through new global state.
- Android remains a standalone Nightfall client and is not modified by this
  experiment.
- A future branded Nightfall/WiVRn Quest client is a separate project decision
  after the host overlay proves valuable.

## Deliverables

Each completed phase should leave:

1. A focused commit or small PR.
2. A reproducible build and launch command.
3. A test log with exact software/hardware versions.
4. Before/after timing measurements.
5. A short decision note: continue, change boundary, or stop.
6. No behavior change to the released Android path.

## First test session checklist

When work begins, the first session should do only this:

1. Create the experiment branch.
2. Confirm the current WiVRn baseline with a native OpenXR sample.
3. Query and record `XR_EXTX_overlay` support.
4. Add the minimum session-chain code required for overlay mode.
5. Display one static transparent test panel.
6. Run it beside the OpenXR sample for ten minutes.
7. Restart the sample and reconnect the headset.
8. Compare frame timing to baseline.
9. Decide whether Godot remains the overlay shell.

Do not begin PipeWire capture until that checklist passes.
