# Preserve vanilla ZipDepth sharpness on Quest

Status: Active

## Objective

Retain the edge sharpness of the upstream standard ZipDepth checkpoint while
running depth inference through LiteRT's GPU delegate on Quest. The accepted
model must remain fully GPU delegated, numerically correct on Adreno OpenCL,
and fast enough to sustain Nightfall's 20-30 Hz depth targets without harming
stream frame pacing.

This investigation precedes the separate custom-head training proposal. The
upstream model already contains the desired sharpness, so the first task is to
preserve its standard convex upsampling head through conversion and mobile
execution rather than train a replacement.

## Evidence and working hypothesis

The official `zipdepth_base.pth` checkpoint was run unchanged on the
development RTX 3090:

- 384x384 FP16 CUDA inference: approximately 2.9 ms.
- Aspect-preserving 672x384 FP16 CUDA inference: approximately 3.7 ms.
- CPU/CUDA raw-output correlation at 384x384: `0.99998`.
- The vanilla standard head is visibly sharper than Nightfall's deployed
  hybrid model.

Nightfall's deployed hybrid keeps the standard encoder, decoder, and
half-resolution depth predictor, but replaces the standard convex upsampler
with the smoother NPU `where_conv` head. The working hypothesis is that this
head substitution, rather than OpenCL precision or the ZipDepth backbone, is
the primary source of lost edge detail.

`tools/export_zipdepth_gpu_safe.py --head-mode standard-mobile` already
provides an exact rewrite of the standard head. It replaces `Unfold` with a
fixed one-hot 3x3 convolution while retaining the pretrained mask predictor,
softmax weights, four independently learned subpixel reconstructions, and
pixel shuffle. Its PyTorch equivalence check must remain mandatory.

## Safety rules

- Keep `zipdepth-base-384-gpu.tflite` as the production default until the new
  graph passes every gate below.
- Initially substitute the model only through the existing
  `NIGHTFALL_ZIPDEPTH_384_MODEL` build override. Do not change Auto selection
  or persisted model indices for the first device test.
- Keep the current hybrid and ZipDepth-256/OpenGL fallback available.
- Compare raw float output before Nightfall normalization, temporal
  smoothing, guided upsampling, texture upload, or stereo warping.
- Treat successful delegation as an operator-support check only. Numerical
  comparison against desktop output is the correctness test.
- Use the same captured input bytes at every stage.

## Phase 1: freeze the conversion ladder

Create a fixed evaluation corpus containing desktop text, icons, overlapping
windows, games, film frames, fine geometry, hair, foliage, fences, and flat
surfaces. Reserve complete scenes or recordings as a held-out set.

For each frame, save raw float output from:

1. Vanilla PyTorch FP32.
2. Vanilla PyTorch FP16 CUDA.
3. Standard-head ONNX.
4. Standard-mobile TFLite on desktop CPU.
5. Current hybrid TFLite on desktop CPU.
6. Standard-mobile TFLite on Quest OpenCL.

All baseline comparisons use identical 384x384 RGB input bytes. Rectangular
models are deliberately excluded until the standard 384 path is correct so
head changes and input-shape changes cannot be confused.

Record correlation, MAE, maximum error, raw range, standard deviation,
multi-scale gradient error, boundary transition width, flat-region noise, and
fixed visual comparisons. Do not use gradient energy alone because noise can
score highly while looking worse.

Decision gate: standard-mobile TFLite CPU must remain visually and
numerically equivalent to vanilla PyTorch before device work continues.

## Phase 2: first Quest OpenCL proof

Build a release APK with the existing packaging override pointing model slot
14 at `zipdepth-base-384-standard-mobile-gpu.tflite`. Keep all runtime code,
model indices, backend selection, and fallback behavior unchanged.

Verify on Quest 3:

- The model loads through OpenCL.
- LiteRT reports the expected GPU delegate rather than CPU fallback.
- Depth inference begins and produces spatially coherent output.
- Raw depth debug output preserves the vanilla model's fine edges.
- Inference cadence and stream FPS remain stable.
- Starting AI 3D, reconnecting, changing Hz cap, and resuming from standby do
  not crash or black-screen the app.

