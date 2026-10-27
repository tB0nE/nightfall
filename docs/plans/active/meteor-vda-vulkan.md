# VDA Vulkan feasibility and implementation plan

Status: Vulkan temporal matrix kernels implemented and tested, 2026-10-25.
Still isolated; not integrated or enabled in Meteor.
Branch: `feat/meteor-xr-streaming`. Preserve the existing TensorRT backend.

## Corrected RX480 targets — user clarification, 2026-10-26

The required target is approximately **80 ms at the original 518×294 input**.
A reduced-resolution VDA option should instead target **40–50 ms**. The earlier
420×238 result at 76 ms is a useful reference but does not complete either
target. Preserve its artifacts; return to optimizing the full-resolution AMD
attention/projection path before selecting a performance-model resolution.

Update: both median-time targets are now met: original 518×294 at 74–75 ms and
392×224 at about 43 ms. See [the RX480 results and reproduction settings](meteor-rx480-vda-performance.md).
These remain standalone experiments, not production Meteor integration.

## RX480 performance-resolution candidate — superseded target interpretation

This experiment misinterpreted the target: 80 ms was required at the original
resolution, with 40–50 ms for a smaller option. Its results are retained for
reference rather than treated as completing the request. Exported **420×238**
from the unchanged official VDA-S checkpoint,
retaining the full model and learned reconstruction head, 31-sample history,
projected-cache policy, fused temporal attention and fused LayerNorm. No training
or quantization change was introduced. Spatial constants/positional interpolation
are generated for the new grid by the actual model export; do not patch tensor
dimensions in the old graph or confuse unchanged learned weights with identical
resolution-dependent graph constants.

Fresh RX480 full-resolution reference and three low-resolution video runs:

| Input | Graph median | Graph p95 | Preparation + graph + storage median |
| --- | ---: | ---: | ---: |
| 518×294 reference | 115.40 ms | 117.65 ms | 117.18 ms |
| 420×238 run 1 | 75.92 ms | 78.59 ms | 77.32 ms |
| 420×238 run 2 | 76.03 ms | 78.22 ms | 77.46 ms |
| 420×238 run 3 | 76.01 ms | 78.41 ms | 77.26 ms |

This meets the requested approximate 80 ms target in the standalone inference
test: about 34% faster than the fresh full-resolution reference. Input pixel
count drops by 34.4%, with width/height reduced by about 19%. Core timing includes
fixture upload/history work but excludes validation readback and real stream
decode/network/refinement/rendering; it is not end-to-end Meteor latency.

All 80 distinct frames, eight recurrent states, cache-slot rollover, and the
frame-64 reset are exercised. Repeats match all 720 output files byte for byte.
The independent same-resolution ONNX CPU rollout gives mean normalized depth
MAE 0.14373%, worst-frame MAE 0.29040%, temporal-delta error 0.03069%. All outputs
are finite and history traces match. These measure conversion/runtime fidelity,
**not** the visual quality cost of reducing resolution. A fresh 518×294 run
still matches all 720 previously validated outputs after the tooling changes.

The new grid is 30×17 patches: state token counts are 510/510/135/135/510/510/
2040/2040 with the original channel widths. `vda_resolution.h`, the probe image
loader and GPU history allocations now use explicit dimensions. Python sequence
preparation accepts `--width/--height`; reference/report infer dimensions from
the sequence manifest. The optional spatial-attention converter now derives
DINO token counts from PNNX metadata (511 here) instead of hardcoding 778.
The 518×294 defaults are preserved and an exact fixture-length check prevents
quietly reading an image at the wrong resolution.

Reproduction:

1. `export_vda_resolution.py --source-dir` pointing at the research checkout's
   `experiments/video_depth_anything_small`, `--width 420 --height 238 --output`
   a fresh directory. Export uses CUDA on the development machine; inference
   on the resulting models does not require CUDA. Both cold and recurrent ONNX
   graphs and an explicit input/state contract are written locally.
2. Run PNNX with `fp16=0 optlevel=2 device=cpu` and all input shapes from the
   contract. Apply `repair_vda_ncnn_linear.py`; recurrent flags are
   `--vulkan-attention --gemm-projections --fused-temporal --projected-cache`.
3. Prepare the same 80-frame/20 Hz clip at the new dimensions and generate its
   own CPU ONNX recurrent reference. Do not compare runtime precision against
   a different-resolution reference.
4. Select Radeon ICD, set `VDA_PROBE_WIDTH=420 VDA_PROBE_HEIGHT=238`, point
   `VDA_PROBE_COLD_PREFIX` at the new repaired cold graph, and use the existing
   resident/packing/FP16-storage/fused-LayerNorm flags. Retain AMD graph-buffer
   deferral. No NVIDIA TensorCore flags are used.

Models and contract: `.build-cache/vda-vulkan-spike/res420x238/`.
Video fixtures/reference/runs: `.build-cache/vda-vulkan-spike/video-420x238/`.
Checkpoint SHA256: `13379300b739e659f076a59d52e9801bd8d38c541a7e71f73bbca4dcfb013609`.

Quality viewer: `tools/model_tester/output/vda-rx480-420x238-20261026/index.html`.
It shows the real full-resolution GPU depth beside the real smaller GPU depth
on the same clip, using one fixed raw-depth colour scale and linear resizing
only for display. This is before Nightfall's final refinement/warping. The
video, fullscreen frame viewer, comparison metadata and separate CPU-fidelity
report are included. `compare_vda_resolutions.py` is reusable and checks source,
timestamps, resets and history rather than synthesizing incompatible states.

The profile that motivated this found spatial attention the largest cost
(approximately 53 ms summed synchronized layer wall time, with submission
overhead included); dense projections/FFNs were the next substantial cost.
Resolution provides a practical candidate now. More unchanged-resolution kernel
work remains possible, but is not required to establish this measured target.

No production Meteor model registry, default, service, package or headset build
has changed. Next assess the visual tradeoff, then integrate a separate lower-GPU
VDA option with explicit model dimensions and backend reporting; retain 518×294
for faster GPUs. Do not replace the higher-quality default automatically.

## Output-tile specialization — 2026-10-26

The next validated opt-in is `VDA_PROBE_TC_TILE_SHAPE=32x32`, added to the
cached + fused-LayerNorm + transposed-weight NVIDIA command. Keep K=16 and
shared padding=0. Default 64x64 remains the reference; Meteor is unchanged.

Smaller output tiles retain four 32-thread subgroups per workgroup but assign
one 16x16 accumulator fragment per subgroup instead of four. This increases
the number of output workgroups and reduces declared shared storage from
20 KiB to 6 KiB at K=16/padding=0. The 16-element FP32 accumulation sequence,
checkpoint bits and all storage rounding remain unchanged. This is a structural
parallelism/resource change, not a measured occupancy claim.

Repeated full-video graph measurements after explicitly specializing constants:

| Run | 64x64 median / p95 | 32x32 median / p95 |
| --- | ---: | ---: |
| 1 | 15.24 / 17.92 ms | 13.90 / 16.51 ms |
| 2 | 15.37 / 17.86 ms | 14.09 / 16.49 ms |
| 3 | 15.61 / 17.87 ms | 13.86 / 16.59 ms |

All six runs exited normally and each matched all 720 saved depth/state files
from the validated coalesced-weight reference byte for byte, with exact history
traces. Matrix tests also cover odd M/N/K dimensions (19x63x33 and 65x79x65),
and padded positional-cache tests cover widths 7/64, slot reuse and reset.
These are model graph times, not live decode-to-display latency. Under 10 ms
remains unmet.

Rejected/diagnostic experiments leading here:

- K tiles 32/64 reduced barrier frequency but did not provide a reliable gain.
  The initial K=16 controls measured 14.19–15.15 ms, K=32 about 15.06–15.21 ms,
  and K=64 about 15.67–15.79 ms. Full output identity held in all six runs.
- Padding shared rows by eight half elements passed matrix/cache and full-video
  identity checks, but did not give a reliable gain. K=16/pad8 measured
  14.66/14.96 ms against controls 15.07/15.01 ms, with worse p95; larger padded
  K tiles were slower. Do not select padding from the fastest single sample.
