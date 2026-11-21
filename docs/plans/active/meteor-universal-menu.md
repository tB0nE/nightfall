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
- Next: headset test of the audio choice; then Windows (shared menu drawn
  with Win32, egui Setup window, named pipe) and macOS.
