# PC VR headsets on Linux (Index, Vive, WMR)

> Status: Proposal (2026-10-25). Candidate for 1.0.0, not a focus. Starts
> after v0.9 (XR streaming and the bundled host) is merged.

## Goal

Run Nightfall on a Linux PC as an OpenXR app for tethered headsets such as
the Valve Index. The user gets the same cinema screen, rooms and AI 3D as on
the Quest. When a VR game starts, Nightfall steps aside, and later it shows
the desktop as an overlay inside the game.

The Quest stays the main product. This plan reuses the Linux build, Meteor and
the Monado work from XR streaming. It also lets us develop and test all of it
on a Quest, with no new hardware.

## How it works

A tethered headset is not a display Nightfall drives. A VR runtime on the PC
(Monado, or SteamVR) owns the headset: it takes over its display and reads its
tracking. Nightfall and VR games are both apps of that runtime.

```text
Linux Nightfall ─┐
                 ├─► Monado ─► Index display (direct mode)
VRChat ──────────┘
```

| Moment | Runtime | Nightfall | Game |
| --- | --- | --- | --- |
| Headset on, no game | Shows Nightfall | Focused: screen, room, AI 3D, input | Not running |
| Game starts | Gives focus to the game | Unfocused: pauses depth, room and video; draws nothing, or an overlay | Focused |
| Game running, user opens the desktop | Composes the overlay over the game | Overlay panel, takes input only while pointed at | Keeps tracking; buttons blocked while Nightfall has them |
| Game exits | Gives focus back | Resumes the full view | Gone |

Monado allows several apps at once and supports overlays (`XR_EXTX_overlay`).
SteamVR runs one main app at a time and does overlays only through its own
OpenVR overlay API. Linux PC VR users are moving to Monado through Envision,
so Monado is the target. SteamVR gets only the full Nightfall view, with no
overlay.

### The Quest as a stand-in headset

Meteor already runs its own Monado for XR streaming
(`meteor/src/xr_session.rs`). Nightfall on the Quest shows Monado's output
and sends tracking back. Monado composes its apps the same way whether the
last step encodes and streams to a Quest or drives an Index's display. The
Linux app can't tell the difference:

```text
Linux Nightfall ─┐
                 ├─► Meteor's Monado ─► encode ─► Quest (display only)
VRChat ──────────┘
```

So this is the test rig: no WiVRn, and no runtime other than our own. It
replaces the WiVRn runtime in
[the WiVRn overlay experiment](wivrn-nightfall-overlay-experiment.md). That
plan's overlay, capture, input, wrist menu and AI 3D phases still apply, and
this plan points to them rather than repeating them.

What the rig can't test: Monado driving the headset's display directly,
base-station tracking, and the Index's 120/144 Hz. Those are Monado's job.
Phase 7 checks them on real hardware.

## Who does what

| Job | Owner |
| --- | --- |
| Headset display, tracking, timing | The runtime (Monado; Meteor's Monado on the rig) |
| Starting the runtime and apps (rig) | Meteor |
| Starting the runtime (real headset) | The user, through Envision |
| Desktop video and input | Bundled Vibepollo (source A), then Nightfall's own capture (source B) |
| Screen, room, AI 3D, menus | Linux Nightfall |
| Showing frames and sending tracking (rig) | Nightfall on the Quest, display-only |

## Desktop video sources

Nightfall on the PC needs the desktop picture. Build these in order, and stop
once one is good enough.

| Source | How | New work | Cost |
| --- | --- | --- | --- |
| A. Localhost stream | Normal Moonlight session to the bundled Vibepollo on `localhost` | None | One encode and one decode on the same GPU as the game |
| B. Nightfall's own capture | PipeWire ScreenCast portal into `PipeWireCapture` and `DmaBufImporter` (both already in `addons/nightfall-stream`) | Revive and finish the zero-copy path | No encode; the frame stays on the GPU |
| C. Vibepollo hands over GPU buffers | The fork sends DMA-BUF handles over a Unix socket ([raw frame plan](sunshine-raw-frame-passthrough.md), redone for the same machine) | Fork change plus the import code | As B, and covers NvFBC on X11 |

B is the target. It's the path the WiVRn plan already chose, and most of the
code exists. C is only worth building if B can't cover a case users care
about, mainly NVIDIA on X11.

**Input with source B.** Use the XDG RemoteDesktop portal. It hands out a
screen-cast stream and pointer and keyboard injection in one approved session,
with no root and no uinput. `DBusPortal` would open a RemoteDesktop session in
place of the plain ScreenCast session. With source A, input already goes
through the Moonlight session to Vibepollo.

## Nightfall's modes on the PC

| Mode | Started by | Shows |
| --- | --- | --- |
| Home | `nightfall` | Full Nightfall as the focused app: screen, rooms, AI 3D, menus |
| Overlay | `nightfall --overlay` | Only desktop panels and the wrist menu, over another app |

The release build keeps its current behaviour unless a mode is asked for.
Android never enters overlay mode. Overlay state sits behind one owner (for
example `XrOverlaySession`), not in branches through `main.gd`, as the WiVRn
plan says.

## Phases

### Phase 0: prerequisites

- v0.9 merged: XR streaming and the bundled host.
- Check Meteor's Monado build (the capture build under
  `monado-linux-spike/capture-build`): it must allow several apps at once and
  expose `XR_EXTX_overlay`. Write down any build options that had to change.
