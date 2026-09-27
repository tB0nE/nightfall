# ZipDepth Standard and Direct profiling plan

Status: Active

## Objective

Explain the latency and quality difference between ZipDepth Standard-v1 and
Direct-192, then use that evidence to pursue two related targets:

1. Keep Standard-v1's learned subpixel edge reconstruction while reducing its
   approximately 39 ms Quest OpenCL inference time.
2. Make Direct-192 faster than its approximately 18 ms baseline without
   discarding the half-resolution detail that makes it visibly better than the
   existing Hybrid heads.

Standard-v2, Standard-v3, Hybrid-v1, and Hybrid-v2 remain useful experiment
records, but they are no longer candidate production models. Standard-v1 is
the quality baseline and Direct-192 is the performance baseline.

## Current architecture boundary

```text
384x384 RGB
  -> encoder
  -> neck and FPN decoder
  -> half-resolution feature fusion (`f_half`)
  -> 192x192 depth prediction (`depth_half`)       [Direct-192 ends]
  -> learned 9-neighbour x 4-subpixel masks
  -> softmax
  -> convex weighted reconstruction
  -> pixel shuffle to 384x384                      [Standard-v1 ends]
  -> Nightfall final 480x270 reconstruction
```

Direct-192 already omits every operation used exclusively by the convex
upsampler. Its remaining `f_half` computation is shared: it supplies the
features used to predict `depth_half`, so it cannot be removed losslessly.

The abandoned depth-only Direct-v2 filter remains a useful negative result.
It was numerically close to Standard but looked little different from
bilinear interpolation because depth alone cannot locate a boundary within a
coarse source pixel. Nightfall's existing colour-guided Direct reconstruction
looked better and remains the visual baseline.

## Profiling ladder

Profile one Standard model as a sequence of dependency-preserving probes. The
Direct boundary is an explicit stage in the same ladder.

1. Encoder output.
2. Neck and FPN decoder through `f1`.
3. Half-resolution fusion through `f_half`.
4. Final 3x3 half-depth prediction (`depth_half`, current Direct-192).
5. Convex mask prediction (36 logits per half-resolution pixel).
6. Softmax over each nine-neighbour mask.
7. Neighbour extraction and weighted subpixel reduction.
8. Pixel shuffle / final Standard-v1 output.

Diagnostic probes must retain all intended dependencies so ONNX/TFLite cannot
prune the stage being measured. Where practical, finish each probe with a
fixed cheap projection to the same 192x192x1 output to reduce output-transfer
bias. Record graph operation counts and intermediate tensor sizes alongside
latency.

## Local measurements

Run every stage through both local paths:

- Exact converted TFLite with XNNPACK CPU: stable stage deltas and converted
  graph behavior.
- Matching PyTorch model with CUDA events and `torch.profiler` on the RTX
  3090: GPU kernel, convolution, reduction, layout, and memory-cost evidence.

Neither backend predicts Quest OpenCL directly. Existing measurements already
show why: desktop CPU reports only about a 6 ms Standard-minus-Direct delta,
while Quest OpenCL reports roughly 21 ms. Local results are for narrowing the
search and validating candidate graphs, not accepting a production winner.

Use warm-up iterations, at least 100 measured iterations for small probes,
median/p90/p99, fixed 384x384 input bytes, and synchronized CUDA timing.

## Automated Quest validation

After local profiling removes poor candidates, benchmark the survivors on the
Quest without requiring an interactive stream or headset wear:

1. Load each TFLite model with the same LiteRT OpenCL delegate configuration
   as Nightfall.
2. Warm the model and delegate kernels.
3. Run a fixed captured input for repeated iterations.
4. Save median, mean, p90, p99, delegate initialization time, and model output
   statistics to a log retrievable over ADB.
5. Compare the same output bytes against desktop TFLite to catch delegate
   correctness errors.

Only this automated Quest result can establish an Adreno performance win.

## Decision tree

### Direct optimization

- If half-resolution fusion and `head_half` are material, train a compact
  Direct-fast tail. First try reducing `f_half` from 32 channels to 16 while
  retaining both shallow spatial and deep semantic inputs.
- Distil from Standard-v1/Direct-v1 half-depth and add multi-scale gradient
  supervision so speed does not come from erasing fine edges.
- If the shared tail is already cheap, meaningful further gains require
  structured pruning/distillation of the encoder or FPN into a ZipDepth-Tiny
  student. Do not remove `f_half` blindly.

### Standard optimization

- If mask prediction is cheap but reconstruction is expensive, preserve the
  learned masks and replace only the delegate-hostile softmax/neighbour/
  reduction layout.