This substitution build is intentionally not an A/B product interface. If the
proof succeeds, add the standard model as a separate experimental model ID so
both heads can be switched within one session.

## Phase 3: exact on-device correctness

Export the exact 384x384x3 float input submitted on Quest and its raw model
output. Run the captured input through the same TFLite file on desktop CPU.

Acceptance criteria:

- Correlation at least `0.9999`.
- No NaNs, infinities, constant fields, or scene-independent gradients.
- Matching output range and standard deviation within normal fp16 rounding.
- No visible loss of the standard head's fine boundaries.
- All intended operators delegated to the GPU.

If these checks pass, proceed directly to profiling. If they fail, begin the
head bisection below.

## Phase 4: bisect and rewrite the failing head operation

The standard-mobile head is:

```text
half-resolution depth
  -> fixed 3x3 neighbour convolution
  -> learned mask prediction
  -> softmax over nine neighbours
  -> same-shaped neighbour/weight multiplication
  -> four nine-channel reductions
  -> depth-to-space
  -> ReLU
```

Produce diagnostic outputs after the neighbour convolution, mask logits,
softmax, each weighted reduction, and depth-to-space. Compare each stage on
desktop CPU and Quest OpenCL to identify the first divergence.

Apply substitutions one at a time:

1. Replace each channel `ReduceSum` with a fixed 1x1 convolution whose nine
   weights are one.
2. Keep the four subpixel branches explicit through their reductions.
3. Materialize all operands to identical shapes before every element-wise
   multiplication or addition.
4. Express pixel shuffle as a verified `DEPTH_TO_SPACE` operation.
5. If softmax diverges, rewrite it with explicitly shaped max subtraction,
   exponentiation, sum, and division, validating each reduction separately.
6. If necessary, replace only the failing operation with an equivalent graph
   composed of Conv2D, DepthwiseConv2D, Resize, ReLU, and same-shaped
   element-wise operations.

Every candidate must first match vanilla PyTorch on desktop and then match
desktop TFLite on Quest. Do not accept a visually plausible approximation in
place of numerical agreement.

The current ncnn conversion of this head producing a nine-channel output is a
separate pnnx reduction-lowering bug. Fix it for Linux after the LiteRT graph
is understood; it must not be used as evidence about Quest OpenCL correctness.

## Phase 5: Nightfall performance validation

Compare the validated standard head against the current hybrid during real
streams at the same model input, Hz cap, resolution, refresh rate, and GPU
priority.

Measure:

- Warm inference latency and achieved depth-update rate.
- One-time model load and kernel compilation time.
- Application and stream frame-time stability.
- Dropped depth submissions.
- GPU utilization and memory use.
- 20 Hz and 30 Hz behavior.
- Interaction with passthrough, ambient lighting, Depth Sync, menu overlays,
  reconnect, standby/resume, and model/backend switching.

Acceptance gate: the standard head must preserve stable 72 Hz streaming at
the same operating points as the hybrid and achieve at least the 20 Hz depth
target. A small inference cost increase is acceptable if stream pacing remains
stable and the visual improvement is material.

## Phase 6: compatibility and production integration

After Quest 3 OpenCL passes, test Quest 3 OpenGL, Quest 2 OpenGL, and Linux
ncnn Vulkan. Keep unsupported combinations explicit rather than silently
falling back to a different head.

If validated broadly:

1. Add a stable standard-head model ID without changing existing indices.
2. Make the standard model the preferred Quest 3/OpenCL choice.
3. Retain the hybrid temporarily as a compatibility fallback.
4. Update Auto only after failure and performance behavior are verified.
5. Regenerate 256 and rectangular variants only after the 384 baseline is
   accepted.
6. Update model documentation, diagnostics, release packaging, and tests.

## Fallback: train a new mobile-safe head

Use `zipdepth-sharp-mobile-head.md` only if the standard head cannot be made
both correct and efficient on LiteRT GPU. Begin with head-only distillation
from vanilla ZipDepth and DA-V2 Large, use Marigold selectively on difficult
boundaries, and unfreeze the backbone only if head-only training is
insufficient.

Training is not the next step while an exact pretrained solution remains
viable.