- Record the versions in use: Monado, Godot, Vulkan driver, desktop
  environment.

**Gate:** a small OpenXR sample and a game run at the same time under Meteor's
Monado, shown on the Quest.

### Phase 1: the Quest as a plain headset

Work on the XR branch's Quest side and in Meteor.

- **Display-only switch on the Quest:** show Monado's frames and send tracking
  and controller input, nothing else. No wristwatch, no workspace handover, no
  Nightfall menus on top. Useful on its own: "use your Quest as a plain PC VR
  headset" for any OpenXR app.
- **Meteor launches any OpenXR app into its Monado,** not just Steam games.
  It sets `XR_RUNTIME_JSON` for the app and lists it in the tray.
- **Meteor starts Monado without a game,** waiting for apps.

**Gate:** with display-only on, an OpenXR sample started from Meteor shows on
the Quest. The Quest app draws nothing of its own on top.

### Phase 2: Linux Nightfall in Home mode

- Export `NightfallLinux` with OpenXR on, and run it under Meteor's Monado.
- Turn off the Android-only paths on Linux: passthrough, the Android depth
  models, the Java browser and SAF import. Each must fail quietly, not crash.
- Connect to the bundled Vibepollo on `localhost` (source A). Check that
  pairing with yourself works, and that USB Link and the Meteor proxy don't
  get in the way.
- AI 3D through the existing Linux ncnn Vulkan model (ZipDepth-384).
- Rooms: the cinema and Your Room. On the PC the room renders at full
  resolution, and `ROOM_RENDER_SCALE` becomes a per-platform setting.
- Measure: delivered frame rate, GPU time for decode, depth and room, and
  latency compared with the Quest app.

**Gate:** 30 minutes of desktop and video use on the rig with no dropped
session. Frame rate stays at the headset's rate with AI 3D on.

### Phase 3: sharing the headset with a game

- Handle OpenXR session states. When focus moves to `VISIBLE` or lower, pause
  depth, the room and video decode, and stop drawing. Resume on `FOCUSED`.
  Clear all held input on every change.
- Close or keep the stream: keep the Moonlight session alive but stop
  decoding (source A), or pause capture (source B). That way returning to
  Nightfall is instant.
- Start order: Nightfall first, then the game; the game first, then
  Nightfall; game restarts; a game crash; a Nightfall crash while the game
  runs.

**Gate:** a game launched over Nightfall runs at its normal frame rate (within
2% of running alone). Nightfall comes back intact when the game exits.

### Phase 4: overlay mode

Follow the WiVRn plan, Phase 1 (minimal overlay probe), Phase 3 (screens) and
Phase 4 (input ownership), against Meteor's Monado instead of WiVRn.