- Moving accumulator output into a global FP32 scratch buffer with a separate
  conversion dispatch failed matrix-oracle tests (errors approximately 0.03–0.11).
  This path was removed from active tools; the rejected prototype is archived
  at `.build-cache/vda-vulkan-spike/rejected-global-epilogue.h`. No performance
  claim is valid for that candidate.
- The first generic output-tile shader regressed even the 64x64 control to
  approximately 22 ms at 1665 MHz. Generating literal fragment counts, array
  sizes, strides and loop bounds restored the control to about 15.2 ms. The
  first generic version also produced two host-heap teardown aborts, despite
  correct saved outputs. Those abnormal runs were excluded. AddressSanitizer
  and debugger controls did not reproduce it; its exact cause is unresolved.
  Do not claim it is fixed upstream. No such abort occurred in the six final
  explicitly specialized runs. This is still experimental, not release approval.

Controls: `VDA_PROBE_TC_K_TILE=16|32|64`, `VDA_PROBE_TC_SHARED_PAD=0|8`, and
`VDA_PROBE_TC_TILE_SHAPE=64x64|64x32|32x64|32x32`. Invalid settings fail pipeline
creation, and declared shared storage is checked against device limits. TensorCore
configuration is now recorded in the probe log. Only the 32x32/K16/pad0 combination
is recommended as the next candidate; retain 64x64/K16/pad0 for comparisons.
AMD's native Gemm path does not use these controls.

Artifacts: `video-sequence-01/{ktile-*,output-tile-*,literal-tile-*,specialized-tile-*}`
in the ignored spike directory. Rejected generic source is archived separately
as `generic-output-tile-experiment.h`. The final viewer and metrics are at
`tools/model_tester/output/vda-output-tiles-20261026/index.html`.

Next profile the 32x32 candidate to locate the remaining spatial-attention,
normalization, convolution and layout costs. Do not assume barrier frequency
alone determines speed or expand arbitrary tuning combinations without checks.

## Coalesced TensorCore weights — 2026-10-26

After validating fused LayerNorm, added the explicit probe flag
`VDA_PROBE_TC_TRANSPOSE_WEIGHTS=1`. The custom TensorCore Gemm uploads weights
in K×N order rather than N×K, so neighboring shader lanes load neighboring
weight elements into the existing shared tile. Input/output tile sizes,
16-step accumulation order, checkpoint values and FP32 accumulation are
unchanged. Reordering happens **after** CPU FP16 conversion to preserve every
stored weight bit, including SIMD/tail rounding. This incurs a one-time CPU
reorder at model load, not a per-frame transpose or extra resident model copy.

Four independent matrix-oracle cases passed: M=768/778/784, N=1536, K=384,
and M=209, N=384, K=384. Sampled maximum errors are about 1.5e-5 or less.
Two alternating full-video comparisons, with fused LayerNorm enabled for both:

| Run | Graph median | Graph p95 |
| --- | ---: | ---: |
| Previous layout 1 | 16.99 ms | 18.82 ms |
| Coalesced layout 1 | 15.25 ms | 18.05 ms |
| Previous layout 2 | 17.40 ms | 21.10 ms |
| Coalesced layout 2 | 15.37 ms | 18.60 ms |
| Coalesced layout repeat | 15.91 ms | 18.38 ms |

All three candidates matched all 720 saved depth/state files from the validated
fused-LayerNorm baseline byte for byte. History, reset and positional-cache
behavior are unchanged. This is approximately 10–12% faster in the matched
comparisons, with bit-identical outputs on the tested GPU/fixture. Do not
generalize that to every driver or future shader change without revalidation.
Positional-cache tests with widths 7 and 64 also pass exactly, covering partial
matrix tiles, padded storage, slot reuse and reset under the new weight layout.
The AMD fused-LayerNorm post-restart repeat matches all 720 pre-restart outputs.

Artifacts: ignored `video-sequence-01/tc-layout-nvidia-*`; viewer and metrics at
`tools/model_tester/output/vda-tensorcore-layout-20261026/index.html`.
Current experimental NVIDIA flags add both `VDA_PROBE_FUSED_LAYERNORM=1` and
`VDA_PROBE_TC_TRANSPOSE_WEIGHTS=1` to the projected-cache sequence command.
Neither flag is automatically enabled in Meteor. AMD's native Gemm path is
unaffected by the TensorCore weight-layout change.

Next: investigate larger K tiles to amortize shared-memory barriers, checking
occupancy/tile-boundary correctness and matched full-video accuracy. Keep the
16-step accumulation baseline available. The under-10 ms goal remains unmet.

## Fused LayerNorm — 2026-10-25, resumed 2026-10-26

`VDA_PROBE_FUSED_LAYERNORM=1` selects a probe-only single-dispatch row LayerNorm
(`vda_fused_layernorm.h`). It replaces forty native LayerNorm operations without
changing model files, weights, tensor dimensions or the cold graph. It uses one
64-thread workgroup per row, FP32 sum and centered variance, and the existing
affine weights/storage precision. Separate output storage avoids shared-input
in-place clones. This is the next experimental baseline, not production Meteor.

Precision differs from native ncnn: reduction order changes, and squared
deviations remain FP32 instead of passing through the native FP16 square buffer.
This is not bit-exact to native LayerNorm. The oracle uses the actual CPU-upload
representation (SIMD/scalar-tail rounding differs), double-precision statistics,
and explicit coefficient/store ULP bounds for FP16. Early reference-rounding
assumptions were corrected before accepting results. Fourteen focused cases
pass on each GPU: FP32/FP16, widths 7/64/192/384, padded 3D rows, constant rows,
offset inputs, and affine-disabled operation.

Alternating RTX3090 real-video measurements (80 distinct frames, unchanged
history/reset policy, 68 warmed recurrent timing samples):

| Run | Graph median | Graph p95 |
| --- | ---: | ---: |
| Cached baseline 1 | 19.27 ms | 23.65 ms |
| Fused LayerNorm 1 | 17.54 ms | 20.52 ms |
| Cached baseline 2 | 19.12 ms | 23.24 ms |
| Fused LayerNorm 2 | 17.59 ms | 20.48 ms |
| Fused LayerNorm 3 | 16.77 ms | 19.73 ms |

The first matched comparison is about 9% faster. All three candidate runs have
byte-identical depth and eight state outputs (720 files). Mean normalized depth
MAE against CPU ORT changes from 0.13938% to 0.14263%; worst-frame error from
0.17402% to 0.17475%; temporal-delta error from 0.02483% to 0.02505%. Per-state
mean absolute errors remain around 0.0027–0.0051. All outputs are finite and
history traces match. These are graph timings, not live stream latency.

RX480, retaining graph-buffer deferral: 122.95 → 118.10 ms median, 125.83 →
121.11 ms p95. Mean normalized depth error improves from 0.14205% to 0.13739%.
This is still too slow for usable RX480 VDA; do not imply otherwise.

Profiling: `VDA_PROFILE_SEQUENCE_FRAME=N` profiles one warmed recurrent frame
while building history normally. Synchronized layer wall times include waits
and preceding conversions and must not be summed as GPU throughput. Use
`VDA_PROFILE_RECORD_ONLY=1` for CPU recording observations. Profiling frames
16/32/48 and record-only profiling retained byte-identical outputs. The installed
`nsys` is a stub for a missing Nsight Systems installation, so no genuine Nsight
GPU timeline was collected.

Reports: `tools/model_tester/output/vda-layernorm-20261025/index.html` and
`amd/index.html`, both accuracy-gated against the independent CPU reference.
Raw artifacts: `video-sequence-01/layernorm-*` and `profile-cache-nvidia-*` in the
ignored spike directory. Next investigate TensorCore weight-load coalescing
and K-tile/barrier overhead. The under-10 ms target remains unmet; Meteor and
its TensorRT default are unchanged.

## Smaller AMD deferral scope — latest, 2026-10-25

The selected AMD probe policy now defers **graph-tensor (blob) buffers only**
until frame completion. Scratch/workspace buffers use a separate allocator with
normal immediate reuse. This remains isolated from production Meteor. NVIDIA's
policy and model implementation are unchanged.

Controlled cold-model checks (identical image, FP32 graph, all nine outputs):

| Allocation policy | Repeats | Differing iterations |
| --- | ---: | ---: |
| Whole-frame deferral, both categories | 300 | 0 |
| Whole-frame deferral, graph tensors only | 300 | 0 |
| Whole-frame deferral, scratch only | 300 | 40 |
| Separate pools, neither category deferred | 150 | 17 |