- If mask prediction itself is expensive, distil it into a compact learned
  subpixel decision head (for example four compact decisions rather than 36
  logits).
- If pixel shuffle is costly, test an equivalent verified depth-to-space or
  direct final-layout graph.
- Keep Standard-v1 as the quality teacher. A candidate may accept a small
  quality loss only if fine boundaries remain materially better than Hybrid.

## Acceptance criteria

- Every candidate is compared at raw model output and after Nightfall's final
  480x270 reconstruction.
- Quality review includes fixed desktop, game, film, foliage, hair, fence,
  text, and flat-surface frames; scalar MAE cannot overrule visible quality.
- No colour-guided change may turn text or texture into false geometry.
- Desktop TFLite and Quest output must be numerically coherent.
- Production selection requires stable stream frame pacing, not inference
  latency alone.
- Experimental model assets and menu entries are removed from release builds
  only after the profiling record and useful conversion recipes are retained.

## Initial local results (2026-09-25)

The fused GPU-safe Standard checkpoint was profiled at 384x384. These results
describe local architectural cost and do not replace Adreno OpenCL timing.

### RTX 3090, PyTorch FP16 CUDA

- End-to-end Direct-192: 1.503 ms median.
- End-to-end Standard-v1: 1.812 ms median.
- Shared Direct tail: `fuse_half` 0.147 ms + `head_half` 0.068 ms.
- Standard mask prediction: 0.058 ms.
- Standard softmax: 0.022 ms.
- Neighbour extraction, weighted reduction, and pixel shuffle combined:
  approximately 0.082 ms in isolated measurements.

The complete Standard reconstruction adds only about 0.31 ms on a backend
that handles the graph well. This confirms that Standard's approximately
21 ms Quest penalty is not explained by arithmetic alone.

### Exact TFLite, one-thread XNNPACK CPU

The cumulative probe medians were:

| Boundary | Median |
|---|---:|
| FPN through `f1` | 48.03 ms |
| Half-resolution fusion | 51.73 ms |
| Direct-192 output | 53.42 ms |
| Mask prediction | 56.28 ms |
| Mask softmax | 59.62 ms |
| Weighted reconstruction | 60.51 ms |
| Full Standard-v1 | 61.43 ms |

Approximate cumulative deltas:

- Shared Direct tail after `f1`: 5.39 ms, of which half fusion is about
  3.70 ms and the final half-depth prediction about 1.69 ms.
- Mask prediction: 2.86 ms.
- Mask reshape/softmax path: 3.34 ms.
- Weighted reconstruction: 0.89 ms.
- Final pixel shuffle/ReLU/output: 0.92 ms.

Mask prediction plus the mask-softmax/layout path account for roughly 78% of
Standard's local 8.01 ms penalty over Direct. The 37-channel mask probes have
larger natural outputs than Direct, so their deltas include unavoidable tensor
materialization and should be treated as cumulative boundaries rather than
perfect isolated kernel timings.

Standard-v2 measured effectively equal to Standard-v1 on XNNPACK and
Standard-v3 was slower, matching the on-device decision to retire both as
candidate models.

### Immediate interpretation

- Direct has a real but bounded optimization target: its shared high-resolution
  tail is about 10-14% of local end-to-end time. A 32-to-16-channel distilled
  tail is worth testing, but cannot produce a dramatic speedup by itself.
- Standard's first optimization target is the learned mask path, especially
  its 36-channel materialization, layout changes, and softmax. Rewriting the
  later weighted reconstruction alone cannot recover most of the lost time.
- The staged TFLite models are ready for an automated Quest OpenCL benchmark;
  that result will determine whether Adreno magnifies mask prediction,
  softmax/layout operations, or both.

## Automated Quest runner

An opt-in release diagnostic runner now exists for the staged models. Setting
`NIGHTFALL_INCLUDE_DEPTH_PROFILE_MODELS=1` while building bundles the five
additional probe assets; normal release builds omit them. A separate one-shot
`depth_profile_<stage>` marker in Nightfall's external-files directory starts
one background benchmark after launch, then deletes itself. Each model uses
the same LiteRT sustained-speed OpenCL delegate configuration as Nightfall,
runs 10 warm-up and 50 measured iterations, and records initialization time
plus median/mean/p90/p99. A `PROFILE_BEGIN` breadcrumb and the result are
fsynced to external app storage so a headset reboot identifies the active
stage. No menu or stream interaction is required.

The original all-model runner rebooted the Quest 3 and left no pre-reboot
logcat history. Running one model per process eliminated that instability and
completed all seven probes.

## Quest 3 OpenCL results (2026-09-25)

