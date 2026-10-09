# Nightfall Meteor as a host

> Status: Active proposal (2026-10-09). The general direction for when this
> work starts; each phase gets its own detailed plan before it begins.
>
> Builds on: [meteor-host-depth.md](meteor-host-depth.md),
> [meteor-microphone.md](meteor-microphone.md), [meteor-appimage.md](meteor-appimage.md),
> [meteor-xr-streaming-spike.md](meteor-xr-streaming-spike.md),
> [meteor-amd-intel.md](meteor-amd-intel.md).

## Goal

Feature parity with Virtual Desktop. Nightfall already matches it on the
headset; the two big gaps are on the host:

1. **Multiple monitors, including virtual ones.** The client already shows
   several screens. Hosts can't feed them: only an uncommitted Polaris
   experiment exists (Linux, every monitor tiled into one frame;
   [docs/integrations/polaris/multi-monitor-server.md](../../integrations/polaris/multi-monitor-server.md)).
   Virtual monitors matter most in VR: a PC with a 60 Hz 1080p monitor should
   still stream a 3840x2160 desktop at 120 Hz.
2. **XR streaming.** Playing SteamVR and OpenXR games from the PC, switching
   automatically between desktop streaming and VR.

## Decisions (2026-10-09)

- **Meteor grows into a full host, one feature at a time.** No PRs to each
  Sunshine fork: Nightfall leads with its own host.
- **The host speaks GameStream**, so it stays compatible both ways:
  - Nightfall still works with plain Sunshine, Apollo, Polaris and
    Vibepollo hosts (Meteor optional);
  - other Moonlight clients can use Meteor as a host.
- **Linux first.** Windows already has options (Apollo, Vibepollo,
  Virtual Desktop); revisit later, if at all.
- **XR starts from ALVR** (MIT); our own implementation can replace parts
  later.
- **Two streams, not one**, when the desktop is shown during VR (2026-10-09
  discussion): the desktop stays a separate stream shown as its own
  compositor layer, so it stays sharp. Decode cost is pixels per second, so
  two streams cost no more than one combined frame, and the desktop stream
  can run at its own rate or pause when hidden.
- **Sunshine stays supported.** Meteor's proxy mode remains for anyone who
  prefers their existing host.

## Why build our own host

- The features that matter here are Nightfall-specific (virtual monitors per
  headset session, XR switching, depth, the microphone, encrypted side
  channels), so upstream PRs to four hosts would mostly stay ours to carry.
- Meteor already understands much of GameStream as a proxy: it parses and
  rewrites RTSP, relays the control, video and audio flows, and reassembles
  video frames from RTP. Nightfall has the client half (moonlight-common-c).
  Sunshine's server code is GPL-3, compatible with Meteor, as a reference.
- Owning capture gives host depth the original frames. Today Meteor decodes
  the stream it forwards; a host could run depth on the captured image before
  encoding, with exact frame identity and no extra decode.
- On Linux, the hard Windows problems (signed virtual-display and
  virtual-gamepad drivers) don't exist: uinput and compositor virtual outputs
  need no drivers.

## Architecture (end state, Linux)

```text
                     ┌──────────────── Nightfall Meteor (host) ───────────────┐
Virtual/real ──► PipeWire capture ──► (depth on the captured frame) ──► NVENC/VAAPI ──► GameStream
monitors           one session per monitor                                  │      sessions ──► Nightfall
                                                                             │      (or any Moonlight client)
SteamVR + ALVR driver (installed and controlled by Meteor) ─────────────────┼──► ALVR stream ──► Nightfall
                                                                             │      (alvr_client_core)
Audio (PipeWire) · input (uinput: mouse, keyboard, gamepads) · microphone ──┘
Proxy mode for existing Sunshine-family hosts stays available.
```

## Phases

Each phase is useful on its own; stopping after any of them leaves a working
product.

### Phase 1: XR streaming with ALVR

Details and exit gates: [meteor-xr-streaming-spike.md](meteor-xr-streaming-spike.md).

- **Headset:** Nightfall embeds `alvr_client_core` (Rust, C API) in
  `nightfall-xr`. While a VR session runs, it renders ALVR's stream as the
  projection layer.
- **PC:** ALVR's streamer is a SteamVR driver (`server_openvr`, built on the
  `server_core` library) that SteamVR loads. Meteor installs a pinned build
  of it, registers it with SteamVR, and controls it as ALVR's dashboard does,
  so users never install or see ALVR separately. The client and driver
  versions are pinned together per Nightfall release.
- **Switching:**
  - desktop streaming by default;
  - VR when SteamVR starts, whether the user starts a VR game from Nightfall
    or Meteor sees SteamVR start;
  - back to the desktop when SteamVR exits.

  The desktop session stays open in the background, and can be shown over
  the VR view as its own layer (the two-streams decision).
- Independent of the host phases below: it works alongside Sunshine too.

### Phase 2: virtual monitors on Linux (spike)

