# RX480 VDA performance investigation

The CPU pipeline bottleneck identified below is now being addressed separately in
[Vulkan frame processing](meteor-vulkan-frame-processing.md). Historical timings
here remain the baseline before that work; the model graph itself is unchanged.

Branch: `feat/meteor-xr-streaming`. The original experiments left Meteor unchanged;
production integration is now recorded below. See also [the Vulkan investigation](meteor-vda-vulkan.md).

## Production integration — 2026-10-26

The persistent Vulkan runner is now integrated into Meteor as an optional native
library (`meteor/native/vda_vulkan.cpp`, `meteor/src/vda_vulkan.rs`). Both sizes
use explicit manifests and shared probe kernels; the combined GPU/model menu
selects a complete configuration with one queued reload. Legacy NVIDIA TensorRT
remains available. CPU offers EdgePad only. See `meteor/README.md` for staging,
packaging and current validation limits.

This supersedes historical statements below saying all changes are tools-only.
The earlier measurements remain standalone graph timings, not live stream times.

### Integrated runner validation

- Rust regression suite: 131 passed, 12 opt-in tests ignored.
- Persistent production FFI: both sizes on RX480 and RTX3090, 80 frames each,
  including history rollover and reset. RX480 depths match its standalone
  reference exactly. NVIDIA's worst per-frame normalized difference from the
  AMD reference is 0.0300% (full) / 0.02375% (Performance).
- Integrated core medians with pre-normalized fixtures, transfers, history and
  validity checks: RX480 80.45 / 45.24 ms; RTX3090 16.21 / 11.90 ms. These
  exclude CPU bicubic preparation, softening and downstream refinement.
- Invalid-state injection is detected; the next valid frame cold-recovers to
  the same GPU's original cold output exactly. A separate shader oracle tests
  seven finite/NaN/infinity half-bit patterns on each GPU. ncnn reflection
  requires the `parameter` block name, all three dispatch dimensions must be
  nonzero, and integer flag transfers use raw FP32-sized storage. Tests caught
  an initially ineffective validity shader before it was accepted.
- AMD VAAPI → CPU preparation → Vulkan VDA → CPU refinement replays produce
  maps at both sizes with **no CUDA library loaded**. However the portable
  720p CPU preparation/refinement path is costly: these runs measured roughly
  327 / 334 ms median frame-to-map latency. Full/Performance model-stage
  medians including preparation/softening were 120 / 71 ms. These are functional
  integration checks, **not low-latency or 20 Hz acceptance**. The replay's
  synchronous decode work can run slower than source time, so output counts
  must not be presented as real-time update rates. CPU pipeline work is now
  the major remaining performance concern; further RX480 tuning stays paused.
- Release binary built; weights/manifests installed in the local Meteor model
  directory. Existing installed AppImage was left running unchanged.
- Windows picker/build/package code is updated. Cross-check was blocked by a
  missing Windows C compiler (Opus dependency); no Windows runtime claim.
  Newer AMD/Intel hardware and live headset switching still need validation.

Logs: `/tmp/meteor-vda-production-parity-verified.log`,
`/tmp/meteor-vda-final-suite.log`, and
`.build-cache/meteor-portable-tests/vda-{full,fast}-integrated.log`.

## Targets clarified by the user

- Original 518×294: approximately 80 ms inference.
- A separate reduced-resolution option: 40–50 ms.
- The prior 420×238 / 76 ms result does **not** complete these targets.

## Confirmed results

Both median-time targets are now met in the standalone self-fed video benchmark:

| Input / run | Model median | Model p95 | Prepare + graph + store median |
| --- | ---: | ---: | ---: |
| Original 518×294, run 1 | 74.59 ms | 77.91 ms | 76.50 ms |
| Original 518×294, run 2 | 74.30 ms | 78.50 ms | 76.31 ms |
| Original 518×294, run 3 | 75.20 ms | 84.91 ms | 76.91 ms |
| Performance 392×224, run 1 | 43.19 ms | 44.27 ms | 44.44 ms |
| Performance 392×224, run 2 | 43.34 ms | 44.87 ms | 44.65 ms |
| Performance 392×224, run 3 | 43.11 ms | 44.29 ms | 44.40 ms |

Do not claim every full-resolution frame finishes below 80 ms: one run's p95
reached about 85 ms. These are inference/core timings with offline input fixtures,
not live decode/network/postprocess/display latency or performance while gaming.
The original-resolution model did not lose input pixels or learned reconstruction.

