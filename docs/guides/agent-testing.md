# Testing without a person in the headset

These tools let a coding agent, or a script, check most changes without someone
putting on the Quest. Run them with the host's Python, `/usr/bin/python3`: a
containerised `python3` can't see ffmpeg, gamescope or the GPU.

## Which check for which change

| You changed | Run | Needs |
|---|---|---|
| Meteor Rust code, GDScript logic | `tools/verify.py unit` | nothing |
| Host depth: decode, pacing, models (`meteor/src/depth*.rs`, `vda*.rs`, `ncnn.rs`) | `tools/verify.py depth` | NVIDIA GPU, ncnn |
| Menus, welcome, settings, panel placement, anything you'd click | `tools/verify.py ui` | gamescope, GPU |
| Anything that only happens on the Quest (Android, OpenXR, passthrough) | `tools/verify.py quest` | headset on adb, a dev build; **ask the user first** |
| Streaming, decode, depth delivery to the headset | `tools/verify.py stream` | as above, plus a paired host; it connects, samples, then disconnects |
| PCVR runtime, Monado capture, the XR encoders | `tools/verify.py pcvr` | the installed XR runtime; NVIDIA and AMD GPUs |
| Anything in the 3D scene: panel placement, layers, recenter, rooms | `tools/verify.py xr` | the installed XR runtime, gamescope, NVIDIA GPU |
| Frame loss and latency across the whole stream | `tools/verify.py e2e` | headset, a paired host fronted by Meteor; restarts Meteor and draws on the desktop, so **ask first** |

Each run writes `build/verify/<check>-<time>/summary.json`, which has the
check's metrics, failures and artifacts (logs, `ui.json`, screenshots). Read
that file rather than the logs.

What's left for a person: comfort, image quality, tracking feel, and anything
that needs real hands. Write them a short checklist with screenshots from the
checks above.

## The dev bridge (`src/dev_bridge.gd`, `tools/nf.py`)

Dev builds (`build.sh --dev`), debug builds, and any run with
`--nf-dev-bridge` listen on `127.0.0.1:47950` for one JSON request per line.
Release builds don't have it.

```sh
tools/nf.py ui                         # visible controls, by panel, with distance from the head
tools/nf.py press "Display"            # clicks it the way the pointer does
tools/nf.py select "Background" Cinema # picks an option list item
tools/nf.py text "IPInput" 10.0.0.13 --submit
tools/nf.py state                      # streaming, menu and screens, head pose, depth stats
tools/nf.py eval "settings.host.stream_fps"   # any expression, with main.gd as self
tools/nf.py wait "is_streaming" --timeout 20
tools/nf.py shot ui menu.png           # a panel's pixels (ui, welcome, or a name from `ui`)
tools/nf.py log -n 50                  # the session log (release builds don't use logcat)
tools/nf.py pose head --pos 0 1.6 0 --rot 0 90 0   # desktop runs only
```

- **Finding controls:** `press` takes visible text (exact, then partial,
  ignoring case) or a node path. When several match, the error lists their
  paths.
- **Clicking:** `press` refuses disabled buttons, scrolls a hidden row into
  view, and reports `hit: false` when something else would have taken the click.
- **Screenshots:** `shot` draws a panel even while it's hidden or idle.
  Transparent panels come out on a dark backdrop.

## On this PC

`verify.py ui` does this for you. To explore by hand:

```sh
gamescope --backend headless -W 1280 -H 720 -- \
  "$NIGHTFALL_GODOT_EDITOR" --xr-mode off --path . -- --nf-no-xr --nf-dev-bridge &
tools/nf.py ui
```

- **Keep it isolated:** set `XDG_DATA_HOME` to a temporary folder, so the run
  doesn't touch a real Nightfall config.
- **What's missing:** without OpenXR there are no composition layers. Panels
  render, which covers `ui` and `shot`, but the 3D view (`shot root`) is
  mostly empty. Streams, the browser and passthrough need the headset.
- **Native library:** the editor loads the *debug* native library. In a new
  worktree it should be a symlink to the release one, which
  `tools/build_support/build_linux.sh` makes. An old copy shows up as
  "Nonexistent function" errors.

## On the headset (`tools/quest.py`)

```sh
tools/quest.py status              # battery, awake, installed version, running
tools/quest.py awake               # acts as worn, without the Guardian dialog
tools/quest.py install Nightfall-Android-arm64-v8a-dev.apk
tools/quest.py launch --fresh
tools/quest.py forward && tools/nf.py ping
tools/quest.py shot quest.png      # the system's view, via the Quest's capture service
tools/quest.py sleep               # back to normal
```

- **Ask first.** Installing and launching changes what the user, or another
  agent, sees in the headset.
