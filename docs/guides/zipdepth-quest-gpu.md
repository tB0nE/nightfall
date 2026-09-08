# ZipDepth on Quest: GPU correctness and model-building guide

Status: working on Quest 3, verified 2026-09-04.

This document records why an otherwise valid ZipDepth TFLite model produced a
scene-independent gradient through LiteRT's Android GPU delegate, the graph
rewrite that fixed it, and the checks required when adding future depth models.

## Final implementation

Nightfall ships a 384x384 ZipDepth hybrid:

- Standard `zipdepth_base.pth` weights for the encoder, decoder fusion, and
  half-resolution depth head. These retain more fine structure than the NPU
  checkpoint on desktop-UI content.
- The `where_conv` upsampling head from `zipdepth_base_npu.pth`. This avoids the
  standard head's `torch.nn.Unfold` and softmax path, which lowers poorly for a
  mobile GPU delegate.
- Float16 weights with float32 input/output tensors.
- Explicitly materialized attention maps before element-wise operations.
- Large spatial reductions decomposed into exact 2x/3x average-pooling stages.

The output is `models/zipdepth-base-384-gpu.tflite`. Model binaries and the
downloaded ZipDepth checkout/checkpoints are ignored by git; the conversion
scripts are the source of truth.

Build the production model from the repository root:

```bash
python3 tools/convert_zipdepth.py --force
```

The script uses the Python interpreter that launched it. Set
`NIGHTFALL_MODEL_PYTHON` only when its conversion subprocesses need a different
environment.

This defaults to `--weights-mode hybrid --head-mode full`. To reproduce the
smoother upstream NPU-only baseline:

```bash
python3 tools/convert_zipdepth.py --force --weights-mode npu
```

## Failure signature

The initial Quest GPU result was a smooth diagonal/vertical colour gradient
with almost no relationship to the streamed desktop. The same TFLite file and
the exact same input bytes produced a coherent depth map on desktop CPU.

This signature is important: LiteRT accepting every node and creating one GPU
delegate kernel does **not** prove numerical correctness on a particular GPU
driver. Compatibility analysis checks whether the delegate can claim an op,
not every tensor shape, broadcast pattern, or device-specific kernel.

## What was ruled out

The investigation established the following before changing model semantics:

1. The `.tflite` bytes in the APK matched the locally tested file.
2. ONNX-to-TFLite conversion matched the ONNX/PyTorch reference on CPU.
3. The exact 384x384x3 float32 bytes sent to `Interpreter.run()` were dumped
   from the headset and produced correct depth on desktop CPU.
4. The raw float32 output was dumped before Nightfall normalization, temporal
   smoothing, texture upload, and warp shaders. The bad gradient already
   existed there.
5. Input/output buffer sizes and layout were correct: NHWC input, float32 I/O,
   384x384.
6. Forcing full-float GPU execution did not fix the gradient, ruling out normal
   fp16 precision loss.
7. Replacing the learned NPU upsampling blend with bilinear-only output did not
   fix it, ruling out the convex upsampling head.
8. Decomposing the large strip/global pools into small exact reductions did not
   fix it by itself, ruling out large pooling as the sole cause.

Activation mosaics then showed recognizable desktop structure throughout the
encoder, while numeric CPU/GPU disagreement began around the attention stages
and accumulated through later decoder fusion.

## Root cause

The broken operator pattern was implicit spatial broadcasting inside
ZipDepth's attention blocks:

```text
StripPoolingAttention:
    [B,C,H,1] + [B,C,1,W] -> [B,C,H,W]

ChannelAttention:
    [B,C,H,W] * [B,C,1,1] -> [B,C,H,W]

GlobalContextBlock:
    [B,C,H,W] + [B,C,1,1] -> [B,C,H,W]
```

These expressions are legal TFLite and pass the delegate compatibility check,
but the Quest 3 Adreno OpenCL execution produced incorrect values. The
dual-axis strip broadcast is the primary first-divergence suspect; the later
channel/global broadcasts share the same unsafe pattern. All three are
materialized defensively because retaining any latent device-specific error is
not useful.

The fix in `tools/export_zipdepth_gpu_safe.py` explicitly resizes the small
attention tensor to the full feature-map dimensions with nearest-neighbour
sampling before `ADD` or `MUL`:

```python
horizontal = F.interpolate(horizontal, size=x.shape[-2:], mode="nearest")
vertical = F.interpolate(vertical, size=x.shape[-2:], mode="nearest")
gate = gate_conv(horizontal + vertical)
result = x * gate
```

The same materialization is applied to the 1x1 channel and global-context
maps. Nearest-neighbour expansion is mathematically identical to broadcasting;
it merely forces LiteRT to generate an explicit resize followed by a
same-shaped element-wise operation.

