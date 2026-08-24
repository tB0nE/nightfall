# Depth model assets

This directory holds the `.tflite` depth-estimation models `build.sh` bundles into
the Android APK (`android/build/nightfallAssets/`, merged into the app via a Gradle
`sourceSets` entry) and the Linux binary (`depth_models/`, resolved at runtime
relative to the executable). None of these files are committed to git (see
`.gitignore`'s `/models/*.tflite`) - they're regenerated/downloaded/copied in
locally before building, per the instructions below. `build.sh` will fail loudly
(missing-file error from `cp`, `set -euo pipefail`) if one it needs isn't present,
rather than silently shipping an APK/binary missing a model.

Every model here shares the same downstream pipeline (`DepthEstimator.java`'s
`postProcess()`, the warp/DIBR shaders) regardless of source - see
`settings_controller.gd`'s `ai_3d_model_labels` for how each maps to a UI choice.

## Manifest

| Filename | Size | Model | Notes |
|---|---|---|---|
| `midas-midas-v2-w8a8.tflite` | ~17MB | MiDaS-256 (CPU, int8) | See "MiDaS models" below. |
| `midas-v21-small-192-int8.tflite` | ~17MB | MiDaS-192 (CPU, int8) | Independently calibrated at 192x192, not a resize of the 256px model - own scale/zero_point (`DepthEstimator.java`'s `MIDAS_192_*` constants). Default landing model when AI-3D is first turned on. |
| `midas-v21-small-256-gpu.tflite` | ~33MB | MiDaS-256 (GPU, fp16) | See "MiDaS-GPU" below. Only reachable via the "MiDaS-256-GPU" model entry or MiDaS-256 + Backend=GPU/Auto (Android only). |
| `yolo26n-depth-256-w8a32.tflite` | ~5.5MB | YOLO26-Depth-N-256 (CPU, w8a32) | Ultralytics' monocular depth export. w8a32 = dynamic/weight-only int8 (no calibration data needed) - fixes a collapse bug the old static-int8 export had. |
| `yolo26n-depth-320-w8a32.tflite` | ~5.5MB | YOLO26-Depth-N-320 (CPU, w8a32) | Same export, 320px input. |
| `yolo26n-depth-384-w8a32.tflite` | ~5.5MB | YOLO26-Depth-N-384 (CPU, w8a32) | Same export, 384px input. |
| `depth-anything-v2-small-196.tflite` | ~25MB | Depth Anything V2 Small-196 (CPU, int8) | See "Depth Anything V2" below. 196 = 14×14 (ViT-S patch-14 multiple), ~192px target. |
| `depth-anything-v2-small-252.tflite` | ~25MB | Depth Anything V2 Small-252 (CPU, int8) | Same conversion, 252 = 14×18, ~256px target. |
| `yolo26s-depth-int8.tflite` | ~13MB | YOLO26-Depth-S (dormant) | **Not bundled by `build.sh`, not selectable in the UI.** Kept here only for future revival work - its int8 quantization proved fragile on real desktop-UI-style low-texture content. Not required for a normal build. |

## Acquiring each model

### MiDaS models (`midas-midas-v2-w8a8.tflite`, `midas-v21-small-192-int8.tflite`)

No conversion script in this repo yet - these were sourced/converted in an earlier
session. If you don't have them, ask in the project or check whether a prior
build's `models/` directory (or a teammate's machine) still has them; regenerating
them from scratch means re-running the MiDaS v2.1-small export + int8
quantization/calibration pipeline that produced the exact scale/zero_point
constants `DepthEstimator.java` expects (`MIDAS_INPUT_SCALE`/`MIDAS_INPUT_ZERO_POINT`/
`MIDAS_OUTPUT_SCALE`/`MIDAS_OUTPUT_ZERO_POINT` and their `_192` counterparts) - if
you do regenerate, verify those constants still match the new export before
trusting the output.

### MiDaS-GPU (`midas-v21-small-256-gpu.tflite`)

This is `moonlight-android-xr`'s own fp16 MiDaS v2.1-small export (originally
`midas_v21_small_256_fp16.tflite` in that project) - copy it in and rename to
`midas-v21-small-256-gpu.tflite`. It's fp16 (not int8) because the GPU delegate
runs the model at its own native precision (see `DepthEstimator.java`'s
`ensureMidasGpuLoaded()` for the `setPrecisionLossAllowed(true)` config this
depends on).

### YOLO26-Depth-N (`yolo26n-depth-{256,320,384}-w8a32.tflite`)

Ultralytics YOLO26's monocular depth export, quantized w8a32 (weight-only int8,
no calibration set required). No conversion script in this repo yet - see
Ultralytics' own export tooling for producing a w8a32 TFLite export at each
resolution, then verify against `DepthEstimator.java`'s `MODEL_YOLO_N_*` input/
output handling (NCHW channel-planar fill, not NHWC - see that comment for why).

### Depth Anything V2 Small (`depth-anything-v2-small-{196,252}.tflite`)

Has a real conversion script: `tools/convert_depth_anything_v2.py`. Downloads the
Depth Anything V2 Small weights from HuggingFace, exports to ONNX, and converts to
int8 quantized TFLite via `onnx2tf -kt input` (this exact flag matters - the naive
export path produces spatially incoherent output, see the script/`DepthEstimator.java`'s
`MODEL_DA_196/252` comment for the history). Run it from `tools/`; see `BUILD.md`
for the exact invocation. Produces both the 196 and 252 sizes.

### YOLO26-Depth-S (`yolo26s-depth-int8.tflite`, dormant/optional)

Not required for a normal build - `build.sh` doesn't reference it and it's not
selectable in the UI. Only relevant if you're specifically reviving this model;
see the "dormant" notes above and in `settings_controller.gd`'s
`ai_3d_model_labels` comment for why it was retired.
