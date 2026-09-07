# ZipDepth sharp mobile head plan

Status: proposed experiment; no runtime or production-model changes yet.

## Objective

Develop a sharper ZipDepth output head that retains the current model's speed
and numerical correctness on the Quest 3 LiteRT GPU delegate. The target is to
close as much of the visible boundary-detail gap to Depth Anything V2 (DA-V2)
as possible without adopting DA-V2's much larger transformer runtime.

The first target shapes are:

- 384x384, as the production baseline.
- 512x288, as the preferred widescreen model at approximately the same input
  pixel count as 384x384.
- 672x384, as the higher-quality experimental model.

The project should produce one convolutional checkpoint that can be exported
as separate static-shape TFLite models where practical. Separate fine-tuned
checkpoints should only be introduced if mixed-shape training demonstrably
loses quality.

## Why this is worth testing

The currently deployed hybrid model uses the standard ZipDepth checkpoint for
the encoder, decoder, and half-resolution depth head, but uses the NPU
checkpoint's unfold-free final upsampler. This is necessary because the
standard convex upsampler uses `torch.nn.Unfold`, softmax, and pixel shuffle in
a form that is poorly suited to the Android LiteRT GPU delegate.

The unfold-free head predicts one alpha map and blends two enlargements of the
same half-resolution scalar depth map:

```text
nearest = resize_nearest(depth_half)
bilinear = resize_bilinear(depth_half)
output = alpha * nearest + (1 - alpha) * bilinear
```

This head can select between a blocky and a smooth reconstruction, but it
cannot give the four pixels in each 2x2 output cell independently learned depth
residuals. Increasing the input resolution helps the backbone see more detail,
but the final head still discards some subpixel boundary information.

DA-V2 and MiDaS both perform learned spatial refinement at or near their final
output resolution. The proposed head gives ZipDepth a lightweight equivalent
without adding a large full-resolution feature decoder.

## Scope and non-goals

This work will:

- Replace only the final mobile upsampling head initially.
- Reuse the working standard-backbone/NPU-head hybrid checkpoint.
- Distil from DA-V2 Large pseudo depth, as upstream ZipDepth does.
- Add explicit high-frequency depth supervision.
- Preserve the existing Adreno-safe export graph transformations.
- Validate numerical correctness using identical raw inputs on desktop and
  Quest, not merely LiteRT's compatibility report.

This work will not initially:

- Reproduce ZipDepth's original 14.1-million-image training run.
- Retrain the backbone from random initialization.
- Add an image-space sharpening filter after inference.
- Use RGB edges directly as a substitute for depth supervision; doing so can
  turn text and texture into false geometry.
- Change Nightfall's temporal smoothing or stereo-warp post-processing until
  the raw model comparison is complete.

## Proposed architecture

### Version A: subpixel residual head

This is the first implementation because it has the best balance of
expressiveness, portability, and cost.

Inputs:

- `f_half`: the existing half-resolution decoder feature map, currently 32
  channels in the base model.
- `depth_half`: the existing one-channel half-resolution prediction.

Proposed computation:

```text
base = resize_bilinear(depth_half, scale=2)

features = conv_3x3(f_half, hidden=32)
features = relu(features)
features = depthwise_conv_3x3(features)
features = relu(features)
residual_4 = conv_1x1(features, channels=4)
residual = depth_to_space(residual_4, block_size=2)

output = relu(base + residual_scale * tanh(residual))
```

The last convolution is initialized to zero. The new model therefore starts
as an exact bilinear-upsample baseline rather than producing random depth. Each
of the four output subpixels receives an independent learned residual, allowing
the head to position an edge within a 2x2 cell.

`residual_scale` should start as either a small fixed value or a learned scalar
with a conservative initialization. Its purpose is to prevent the randomly
introduced head from overwhelming the already useful half-resolution depth.
The need for `tanh` should be measured: omitting it produces a simpler graph,
but bounded residuals may stabilize head-only training.

Expected operator set:

- `CONV_2D`
- `DEPTHWISE_CONV_2D`
- `RELU` (and optionally `TANH`)
- `RESIZE_BILINEAR`
- `DEPTH_TO_SPACE`
- same-shaped `ADD`/`MUL`

All tensors involved in element-wise operations must have identical explicit
shapes. The exporter must not rely on implicit spatial broadcasting, because
that previously produced numerically incorrect ZipDepth output on the Quest 3
Adreno OpenCL delegate.

### Version B: gated subpixel residual

Only test this if Version A produces overshoot, noisy edges, or unstable flat
surfaces. Predict four residual channels and four confidence channels at half
resolution, transform both with depth-to-space, then compute:

```text
output = relu(base + sigmoid(confidence) * residual_scale * tanh(residual))
```