Graph-buffer deferral also passed a full baseline video and three independent
80-frame cached rollouts. Each rollout's depth and eight state outputs match
the corresponding known-good full-deferral run byte for byte (720 files).
The final default-policy run is checked against this same baseline. This
narrows the workaround to graph-tensor allocation reuse; separating the pools
alone does not fix it. The underlying faulty operation/barrier is still unknown.

Graph timings with the smaller scope:

| Run | Median | p95 |
| --- | ---: | ---: |
| Uncached baseline | 140.26 ms | 213.43 ms |
| Projected cache, run 1 | 120.62 ms | 126.44 ms |
| Projected cache, run 2 | 119.98 ms | 122.41 ms |
| Projected cache, run 3 | 119.67 ms | 122.70 ms |

These are graph timings, not live pipeline latency. Timing variability remains
visible in the baseline's p95. Do not interpret the small difference from the
earlier full-deferral cache timings as a proven throughput improvement.

The cached graph allocator peaks at 1,194,766,720 bytes; the independent scratch
allocator peaks at 108,359,680 bytes. Their sum gives a conservative upper bound
of 1,303,126,400 bytes (1.21 GiB), versus the earlier shared deferred allocator's
1,560,855,728 bytes (1.45 GiB): at least 16.5% less outstanding buffer capacity
in this fixture. The two individual peaks need not coincide. These capacity
counters exclude separately allocated model weights, staging and allocator
reservation/fragmentation overhead; they are not total resident VRAM readings.

Rejected lower-memory alternatives, retained as explicit diagnostics:

- Completing and reclaiming every 32/64/128 layers passed the first 80-frame
  rollouts at approximately 0.51/0.52/0.72 GiB of buffer capacity. However, the
  64-layer version failed a longer cold repeat at iteration 128: depth changed
  by only 0.00187, while outputs 7/8 changed by approximately 1.9. Automatic
  batch selection was reverted. A plausible-looking depth image and one passing
  clip are insufficient; inspect recurrent states and longer repeats too.
- `VDA_PROBE_REUSE_BARRIER=1` permits immediate reuse with conservative
  first-use memory access metadata. It failed 39/300 cold repeats.
- A compute-based clone plus the same barriers failed 43/300 repeats. A first
  harness attempt had an invalid push-constant reflection name and was discarded;
  the corrected harness validates descriptor/push-constant counts before use.
  Therefore neither experiment supports claiming a complete barrier fix.
- Inspected ncnn 20260526 `allocator.cpp`: reused ranges get new TOP_OF_PIPE/no
  access metadata. `command.cpp`'s transfer clone replaces destination metadata
  without an explicit destination buffer barrier. These are investigation leads,
  not proven explanations for the complete graph's intermittent errors.

Current controls:

- AMD defaults to `VDA_PROBE_DEFER_SCOPE=blob`, with graph/workspace pools split.
- `VDA_PROBE_DEFER_SCOPE=all` restores the earlier full-deferral reference;
  `workspace` is a known-failing control. Scope overrides require deferral.
- `VDA_PROBE_ALLOW_BUFFER_REUSE=1 VDA_PROBE_SPLIT_ALLOCATORS=1` selects the
  separate-pool native-reuse control; it is known to fail.
- `VDA_PROBE_SYNC_LAYERS=0` is the selected whole-frame policy. Positive values
  enable rejected/experimental completed-batch reclamation; no automatic batching.
- `VDA_PROBE_COMPUTE_CLONE=1` is a fixed-executor diagnostic only and does not
  fix the error. It is never selected automatically.
- Full video artifacts are in `video-sequence-01/blob-only-*` and
  `blob-default-final-amd` under the ignored spike directory. The AMD report at
  `tools/model_tester/output/vda-projected-cache-20261025/amd/` uses these passing
  graph-buffer-deferral runs and the explicit 0.5% worst-frame accuracy gate.

Next: retain this correctness baseline and resume profiling remaining NVIDIA
backbone/MLP/layout cost toward 10 ms. A smaller graph-buffer-reuse reproducer
remains useful, but the proven isolation does not justify changing production
ncnn allocation or claiming the upstream defect is fixed.

## RX480 repeatability investigation — follow-up, 2026-10-25

**Update to the earlier AMD failure report below:** deferring released GPU
buffers until frame completion eliminated the corruption in the validation
runs so far. This is a probe workaround, not an established upstream root-cause
fix and not a production Meteor change.

Isolation results:

- Dividing the fixed graph into batches of 32 layers did not fix the error.
- Disabling shader local memory or subgroup operations separately did not fix it.
- ncnn's normal executor also showed intermittent errors, with and without the
  projected cache. The fixed executor is not required to reproduce it.
- Repeating one identical image through the original cold FP32 graph, with no
  temporal history, produced 8 differing iterations in 80 runs. Intermediate
  extraction reproduced divergence in the transformer backbone, before the
  temporal head. Early stable checkpoints do not prove a unique first bad layer:
  the failures are intermittent and different truncations change the workload.
- Native attention, the separate scalar attention implementation, and the two
  feed-forward Gemms in transformer block 3 each passed 1,000 isolated repeats
  on saved fixed inputs. Replacing spatial attention in the complete cold graph
  did not eliminate failures. Do not attribute this solely to native softmax.
- Holding released buffer allocations until the prior frame finishes passed
  150 identical-image cold-model repeats, then an 80-frame baseline and three
  independent 80-frame cached video rollouts. The three cached rollouts have
  byte-identical depth and all eight state outputs (720 files per rollout),
  finite values, and exact reference history traces. This strongly implicates
  reuse/lifetime/synchronization interaction in the composed graph, but does
  not establish which allocator or barrier implementation is responsible.

Matched RX480 graph timings with deferred reuse:

| Run | Median | p95 |
| --- | ---: | ---: |
| Uncached baseline | 142.29 ms | 170.32 ms |
| Projected cache, run 1 | 123.90 ms | 208.01 ms |
| Projected cache, run 2 | 124.73 ms | 139.32 ms |
| Projected cache, run 3 | 122.50 ms | 135.42 ms |

Timing variability remains material; do not hide the first cached run's high
p95. Depth error against CPU ORT is 0.14205% mean normalized MAE, 0.18638%
worst-frame MAE; temporal-delta error is 0.02710%. This is a correctness recovery
and approximately 13% median graph speedup, not usable RX480 VDA speed yet.
The final default-policy rollout also passes the same output comparison. Its
deferred allocator peaks at 1,560,855,728 bytes (about 1.45 GiB) of buffer
capacity including retained/released working buffers and history; this is not
total process VRAM, and separately allocated model weights are excluded.

Implementation and reproduction:

- `vda_probe_allocator.h`: defer buffer frees, drain only at a completed-frame
  boundary, log peak outstanding buffer capacity. AMD resident probes now use
  it by default. `VDA_PROBE_DEFER_FREE=1` enables it explicitly elsewhere;
  `VDA_PROBE_ALLOW_BUFFER_REUSE=1` restores the failing experimental control.
  The two flags are mutually exclusive. NVIDIA retains its existing policy.
- `VDA_PROBE_NATIVE_EXECUTOR=1` selects ncnn's executor in sequence validation.
- `VDA_PROBE_SYNC_LAYERS=32` splits the fixed executor for diagnostics only.
- `VDA_PROBE_CHECK_REPEAT=1 VDA_PROBE_REPEATS=150` checks all nine saved outputs
  against the first iteration, returning exit 10 on any repeat difference.
  Combine with `VDA_PROBE_OUTPUT_BLOB=60` to examine a native-executor checkpoint.
- `test_vda_layer_repeat.cpp` runs a single loaded cold layer on a fixed saved
  two-dimensional FP32 tensor: `MODEL_PREFIX LAYER INPUT_F32 WIDTH HEIGHT
  REPEATS GPU`. It excludes upstream work and temporal state. It is a
  repeatability diagnostic, not an independent numerical correctness oracle.
- Full AMD viewer and metrics were regenerated from passing, accuracy-gated
  rollouts: `tools/model_tester/output/vda-projected-cache-20261025/amd/`.

