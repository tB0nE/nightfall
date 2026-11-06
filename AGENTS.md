# Notes for coding agents

## Testing: check it yourself before asking the user

Most changes can be checked without a person in the headset. Read
[docs/guides/agent-testing.md](docs/guides/agent-testing.md) first. Run the
tools with the host's `/usr/bin/python3`: a containerised `python3` can't see
ffmpeg, gamescope or the GPU.

`tools/verify.py <check>` writes `build/verify/<check>-<time>/summary.json`.
Read that summary rather than the logs.

| Check | Covers | Needs |
|---|---|---|
| `unit` | Meteor's Rust tests, the GDScript suite | nothing |
| `ui` | menus, welcome, settings: the app on this PC, driven and screenshotted | gamescope, GPU |
| `xr` | the 3D scene: the app in a real OpenXR session, with a picture of each eye | Meteor's XR runtime, NVIDIA |
| `depth` | Meteor host depth keeps up with a jittery 72 fps stream | NVIDIA, ncnn |
| `pcvr` | PCVR capture and encode, NVENC and VA-API | Meteor's XR runtime |
| `quest` | the app on the headset: UI tree, state, screenshots | headset |
| `stream` | a stream to the headset: fps, latency, depth source and rate | headset, paired host |
| `e2e` | frames lost and latency through host → Meteor, with a test pattern | headset; restarts Meteor, draws on the desktop |

Routine builds, in-place headset updates, app launches, Meteor restarts and
testing within the active development task are authorized without asking again.
Explain disruptive actions before running them and coordinate with any other
agent using the same headset or service. Preserve app data and pairings.

Other tools:

- **`tools/nf.py`** drives a running dev build through its bridge
  (`src/dev_bridge.gd`): `ui`, `press`, `select`, `text`, `state`, `eval`,
  `wait`, `shot`, `log`. Dev and debug builds only.
- **`tools/quest.py`** runs the headset from the desk: `status`, `awake`,
  `install`, `launch`, `forward`, `shot`, `logcat`. Use in-place updates;
  never uninstall.
- **`test/run_xr_app.py`** runs any OpenXR app under Meteor's XR runtime,
  with no headset.

Gotchas:

- **Bridge ports:** port 47950 may be forwarded to the headset. Runs on this
  PC use 47951 and 47952.
- **XR in Godot runs:** Godot hangs without `--xr-mode off` unless an OpenXR
  runtime is present.
- **When the headset stops answering:** the app pauses whenever something
  else is in front of it (the Guardian dialog, lost tracking, Settings).
  `quest.py status` names what's in front.
- **What's left for the user:** comfort, image quality and tracking feel.
  Send them a short checklist with screenshots from the checks.

## Docs

Documentation lives in [docs/](docs/README.md). Proposed or ongoing work goes
in `docs/plans/active/`; build steps are in [BUILD.md](BUILD.md).