This costs one additional small output projection. It lets the model preserve
the bilinear base in uncertain regions while using residual refinement at
teacher-supported boundaries.

### Version C: full-resolution refinement

Only test this after profiling Version A. Run a small depthwise 3x3 plus
pointwise 1x1 convolution after depth-to-space. This most closely resembles
the high-resolution refinement used by MiDaS and DA-V2, but it consumes
full-resolution bandwidth and could be disproportionately expensive on Quest.

Version C is accepted only if its visible and measured quality improvement is
material and it does not reduce stream stability.

## Phase 0: freeze a trustworthy baseline

Before training, capture the current results so an attractive-looking model
cannot hide a regression.

1. Select a fixed evaluation corpus containing:
   - Windows and Linux desktops with text, windows, icons, and overlapping UI.
   - Games with characters, weapons, foliage, railings, and particle effects.
   - Film/video frames with people and natural scenes.
   - Difficult boundaries such as hair, cables, chair legs, fences, and
     transparent or reflective objects.
   - A small general-purpose subset from NYUv2, KITTI, DIODE, ETH3D, or
     ScanNet where licensing and local availability permit.
2. Keep a separate held-out test set that is never sampled during training.
3. Save outputs from:
   - Current ZipDepth hybrid at 384x384.
   - Current ZipDepth hybrid at 512x288 and 672x384.
   - Standard ZipDepth convex head on desktop.
   - NPU-only ZipDepth.
   - DA-V2 Small/appropriate Nightfall references.
   - DA-V2 Large teacher.
   - MiDaS-192.
4. Record desktop inference time, raw output statistics, parameter count, and
   operation count.
5. Record Quest inference latency and Nightfall application FPS using the
   current low-priority LiteRT context.

Baseline metrics should include:

- Scale-and-shift invariant L1 or RMSE.
- Gradient error at full, half, quarter, and eighth resolution.
- Boundary precision/recall or boundary F1 against teacher depth edges.
- Edge-transition width: how many pixels a strong depth discontinuity takes to
  move between its two plateau values.
- Flat-region noise and false-edge rate.
- Temporal output consistency on a fixed video clip.

Generic gradient energy alone is not a sufficient sharpness metric: noise can
score highly while looking worse. Every numerical result must be accompanied
by fixed visual comparisons using the same normalization.

Decision gate: do not start a large training run until a head-ablation on
desktop shows that the standard convex head is materially sharper than the
current unfold-free head on the held-out Nightfall corpus.

## Phase 1: implement and export an untrained proof

1. Add a new upsampling mode to ZipDepth rather than replacing the upstream
   NPU mode.
2. Implement Version A with a zero-initialized final projection.
3. Add shape tests for 384x384, 512x288, and 672x384.
4. Verify that the zero-initialized PyTorch output equals the bilinear baseline
   within floating-point tolerance.
5. Export through ONNX and TFLite before training.
6. Confirm that all operations are accepted by the LiteRT GPU compatibility
   analyzer.
7. Run the untrained model on Quest and compare raw GPU output with desktop
   TFLite CPU output using the same captured input.

This early deployment prevents spending days training a head that later turns
out to contain an unusable or incorrectly computed delegate operation. If
`DEPTH_TO_SPACE` is problematic, fall back to four explicit channel slices and
concatenation only after testing their delegate cost and correctness. Do not
silently substitute a CPU operation.

## Phase 2: prepare a focused distillation dataset

The upstream training corpus contains approximately 14.1 million images across
17 domains. Reproducing it is unnecessary for a head experiment and
impractical on one workstation. Start with a targeted corpus:

### Proof dataset

- 5,000-20,000 RGB images.
- At least half should resemble Nightfall's actual inputs: desktop capture,
  streamed games, video, application UI, and mixed text/3D content.
- Fill the remainder with diverse public images to reduce catastrophic
  specialization.

### Serious fine-tuning dataset

- 50,000-200,000 images if the proof succeeds.
- Balance screen/UI, games, people/indoor, outdoor, and fine-structure scenes.
- Deduplicate adjacent video frames aggressively; thousands of nearly
  identical frames provide much less value than diverse scenes.

Generate pseudo-depth with DA-V2 Large at a resolution at least as high as the
largest student target. Preserve the source aspect ratio. Store depth in
float16 `.npy` files, or another lossless representation whose precision is
verified against float32. Avoid JPEG for depth labels.

Pseudo labels should be created once and cached. Training DA-V2 Large jointly
with the student would waste most of the 3090's memory and recompute identical
targets every epoch.

Split by source video/game/scene rather than individual frames. Otherwise
adjacent frames can leak between training and validation and make the results
look much better than they generalize.

## Phase 3: losses

Retain upstream ZipDepth's scale-and-shift invariant loss and multi-scale
gradient loss as the base objective. Add detail terms incrementally so their
effect can be isolated.

