# Independent OpenXR sample: Khronos hello_xr

The independent-application diagnostic uses the official Khronos
`OpenXR-SDK-Source` sample, revision
`a9f14c416e383d05c142f5a2539a91fe3931b52a` (OpenXR SDK 1.1.65).
Source: https://github.com/KhronosGroup/OpenXR-SDK-Source

Unlike the Nightfall-authored spheres and cube-grid fixtures, this sample owns
its own OpenXR instance/session loop, event handling, action setup, swapchain
management, Vulkan2 renderer and reference-space cube geometry. This is a
controlled compatibility milestone, **not unmodified arbitrary-game support**.

## Reproducible adaptations

`tools/build_support/build_hello_xr_probe.sh` fetches the immutable upstream
revision into ignored cache and verifies it remains clean. The container copies
it into `hello-xr-spike/source`, applies the checked-in
`test/hello_xr_diagnostic.patch` with zero fuzz, and builds the `hello_xr` target
in Release mode. Python and the X11 build dependency live only in the container.
Unused OpenGL/EGL backends are disabled; Vulkan is used without an on-screen
host window. No active system XR runtime is registered or changed.

When `METEOR_XR_HELLO_DIAGNOSTIC` is set, the sample adapter:

- Selects RGBA8 UNORM, one sample and 256/512-square eye swapchains, within
  runtime limits. The default upstream dimensions/format exceed this spike's
  intentionally restricted capture contract.
- Requests transfer-source usage needed by the existing stereo-copy hook.
- Disables compositor depth submission and uses upstream's own fallback depth
  textures; this is not disabling the sample renderer's depth testing.
- Enables the standard timespec conversion extension to log submitted display
  timestamps in host CLOCK_MONOTONIC, rather than assuming OpenXR clock epochs.
- Counts only actual projection submissions, stops after the configured 1–240
  frames, waits up to five seconds for final capture, then calls
  `xrRequestExitSession`. No per-frame file ACK wait is introduced.
- Disables the upstream detached keyboard-quit thread for unattended tests.
  Otherwise stdin EOF immediately quits, while keeping a blocking getchar
  thread alive caused exit to hang in this environment.

The renderer, reference-space geometry, action setup and normal session/event
loop remain upstream code. The runner launches `-g Vulkan2 -s Stage -bm Opaque`;
STAGE is the explicitly adopted Quest LOCAL root in this virtual-device spike.
The controller actions are created by the sample but no remote controllers are
provided yet, so this does not validate interaction or haptics.

## Validation

Host tests with synthetic changing head poses and asymmetric eye optics passed:

- 32 submissions / 31 encoded and delivered, one pending raw replacement.
- Final 120 submissions / 118 encoded and delivered, one pre-worker skip and
  one pending raw replacement; final frame drained and encoder released once.
- Negotiated asymmetric FOV and 64 mm separation reached actual encoded views.
- Encoded timestamps mapped to real sample submissions; packet bytes/metadata,
  decoded dimensions/count and image-lease balances matched through loopback.
- A decoded stereo preview was inspected and shows the reference-space cubes
  on the sample's plain background.

There is a broad nonblank-output smoke check, **not a pixel oracle**. No CPU image
readback was introduced into the streaming compositor. App-side GPU timing is
not instrumented here. Host packing median was 196 us, encode/packet-copy 638 us;
scheduled display cadence 54.42 Hz at the 60 Hz target, not headset presentation
FPS or end-to-end latency. Short-run startup affects these figures.

Ignored evidence: `.build-cache/meteor-xr/profiles/512-60-hello-xr-timing.json`
and `512-60-hello-xr-preview.png` in the same directory. Per-run logs/bitstream
remain in `monado-nvenc-spike` and are overwritten by the next diagnostic.

## Build and run

```bash
bash tools/build_support/build_hello_xr_probe.sh
NIGHTFALL_XR_HELLO_XR=1 NIGHTFALL_XR_HEADSET_OPTICS=1 \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 \
  .build-cache/model-tester-venv/bin/python test/run_monado_tracking_spike.py "$PWD"
```

Do not combine the independent-app flag with the internal GPU-scene, raster or
measurement flags. The harness rejects those contradictory modes. App-abort
testing is not supported in this mode yet. The sample subprocess has a 40-second
deadline; timeout output is retained in `probe.log` for diagnosis.

For headset testing, pass those same flags to
`tools/build_support/probe_headset_xr_tracking_runtime.sh` when the user is ready,
setting `NIGHTFALL_ADB` if needed. The installed optimized optics-aware DEV APK
works unchanged. Press `DEV: Meteor decoded stereo`, look forward and move your
head gently. Expect small colored reference-space cubes on a plain background,
not the previous floor/grid. The ViewFront cube intentionally follows the head;
other locatable reference-space cubes stay in their respective spaces. Hold
B/Y one second to exit; the finite stream holds its final picture after ending.
Headset validation succeeded: the user reported everything looked correct.
240 submissions produced 236 encoded/delivered frames, all 236 logged decoded
by Quest. Four submissions skipped before the raw worker; all 236 accepted
raw jobs encoded, with zero pending replacements. Final frame drained and
host shutdown passed. Host scheduled cadence was 57.79 Hz at the 60 Hz target,
not measured Quest presentation FPS. Packing median was 284 us and
encode/packet-copy 708 us. Captured device logs end holding the final picture;
they do not establish the later local-exit result. Retained timing evidence:
`.build-cache/meteor-xr/profiles/512-60-hello-xr-headset-timing.json`.

## Limits and licensing

The source is Apache-2.0 (retain upstream notices if distributing it). The
sample binary is a local diagnostic artifact, not included in the APK or Meteor
release. This does not resolve Monado/WiVRn/encoder distribution requirements.
The capture contract remains plain full-rect, separate-image stereo RGBA8, one
projection layer. More engines, array swapchains, compositor depth, higher sizes,
longer sessions, audio/controllers, managed LAN/authentication and Windows remain
separate compatibility and product gates.
