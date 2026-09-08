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
| `zipdepth-base-384-gpu.tflite` | ~12MB | ZipDepth-384 Hybrid (GPU, fp16 weights) | Standard checkpoint backbone/decoder plus the mobile-safe NPU head. |
| `zipdepth-base-384-standard-mobile-gpu.tflite` | ~12MB | ZipDepth-384 Standard Full Head (float reference) | Portable rewrite of the standard checkpoint's learned convex head. Used as the conversion/validation reference; not bundled. |
| `zipdepth-base-384-standard-w8a32.tflite` | ~6MB | ZipDepth-384 Standard Full Head (CPU, w8a32) | INT8 weights with float32 activations/I/O. Bundled as `zipdepth-base-384-cpu.tflite`. Full w8a8 was rejected after severe numerical degradation in representative-scene validation. |
| `zipdepth-base-512x288-gpu.tflite` | ~12MB | ZipDepth-512x288 Hybrid (GPU, experimental) | Aspect-preserving test at the same pixel count as 384x384. |
| `zipdepth-base-672x384-gpu.tflite` | ~12MB | ZipDepth-672x384 Hybrid (GPU, experimental) | Aspect-preserving test at approximately the same pixel count as 512x512. |
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

### ZipDepth-GPU (`zipdepth-base-384-gpu.tflite`)

Has a real conversion script: `tools/convert_zipdepth.py`. The complete Quest
GPU investigation and reusable model-porting guidance are in
[`docs/guides/zipdepth-quest-gpu.md`](../docs/guides/zipdepth-quest-gpu.md).
[ZipDepth](https://github.com/fabiotosi92/ZipDepth)
(ECCV 2026, MIT) is a 6.1M-param pure-CNN (RepVGG blocks + Strip Pooling/SE/
Global-Context attention, convex-upsampling FPN decoder) distilled from Depth
Anything V2 Large across 14.1M images/17 domains - same "foundation model"
depth judgment as DA-V2, but with no transformer attention/softmax/matmul ops, which is
exactly what makes it viable on the GPU delegate where DA-V2-GPU wasn't (see
`DepthEstimator.java`'s `MODEL_ZIPDEPTH_*_GPU` comment for the full DA-V2-GPU
history this replaces).

The default export combines the standard checkpoint's sharper backbone and
decoder weights with the NPU checkpoint's unfold-free `where_conv` upsampling
head. This keeps the standard checkpoint's additional detail without bringing
its `torch.nn.Unfold`/softmax convex head into the mobile graph. It also rewrites
ZipDepth's attention blocks to avoid implicit spatial broadcasting, which the
Quest 3 Adreno OpenCL delegate executes incorrectly despite accepting every op.
The rewritten graph explicitly expands strip/channel/global attention maps to
the feature-map size before element-wise addition or multiplication. On a real
captured frame, the resulting hybrid Quest GPU output matched desktop TFLite
CPU output with correlation `0.99999999997`, mean absolute error `2.33e-7`, and
maximum absolute error `5.29e-7`.

Run the reproducible default conversion with:

```bash
python3 tools/convert_zipdepth.py --force
```

Use `--weights-mode npu` only to reproduce the smoother upstream NPU-only
baseline. Diagnostic `--head-mode` values generate activation mosaics and
overwrite the production model filename; see the dedicated document before
using them.

The script exports to ONNX and converts via `onnx2tf` - deliberately **without** `-ofgd`
(`--optimization_for_gpu_delegate`): the op composition is already 100%
native GPU-delegate ops, and `-ofgd` empirically introduces a real numerical
bug for this specific graph (verified against the onnxruntime reference -
with `-ofgd` the output diverges sharply and the depth map is visibly
striped/broken; without it, output matches the ONNX reference to ~1e-6 max
abs diff). Also uses `-tb tf_converter` (not onnx2tf's default
`flatbuffer_direct` backend) to get proper weight-only float16 quantization
via the real `tf.lite.TFLiteConverter` - only weight tensors become fp16
(with a Dequantize op at the boundary), input/output stay float32, matching
MiDaS-GPU's own convention and roughly halving file size vs. a naive float32
export (verified: I/O still float32, output within ~2-5e-4 of the ONNX
reference - normal fp16 quantization noise - and confirmed GPU-delegate-
compatible via TFLite's own `Analyzer.analyze(gpu_compatibility=True)`).
The standard full-head CPU variant is produced from
`tools/ZipDepth/tflite_384x384` with:

```bash
python3 tools/quantize_zipdepth_cpu.py
```

The default is W8A32: INT8 weights with float32 activations and I/O. Validation
against the float reference over 30 representative scenes measured mean raw
correlation `0.987300` and mean robust-normalized MAE `0.030090`. A strict W8A8
attempt (INT8 weights and activations, still with float model boundaries) was
only `0.646310` mean correlation and visibly collapsed on some scenes, so it is
deliberately not bundled. Revisit full integer quantization only with QAT or
selective activation quantization and the same validation set.

The production choice remains 384 (ZipDepth's native/trained resolution). Two
experimental widescreen inference shapes can be generated together with:

```bash
python3 tools/convert_zipdepth.py --shape 512x288 --shape 672x384
```

These reuse the 384-trained weights; they are inference-shape experiments,
not separately trained checkpoints. The 512x288 model has the same pixel
count as 384x384, while 672x384 is approximately equivalent to 512x512.

Square 192 and 256 models were also
built and visually compared via `tools/model_tester/`, but dropped
(2026-09-04): every number in ZipDepth's own paper is measured at 384x384,
and ZipDepth has no dedicated lower-resolution training. The 192/256 exports
are just the 384 weights operating outside their trained distribution, and
the quality loss was visible (192 especially).

### YOLO26-Depth-S (`yolo26s-depth-int8.tflite`, dormant/optional)

Not required for a normal build - `build.sh` doesn't reference it and it's not
selectable in the UI. Only relevant if you're specifically reviving this model;
see the "dormant" notes above and in `settings_controller.gd`'s
`ai_3d_model_labels` comment for why it was retired.