Recommended starting objective:

```text
L = 1.0 * L_SSI
  + 2.0 * L_multiscale_gradient
  + 1.0 * L_edge_weighted_gradient
  + 0.25 * L_laplacian
```

Where:

- `L_edge_weighted_gradient` weights prediction-gradient errors more heavily
  where the teacher depth has a strong gradient.
- `L_laplacian` compares second derivatives and discourages excessively wide,
  rounded transitions.
- Edge weights are derived from teacher depth, not RGB texture.
- Robust Charbonnier penalties may replace raw L1 if isolated pseudo-label
  artifacts dominate training.

Run an ablation for each added loss. A sharp model that invents depth edges on
text or produces ringing is a regression, even if boundary recall rises.

## Phase 4: staged training

Use the current hybrid checkpoint as initialization.

### Stage A: head-only proof

- Freeze the encoder, decoder fusion, `fuse_half`, and `head_half`.
- Train only the new subpixel residual head.
- Use 384x384 or 512x288 initially.
- Start around 2,000-10,000 optimization steps.
- Use BF16 mixed precision on the RTX 3090.
- Save frequent checkpoints and fixed visual samples.

Purpose: determine whether `f_half` already contains enough boundary
information for the new head to recover it. If it does not, a larger head alone
will not solve the problem.

### Stage B: half-resolution decoder adaptation

- Unfreeze `fuse_half`, `head_half`, and the new head.
- Give new head parameters the base learning rate and pretrained parameters a
  10x lower rate.
- Train roughly 10,000-30,000 additional steps.
- Monitor flat-region stability and general-domain validation closely.

Purpose: allow half-resolution features and depth to reorganize around the new
subpixel output rather than forcing the head to undo the old NPU objective.

### Stage C: decoder fine-tune

- Unfreeze the remaining decoder at another reduced learning rate.
- Keep the encoder frozen initially.
- Train roughly 20,000-50,000 steps on the larger dataset.

Only unfreeze the final encoder stage if validation plateaus and the decoder
still lacks information visible in DA-V2. Full-backbone fine-tuning carries the
greatest risk of losing ZipDepth's broad zero-shot generalization.

### Resolution schedule

Start at 384x384 because that matches upstream training. Once stable:

1. Fine-tune on 512x288 batches.
2. Add 672x384 batches.
3. Alternate complete batches of one shape; tensors within a batch must share
   a shape.
4. Include some 384x384 batches so the production baseline does not regress.

Use one shared checkpoint first. Static TFLite files can still be exported for
each input shape. Compare it against short shape-specific fine-tunes only after
the shared model is working.

## Phase 5: desktop evaluation and selection

For every candidate checkpoint:

1. Run the fixed model tester corpus with identical visualization ranges.
2. Compare against the current hybrid, standard convex ZipDepth, MiDaS, and
   DA-V2.
3. Generate difference maps against DA-V2 Large.
4. Report all Phase 0 metrics separately for screen/UI, game, video, and
   general-image subsets.
5. Inspect failure cases rather than selecting by an aggregate score alone.
6. Reject candidates with halos, ringing, texture-copy artifacts, unstable
   flat surfaces, or worse foreground/background ordering.

The standard convex ZipDepth result is a useful practical ceiling for a new
head using the existing backbone. Matching it with mobile-safe operations is a
strong success even if DA-V2 remains sharper.

## Phase 6: TFLite and Quest validation

Run the complete conversion ladder for each selected shape:

1. PyTorch candidate versus PyTorch reference.
2. ONNX versus PyTorch on several real inputs.
3. Desktop TFLite CPU versus ONNX.
4. TFLite GPU compatibility analysis.
5. Quest raw GPU output versus desktop TFLite CPU using identical input bytes.
6. Long-running live stream test for numerical drift, delegate failures, and
   thermal throttling.

Reuse the explicit-attention-map and staged-reduction rewrites documented in
`doc/zipdepth-quest-gpu.md`. Treat a single delegated kernel as necessary but
not sufficient evidence; numerical comparison is mandatory.

Initial correctness thresholds should be at least as strict as the current
working hybrid:

- Correlation greater than 0.99999 between Quest GPU and desktop TFLite CPU.
- No scene-independent gradients, stripes, quadrant seams, or spatially
  repeated corruption.
- Error magnitude consistent with normal float16-weight execution.

Performance acceptance should be measured in the real application, not only a
standalone benchmark:

- 384x384 and 512x288 should preserve 20 Hz depth scheduling and 90 FPS stream
  presentation under the low-priority OpenCL context.
- Added head latency should ideally stay within 1-2 ms at equal pixel count.
- 672x384 should be judged against its explicit quality/performance preset; it
  must not silently lower stream FPS.