| Cumulative boundary | Median | Delta |
|---|---:|---:|
| FPN through `f1` | 16.552 ms | - |
| Half-resolution fusion | 17.434 ms | +0.882 ms |
| Direct-192 output | 17.620 ms | +0.186 ms |
| Mask logits | 20.105 ms | +2.485 ms |
| Mask softmax | 34.578 ms | +14.473 ms |
| Weighted reconstruction | 34.150 ms | within run variance |
| Full Standard-v1 | 43.673 ms | +9.523 ms versus weighted |

The Direct tail is not a worthwhile graph-only optimization target: everything
after `f1` adds only about 1.07 ms. Standard's mask convolution is also
reasonable. The clear delegate-specific bottlenecks are:

1. Softmax over the 192x192x9 neighbour dimension for four subpixels, costing
   about 14.5 ms on Adreno OpenCL versus 3.3 ms on one-thread XNNPACK.
2. Final four-channel-to-384x384 reconstruction, nominally pixel shuffle plus
   ReLU, costing about 9.5 ms on Adreno despite preserving the same element
   count as its 192x192x4 input.

The next lossless experiments should isolate `DEPTH_TO_SPACE` from ReLU and
replace it with equivalent reshape/transpose layouts supported efficiently by
the delegate. In parallel, test mathematically equivalent softmax formulations
or move normalization to a lower-cost representation. Any rewrite must retain
the Standard-v1 output within the existing equivalence tolerance before it is
benchmarked on Quest.

### Live-stream correction and packed output experiment

The isolated runner overstates the practical final-layout saving. During an
actual 72 Hz stream at a 20 Hz depth cap, Standard-v1 invoked at approximately
38 ms and the lossless packed-output candidate invoked at approximately
35-37 ms. Moving pixel shuffle/ReLU out of TFLite therefore saves only about
2-3 ms in the real workload. Packed remains mathematically exact, but this is
not enough to make Standard competitive with Direct-192 at approximately
15-17 ms. The 9.5 ms cumulative harness delta must not be presented as the
expected live-stream gain.

The same session also produced a full headset reboot while switching from
Packed back to Standard-v1. The persisted log ends during creation of the new
OpenCL delegate, after the asset/backend message but before `model loaded`;

both models had run stably before the switch. Model switching now pauses frame
submission, closes the prior delegate on its owning inference thread, waits
750 ms for Qualcomm OpenCL resources to quiesce, and only then permits the new
delegate to compile.

### Lossless Softmax4 result

The next candidate reorders the final learned mask-convolution channels from
neighbour-major (`n * 4 + subpixel`) to subpixel-major (`subpixel * 9 + n`).
It replaces the five-dimensional transpose/softmax path with four ordinary
NHWC 9-channel softmax branches and retains Android's packed-output unpacking.
The weights are only permuted; no model values are trained or approximated.

Deterministic local TFLite validation against Standard-Packed measured exactly
zero output error (`max=0`, `mean=0`, correlation `1.0`). Four-thread XNNPACK
median improved from 20.90 ms to 19.69 ms. In isolated Quest 3 OpenCL runs from
the same release APK:

| Candidate | Median | p90 | Delegate summary |
|---|---:|---:|---|
| Standard-v1 | 43.404 ms | 46.350 ms | GPU 105/223 nodes, 3 partitions |
| Standard-Softmax4 | 32.144 ms | 32.959 ms | GPU 110/211 nodes, 3 partitions |

This is a lossless 11.26 ms / 25.9% isolated improvement over Standard-v1 and
about 2 ms faster than the earlier weighted/packed boundary. The graph still
has three GPU partitions and three XNNPACK partitions, so residual delegate
handoffs remain. A live-stream comparison is still required; the prior Packed
experiment established that isolated savings overstate the real stream gain.

Next investigation: identify which operations separate the three GPU
partitions. Prefer exact rewrites which keep the four 9-way softmaxes and
packed output. Do not spend further time on rapid model-switch stability unless
it also reproduces during normal one-model usage.

Two further exact tail rewrites improved this result:

| Candidate | Median | Change from Standard-v1 |
|---|---:|---:|
| Standard-Softmax4 | 32.144 ms | -25.9% |
| Standard-Conv4 | 29.750 ms | -31.5% |
| Standard-Conv4-ReduceConv | 29.202 ms | -32.7% |

Conv4 replaces the final 36-channel 1x1 mask convolution plus `SPLIT` with
four independent 9-channel convolutions containing slices of the same learned
weights. Its TFLite output is bit-identical to Softmax4. ReduceConv expresses
each weighted nine-neighbour sum as a fixed 1x1 convolution of ones; its local
maximum difference is `2.98e-8` (correlation effectively `1.0`). Both still
produce three GPU and three XNNPACK partitions. The best ReduceConv candidate
is exposed in the Android comparison UI as `Standard-Optimized`.

