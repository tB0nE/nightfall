# Meteor-managed XR development sessions

This is the first Rust lifecycle adapter in Meteor, not a shipped XR service.
It owns the existing validated Linux/NVIDIA USB test workflow behind one command:

```bash
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  meteor/target/release/nightfall-meteor --xr-dev "$PWD"
```

Use `--smoke` after the checkout argument for the synthetic host integration
run instead of a headset connection. No APK rebuild is required. Prerequisites
are still the pinned Monado build, isolated fixed Godot executable and upstream
demo checkout described in meteor-xr-godot-engine.md. Missing dependencies fail
with a path; they are not downloaded or installed automatically.

## Ownership and behavior

- Development-only CLI dispatch occurs before normal Meteor proxy/depth/mic/tray
  initialization. Ordinary Meteor startup is unchanged.
- An advisory descriptor lock prevents two managed sessions for this checkout.
- The supervisor pins a known test profile, discards inherited diagnostic profile
  variables, and launches the adapter in its own Unix process group.
- Runtime selection remains private to the adapter's app environment. No system
  runtime registration, SteamVR setup or existing runtime service is touched.
- Console and private `.build-cache/meteor-xr/managed-session/status.json` expose
  starting, waiting, streaming, completed/interrupted/failed/cancelled states.
  `streaming` means fresh encoded-frame metadata exists, not proof of headset
  display. Detailed output is in the same directory's `session.log`.
- A successful child exit alone cannot produce completed: fresh current-run
  normal validation must prove the engine shutdown and encoder drain, with app
  provenance. Fresh interrupted outcomes remain interrupted, not drain passes.
- Ctrl+C or SIGTERM requests app exit, allows four seconds for graceful teardown,
  then cleans the owned process group. Failures and the 100-second outer deadline
  also stop only that group. The shell adapter cleans its exact ADB forwards.

The headset still uses **DEV: Meteor decoded stereo** to opt into this USB test.
The current app is the pinned upstream movement demo, fixed at 512-square eyes,
20-Hz target and 200 encoded frames (120 in synthetic smoke). This preserves the
existing wire/decoder safety bounds; it is NOT continuous play or arbitrary game
launch support. Do not describe the command as automatic XR detection or LAN
pairing. Audio is still absent. Windows requires a separate platform adapter.

## Next product-size milestone

Replace this checkout-dependent adapter with packaged runtime/application
session management and a paired, authenticated LAN control exchange. Negotiate
exclusive headset entry before starting the application; report exit/disconnect
back to Meteor. Remove diagnostic frame/deadman limits only after replacing them
with continuous-session sequence, timing, cancellation and queue tests. Keep
runtime selection process-local. Then batch one launch → interaction → headset
exit → relaunch check instead of repeating individual rendering fixtures.

## Build notes

On this Fedora machine, audiopus_sys's bundled CMake install chose lib64 while
its build script searched lib. The existing tools/cmake/install-libdir-lib.cmake
documents the lib directory workaround; CMake 4 also needs
`CMAKE_POLICY_VERSION_MINIMUM=3.5` for the bundled legacy Opus project. This is
host build-cache setup, not an XR/audio-processing change. Use the established
release container build for distribution; no new AppImage was packaged here.

## Verified checkpoint

The optimized Meteor executable passed the complete synthetic host workflow:
121 decoded frames, real upstream Touch locomotion, optics, ownership and clean
shutdown. The supervisor reached completed only after normal validation.
`test/run_meteor_xr_managed_lifecycle.py` then rejected a concurrent launch,
cancelled an active streaming session, and successfully relaunched to completed.
Logs: /tmp/meteor-managed-xr-smoke.log and /tmp/meteor-managed-xr-lifecycle.log.
Meteor's no-default-features test suite passed 57 tests with 5 ignored; six
upstream input tests include a resting left controller on hardware without
weakening the synthetic two-controller test. Physical managed USB launch/exit
has now passed: local exit stopped the app without forced termination; relaunch
completed with 201 decoded frames, right-stick locomotion, balanced ownership
and clean shutdown. The first run remains interrupted (178 encoded frames), not
a completed drain pass. This does not replace a LAN gate.