- The overlay session is chained in `nightfall-xr`'s
  `OpenXRExtensionWrapperExtension`, through
  `_set_session_create_and_get_next_pointer()`. If Godot can't create an
  overlay session cleanly, use the fallbacks in the WiVRn plan (a small Godot
  patch, or a native overlay shell). Never fork Monado to work around it.
- The wrist menu (WiVRn plan, Phase 5) reuses the XR branch's wristwatch.

**Gate:** the WiVRn plan's Phase 1 and Phase 4 gates, on the rig.

### Phase 5: direct desktop capture (source B)

The WiVRn plan's Phase 2, plus:

- A RemoteDesktop portal session for capture and input together.
- Fall back to source A when the portal is missing or the user declines it.
- Keep the GPU-path audit: log every copy and CPU mapping, and never report a
  CPU fallback as the zero-copy result.

**Gate:** the WiVRn plan's Phase 2 gate. In Home mode, the desktop is sharper
and uses less GPU than source A.

### Phase 6: AI 3D and multiple monitors in overlay mode

The WiVRn plan's Phases 6 and 7, unchanged. Stream priority stays the
default, so monitor depth never starves the game.

### Phase 7: real hardware

- Borrow or buy one tethered headset. Rough used prices, to check locally:
  - Windows Mixed Reality (Reverb G2, Odyssey+, Explorer): cheapest, under
    about $100. Monado supports the inside-out tracking; controllers are less
    mature.
  - Original HTC Vive with base stations: about $150–250. It uses the same
    tracking as the Index, so it's the best stand-in.
  - Valve Index: only if Index users become a real audience.
- Set it up the way users do: Envision, Monado with Valve's base-station
  driver (`steamvr_lh`) or libsurvive, and xrizer for SteamVR games.
- Repeat the Phase 2–4 gates on it.
- SteamVR: check Home mode only, and document that there is no overlay there.

**Gate:** Home mode and overlay mode with one OpenXR game and one SteamVR game
through xrizer.

### Phase 8: packaging and docs

- Ship the Linux build: as part of the Meteor AppImage, or as its own AppImage
  that Meteor finds. Decide when Phase 2 shows its size.
- Meteor tray: "Open Nightfall in VR" (Home mode) and "Show desktop in VR
  games" (overlay mode on or off).
- A short "PC VR headsets on Linux" guide: Envision setup, starting Nightfall,
  overlay mode, what works under SteamVR.
- Diagnostics export: runtime, extensions, session states, video source, copy
  counts.

## Release decision for 1.0.0

Include it if Phases 1–4 pass on the rig and Phase 7 passes on at least one
real tethered headset. Phases 5 and 6 can follow in a later release: Home mode
with source A is already useful.

If it isn't ready, the display-only Quest switch (Phase 1) can still ship on
its own.

## Not in this plan

- Windows. Tethered headsets there use SteamVR, where Nightfall would need
  OpenVR overlays.
- SteamVR overlays through OpenVR.
- Our own tracking drivers, or any change to Monado's headset support.
- WiVRn or ALVR support. Users can run them; we don't test against them.

## Risks

| Risk | Mitigation |
| --- | --- |
| Godot can't create an overlay session | Fallbacks from the WiVRn plan; Home mode still ships |
| Meteor's capture build of Monado lacks multi-app or overlay support | Phase 0 check; change build options, not Monado's code |
| GPU contention: the game, Monado, the stream and depth on one GPU | Pause everything on lost focus; Stream priority; source B removes the encode |
| Input leaks between Nightfall and the game | WiVRn plan's Phase 4 rules; clear held input on every focus change |
| Two Nightfalls on the rig confuse testing | Display-only switch; log which side handled each input |
| Linux desktop variety (portals, KDE vs GNOME, NVIDIA on X11) | Source A as the fallback; source C only if X11 users ask |
| Small audience | Keep it behind the release decision; the Quest stays the focus |

## Open questions

- Should the display-only Quest mode be a user-facing feature in v0.9.x,
  ahead of the rest?
- Does Meteor's Monado also become the runtime Index users run, or do they
  keep Envision's Monado with Nightfall only as an app? Envision is the
  likely answer, which keeps Meteor out of the headset's way.
- Is the Linux build's size acceptable inside the Meteor AppImage?