Next: isolate the minimum allocation-reuse/barrier reproducer and reduce the
workaround's memory cost before integration. NVIDIA remains at 18.87 ms with
the existing cache result; resume profiling its remaining backbone/MLP/layout
cost toward 10 ms after preserving this AMD correctness baseline. No model,
resolution, production backend selection or running Meteor service changed.

## Goal

### Projected-history cache experiment — 2026-10-25

Implemented in the standalone tools only; Meteor is unchanged. Cache each
temporal state's key/value projection once in a 44-slot GPU pool instead of
reprojecting the selected 31 history samples on every frame. Project immutable
position terms separately and add them during gather. Query projection retains
the original current-state-plus-position ordering. Checkpoint weights are
unchanged, but FP16 rounding differs when factoring the addition: this is not a
bit-exact transformation of the original graph.

The rewritten graph has 521 layers (569 before caching). Sixteen projected pools
use 168,284,160 bytes (160.49 MiB), replacing approximately 80.24 MiB of raw state
pools. Selection follows the existing history policy, with slot-validity checks,
overwrite handling and reset/reseeding. The probe context is deliberately
single-threaded and is not a production runner interface.

Matched RTX3090 real-video results (80 distinct frames, 20 Hz sampling, a reset
at frame 64; 68 warmed recurrent timing samples):

| Metric | Before cache | Projected cache |
| --- | ---: | ---: |
| Graph median | 23.30 ms | 18.87 ms |
| Graph p95 | 28.11 ms | 22.24 ms |
| Mean normalized depth MAE vs CPU ORT | 0.13934% | 0.13938% |
| Mean temporal-delta error | 0.02489% | 0.02483% |
| Prepare + graph + store median | 25.51 ms | 20.43 ms |

All NVIDIA states/depth were finite and history traces matched the reference.
These are standalone graph/core timings, not live decode-to-display latency.
Under 10 ms remains unmet. NVIDIA I/O workgroups of 64 produced byte-identical
saved depth/state files to the eight-thread cache version across all 720 files.
Viewer: `tools/model_tester/output/vda-projected-cache-20261025/index.html`.

**AMD validation is not complete.** Initial cache runs appeared correct at about
120 ms, but later full rollouts produced intermittent finite corruption. A
64-thread I/O experiment first exposed this; reverting to eight threads did not
resolve it. One uncached baseline run reached 14.18% worst-frame normalized MAE,
while an identical repeat passed. Cached repeats reached 6.05% and 7.44% worst
frame error. Therefore neither the cache nor the workgroup size alone is an
established cause. The issue also affected a cold reset frame. Do not accept
AMD speed numbers or promote this path until the intermittent error is isolated.
AMD defaults remain eight-thread I/O, which is conservative, not a proven fix.
Focused identity projection tests pass on both GPUs and demonstrably do not
cover the full-model failure.

The video report now supports `--max-normalized-error` to reject a run whose
worst-frame MAE divided by reference p98-p2 exceeds an explicit threshold.
Use `--max-normalized-error 0.005` for this fixture as a regression gate; this is
a test threshold, not a universal model-quality specification. Finite values and
correct history traces alone are insufficient. Next priorities: isolate AMD
cold/recurrent nondeterminism with repeated runs and intermediate tensors, then
profile remaining NVIDIA backbone/MLP/layout work toward the 10 ms target.

Run the existing Video Depth Anything Small streaming model on Vulkan for AMD,
Intel and NVIDIA without changing its 518×294 input, checkpoint or temporal
behavior. Compare against the NVIDIA TensorRT path before claiming useful speed.
The RX480 is an available compatibility target; it is not representative of newer
AMD hardware. EdgePad remains the working vendor-independent production option.

## Contract

Two graphs: `vda_s_518x294_cold.onnx` and `vda_s_518x294_step.onnx`, with shared
`vda_s_518x294.onnx.data`. Image input is `[1,1,3,294,518]`, not ordinary NCHW.
Each produces depth plus eight states. Streaming history shapes are:

| States | Shape |
| --- | --- |
| 0, 1 | 777×31×192 |
| 2, 3 | 209×31×384 |
| 4, 5 | 777×31×64 |
| 6, 7 | 3108×31×64 |

The eight packed FP32 histories total 113.07 MiB. Production must retain/gather
them on GPU; repeatedly uploading them is not the intended final architecture.
Cold-start state has history length one. Use Meteor's actual `History` policy,
including reset rules and thinning, for eventual sequence validation.

## Completed spike

Artifacts are ignored under `.build-cache/vda-vulkan-spike/`:

- Self-contained copies of both ONNX graphs, original weights unchanged.
- `graph-contract.json`, PNNX conversion logs and original/adjusted ncnn graphs.
- Deterministic normal-distribution input, ONNX Runtime CPU reference outputs,
  seeded history files, native CPU/Vulkan probe outputs and logs.
- No installed model, saved preference or running Meteor process was changed.

PNNX emits both graphs but logs unsupported batch-axis broadcasts. Its zero exit
code is not an accuracy check. Unmodified cold conversion produces NaN depth.

Located one concrete error: PNNX selects ncnn InnerProduct for temporal Linear
inputs whose leading dimension is the number of spatial tokens. InnerProduct
flattens a 3-D tensor instead of applying the weights on the last axis.
`meteor/tools/repair_vda_ncnn_linear.py` inserts explicit flatten/restore operations
around these layers without modifying weights: 16 cold, 32 recurrent operations.
The script checks the graph contract and refuses unexpected layer counts/shapes.

`meteor/tools/vda_ncnn_probe.cpp` is a standalone validator, not runtime code. It
extracts all nine outputs, reports actual CPU-only layers and can repeat runs via
`VDA_PROBE_REPEATS`. GPU index -1 selects CPU. Use separate Vulkan ICD selection
to target a specific physical GPU. It intentionally disables FP16 and packing
while investigating correctness. Do not deploy these artifacts.

### Accuracy observed

One deterministic input and a second step with repeated reference cold history;
this is not a real-video or recurrent-rollout validation.

- Repaired CPU cold depth MAE versus ORT: 0.00000260, maximum 0.0000134.
- Repaired CPU recurrent depth MAE: 0.00000561.
- All eight CPU states finite; largest state MAE about 0.000108.
- Cold Vulkan depth MAE: approximately 0.00189 on both cards.
- Recurrent Vulkan depth MAE: approximately 0.00145 on both cards, maximum
  approximately 0.00476. Investigate before calling this lossless.
- An initial packed NVIDIA recurrent run reported heap corruption at shutdown.
  The probe now disables packing; three repeat runs then exited normally. This
  does not establish general memory safety or resolve the original cause.

### Performance finding

The current ncnn build reports **16 CPU-only MatMul layers**, the two matrix
multiplications for each temporal attention block. Therefore the graph is mixed
CPU/GPU, with synchronization and transfers inside attention. It is not a fully
Vulkan implementation.

Repeated isolated FP32 recurrent probes took roughly 2.0–2.6 seconds on NVIDIA
and 2.2–2.5 seconds on RX480. These measurements include host history loading,
uploads and downloading all states; the final repeat also writes outputs.
They are diagnostic numbers, not fair kernel-only benchmarks or expected final
VDA performance. The main conclusion is that this direct conversion is unusable.
Cold-start first runs were about 121 ms AMD and 157 ms NVIDIA, including pipeline
startup; these do not measure ongoing streaming throughput.

## Vulkan attention follow-up: implemented

`meteor/tools/vda_vulkan_matmul.h` implements the two batched matrix multiplication
forms using an FP32 compute shader. It accepts only equally batched, unpacked 3-D
tensors, checks shapes/storage, honors channel padding, supports transposed B and
rejects unsupported inputs. It does not modify weights or reduce resolution.
PNNX graph repair now accepts `--vulkan-attention` to replace all 16 CPU-only
MatMul layers with this registered custom layer. This is not a fused attention
implementation: existing scale/softmax and projections remain separate layers.

Shader setup follows ncnn's reflection convention: the push-constant block must
be named `parameter`. Raw SPIR-V pipelines also require the three local-size
specializations to be supplied. Early shader-setup attempts logged errors; only
the corrected, error-free runs are used for the results below.

