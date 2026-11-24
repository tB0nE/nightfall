# Meteor: one tray menu on every OS

Started 2026-11-21 on `codex/meteor-universal-menu`. Linux is the template;
Windows and macOS follow.

## Why

Each OS had its own hand-written menu (`tray.rs` with ksni, `tray_windows.rs`
with raw Win32, `tray_macos.rs` with NSMenu). Items were added where they were
needed, so names, order and nesting drifted apart, and several items existed
on one OS only.

## Design

- `meteor/src/menu.rs` describes the menu once: `Entry` (Label, Separator,
  Item, Choice, Options, Submenu) and `Action`. `Sources::entries()` builds
  it and `Sources::activate()` carries an action out. A tray only draws the
  entries; `tray.rs` maps them to ksni (Choice/Options to radio groups).
- Sections: Setup…; Meteor (version; status with ports; firewall warning
  when blocked); PCVR (status; PCVR › encoder; XR headset approval when
  pending); Host (pairing PIN when pending; host status with input status;
  Enable virtual input when needed; Start/Stop; Host cursor size ›; Host
  settings ›, or the bundled-host offer); AI 3D (status; Host depth; Depth
  model configuration…); Audio (status with the microphone; Audio plays on
  ›; Mute microphone; Set as default input); Start with my computer; Quit.
- Removed from the menu: Traffic, VR Apps (the headset is where VR apps are
  opened). Moved to Setup: model downloads, Release information & licenses,
  Open log, Open settings file, Open models folder.

### Depth model configuration window

`depth_window.rs`, its own process (`--depth-settings <socket>`) like Setup:
a window toolkit owns its process's main thread, and winit allows one event
loop per process, so it can't live inside Meteor. Model, Rate, Temporal
smoothing, Edge softening (VDA models only), Edge alignment, Contour
cleanup, and a collapsed Advanced section (decoder, VA-API GPU, CPU frame
processing). Changes apply live.

### Control socket

`control.rs`: Meteor's windows reach the running Meteor through a Unix socket
in `$XDG_RUNTIME_DIR` (`nightfall-meteor-<host port>.sock`, mode 0600), never
the network port. One JSON request per connection. Requests: the depth
snapshot, every depth setting, and model downloads (VDA, Vulkan VDA,
remove, cancel), which run in Meteor so its menu sees their progress.

On Windows it's the named pipe `\\.\pipe\nightfall-meteor-<host port>`. Its
DACL is `D:P(A;;GA;;;SY)(A;;GA;;;<user SID>)`: SYSTEM and the user, nothing
inherited. The first instance is made with FILE_FLAG_FIRST_PIPE_INSTANCE, so
no other process can create the name first, and every instance rejects
remote clients. Same one-line JSON. A test reads the DACL back from a live
pipe and checks it has exactly those two entries.

### Audio plays on (Headset / PC / Headset and PC)

The choice is `audio_output` in meteor.toml (default Headset), announced in
the discovery answer (`audio.output`) and `/meteor/host-status`
(`audio_output`). Meteor can't apply it: Moonlight's `localAudioPlayMode`
is in the TLS launch request. Nightfall sends 0 for Headset (the host mutes
the PC) and 1 otherwise, and for PC mutes its own playback
(`AudioRenderer.set_muted`, now bound). While streaming it polls
host-status every 2 s; a change needing the other flag restarts the stream,
PC ↔ both only mutes or unmutes.

## Status

- Linux menu, depth window, control socket, Setup additions, audio choice:
  done. Rust tests (227) and the GDScript suite pass. Checked against an
  isolated Meteor instance (own config/data folders, port 52989): menu
  layout read over D-Bus, audio click saved and announced, depth window and
  Setup screenshots, Quit.
- Android native library rebuilt for `set_muted`.
- Next: headset test of the audio choice.

### Windows (2026-11-21)