Final ingredients: fused QKV/spatial attention, padded shared keys, twelve
queries/workgroup, fixed-64-lane subgroup softmax reductions, shared KV packed
as uint words, direct packed-word loads, and ncnn's native subgroup Gemm path
selected by `VDA_PROBE_NO_LOCAL_MEMORY=1`. Keep `use_subgroup_ops` enabled.
The latter is a native kernel-selection change: our slower portable Gemm is
**not** selected. Disabling both local memory and subgroup ops failed pipeline
creation and is not a valid configuration.

The packed words preserve the pre-existing FP16 QKV values. Arithmetic remains
FP32, without FP16 ALU/cooperative matrices, supported on this RX480. Softmax
reduction order and fused-vs-native intermediate rounding differ, so the new
path is not bit-exact to the old implementation. Same-resolution CPU ONNX
references validate each separately:

- 518×294: mean normalized depth MAE 0.14044%, worst frame 0.16402%; temporal
  delta error 0.02495%.
- 392×224: mean normalized depth MAE 0.14769%, worst frame 0.20721%; temporal
  delta error 0.02846%.
- All depth and eight state outputs are finite; all history traces match.
- Each repeat matches all 720 saved output files from its own first run exactly,
  including cache rollover and cold/reset frames.

Four independent attention cases pass at each tested group size, including
partial key/query tiles and strong logits. Matrix tests cover real tagged bias
serialization, padded/odd dimensions, and validate reader consumption; the
MatArray-only tests were insufficient to catch the prototype loader mismatch.

Reports and quality comparison:
`tools/model_tester/output/vda-rx480-optimized-20261026/index.html`, with
`full-resolution/index.html` (previous vs optimized at 518×294) and
`validation/index.html` (392×224 GPU vs its CPU reference). These show raw depth
before Nightfall refinement/warping, with shared colour scales and no hidden
affine fitting. Review smaller-resolution visual quality separately from
conversion-fidelity error; the latter does not measure lost detail.

Full model prefix: `step-amd-scalar-spatial`, cold `cold-repaired`, original
fixture `video-sequence-01`. Performance prefixes are under `res392x224/`:
`step-repaired`, `cold-repaired`; fixture `video-392x224`.
The 392×224 contract is 28×16 patches, state token counts
448/448/112/112/448/448/1792/1792, with unchanged feature widths/checkpoint.

Final flags below add **`VDA_PROBE_NO_LOCAL_MEMORY=1`** to the earlier candidate.
For the small variant also set `VDA_PROBE_WIDTH=392 VDA_PROBE_HEIGHT=224` and
point at its own cold/step graphs and fixture. AMD graph-buffer deferral stays
enabled. No production Meteor defaults, registry, service or headset build was
changed; these candidates are ready for quality review and subsequent integration.

## Original-resolution progress (2026-10-26)

The active candidate preserves the checkpoint, full reconstruction head, 31
history samples and projected-cache selection policy. Native ncnn Gemm is still
used on AMD. TensorCore-specific NVIDIA changes are not involved.

| Stage | Median graph time |
| --- | ---: |
| Prior full-resolution cached + fused LayerNorm reference | 115–118 ms |
| Fused scalar spatial attention, no bank padding | 132.42 ms (rejected) |
| Padded spatial keys, four queries/group | 109.06 ms |
| Eight queries/group | 93.79–94.02 ms |
| Eight queries + subgroup reductions | 88.07 ms |
| Packed shared KV, 64 keys/tile, eight queries | 82.43 ms |
| Direct packed loads, twelve queries | 81.36–81.62 ms |

These are measured standalone model times, not live-stream latency. Preparation
and history work add approximately 1.5–2 ms. Twelve queries is currently the best
tested direct-load setting; ten and sixteen queries were slower. Do not claim
the target is already achieved or substitute reduced resolution for this table.

Changes in `vda_vulkan_spatial_attention.h`:

- Join the three Q/K/V projections, retaining serialized checkpoint weights.
- Pad shared keys to avoid a stride-64 bank-access pattern.
- Reuse each KV tile across more queries.
- Use fixed 64-lane subgroup reductions for softmax maxima/sums instead of
  repeated workgroup-wide reductions. Unsupported subgroup hardware rejects
  the explicit experimental setting.
- Pack existing FP16 KV values into shared uint words and process 64 keys/tile,
  activating all 64 lanes for dot products. Arithmetic stays FP32; no FP16 ALU
  or cooperative-matrix support is required.
- Load packed words directly from the existing FP16 QKV buffer, avoiding
  unpack/repack during staging. This requires the known even-width 384-feature
  QKV layout; the packed option rejects non-FP16 storage.