- **When the bridge stops answering, check focus.** The app pauses whenever
  something else is in front, e.g. the Guardian boundary dialog or Settings.
  `quest.py status` names what's in front.
  - `awake` sets `debug.oculus.guardian_pause 0`, which kept Guardian away on
    the user's Quest 3 (2026-10-28).
  - `quest.py launch` brings Nightfall back to the front.
- **Signing:** `install` never uninstalls to get past a signing mismatch,
  because that wipes the user's pairing.

## Depth regression check

`verify.py depth` makes a 72 fps test pattern with ffmpeg, without B-frames,
like a game stream. It replays the pattern through Meteor with
`--jitter-ms 4`, a network's timing, at a requested rate of 72 Hz, using
isolated settings. It fails when fewer than 93% of frames get a depth map.

On 2026-10-28 this reproduced the bug that showed as ~55 fps in the headset.
The old rate cap made 48 Hz of the 72 requested; the RatePace fix made
71.2 Hz.

## Stream check

`verify.py stream` brings Nightfall to the front and presses Connect. It waits
for the stream, then samples the headset's status line three times: resolution,
fps, bitrate, codec, network latency, app fps, and the depth source and rate.

- **Depth from Meteor:** Meteor's maps must arrive at 90% or more of the
  stream's fps, capped by the `max_hz` Meteor advertises.
- **Depth on the headset:** the check notes it, and doesn't test Meteor's depth.
- **Afterwards:** it disconnects only a stream it started.

Meteor's depth needs the headset to find Meteor when it connects, so the host
it streams from must be the one Meteor fronts.

## PCVR check

`verify.py pcvr` runs `test/smoke_xr_local_application.py` once per encoder
(`--encoders nvenc,vaapi`). Each run uses the sample OpenXR app hello_xr,
synthetic tracking, the installed runtime's Monado and the real encoder.

- **Passing:** each encoder must be the one that actually ran, encode 60
  frames or more, and reject none in the capture hook.
- **Bisecting:** `--runtime <version prefix>` runs an older installed runtime,
  from `~/.local/share/nightfall-meteor/xr/versions/`.
- **Not covered:** real games (Proton, quad layers) and a second XR session in
  the same app.

On 2026-10-28 runtime 53d31ca1 passed on both GPUs: NVENC 64 frames, VA-API
62. So that day's VRChat and Moss failures weren't in the basic capture and
encode path.

## The app in a real XR session on this PC

`verify.py xr` runs Nightfall itself under Meteor's XR runtime
(`test/run_xr_app.py`). Monado provides a real OpenXR session, and a synthetic
publisher holds the head and controllers still. The app runs in a headless
gamescope on the 3090, so nothing appears on the desktop.

- **Scripting:** the bridge answers on port 47951. `verify.py ui` uses 47952.
  Neither is 47950, which `quest.py forward` may have pointed at the headset.
- **Seeing the 3D view:** the frames a headset would get are encoded to
  `<session>/monado-stereo.h264`. The check decodes stereo pictures from it,
  both eyes side by side: `view-welcome.png`, `view-menu.png`.
- **What it checks:** the welcome screen, that the menu opens within reach,
  that no frames are rejected, and that the app logs no script errors.

To script your own run, use `XrAppSession` and `nightfall_argv` from
`test/run_xr_app.py`, as `check_xr` does. Head poses come from the
publisher, so the bridge's `pose` has no effect here.

## End to end: a test pattern through the stream

`verify.py e2e` measures the stream with a pattern a script can read:

1. **The pattern:** `test/stream_pattern.gd` draws a small window on the
   streamed monitor, at `--pattern-x/--pattern-y` (default 64,64). Each frame
   it shows two rows of black and white blocks: a frame counter and the time it
   was drawn.
2. **Meteor:** the check restarts the running Meteor with `--dump-video`, as
   `--meteor-binary` (default: this checkout's release build), keeping its
   arguments and environment. The dump writes each frame's arrival time to
   `<video>.frames.tsv`.
3. **The stream:** the headset streams for `--seconds`; meanwhile the check
   samples the headset's status line.
4. **Cleanup:** it disconnects, puts Meteor back as it was, and reads the
   pattern out of Meteor's copy of the stream (`test/analyze_stream_pattern.py`).

It reports:

- **`missing` / `missing_pct`:** counter values that never reached Meteor.
  The host didn't capture or send them.
- **`repeated`:** the same captured frame sent twice.
- **`latency_ms_*`:** from drawing the pattern to the frame reaching Meteor:
  display, capture, encode and send on this PC. The network hop and the
  headset's decode aren't included; the headset's own numbers (network
  latency, app fps) come from the bridge.

The analyzer also works on any recording: `/usr/bin/python3
test/analyze_stream_pattern.py VIDEO --x 64 --y 64 --block 48`.

