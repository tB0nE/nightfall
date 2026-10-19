# XR diagnostic: resolution/rate profiles and stage timings

2026-10-19, `feat/meteor-xr-streaming`. Follows the
[worker-driven encode path](meteor-xr-async-encoding.md).

## Profiles

The original default remains 256x256 per eye with a 20 Hz null-compositor target.
Opt in to 512x512 per eye and a 60 Hz target with
`NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60`. This is four times as many
source pixels per eye, not a final headset-native resolution. The packed video
becomes 1024x512. The Quest projection swapchain stays 1024x1024 per eye.

Host eye swapchains, packing extents, CUDA/NVENC resources, copied delivery
metadata, wire dimensions, image references, decoder/ImageReader and AHB checks
now agree on the selected profile. The local diagnostic ABI adds `eye_size`;
rebuild the isolated Monado service and encoder together. Legacy zero means 256.
The headset allows only the two bounded profiles and rejects dimensions changing
inside a stream. Generic Rust framing still accepts its existing bounded sizes.

The optimized release-signed DEV APK supporting both decoder profiles is
installed. Build log: `/tmp/nightfall-xr-profile-apk.log`. The ordinary stream,
browser and model settings are unchanged; this is still the DEV XR button.

## Color correction found by the larger test

The first larger stripe run failed the unchanged RGB tolerance: red decoded near
232 instead of 255. The H.264 stream's color metadata was unspecified; decoding
the same bytes explicitly as BT.709 recovered red near 254. Added explicit VUI
primaries/transfer/range and matrix metadata matching the observed driver
conversion (BT.601/SMPTE170M matrix for the old packed width, BT.709 for the
larger profile). The high-profile stripe and legacy-profile tests then passed
without loosening color thresholds. Bitrate scales with pixel count, from
4 Mbps to 16 Mbps; the initial preset remains P1/ultra-low-latency H.264.

## Reference-app bottleneck and correction

The null compositor's old target was 20 Hz. The CPU scene app also lacked `-O2`;
it is now built optimized, independently of the already-optimized APK/runtime.
Early detailed profiling of the larger scene still showed approximately 94 ms
median app-frame work: around 15 ms CPU generation and 31 ms verification/artifact
work **per eye**, while GPU pack/encode were well below 2 ms combined.

The app now prefers coherent host-cached upload/readback memory, snapshots GPU
readback once into ordinary RAM, and verifies/extracts RGB there. It no longer
repeatedly reads potentially uncached mapped GPU memory. RGB/PPM artifacts are
written in bulk rather than per pixel. FOV tangents, camera basis and sphere
constants are computed once per eye instead of once per pixel. This preserves
the same scene equations and validation, not a reduced quality mode.

These are **test app** changes. The actual Monado-to-encoder streaming path still
has no full-image CPU readback; only compressed bitstream bytes return to CPU.

## Results and meaning of timings

The larger 60-Hz-target stripe test passed all 120 submitted/encoded/delivered
frames. The longer tracked scene passed 120 submissions / 119 encoded/delivered,
with one raw pending replacement, balanced ownership and final drain. Mean
decoded-reference byte error was 0.962/255. Standalone Qualcomm hardware decoding
on Quest passed 32 in-order 1024x512 buffers and teardown. This does not yet prove
the larger profile's visual projection on the headset.

The preserved scene timings are in
`.build-cache/meteor-xr/profiles/512-60-scene-final-timing.json`:

| CPU-wall diagnostic stage | Median | 95th percentile |
| --- | --- | --- |
| App reference frame, both eyes | 12.776 ms | 16.855 ms |
| Per-eye CPU image generation | 5.649 ms | 8.095 ms |
| Per-eye upload/readback submission and wait | 0.250 ms | 0.309 ms |
| Per-eye verification/artifact work | 0.432 ms | 0.752 ms |
| Stereo packing record/submit/wait | 0.195 ms | 0.239 ms |
| NVENC submit through packet copy | 0.761 ms | 0.885 ms |

Observed host **display-timestamp cadence** was approximately 46.9 Hz over this
short 120-submission run. The application process took approximately 2.88 seconds
including startup/exit. These are not interchangeable with measured headset FPS,
motion-to-photon latency or sustained throughput. Startup, CPU-reference work,
diagnostic readback/files and app pacing remain in the experiment. The 60 Hz
configuration is a target, not a claim it was achieved everywhere.

`timing-summary.json` records stage sample counts, p50/p95/max and configuration.
GPU pack numbers are CPU-wall command recording/submission/wait measurements,
not timestamp-query GPU execution times. NVENC numbers also include host packet
copy/file-write work before the existing timer ends. Performance records now use
single stderr log calls to avoid buffered stdout/stderr splitting measurements.
The preserved run above predates that log adjustment and contains 117 pack
samples for 119 frames; it is not a per-frame timing completeness proof.

## Reproduce

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_PCVR_ALVR=OFF ./build.sh --dev --install
NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_PROBE_FRAMES=120 NIGHTFALL_XR_ASYNC_ENCODE=1 \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_xr_transport.sh

# Arm only when the user is ready. 240 is the current bounded frame maximum.
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_PROBE_FRAMES=240 NIGHTFALL_XR_ASYNC_ENCODE=1 \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_headset_xr_tracking_runtime.sh
```

Move gently as soon as the spheres appear. The live sequence is only a few
seconds; afterwards the last picture remains until local exit or the existing
45-second auto-exit. This is not a continuous game session. Next: visual larger-
profile check, longer bounded measurement without excessive RGB artifacts,
real-device FOV/IPD negotiation, and a GPU-rendered reference app/actual XR app
before treating this CPU sphere renderer as a realistic performance workload.