`test_vda_vulkan_matmul.cpp` checks ten cases per GPU: both multiplication forms
for all four temporal shapes plus odd matrix sizes with multiple rows/batches
to exercise padding. It compares to a double-accumulated CPU reference, checks
finite values, and verifies mismatched batches are rejected. All ten passed on
both RTX3090 and RX480. Maximum absolute error was approximately 0.000011.
Sixteen repeated dispatches per submission amortize queue overhead for timing;
reported times are wall-clock burst averages, not individual GPU timestamps.

| Kernel pair (each occurs twice per full model) | RTX3090 | RX480 |
| --- | ---: | ---: |
| 777 spatial tokens, 192 channels, 8 heads | 0.096 ms | 0.940 ms |
| 209 spatial tokens, 384 channels, 8 heads | 0.082 ms | 0.639 ms |
| 777 spatial tokens, 64 channels, 8 heads | 0.071 ms | 0.257 ms |
| 3108 spatial tokens, 64 channels, 8 heads | 0.140 ms | 0.761 ms |

The sum across all sixteen operations is approximately 0.78 ms NVIDIA / 5.19 ms
AMD in these isolated tests. This is not a measured fused full-attention time.

### Full recurrent graph

The probe now supports `VDA_PROBE_RESIDENT=1`: upload image and histories once,
extract all nine outputs into GPU tensors in one command stream, then submit and
wait. Download/write happens after the timed graph on the final iteration only.
It refuses resident benchmarking if any layer reports CPU-only execution.
`VDA_PROBE_PACKING=1` enables ncnn packing for the rest of the graph; the custom
kernel declares packing unsupported so ncnn supplies unpacked tensors to it.

| Graph, same 518×294 model | RTX3090 median / p95 | RX480 median / p95 |
| --- | ---: | ---: |
| FP32, resident inputs, packing enabled | 51.88 / 58.04 ms | 222.42 / 225.50 ms |

Twelve repetitions, first two excluded, ten measured warm samples per GPU.
All sixteen CPU MatMul fallbacks are gone. Separate preliminary unpacked runs
were roughly 60 ms NVIDIA / 225 ms AMD. Neither is yet competitive with the
existing TensorRT path. There was no heap error in the completed packed custom
kernel run; this does not prove the earlier fallback-path error is fixed.

Depth and all eight output states are finite on both GPUs. Depth error versus
ORT remains approximately MAE 0.00145, maximum 0.00476, essentially unchanged
from the original mixed CPU/GPU conversion. Thus the custom matrix operations
did not introduce the pre-existing full-graph difference. It remains necessary
to locate that difference and validate actual images and recurrent sequences.

These runs reuse a fixed image and fixed history. They measure graph throughput,
not a working sequence: GPU history-ring maintenance, selection and reset policy
are not implemented. They exclude RGB preprocessing, decode, network and final
refinement. No comparison to live headset latency or fully optimized TensorRT
should use these numbers as equivalent end-to-end measurements.

Results and logs: `.build-cache/vda-vulkan-spike/`, specifically
`vulkan-attention-results.json`, `packed-{nvidia,amd}.log`,
`matmul-{nvidia,amd}-burst.log`. Production Meteor is unchanged.

## Next implementation steps

### Real-video recurrent validation — completed

Added a self-fed, real-frame validation path before projected-state caching.
No normal Meteor backend, settings or services were changed.

Tools:

- `vda_video_sequence.py prepare`: FFmpeg RGB decode of a real clip; float
  OpenCV bicubic resize to 518×294 and DINO normalization, preserving cubic
  overshoot. Saves exact planar float inputs, hashes, input previews and reset
  annotations. Normalized 16×9 thumbnail mean change >1.0 follows Meteor's cut
  criterion. A configurable synthetic 0.75-second timestamp gap exercises reset.
- `reference`: independent CPU ONNX cold/recurrent graphs. Each frame feeds its
  own outputs into later history. Stores state as FP16, matching Meteor, while
  ONNX computation is FP32. No GPU result is fed into the reference and no
  reference state is fed into the GPU rollouts. Future reference completion
  metadata includes source ONNX hashes; input hashes are checked during reference
  and report generation.
- `vda_sequence_history.h`: 44-slot FP16 GPU pool, 31-sample gather and GPU stores.
  History selection/growth/thinning matches `meteor/src/vda.rs`; immutable pool
  data is gathered into new working inputs so graph in-place operations cannot
  corrupt stored history. Recurrent preparation/store stays on Vulkan. FP32 cold
  outputs use a one-time validation download/cast to seed FP16 history.
- `vda_sequence_runner.h` / probe mode `VDA_PROBE_SEQUENCE=1`: persistent cold/step
  nets, new image per frame, independently propagated GPU states, per-stage timing,
  exact history trace and finite checks on depth plus all eight updated states.
  Source timestamps/reset labels drive the offline run, not processing wall time;
  this does not test the application's live headset/network lifecycle.
- `report`: checks all states/depth, exact reference-vs-GPU history traces and
  input hashes. Reports normalized depth MAE, state MAE and temporal-delta residual
  versus the independent reference. Generates a slider/play/fullscreen HTML view
  and MP4, with one shared color scale fixed across the entire clip.

### Clip and coverage

80 frames at 20 Hz, starting 30 seconds into the user's previously supplied
Maizen game video (`Y7fEldmgkJY`). There are no detected natural hard cuts in this
portion. Resets: frame 0 start and frame 64 synthetic timestamp gap. This covers
the growing history, 42-entry thinning boundary and **21 slot reuses within a
session**, followed by reset/reseed. All four GPU history traces match the
independent reference byte for byte. No frozen history, repeated frame or teacher
forcing is used. This is only a four-second clip, not long-session coverage.

Three CPU boundary tests pass: expected selected frame ages after rollover,
reset selects no old-session slots, and thumbnail channel/threshold units.
Compiled runner additionally rejects malformed timestamps/reset annotations and
nonfinite output. Report requires complete, correctly shaped finite state files.

### Real-video results

| GPU / variant | Model median | Model p95 | Mean normalized MAE vs reference |
| --- | ---: | ---: | ---: |
| RTX3090 before temporal fusion | 26.90 ms | 31.51 ms | 0.1388% |
| RTX3090 after temporal fusion | **23.98 ms** | **27.97 ms** | 0.1393% |
| RX480 before temporal fusion | 154.29 ms | 157.16 ms | 0.1418% |
| RX480 after temporal fusion | **139.88 ms** | **147.40 ms** | 0.1422% |

Each timing has 68 steady recurrent samples: cold frames and the first five
recurrent frames after each reset are excluded from timing, but **all 80 frames**
are included in accuracy analysis. NVIDIA uses explicit Tensor Core projections
and spatial attention; AMD uses native spatial attention/Gemm and portable fused
temporal attention. These are unchanged-resolution models with the same weights.

Depth difference remains small over this test; final mean normalized temporal
delta error is 0.02489% NVIDIA and 0.02711% AMD, essentially unchanged from each
pre-fusion baseline. These measure disagreement with the same model's ONNX
rollout, not physical depth accuracy or an absence of all motion artifacts.
All 80 depth maps and eight states/frame are finite in all four runs.

Timings separate preparation (fixture read/upload + GPU history gather), graph,
history store and validation download. For optimized NVIDIA, medians are about
1.91 / 23.98 / 0.74 / 2.01 ms respectively. For optimized AMD, about
3.30 / 139.88 / 0.60 / 2.61 ms. Median prepare+graph+store is 26.69 ms NVIDIA /
143.75 ms AMD; those are **harness core times**, not live frame-to-map latency.
They include fixture I/O but exclude video decoding, network, postprocessing,
rendering and validation file writes. Validation download is excluded from model
and core timing. This validates raw model output, before Meteor softening, depth
normalization, edge refinement and stereo warp.

Artifacts:

- Raw fixtures/reference/GPU states and traces:
  `.build-cache/vda-vulkan-spike/video-sequence-01/`.
- NVIDIA report/video:
  `tools/model_tester/output/vda-vulkan-sequence-20261025/index.html` and
  `comparison.mp4`.
- RX480 report/video: same report folder's `amd/index.html` / `amd/comparison.mp4`.
- `summary.json` beside each report contains all per-frame errors and stage
  timing summaries. Raw timing CSVs and history traces remain in each run folder.
- Reports/previews use ignored model-tester output; large fixtures and model
  files remain ignored. The comparison sheet was inspected locally.

Reproduction:

