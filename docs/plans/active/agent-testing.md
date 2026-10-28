# Testing without a person in the headset

> Status: Active (2026-10-28). Levels 1, 2 and the depth part of 4 are done
> (`feat/agent-testing`). How to use them: [the guide](../../guides/agent-testing.md).

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
3. **The app on the PC with a simulated headset.** Partly done.
   - Done: `--nf-no-xr` in headless gamescope (`verify.py ui`) covers panels
     and menus.
   - Next: run the Linux build with OpenXR on Monado's simulated HMD (already
     in the XR stack). That adds composition layers and the 3D view, and
     `pose` works for real.
4. **The full pipeline on the PC's GPUs.**
   - Done: `verify.py depth` (jittered replay, depth rate).
   - Next: a PCVR golden test per encoder (NVENC on the 3090, VA-API on the
     RX 480). It wraps `test/smoke_xr_local_application.py` and asserts:
     - `ENCODE_OK` ≥ N;
     - no `CAPTURE_FAILED`;
     - a second XR session recovers;
     - pixels check out with `test/xr_stack_oracle.py`.
     - Not built yet: the other agent is debugging PCVR on the same Monado
       cache, and the runs share `managed-session.lock`.
   - Then: a stream test pattern with a frame counter, for frames dropped and
     latency end to end.
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