Focused CPU-oracle attention tests pass for 17/37/778 tokens, partial tiles and
strong logits. Query grouping and key padding alone preserve all 720 saved
outputs exactly. Subgroup reductions / changed key-tile grouping alter FP32
summation order slightly: same-resolution CPU reference error remains about
0.1402% mean normalized MAE, at most 0.1625% worst frame in the tested clip.
Do not call that transformation bit-exact to the original kernel.

Environment for the current full-resolution candidate:

```sh
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
VDA_PROBE_SEQUENCE=1
VDA_PROBE_COLD_PREFIX=.build-cache/vda-vulkan-spike/cold-repaired
VDA_PROBE_RESIDENT=1
VDA_PROBE_PACKING=1
VDA_PROBE_FP16_STORAGE=1
VDA_PROBE_NO_COOPERATIVE_MATRIX=1
VDA_PROBE_FUSED_LAYERNORM=1
VDA_PROBE_SPATIAL_KEY_PAD=1
VDA_PROBE_SPATIAL_QUERIES=12
VDA_PROBE_SPATIAL_SUBGROUP=1
VDA_PROBE_SPATIAL_PACKED64=1
VDA_PROBE_NO_LOCAL_MEMORY=1
```

Use `step-amd-scalar-spatial` (repaired with `--spatial-attention`), the unchanged
`video-sequence-01` fixture and a fresh output directory. Retain graph-buffer
deferral and separate normally reused workspaces. Never set TensorCore flags.

## Rejected matrix prototype

`VDA_PROBE_PORTABLE_GEMM=1` selects a conventional 32×32-output / 64-thread
FP32-accumulating kernel with FP16 storage and reordered weights. It passed
matrix and cache tests but was slower at full-model level: about 112.76 ms
versus 109.14 ms for the comparable padded-attention configuration. Keep it
disabled; do not select it merely because it is tailored to a GPU.

An initial loader used the raw bias format instead of tagged Gemm bias data.
MatArray tests hid that error; full-model CPU-reference comparisons caught it.
The tagged loading was corrected and the matrix test now exercises serialized
weights and verifies reader consumption. Earlier ~50% error runs are invalid,
not performance/quality candidates. Prototype source is `vda_portable_gemm.h`.

## Remaining work

### Final bounded checks — RX480 optimization paused

At the user's request, check matrix multiplication, tensor-layout conversions
and attention once more, then stop RX480 tuning unless a gain is established.
The original 518×294 resolution, checkpoint, reconstruction head and history
contract were retained throughout. These are standalone graph measurements,
not live Meteor latency.

| Final experiment | Model median | p95 | Identical saved outputs |
| --- | ---: | ---: | ---: |
| Selected configuration, opening control | 74.72 ms | 77.65 ms | 720/720 |
| Fixed-shape portable Gemm | 86.25 ms | 88.72 ms | 18/720 |
| Disable packed tensor layouts | 74.75 ms | 77.94 ms | 720/720 |
| Register-shuffle attention scores | 74.39 ms | 76.92 ms | 720/720 |
| Selected configuration, closing control | 76.98 ms | 85.68 ms | 720/720 |

Each run covers 80 distinct self-fed video frames with 71 warmed recurrent
timing samples (frame >=8, resets excluded). All runs exit normally and preserve
the independent reference's history trace. The slower Gemm changes FP32
accumulation ordering and therefore is not bit-identical; its matrix oracles
pass, and independent same-resolution CPU-depth fidelity was checked separately.
Six serialized-weight matrix tests cover real and odd dimensions. Four attention
oracle cases include partial tiles and strong logits; all pass.

**Decision: no new configuration is selected.** The apparent 0.3 ms attention
change is inside the previously measured 74–75 ms range and much smaller than
control-run variation. Disabling packing does not improve throughput. Literal
matrix-shape specialization is slower than ncnn's selected native kernels.
Do not claim these checks prove that all possible layout or attention work is
exhausted; they establish no useful gain from this bounded set of candidates.
Leave the validated original-resolution 74–75 ms and reduced-resolution 43 ms
paths as the current results. The 50 ms original-resolution target is unmet;
further RX480 tuning is paused as requested.

Reproduction: compile `vda_ncnn_probe.cpp` as `probe-final-checks` against the
existing SDK, then run `meteor/tools/benchmark_rx480_final_checks.py --root
.build-cache/vda-vulkan-spike --tag UNIQUE_NAME`. The script refuses to overwrite
existing runs, sanitizes inherited experiment flags, brackets the three cases
with controls, and checks all saved outputs/history against the validated run.
Recorded results: `.build-cache/vda-vulkan-spike/rx480-final-checks-summary.json`;
fidelity: `rx480-final-checks-fixed-gemm-fidelity.json`.