Prove that a virtual output at any resolution and refresh rate can be
created on demand and captured through PipeWire, on the desktops people use:

| Route | Where | Notes |
| --- | --- | --- |
| KWin virtual outputs | KDE Plasma 6 (Bazzite, the development machine) | Plasma's screen-cast virtual outputs, as used by its virtual-monitor feature: a real extra monitor windows can be moved to |
| Mutter virtual monitors | GNOME | The screen-cast API's virtual-monitor recording, as GNOME Remote Desktop uses |
| gamescope headless | Games, any desktop | Valve's compositor runs a game at any size and rate and exposes it through PipeWire; for "play at 4K120" rather than a desktop |
| Headless wlroots compositor | Fallback | What the Polaris experiment used: reliable, but a separate private desktop |

- **Exit:** on KDE, a 3840x2160 120 Hz virtual output created and removed by
  Meteor, captured at 120 fps, with windows movable onto it. GNOME and
  gamescope next.

### Phase 3: Meteor serves extra monitors

- Meteor becomes a GameStream host **for additional monitors only**. Each
  monitor (real or virtual) is listed as its own app ("Monitor 2",
  "Monitor 3"), with its own session, resolution, rate and stream. Sunshine
  still handles the primary display, audio, gamepads and app launching.
- **Pieces:**
  - **The GameStream server side:** pairing (certificates and PIN), the
    HTTPS endpoints (`serverinfo`, `applist`, `launch`, `resume`, `cancel`),
    RTSP, the ENet control stream, RTP video with FEC, and encryption;
  - PipeWire capture;
  - encoding: NVENC first, VAAPI next (the reverse of meteor-amd-intel.md's
    decode split);
  - mouse and keyboard input for those monitors through uinput, with
    absolute positions mapped into the shared desktop.
- **Nightfall:** opens one session per monitor, and decodes only the
  monitors in view (see
  [docs/architecture/multi-monitor-encode-budget-and-layout.md](../../architecture/multi-monitor-encode-budget-and-layout.md)
  for the decoder budget).
- Several sessions at once is a difference from Sunshine (one session per
  host). Any Moonlight client can still open "Monitor 2" on its own.
- **Exit:** two extra virtual monitors beside a Sunshine primary, each at its
  own resolution, with input working on all three.

### Phase 4: Meteor as the full host (Linux)

- **Adds:** the primary display, audio capture (PipeWire), gamepads (uinput
  with rumble), app launching (including Steam and gamescope sessions), and
  the pairing UI in the tray instead of a web interface.
- Host depth moves before the encoder: EdgePad or VDA on the captured frame,
  tagged with the frame number it will be encoded as. The decode tap becomes
  proxy-mode only.
- Sunshine becomes optional; proxy mode stays.
- **Exit:** Nightfall and stock Moonlight both stream a game from a PC
  running only Meteor, with audio, gamepads and input, at the latency and
  quality of Sunshine on the same PC.

### Later

- **Windows:** the signed driver problem (virtual displays need an IddCx
  driver like Apollo's SudoVDA; gamepads need ViGEmBus or a replacement)
  decides whether it's worth it.
- **Our own XR implementation:** replacing ALVR's driver or client core
  piece by piece, if pinning ALVR becomes limiting.
- **AMD and Intel:** decode for host depth is planned in
  [meteor-amd-intel.md](meteor-amd-intel.md); encoding (VAAPI) arrives with
  Phase 3.

## Compatibility promises

- Nightfall without Meteor keeps working with every Sunshine-family host.
- Meteor in proxy mode keeps working with every Sunshine-family host.
- Meteor as a host works with stock Moonlight clients, with features
  Nightfall-only where GameStream has no equivalent: XR, depth, the
  microphone, and several monitors at once.
- One protocol version field (discovery's `protocol`) tells Nightfall which
  Meteor features exist.

## Risks

| Risk | Mitigation |
| --- | --- |
| GameStream server is a large surface (pairing, RTSP, ENet, FEC, encryption) | Sunshine's GPL-3 code as reference; Meteor's proxy already parses most of it; Phase 3 needs only a subset (no audio, no gamepads) |
| Virtual-output APIs differ per desktop and change between releases | Phase 2 spike before committing; start with KDE; gamescope as the desktop-independent route for games |
| ALVR driver/client version lock | Pin per Nightfall release; Meteor installs the matching driver |
| Latency or quality worse than Sunshine | Each phase's exit compares against Sunshine on the same PC |
| Scope creep: a host is a large maintenance commitment | Phases are independent; stop at any phase that doesn't pay off |

## Open questions

- Does Phase 3 need audio per monitor session, or does the primary session's
  audio cover it (one audio stream per host)?
- Which routes does Phase 2 support from the start: KDE only, or KDE and
  GNOME?
- Is a web UI needed at all, or are the tray and the headset enough
  (pairing, app list, settings)?
- How should a VR session interact with virtual monitors (keep them alive,
  or tear them down while in VR)?