```sh
PY=.build-cache/model-tester-venv/bin/python
"$PY" meteor/tools/vda_video_sequence.py prepare --video /path/to/gameplay.webm \
  --output .build-cache/vda-vulkan-spike/NEW-SEQUENCE --frames 80 --fps 20 --start 30 --gap-at 64
"$PY" meteor/tools/vda_video_sequence.py reference \
  --sequence .build-cache/vda-vulkan-spike/NEW-SEQUENCE \
  --cold .build-cache/vda-vulkan-spike/cold.onnx \
  --step .build-cache/vda-vulkan-spike/step.onnx \
  --output .build-cache/vda-vulkan-spike/NEW-SEQUENCE/reference
```

For GPU runs, use probe arguments `STEP_PREFIX GPU_INDEX SEQUENCE_DIR OUTPUT_DIR`,
`VDA_PROBE_SEQUENCE=1`, `VDA_PROBE_COLD_PREFIX=.../cold-repaired`, resident/FP16
storage flags, and the appropriate ICD/step variant. NVIDIA enables explicit
Tensor Core flags; AMD never does. Run `vda_video_sequence.py report --sequence
SEQ --reference REF --run 'Before=DIR1' --run 'After=DIR2' --output REPORT_DIR`.

This is the acceptance harness for the next structural optimization: projected
key/value history caching. Retain raw output-state observability and compare a
fully self-fed rollout, including positional encoding and reset behavior. The
under-10-ms NVIDIA target and usable RX480 throughput remain outstanding.

### Portable temporal fusion follow-up

Profiled the current Tensor Core candidate using synchronized per-layer timing.
Reshape/permutation categories remain substantial, although those aggregate
wall times include profiling overhead and are not independent GPU timestamps.
Selected a state-contract-preserving optimization before projected-state caching.

`vda_fused_temporal.h` consumes the three projected tensors directly in
`[token,time,channel]` layout. It computes score, scale, stable softmax and the
weighted value sum in one dispatch, avoiding head-layout permutations and
intermediate score/probability allocations. The FP16 variant retains rounding
at the original stored matmul/scaled-score/probability boundaries. Both use FP32
accumulation. The kernel is portable Vulkan; no Tensor Core requirement.

Converter flag `--fused-temporal` replaces eight validated weight-free regions.
Graph size drops from **689 to 569 layers (120 removed)**. It preserves the Q/K/V
and output projections, input/output state shapes, original weights, history
length and scale. Conversion refuses changed transpose, softmax axis, projected
shapes or external users of removed intermediate tensors. Actual converted graph
passes; deliberately altered axis/transpose/history/external-consumer cases fail.

An initial direct-read version and a generic shared-memory version did not
establish a speed gain against the historical 24.7 ms run. The retained variant
specializes shared storage and loop bounds for each 8/24/48-channel head width,
avoiding strided key loads and excess local-memory allocation. The direct-read
source is archived under ignored `fused-temporal-direct.h`.

### Matched comparisons for temporal fusion

| GPU / same-run path | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| RTX3090, explicit Tensor Core spatial/projection path | 29.91 / 34.29 ms | **26.11 / 29.85 ms** |
| RX480, native spatial attention and Gemm projections | 155.08 / 157.98 ms | **139.81 / 142.40 ms** |

NVIDIA: 500 repeats, first 100 excluded, clock monitored, sequential before/after.
AMD: 100 repeats, first 20 excluded, sequential before/after, no NVIDIA-only
kernels. Fixed executor and protected GPU inputs for both variants. This remains
fixed-input recurrent-graph throughput, not measured video latency.

Matched median reduction: approximately 12.7% NVIDIA, 9.9% AMD. Do **not** claim
that 26.1 ms beats the prior historical 24.7 ms: repeated runs show variability.
Use the matched comparison as evidence for this optimization and retain both
graphs for remeasurement. Under 10 ms remains unmet.

All nine output tensors finite. NVIDIA final depth MAE / maximum versus ORT:
before 0.001996 / 0.01108, after 0.002000 / 0.01105. AMD: before 0.002350 /
0.01410, after 0.002222 / 0.01246. These single-fixture numbers do not establish
general visual quality or video stability. Small differences arise from fused
reduction/rounding behavior; no claim of bit-identical output.

`test_vda_fused_temporal.cpp`: ten CPU-oracle cases per GPU, covering FP32/FP16,
all production head widths, padded per-token storage, large scores and invalid
history-shape rejection. All twenty cases passed. The real graph's conversion
guard checks also pass. Logs and outputs:
`fused-temporal-tests-{nvidia,amd}.log`, `fused-temporal-comparison.json`,
`matched-{baseline-nvidia,fused-specialized-nvidia,baseline-amd,fused-temporal-amd}*`.

New graph prefixes: `step-temporal-fused` (NVIDIA custom spatial variant) and
`step-temporal-fused-amd` (native spatial variant). Source flags for NVIDIA:
`--vulkan-attention --gemm-projections --spatial-attention --fused-temporal`;
AMD omits `--spatial-attention` and never enables Tensor Core runtime flags.
Normal Meteor remains unchanged; these are optional experimental tools/artifacts.

Next: establish real-video recurrent sequence validation before implementing
projected-history caching. Preserve exact sample selection and resets. Positional
encodings change with each selected sample's position, so caching projected raw
states requires handling projected positional terms explicitly and checking
mixed-precision differences over rollouts. Do not benchmark cache hits on an
unchanging fixture as if they represented a live video stream.

### NVIDIA profiling / explicit Tensor Core follow-up

Target: under 10 ms for the unchanged-resolution recurrent graph. **Not achieved**.
The new validated experimental baseline is approximately 25 ms on RTX3090.
Nothing from this spike has been enabled in normal Meteor.

The initial recording/wait timing split was misleading if interpreted as CPU vs
GPU: native ncnn spatial attention calls `submit_and_wait()` inside its forward
function on NVIDIA as a softmax correctness workaround. `NetPrivate` also submits
at a dispatch-count threshold. Consequently `graph_record_ms` includes those
hidden waits in the normal executor. `submit_wait_ms` is only the final explicit
wait, not total GPU execution time. Keep that distinction in reports.

`vda_layer_profiler.h` now has optional `VDA_PROFILE_VALIDATE=1` to stop at the
first nonfinite layer, and `VDA_PROFILE_RECORD_ONLY=1` to time forward calls
without adding profiler synchronization. The latter still includes native
internal waits. They must not be enabled together (validation downloads require
completed work).

The failing native cooperative route first produced NaNs in the first spatial
attention block. Disabling cooperative matrices just within native attention
(`vda_safe_attention.h`, `VDA_PROBE_SAFE_ATTENTION=1`) allowed that block to pass,
but the first feed-forward Gemm then produced infinity. Therefore this is not an
attention-only problem. Standalone deterministic projection tests reproduced
large numeric errors on both aligned M=768 and uneven M=778/784/209 shapes with
native cooperative matrices enabled. Without cooperative matrices those tests
pass. Exact upstream cause remains unisolated; do not blame tail handling or
driver behavior without further evidence. Global native FP16 arithmetic also
did not help: cooperative still invalid; no-cooperative slower and less accurate.

Implemented an independent cooperative route for testing:

- `vda_vulkan_tensorcore.h`: explicit KHR 16×16×16 cooperative operations tiled
  into 64×64 outputs, four subgroups per workgroup, plain FP16 weights/input,
  FP32 accumulation, row/column/K boundary checks. No ncnn cooperative prepacking.
- `vda_tensorcore_attention_shader.h`: 16 queries × 64 keys with shared Q/K/V
  tiles, stable online softmax, FP32 accumulated output and FP16 storage.
  It replaces the native attention path entirely, including its forced submits.
- `vda_vulkan_spatial_attention.h` selects the new shader only with
  `VDA_PROBE_TC_ATTENTION=1`. It still retains the prior generic tiled experiment.
- `VDA_PROBE_TENSORCORE=1` selects explicit projection kernels for temporal,
  feed-forward and combined-QKV/output projections. Requires FP16 storage and
  KHR cooperative-matrix 16×16×16 support; RX480 cannot select this path.
- `vda_fixed_graph.h`: optional `VDA_PROBE_FIXED_GRAPH=1` standalone fixed-order
  executor with the same packing and in-place-copy rules, but without ncnn's
  dispatch-count submit heuristic. It checks for missing inputs/unsupported
  layers and returns all nine outputs. This is not a general production executor
  or a modification of Meteor's watchdog behavior.