Large reductions remain decomposed into exact small pooling stages. Although
that change was not sufficient to fix the gradient, it avoids unusually large
driver-specific reduction kernels and is CPU-equivalent within floating-point
rounding.

## Verification result

After materializing the broadcasts, the original NPU-weight model's Quest GPU
output matched desktop TFLite CPU on the exact captured input:

| Measurement | Result |
|---|---:|
| Correlation | `0.99999999998` |
| Mean absolute error | `3.97e-8` |
| RMSE | `6.03e-8` |
| Maximum absolute error | `4.25e-7` |

The successful hybrid model was independently checked on its on-device capture:

| Measurement | Result |
|---|---:|
| Correlation | `0.99999999997` |
| Mean absolute error | `2.33e-7` |
| RMSE | `2.65e-7` |
| Maximum absolute error | `5.29e-7` |

CPU and GPU standard deviation also matched (`0.01743403`), showing that the
fix restored both structure and signal range rather than merely creating a
visually plausible map.

## Why the hybrid weights are used

The NPU checkpoint's unfold-free output was correct after the broadcast fix,
but its depth map was visibly smooth. On the same captured frame, the standard
checkpoint had roughly twice the gradient/edge energy.

The two checkpoints have matching shapes for every non-upsampler tensor. The
exporter therefore loads all compatible standard checkpoint weights, then
overlays only the NPU checkpoint's `decoder.convex_up.where_conv.*` tensors.
This preserves the delegate-friendly graph while recovering much of the
standard checkpoint's detail. The hybrid is an intentional deployment model,
not an accidental `strict=False` partial load: the exporter reports missing
and unexpected keys and should stop being trusted if either list becomes
non-empty.

## Conversion requirements

Keep these constraints when changing the export:

- Treat 384x384 as the production baseline. ZipDepth was trained/benchmarked
  at 384; the tested 192 and 256 square resizes lost too much quality.
- Experimental rectangular shapes must use dimensions divisible by 32 and
  must be revalidated on the Quest GPU. Generate the current 512x288 and
  672x384 experiments with repeated `--shape WIDTHxHEIGHT` options.
- Do not pass onnx2tf's `-ofgd`. For this graph it caused CPU-visible numeric
  divergence and striped output despite its name implying a GPU improvement.
- Use `-tb tf_converter`. This produces weight-only float16 models with
  float32 I/O, matching Nightfall's direct float buffers.
- Verify input/output types and shapes after every conversion.
- Run TFLite's GPU compatibility analyzer, but treat it only as a support
  check—not a correctness test.
- Compare the exported TFLite CPU output against the PyTorch/ONNX reference
  before copying it into the APK.
- Finally compare on-device raw GPU output against desktop CPU using the exact
  same captured input. This is the decisive device/driver check.

The diagnostic exporter modes are:

```text
--head-mode encoder-mosaic   encoder stage boundaries
--head-mode stage2-mosaic    internals of encoder stage 2
--head-mode decoder-mosaic   decoder pyramid fusion stages
--head-mode bilinear         bypass the learned mobile upsampling blend
```

Each diagnostic mode writes the normal production filename. Regenerate with
`--head-mode full` before building a release.

## Guidance for future custom models

When bringing another model to Quest/LiteRT GPU:

1. Prefer convolution, depthwise convolution, small pooling, resize, and
   same-shaped element-wise operations.
2. Avoid assuming that a delegated graph is correct. Validate real device
   output numerically.
3. Be suspicious of implicit broadcasting across spatial dimensions,
   especially two tensors broadcasting different axes.
4. Materialize small maps explicitly before element-wise operations when a
   model uses SE, channel attention, global context, strip pooling, or similar
   gates.
5. Keep model input normalization inside the graph or document it precisely;
   never infer NHWC/NCHW or float/int8 I/O from the filename.
6. Dump raw model output before application post-processing when diagnosing.
   Otherwise normalization and visualization can make a broken tensor look
   plausible—or a correct low-contrast tensor look broken.
7. Use activation-boundary mosaics when TFLite offers no convenient
   intermediate-output debugging. Project each checkpoint to one channel,
   place four checkpoints in output quadrants, and compare the same input on
   CPU and GPU.

## Relevant files

- `tools/convert_zipdepth.py`: downloads checkpoints and runs the full export.
- `tools/export_zipdepth_gpu_safe.py`: hybrid loading, graph rewrites, and
  activation diagnostics.
- `android/src/main/java/com/godot/game/DepthEstimator.java`: GPU delegate,
  NHWC input preparation, raw diagnostic dump, and depth post-processing.
- `models/README.md`: model manifest and short acquisition instructions.
- `build.sh`: copies the generated model into Android assets.