New flags `VDA_PROBE_PORTABLE_GEMM_FIXED_SHAPE` and
`VDA_PROBE_SPATIAL_SHUFFLE_SCORES` are probe-only and disabled by default.
The latter requires FP16 packed KV, a 64-lane arithmetic subgroup and subgroup
shuffle support. It replaces shared score loads with register shuffles without
changing score order or output bits. No production service, defaults, APK or
model files were changed.

### Follow-up: 50 ms original-resolution target

The user has requested investigating **50 ms at unchanged 518×294**, after
meeting the earlier 80 ms target. This needs roughly another 33% reduction
from the validated 74–75 ms result. It is not achieved by the follow-up below.

New full-sequence checks (warmed recurrent frames >=8; reset frames excluded):

| Configuration | Median | p95 |
| --- | ---: | ---: |
| Selected RX480 path, profiling frame excluded | 74.80 ms | 78.49 ms |
| Eight queries instead of twelve | 76.05 ms | 79.42 ms |
| Sixteen queries instead of twelve | 76.34 ms | 78.95 ms |
| Disable tensor storage | 74.64 ms | 78.01 ms |
| Pack shared queries as FP16 uint pairs | 76.22 ms | 82.25 ms |

No candidate establishes a gain over the existing three-run baseline. Keep
twelve queries and the original query representation. The packed-query
prototype remains tools-only behind `VDA_PROBE_SPATIAL_PACKED_QUERY=1`, requires
packed KV/FP16 storage, and is disabled by default. Four CPU-oracle attention
cases passed, but the full-model result is slower despite halving query LDS
storage. Do not promote it to the selected configuration.

A synchronized frame-32 diagnostic attributes about 22.4 ms to the twelve
spatial blocks (inside those: QKV 5.3, attention 12.1, output projection 3.0 ms),
19.2 ms to forty other Gemm calls, 10.4 ms to convolution and 15.3 ms to 102
Reshape calls. These timings include synchronization and surrounding layout
traffic: **do not sum them or treat them as unbiased GPU kernel durations**.
The next substantial investigation should distinguish actual layout-copy cost
from profiler submission overhead, then target dense projections/FFN epilogues
and attention together. Another query-count sweep is not justified.

RTX3090 recheck of the optimized Vulkan path: **14.84 ms median, 17.06 ms p95**,
normal exit, all 720 outputs and history trace exactly match the prior validated
32x32 reference. Configuration: `step-projected-cache`, fused LayerNorm,
`VDA_PROBE_TENSORCORE=1`, `VDA_PROBE_TC_ATTENTION=1`, transposed weights,
32x32/K16 output tiles and `VDA_PROBE_NO_COOPERATIVE_MATRIX=1`. The native ncnn
cooperative-matrix switch is disabled while our explicit cooperative-matrix
kernels remain enabled. This check also used conservative blob deferral.
Initial rechecks omitted parts of this configuration and aborted; their
timings are rejected. The validated recheck is stored in
`video-sequence-01/3090-current-deferred`.

Both vendors use Vulkan and share graph-level optimizations, projected temporal
caches and fused LayerNorm. They do **not** share every fastest shader: NVIDIA
uses cooperative-matrix/Tensor Core kernels, whereas this RX480 uses wave64
FP32 arithmetic with FP16 storage. The RX480's fixed-wave64 attention setting
must not be blindly enabled on newer wave32 AMD or NVIDIA devices. Performance
on newer AMD hardware still needs measurement; this result is not a universal
compatibility or gaming-contention guarantee. Meteor production remains unchanged.

1. Review the raw-depth quality comparison, then integrate a distinct performance
   option without silently replacing the full-resolution default.
2. Implement the production Vulkan VDA runner using the explicit dimensions,
   history contract and guarded allocator; keep TensorRT the NVIDIA default.
3. Validate real decode→inference→refinement→transport behavior and GPU contention.
4. Investigate tail latency and the original allocation-reuse defect. The
   conservative graph-buffer deferral remains necessary.

Artifact root: `.build-cache/vda-vulkan-spike/`. Source/checkpoint exports are
`res392x224`, `res420x238`; frame fixtures are `video-392x224`, `video-420x238`
and original `video-sequence-01`. Detailed raw summaries are named
`rx480-spatial-summary.json`, `rx480-queries-summary.json`,
`rx480-subgroup-summary.json`, `rx480-packed-summary.json`,
`rx480-raw-packed-summary.json`, and `rx480-native-kernel-summary.json`.
