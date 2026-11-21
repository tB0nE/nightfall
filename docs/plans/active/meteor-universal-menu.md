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
Windows will need a named pipe restricted to the user's SID.

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
- macOS (2026-11-21, `codex/meteor-universal-menu-macos`): `tray_macos.rs`
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
- Next: headset test of the audio choice; then Windows (shared menu drawn
  with Win32, egui Setup window, named pipe).