- Record inference prepare, invoke, post-process, upload, app FPS, video FPS,
  dropped frames, GPU level, and headset temperature.

## Phase 7: Nightfall integration

Only after a model passes desktop and Quest validation:

1. Add it as an experimental model option rather than replacing the production
   ZipDepth model immediately.
2. Keep the current hybrid available for direct A/B testing.
3. Do not change temporal smoothing, depth normalization, separation, or
   convergence defaults during the model comparison.
4. Add model metadata describing training shape, teacher, head version,
   checkpoint hash, export command, and conversion-tool versions.
5. Run repeated real-world tests before promoting a candidate to the default.

## RTX 3090 hardware assessment

An RTX 3090 with 24 GB VRAM is sufficient for this project as scoped.

It is well suited to:

- Generating cached DA-V2 Large pseudo labels in FP16/BF16.
- Head-only and decoder fine-tuning of the approximately 6.1-million-parameter
  ZipDepth base model.
- Training 384x384, 512x288, and 672x384 with a batch size chosen from an
  empirical memory probe.
- ONNX/TFLite conversion and desktop reference testing.

Do not copy upstream's batch size of 96 blindly. Begin with conservative
per-GPU batches and increase until peak allocated VRAM remains below roughly
21-22 GB, leaving room for CUDA/compiler workspaces. Likely starting points are:

| Training shape | Conservative starting batch | Adjustment |
|---|---:|---|
| 384x384 | 16 | Increase if full training step stays below the VRAM target. |
| 512x288 | 16 | Similar pixel count to 384x384. |
| 672x384 | 8 | Use gradient accumulation if a larger effective batch helps. |

These are starting estimates, not promises: PyTorch version, compiled graphs,
optimizer state, frozen layers, and loss implementation materially affect
memory. Add a small script that runs a complete forward/backward/optimizer step
and prints `torch.cuda.max_memory_allocated()` before fixing batch sizes.

Recommended supporting hardware:

- 32 GB system RAM minimum; 64 GB recommended for cached labels and multiple
  data-loader workers.
- Fast NVMe storage. A 50,000-200,000-image experiment can consume tens to
  hundreds of GB once RGB data, float16 depth, checkpoints, and comparisons are
  included.
- 200 GB free is a workable proof-stage target; 500 GB or more is more
  comfortable for the serious dataset.
- Adequate GPU cooling for sustained multi-hour or multi-day runs.

Very approximate single-3090 expectations:

- Architecture/export/device proof: less than a day once implemented.
- 5,000-20,000-image pseudo-label and head-only experiment: hours, not weeks.
- 50,000-200,000-image staged fine-tune with several ablations: roughly one to
  several days depending on storage speed, step count, and how many candidates
  are tested.
- Reproducing the original 14.1-million-image, five-epoch distillation run:
  inappropriate for this workstation-scale project; it implies enormous data
  acquisition/storage and multi-GPU-scale compute.

The 3090 is therefore not the limitation for establishing whether the head
works. Dataset quality, teacher-label generation, disciplined evaluation, and
Quest delegate correctness are more likely to determine success.

## Suggested implementation commits

Keep the work reviewable and reversible:

1. `docs: define ZipDepth sharp-head baselines and evaluation protocol`
2. `model: add zero-init mobile subpixel residual head`
3. `test: validate sharp-head shapes and export operators`
4. `training: add edge-weighted and Laplacian distillation losses`
5. `training: add mixed-shape schedule and head-first fine-tuning config`
6. `tools: export sharp ZipDepth through the Adreno-safe conversion path`
7. `test: add desktop and Quest raw-output comparison report`
8. `app: expose validated sharp ZipDepth models as experimental choices`
9. `docs: record checkpoint provenance and reproduction commands`

Training checkpoints, downloaded datasets, pseudo labels, ONNX intermediates,
and generated TFLite binaries should remain out of Git unless the repository's
release policy explicitly says otherwise. Scripts, configs, hashes, metrics,
and representative comparison images are the reproducible source of truth.

## Go/no-go checkpoints

Stop or change direction when any of these gates fail:

1. **Architecture gate:** Version A must export and execute correctly on Quest
   before training.
2. **Information gate:** head-only training must improve held-out boundaries;
   otherwise `f_half` lacks recoverable detail and the decoder must be adapted.
3. **Quality gate:** improvements must survive held-out general imagery and
   avoid texture-copy artifacts.
4. **Runtime gate:** the model must remain fully delegated and preserve the
   chosen stream-performance target.
5. **Value gate:** if Version A approaches the desktop standard convex head,
   stop adding complexity unless DA-V2 comparisons show a meaningful user-
   visible gap worth the cost.

The first deliverable should therefore be a small, deployable, zero-initialized
Version A model—not a large dataset download or a full training run. It tests
the most important technical assumption at the lowest cost.