## Full-GPU reconstruction result (2026-09-26)

Per-kernel OpenCL profiling corrected the earlier interpretation. The
optimized packed model spent only about 13.3 ms in GPU kernels but about
29.2-29.9 ms wall-clock. Its graph was split at the unsupported replicate
padding used for neighbour extraction. LiteRT delegated only the largest of
three eligible partitions, then read four 192x192x9 softmax tensors back to
CPU for the final multiply, reduction, and concat. That boundary transferred
approximately 5.06 MiB per inference; the final packed result is only 576 KiB.

The production candidate now expresses neighbour extraction as a padded
`CONV_2D`, using zero padding at the outer boundary. LiteRT 1.4.2 delegates
all 217 operations in one OpenCL partition and reads back only the packed
192x192x4 result.

Quest 3 release benchmark:

| Candidate | GPU partition | Median | p90 |
|---|---:|---:|---:|
| Previous Standard-Optimized | split | ~29.2 ms | - |
| Standard Full-GPU (instrumented delegate) | 217/217 | 17.660 ms | 19.073 ms |
| Standard Full-GPU (production delegate) | 217/217 | 17.579 ms | 19.570 ms |

Against the previous optimized model, a deterministic local TFLite comparison
reported zero difference throughout the entire interior. Differences are
limited to the outermost one-pixel border: whole-output mean absolute error
0.00003964, RMSE 0.0004854, maximum 0.03296.

Initializing this candidate while AI 3D and the stream started together caused
a headset-level reboot. Android retained no kernel panic, tombstone, or
watchdog entry—only a generic `reboot` reason. A subsequent test connected the
stream with AI 3D disabled, waited for playback to settle, and then enabled the
same model successfully. The full-GPU candidate is therefore restored to the
experimental `Standard-Optimized` slot for delayed-enable testing; it must not
become an automatic startup choice until initialization is made safe.

Direct-192 is already exactly the Standard graph cut at `depth_half`, before
all four optimized reconstruction branches. Export pruning removes the mask
predictor, softmax, neighbour extraction, reduction, and packed output, so a
separate "Direct optimized" export would duplicate the existing model. Local
four-thread XNNPACK measured Direct at 15.123 ms versus 17.277 ms for Full-GPU
Standard. On Quest OpenCL, however, the existing cumulative measurements were
17.620 ms for Direct and 17.579 ms for Full-GPU Standard, while prior live
Direct invocations ranged from approximately 14.7 to 16.9 ms. The fully
delegated reconstruction tail is therefore effectively hidden by the shared
GPU workload; further Direct gains require optimizing the encoder/decoder
trunk rather than removing more of the output head.

The attempted FP16 model-output route was discarded. The normal converter
restored FP32 I/O, while the direct-flatbuffer route also changed input type
and layout. More importantly, eliminating the accidental intermediate
readbacks recovered the desired performance without changing the public
tensor ABI.

## Final model decision (2026-09-27)

The initial three-tier decision was superseded after comparing the actual
full-screen warp in-headset. Raw and 480x270 comparison images made Direct-192,
Direct-128, and Hybrid-256 look competitive, but their coarse displacement
fields produced obvious blockiness at viewing size. Guided 5x5 reconstruction
and a zero-extra-pass linear offset-sampling experiment softened the grid but
could not restore geometry discarded with the learned reconstruction head.

Only two Android production models remain:

- EdgePad-384: exact full head with hardware-linear conversion. A broad
  scale-matched 5x5 guided retest looked blocky, while a conservative four-tap
  guided-linear pass produced practically no visible gain for substantially
  more shader work. Both were rejected for production.
- EdgePad-256: the same full-head graph at 256 input/output with the same
  hardware-linear production conversion.

The retained temporal change restores Moonlight Android XR's temporal intent with
cadence-independent equivalents: 0.055-second depth tau and 0.308-second range
tau. `DMap-Final` now displays the exact native production map used to judge
these experiments.

Auto selects EdgePad-384/OpenCL on Quest 3/3S and EdgePad-256/OpenGL on Quest
2; failed Quest 3/3S OpenCL initialization also falls back visibly to
EdgePad-256/OpenGL. The Direct and Hybrid exports remain profiling references
but are neither selectable nor bundled. The full latency table, resizing and
widescreen comparisons, final-warp diagnosis, and retained model inventory are
consolidated in `docs/guides/zipdepth-quest-tiers.md`.