The explicit projection kernel passes four deterministic matrix tests (aligned
and uneven rows). The attention path passes CPU-oracle identity-projection tests
for 17, 37 and 778 tokens, plus strong logits at 37 tokens. These cover partial
query/key tiles and stable softmax; all finite with errors within the stated
mixed-precision test tolerances. Full model output/state comparisons also pass
finite checks and retain small error versus ORT.

### Sustained, clock-monitored comparison

`meteor/tools/benchmark_vda_probe.py` runs the probe, optionally records GPU
clocks/power/load, and excludes a configured warm-up count from its summary.
It does not treat timings as proof of accuracy. RTX3090 rose from P8 210 MHz to
P2 approximately 1665 MHz during testing. Low idle clocks do not explain the
remaining steady-state cost.

| Same 518×294 recurrent graph | Median | p95 | Depth MAE / maximum vs ORT |
| --- | ---: | ---: | ---: |
| Previous correct FP16-storage native path | 30.42 ms | 39.58 ms | 0.002736 / 0.01647 |
| Explicit 32×32 projection tiles + tiled TC attention | 31.76 ms | 38.47 ms | 0.001996 / 0.01108 |
| Explicit 64×64 projection tiles + tiled TC attention | **24.66 ms** | **33.14 ms** | **0.001996 / 0.01108** |

300 repetitions each, first 50 excluded, 250 measured samples; all final depth
and eight states finite. Median reduction versus sustained native baseline is
approximately 19%. The 64×64 variant is the selected **experimental** NVIDIA
candidate. This is still fixed-input/fixed-history graph throughput, not a video
rollout or end-to-end stream latency. No quality claim beyond the checked inputs.

Other trials (short runs) did not beat that candidate: native arithmetic FP16,
selective native cooperative matrices, explicit 16/32 output tiles and the older
generic fused-attention route. Keep their ignored logs, not their timing as a new
baseline. 32×32 projection source archived as `tensorcore-projection-32.h`.

Results: `nvidia-tensorcore-optimization-results.json`,
`clocked-{baseline,tensorcore,tensorcore64}-nvidia.{log,clocks.csv,summary.json}`,
`projection-{coop,standard}-test-nvidia.log`,
`projection-tensorcore64-test-nvidia.log`, `tensorcore-attention-tests-nvidia.log`.

Reproduce the selected candidate with the `step-spatial` converted graph and:
`VDA_PROBE_FIXED_GRAPH=1 VDA_PROBE_TENSORCORE=1 VDA_PROBE_TC_ATTENTION=1
VDA_PROBE_REPEATS=300 VDA_PROBE_RESIDENT=1 VDA_PROBE_PACKING=1
VDA_PROBE_FP16_STORAGE=1 VDA_PROBE_NO_COOPERATIVE_MATRIX=1` and NVIDIA ICD.
The last switch disables ncnn's failing native cooperative implementation, not
the explicitly selected custom Tensor Core kernels.

Next work must profile this candidate's actual GPU kernels/layout traffic and
evaluate temporal projected-state reuse, then validate real-image/video rollouts.
Merely removing submission boundaries did not achieve under 10 ms. Preserve
the correct FP32/native paths and AMD results while pursuing that target.

### Requested RTX3090 comparison on the corrected optimized path

User explicitly requested the same-path NVIDIA speed comparison. Before testing,
`nvidia-smi` reported 267 MiB used, 23,911 MiB free, 1% GPU utilization: no active
LLM load was evident. Same protected-input protocol, 12 repeats / first two
excluded, fixed input/history and all nine outputs checked:

| Optimized recurrent graph | RTX3090 median / p95 | RX480 median / p95 |
| --- | ---: | ---: |
| Gemm projections, FP32 | 41.16 / 42.76 ms | 162.72 / 166.45 ms |
| Gemm projections, FP16 storage / FP32 arithmetic | 34.06 / 38.71 ms | 152.54 / 155.98 ms |

The NVIDIA FP16-storage comparison explicitly disables cooperative matrices via
`VDA_PROBE_NO_COOPERATIVE_MATRIX=1`. The default cooperative-matrix run took
31.87 ms but produced nonfinite states and invalid depth: **reject that result**.
With cooperative matrices disabled all outputs are finite; depth MAE is 0.002736,
maximum 0.01647 versus ORT. FP32 depth MAE is 0.001453, maximum 0.004755.
RX480 has no cooperative-matrix support, so this switch does not remove a feature
available to its earlier run. The root cause of the NVIDIA cooperative failure
has not been isolated; it is not evidence about ncnn cooperative kernels in general.

NVIDIA is approximately 4–4.5× faster on these graph variants. These are still
FP32 arithmetic graph probes, not the production FP16 TensorRT engine (~3.2 ms
model / ~5.5–6 ms frame-to-map in historical logs). They demonstrate substantial
remaining backend overhead/optimization opportunity, not production regression.
Logs/output summary: `nvidia-optimized-path-results.json`,
`protected-gemm-nvidia.log`, `protected-gemm-fp16-nocoop-nvidia.log`.

### Accepted temporal projection optimization and spatial experiments

Retested the Gemm projection adapter with the corrected protected-input probe.
It **does** preserve the outputs: the earlier failure was not a valid rejection
of this approach. `vda_vulkan_projection.h` reads the original InnerProduct
weight/bias format, passes the unchanged tensors to ncnn Vulkan Gemm, and exposes
the same flattened rows / restored temporal shape. Converter flag:
`--gemm-projections`. No ONNX checkpoint modification is required.

| RX480 protected-input recurrent graph | Median | p95 | Depth MAE vs ORT |
| --- | ---: | ---: | ---: |
| Corrected baseline, FP32 | 221.38 ms | 223.30 ms | 0.001454 |
| Gemm temporal projections, FP32 | 162.72 ms | 166.45 ms | 0.001454 |
| Gemm temporal projections, FP16 storage / FP32 arithmetic | 152.54 ms | 155.98 ms | 0.002350 |
| Combined QKV + naive fused spatial attention, FP32 | 241.44 ms | 244.65 ms | 0.001454 |
| Combined QKV + tiled spatial attention, FP32 | 183.42 ms | 185.04 ms | 0.001454 |
| Gemm + FP16 storage, subgroup operations disabled | 153.36 ms | 155.64 ms | 0.002350 |

Each run: 12 repetitions, first two excluded, ten measured samples. Same model,
weights, fixed image and fixed history. Image/history device copies are included;
CPU I/O is excluded. No NVIDIA GPU test was performed in this pass. The user has
subsequently allowed NVIDIA tests, but they remain unnecessary for these results.

The accepted **standalone** FP32 improvement is about 26.5%; optional FP16 storage
brings it to about 31%. All nine outputs remain finite. FP32 projection changes
retain approximately the baseline error; FP16 storage raises maximum depth error
to about 0.0141 (versus 0.00476 FP32). Real-image visual validation and recurrent
error accumulation remain outstanding. Keep FP32 as the probe's default; enable
storage experiment explicitly via `VDA_PROBE_FP16_STORAGE=1`. The temporal shader
uses FP32 accumulation and optionally stores inputs/outputs as half precision;
it does not request native FP16 arithmetic on Polaris.

Focused temporal tests now accept `--fp16`, with inputs rounded to half precision
before forming the double-accumulated oracle and an appropriate FP16 output
tolerance. Ten FP32 plus ten FP16-storage cases passed on RX480 after these
changes (`matmul-final-amd-fp32.log`, `matmul-final-amd-fp16.log`).

`vda_vulkan_spatial_attention.h` is an **unselected research variant**, enabled
only by converter flag `--spatial-attention`. It joins the three Q/K/V projections
without changing their weights, performs tiled online-softmax attention in FP32,
then applies the original output projection. Each 256-thread group processes four
queries and shares 32-key/value tiles. It handles padded final query/key tiles.
The naive version is archived as `spatial-naive.h` in the ignored spike folder.
Both preserve the full-graph reference accuracy, but neither beats native ncnn
attention. Do not select them as an optimization. The no-subgroup test also does
not improve performance and is not selected.

Results: `rx480-optimization-results.json` in the spike directory. This remains
an experimental graph benchmark, not video latency or a deployable backend:
the best variant is still only about 6.6 graph steps/s before stream overhead.
Normal Meteor model/backend selection remains untouched.

