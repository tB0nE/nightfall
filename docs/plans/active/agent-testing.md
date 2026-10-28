# Testing without a person in the headset

> Status: Active (2026-10-28). Levels 1 and 2 are done; level 4 has the depth,
> headset stream and basic PCVR checks (`feat/agent-testing`). How to use them:
> [the guide](../../guides/agent-testing.md).

## Why

Most checks needed the user in the headset. On 2026-10-28 two regressions were
found that way:

- depth ran at ~55 of 72 fps;
- PCVR failed on NVIDIA.

Both are numbers a script can read. The goal is a ladder of test levels, each
letting an agent check more on its own, so the person checks only what needs a
person.

## Levels

1. **The headset without wearing it:** `tools/quest.py`. Done.
   - Covers status, the proximity override, install with retries (never an
     uninstall), launch, port forwarding, system screenshots and logcat.
2. **Dev bridge:** `src/dev_bridge.gd` and `tools/nf.py`. Done.
   - Commands: `ui`, `press`, `select`, `set_text`, `state`, `eval`, `wait`,
     `pose`, `screenshot`, `log`.
   - Covered by `test/test_dev_bridge.gd`.
3. **The app on the PC with a simulated headset.** Done.
   - `--nf-no-xr` in headless gamescope (`verify.py ui`) covers panels and
     menus.
   - `verify.py xr` runs the app in a real OpenXR session under Meteor's
     runtime, with synthetic tracking (`test/run_xr_app.py`). It covers
     composition layers and the encoded 3D view per eye.
   - Next: let the publisher take scripted poses, so tests can turn the head.
4. **The full pipeline on the PC's GPUs.**
   - Done:
     - `verify.py depth` (jittered replay, depth rate).
     - `verify.py stream`: the headset streams and reports fps, latency and
       depth.
     - `verify.py pcvr`: hello_xr per encoder, against any installed runtime.
   - Next for PCVR:
     - A second XR session in the same app (where Moss failed).
     - Quad and cylinder layers through `smoke_xr_layer_compatibility.py`. It
       needs a development runtime build.
     - Pixels checked with `test/xr_stack_oracle.py`.
   - Done: `verify.py e2e`. A pattern with a frame counter and draw time
     goes through the host and Meteor, giving frames lost, repeats, and
     latency from drawing to Meteor.
   - Next: latency all the way to the headset's display. That needs the
     headset to read the pattern back, or a camera.
5. **Windows and downloads.**
   - A Windows install smoke in the existing `windows-2022` workflow: silent
     install, `--no-tray --no-depth`, probe `/meteor`, uninstall.
   - Download tests against a local fake release server: resume, wrong
     SHA-256, an HTTP error, rollback.
   - A weekly check that the pinned URLs still resolve.

## Decisions

- **The bridge is in dev and debug builds only** (`nightfall_dev`,
  `OS.is_debug_build()` or `--nf-dev-bridge`). It binds to `127.0.0.1` and is
  reached with `adb forward`. `eval` runs any expression, which is acceptable
  for a dev build on the user's own headset.
- **No self-hosted GitHub runner on this public repo:** a pull request would
  run code on the user's PC. GPU checks run locally through `verify.py`.
- **`verify.py` writes one `summary.json` per check**, so an agent reads a few
  lines rather than the logs.