- `tray_windows.rs` only draws `sources.entries()`: Item → MF_STRING
  (MF_CHECKED / MF_GRAYED), Choice → popup of radio items
  (CheckMenuRadioItem) plus the grey note, Options → the same inline,
  Submenu → MF_POPUP. Command id N is the Nth action of the open menu; a
  click runs `activate()` on tokio's blocking pool (actions use
  tokio::spawn, and some wait). Balloons, the pairing balloon click and
  double-click to open the log are unchanged.
- Windows slots in the shared sections, all `cfg(windows)`:
  - Meteor: "Windows Firewall is blocking the Quest" + "Allow the Quest
    through the firewall…" (AllowFirewall, the same UAC flow).
  - PCVR › a runtime choice per game (Monado / xrizer, SteamVR), "Enable
    PCVR (restarts Meteor)" when off, "Open PCVR profiles folder". No
    encoder list: the Windows encoder picks NVENC or AMF itself.
  - Host: "Pair a headset by PIN…" (Pair-Headset.ps1) under Start/Stop; Host
    settings › also has "Open the host login (host.toml)" and "Install the
    virtual display driver (administrator)…". Pairing approve/reject use
    PairApprove/PairReject.
  - No "Host cursor size": the Windows host doesn't read the cursor-scale
    file (only Linux capture does).
  - Audio: "microphone: install VB-CABLE" plus "Get VB-CABLE…" when it's
    missing; "Choose CABLE Output in Sound settings…" replaces "Set as
    default input".
  - "Taskbar icon settings…" before Quit.
- Setup and Depth model configuration build on Windows (eframe glow), are
  started without a console, and use Segoe UI. Setup's Windows rows:
  PCVR on/off (the installer prepares it), built-in host, VB-CABLE,
  virtual monitors (driver status, Install with UAC when missing), Windows
  Firewall (status, Allow with UAC when blocked), VDA, Vulkan VDA offers and
  Support. Install All covers PCVR, the host and VDA; Steam launch options
  stay Linux-only.
- Tests: 213 pass on Windows (`cargo test --bin nightfall-meteor
  --no-default-features`), including the pipe's DACL, name squatting and a
  round trip. Linux builds; `proxy::tests::multipath_owner_token_change_
  revokes_old_secondary` fails in the WSL checkout under /mnt/c even without
  these changes, and passes from a clean checkout elsewhere.
- Checked on the desktop (installed build): the drawn menu matches the
  Linux order and wording, and PCVR › lists each game with its runtime
  choice. The pipe's DACL is logged at startup. A depth-rate change sent
  through the pipe applied ("Depth rate: 30 Hz") and was set back. Setup and
  Depth model configuration open and show the live state (their
  screenshot modes). Audio plays on → PC saved `audio_output = "pc"` and is
  announced in discovery and /meteor/host-status.
- Found by that check: Meteor called DisconnectNamedPipe after writing a
  reply, which discards what the client hasn't read, cutting the depth
  snapshot (several KB) short. It now just closes its end; a test sends a
  200 KB answer.
- Still to do with the headset: a stream with each audio choice, and PCVR
  handing over and back.

### macOS (2026-11-21)

- `codex/meteor-universal-menu-macos`: `tray_macos.rs`
  draws the shared menu with NSMenu (Choice: a submenu of ticked options and
  its note; Options: ticked items inline). The menu leaves out what the Mac
  doesn't have: PCVR (no XR runtime; the control connection serves only the
  host background), Host cursor size, and Set as default input. The host's
  input line reports Screen Recording and Accessibility, with "Allow in
  Setup…". The control socket lives in `$TMPDIR` (no XDG_RUNTIME_DIR; a socket
  path must fit 104 bytes). The depth window uses egui's bundled fonts. Setup
  (setup_window_macos.rs) gains the Vulkan model installs and the Support row;
  the app bundle now ships RELEASE.md in Contents/share/doc/nightfall-meteor.
  Checked on an M1: menu read through Accessibility, audio choice clicked,
  saved and announced, depth window and Setup opened from the menu, the
  control socket answers (mode 0600). Rust tests (190 on macOS) pass.