Next priorities: measure the accepted graph's updated per-layer cost, test real
images/sequences, and investigate removing redundant recomputation/layout changes
in temporal history. Cached history features are repeatedly projected for keys
and values; a projected-state cache must account for each selected position's
positional encoding and preserve the reference history selection policy. This
requires graph/state-contract work and numerical validation, not just another
shader option. Do not promise that it alone will reach the desired update rate.

### RX480-only follow-up and benchmark input protection

User requested all further GPU work target RX480, leaving RTX3090 to an LLM.
Existing TensorRT logs are the NVIDIA baseline; do not rerun NVIDIA benchmarks.
User then reported playing a game on RX480 and authorized concurrent testing.
Keep game-running and game-closed measurements separate; wait for explicit
confirmation that the game is closed before labeling a run unloaded.

Added optional `VDA_PROBE_PROFILE=1` per-layer synchronization wrapper in
`vda_layer_profiler.h`. It submits/waits/resets at every layer. Timings include
driver/submission and preceding layout work: use them to locate hotspots, not
as an unbiased throughput total. Preliminary RX480 profile identified temporal
InnerProduct projections (~70 ms aggregate), spatial MultiHeadAttention (~52 ms),
Reshape (~30 ms) and Gemm (~23 ms) as the major categories.

The follow-up exposed a benchmark bug: directly reusing GPU input fixtures
across extractors allowed output drift. Fresh CPU input uploads retained the
expected accuracy; adding device-side copies of the immutable image/history
before each extractor restored consistent output in resident mode. Its timed
region now **includes those GPU copies**. Also normalize downloaded states to
pack1 before writing float files; states 6/7 can otherwise remain pack4 on GPU
downloads, which cannot be compared as planar arrays.

A corrected game-running run, 12 iterations / first two excluded, measured
**215.55 ms median / 216.81 ms p95** on RX480. Depth MAE 0.001454, maximum
0.004758 versus ORT; all states finite, state MAE roughly 0.0014–0.0027. Files:
`protected-amd-game.log`, `protected-amd-game-out*.f32`. This is still a
fixed-input graph benchmark, not measured real-video latency. Repeat this exact
version after the user closes the game. Do not claim a speedup from its difference
against the older, unprotected benchmark or other varying game-load runs.

An attempted temporal InnerProduct→Gemm adapter and FP16-storage variant were
not accepted. Their initial full-graph accuracy failures occurred before the
input-reuse bug was isolated, so they are **not conclusive evidence that either
approach is intrinsically inaccurate**. Both require a clean retest with protected
inputs. The Gemm adapter was removed from source; attempted graphs/logs remain
ignored (`step-gemm*`, `gemm-*`). FP16-storage experiment source/test snapshots
are retained under `.build-cache/vda-vulkan-spike/fp16-storage-experiment*`;
production probe/kernel remain FP32. Ten focused FP16-storage matrix tests passed
on RX480 using rounded-input references and an FP16-appropriate error tolerance.
Do not promote either experiment on the basis of these preliminary results.

The earlier unprotected game-running samples (`fp32-amd-game*`,
`layout-amd-game*`, `fp32-restored-amd-game*`) are invalid for numerical or speed
conclusions because output drift was present. Existing prior benchmark numbers
are preliminary; use protected-input measurements going forward.

After the user confirmed the game was closed, the identical protected-input run
measured **221.38 ms median / 223.30 ms p95** (ten warm samples). Final depth is
bit-identical to the game-running run, with the same reference error. All nine
outputs are finite. The approximately 2.7% higher median after closing the game
does not establish a meaningful workload effect from these short runs; GPU clocks
and other load were not controlled. The approximately 220 ms graph cost remains
the optimization target. Comparison: `rx480-game-comparison.json` and
`protected-amd-game-closed.log` in the spike directory. No NVIDIA test was run.

### Production baseline and measurement caveat

Existing Meteor logs confirm the user's approximately 6 ms observation. On
2026-10-25 at 04:37–04:38 UTC, actual streaming on RTX3090 reported model p50
3.14–3.18 ms / p95 3.49–3.52 ms and frame-to-map p50 5.43–5.58 ms / p95
5.82–5.92 ms. These are historical measurements, before the user started an LLM.
The recurrent production engine is TensorRT FP16, with persistent engine/context
and GPU-managed history. Cold start uses a separate FP32 engine.

The Vulkan 52 ms number is **not** a new production measurement: it is an FP32
converted-graph benchmark using a fixed input and fixed history, creating an
extractor each iteration and timing host graph recording plus GPU completion.
It excludes video decoding/preprocessing/history updates. Replacing the test
image with video alone does not explain or resolve the large runtime gap.

Before drawing backend performance conclusions, compare the same recurrent
step with aligned precision, inputs, warm-up and timing boundaries; report
graph-only and real-video frame-to-map separately. Retain the FP32 correctness
test. The user is now running an LLM on RTX3090: do not launch more GPU/model
tests without coordinating resource availability. Shared-load results are not
comparable to the historical idle baseline.

1. Profile the remaining graph, particularly spatial transformer and temporal
   projections: isolated matrix kernels now account for only a small fraction of
   full graph time. Do not spend the next optimization pass exclusively on them.
   Assess GPU-native attention fusion and safe mixed precision against reference
   quality. Preserve the unchanged-resolution FP32 baseline for comparisons.
2. Validate complete temporal attention blocks with nontrivial reference inputs
   and then real video rollouts. Matrix correctness tests pass, but are not a
   substitute for streaming-state correctness.
3. Keep temporal history and gathers resident on GPU, with the existing 31-sample
   selection policy. Separate graph time from history management and transfers.
4. Investigate Vulkan/ORT numeric differences and the packed-path memory error.
   Test real RGB images, nontrivial history and repeated multi-frame rollouts.
5. Compare warmed FP32 and supported mixed-precision paths on RTX3090/RX480 at
   unchanged model resolution. Measure median/p95, accuracy, state memory and
   actual CPU fallbacks. RX480 lacks native FP16 arithmetic; do not assume the
   same benefit as newer cards.
6. Only after those gates, integrate a separate VDA Vulkan runner into Meteor,
   retaining TensorRT as the NVIDIA default. Add explicit backend/status reporting
   and predictable errors; do not silently serve slow CPU attention.
7. Validate AMD-only decode→VDA→refinement pipeline and package required shaders.
   Windows and Intel hardware validation remain separate follow-ups.

## Reproducing the initial conversion

Use `.build-cache/model-tester-venv/bin/python` to load each installed ONNX graph
with external data and save a self-contained copy in the spike directory.
Run its installed PNNX binary with `fp16=0`, cold inputshape
`[1,1,3,294,518]`; recurrent shapes append the eight history shapes above.
Keep full logs. Then run:

```sh
.build-cache/model-tester-venv/bin/python meteor/tools/repair_vda_ncnn_linear.py \
  .build-cache/vda-vulkan-spike/cold .build-cache/vda-vulkan-spike/cold-repaired
.build-cache/model-tester-venv/bin/python meteor/tools/repair_vda_ncnn_linear.py \
  .build-cache/vda-vulkan-spike/step .build-cache/vda-vulkan-spike/step-flat
c++ -O2 -std=c++17 meteor/tools/vda_ncnn_probe.cpp \
  -Imeteor/target/ncnn/include/ncnn -Lmeteor/target/ncnn/lib -lncnn \
  -Wl,-rpath,"$PWD/meteor/target/ncnn/lib" -o .build-cache/vda-vulkan-spike/probe
```

Probe arguments: model prefix, GPU index, planar input float file, output prefix,
and optionally a prefix for eight packed history float files (`PREFIX0.f32` etc.).
Choose NVIDIA/Radeon via `VK_ICD_FILENAMES` and read the actual enumerated name.

For the custom graph, add `--vulkan-attention` to the repair command and use the
resulting prefix. Build the focused test with the same include/library flags,
substituting `meteor/tools/test_vda_vulkan_matmul.cpp`; it takes a GPU index.
Resident benchmark environment: `VDA_PROBE_RESIDENT=1 VDA_PROBE_PACKING=1
VDA_PROBE_REPEATS=12`. Use the recurrent history prefix as the last argument.
