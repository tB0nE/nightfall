# Rasterized OpenXR diagnostic workload

`NIGHTFALL_XR_RASTER_SCENE=1` selects a direct-to-swapchain Vulkan graphics
workload in the diagnostic OpenXR application. The existing compute-rendered
spheres remain the baseline and default GPU scene.

This workload draws 25 independently rotating colored cubes at different
distances over a checkerboard floor. It exercises vertex/fragment shaders,
triangle rasterization, asymmetric per-eye projection, device-local D32 depth
testing and OpenXR color attachments. The floor is drawn after the cubes,
with depth testing retaining foreground occlusion. There is no CPU pixel
generation or buffer-to-color-image upload in this rendering path.

Each acquired eye image has its own color view/framebuffer. One depth attachment
is reused only after the existing completion fence finishes; both eyes remain
serially rendered. Color layout transitions, image leases, GPU timing queries,
bounded encoding/delivery and tracking are retained. Shader compilation and
SPIR-V validation happen in the existing isolated build container.

This remains **our diagnostic application**, not an independently sourced game,
general compositor, engine compatibility test or representative heavy GPU load.
There are no textures, MSAA, application controller actions or audio yet. It is
a more conventional graphics workload than the procedural compute spheres,
and provides visible animation independent of head motion.

## Validation

The mode requires explicit GPU measurement mode. It does not reuse the sphere
CPU oracle or claim exact raster pixel/depth correctness. Instead, the decoded
video smoke check rejects incomplete frames, absent colored foreground, absent
gray floor/dark background, identical eyes, and an unchanging sequence.
These are broad content checks, not proof of correct depth at every pixel.
An independent decoded stereo preview was inspected on the host and showed
the cube grid and checkerboard with expected perspective and occlusion.

Five smoke-check unit tests cover nonblank moving stereo acceptance, blank and
truncated outputs, duplicated eyes and a static sequence. Existing metadata,
transport byte equality, decoded frame count, latest-job accounting, image-lease
balance and final-frame drain checks remain enabled.

Host tests with synthetic tracking/optics:

- Initial 32 submissions: 31 encoded/delivered, one raw pending replacement.
- Longer 120 submissions: 119 accepted by raw worker, 118 encoded/delivered,
  one pre-worker skip plus one pending replacement, final frame drained.
- Negotiated asymmetric FOV and 64 mm separation reached render metadata.
- Median both-eye app wall time 285.5 us, GPU raster 7.424 us per eye (240
  samples), pack 184.5 us and encode/packet-copy 724 us.
- Host scheduled cadence 55.28 Hz at a 60 Hz target. This is not measured Quest
  presentation FPS or end-to-end latency. The scene is deliberately lightweight.

Ignored retained evidence:
`.build-cache/meteor-xr/profiles/512-60-raster-timing.json` and
`512-60-raster-preview.png` in the same directory.

## Run

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_RASTER_SCENE=1 NIGHTFALL_XR_HEADSET_OPTICS=1 \
  NIGHTFALL_XR_GPU_SCENE=1 NIGHTFALL_XR_GPU_MEASURE=1 \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 \
  .build-cache/model-tester-venv/bin/python test/run_monado_tracking_spike.py "$PWD"
```

For a headset check, pass the same flags to
`tools/build_support/probe_headset_xr_tracking_runtime.sh` when the user is ready.
No new APK is needed: the already installed optimized optics-aware DEV build
can decode/project it. Press `DEV: Meteor decoded stereo`; expect cubes rather
than spheres. Look forward, gently move your head, check floor/cube world-lock,
occlusion, stereo comfort and cube rotation. Live content is still bounded to
240 app frames, then the final picture is held. Hold B/Y one second to exit.
Headset validation succeeded: the user saw the cubes and reported smoothness.
The 240-submission run delivered 236 frames, all logged decoded by Quest;
three submissions skipped before the raw worker, one pending raw job replaced,
final frame drained. Both-eye app wall median was 678.5 us and GPU raster
7.616 us per eye (480 samples). Host scheduled cadence was 58.02 Hz against
the 60 Hz target, not measured headset presentation FPS. Host shutdown passed;
device logs end at final-picture hold, not the subsequent local exit.
Evidence: `.build-cache/meteor-xr/profiles/512-60-raster-headset-timing.json`.

## Next gates

After headset confirmation, exercise an independent OpenXR application with
its own rendering/session lifecycle rather than extending this small fixture
indefinitely. The current capture hook accepts plain two-eye projection with
separate swapchain images; array swapchains/depth composition/multiple layers
and other engines remain compatibility work. Higher resolution/refresh,
longer-duration stability, prediction/clock refresh/recenter/standby, LAN service
lifecycle/authentication, controllers/audio and Windows remain outstanding.
