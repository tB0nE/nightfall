# Meteor same-frame depth fusion spike

Branch: `codex/meteor-depth-fusion-spike` (2026-11-03).

## Goal

Explore a detailed central prediction over a complete background depth map,
without changing the normal single-model default. This is host-side work: the
15 ms budget previously discussed was for headset blending, not this experiment.

The branch starts at the saved Quest compatibility-browser checkpoint. It also
retains the separate, uncommitted local comparison scripts. Linux-browser GPU
experiments remain disabled; this work does not change the headset APK.

## Controls (Linux tray)

Host depth → **Depth fusion — experimental**:

- Enable centre detail fusion (off by default; choose a detail model first).
- Background: selects the existing inference GPU/model configuration. This is
  the same background selection as the normal GPU / model menu.
- Centre detail: a second independent model on the background's hardware group.
  EdgePad and compatible VDA variants are selectable, including VDA over VDA.
- Blend: affine + feather, low-frequency correction, multiscale, or the combined
  correction/multiscale/disagreement-protected mode.
- Status: active blend backend, both model names, preparation + blending time,
  and actual decoded source dimensions; failures remain visible here.

No new models are required. Only installed, compatible models are offered.
This spike adds the Linux menu; Windows menu integration is not included.

## Pipeline

1. While enabled, request decoded RGB at up to 1920×1080 rather than reducing
   the source to the background model's input size before cropping.
2. Use one decoded frame and its existing stream/epoch/frame identifier for
   both predictions. Never blend maps from different source frame numbers.
3. Run the background on the full image and the detail model on a central
   crop: half the width and half the height, one quarter of the image area.
4. Keep separate model instances and separate VDA temporal histories. The
   detail pass must not reuse/update the background's recurrent state.
5. Normalize each map using Meteor's robust histogram range. Bilinearly expand
   to a 960×540 fusion map and the corresponding 480×270 central patch.
6. Fit a positive affine scale/offset on the overlap ring using trimmed least
   squares. Constant overlap is handled without inventing a depth slope.
7. Blend on CUDA on the NVIDIA path, with an explicit CPU reference on other
   hardware or if CUDA initialization is unavailable. Invalid predictions,
   loading failures or blend failures disable fusion and resume normal inference.
8. Run existing optional edge alignment/contour cleanup on the fused result,
   then deliver one depth map through the unchanged depth transport.

CUDA is not silently selected for an AMD or CPU inference choice. This first
GPU implementation uses NVIDIA's existing primary-context CUDA infrastructure;
a generic Vulkan fusion backend is future work. There is no multi-GPU fusion
selection yet. Host inference and blending are not moved to the Quest.

## Blending implementation

CPU preparation currently includes RGB crop/resizing, raw depth readback,
normalization, sparse robust fitting and depth resampling. The GPU receives
normalized background, aligned residual and feather mask. The actual spatial
filtering/blending is CUDA, including:

- Affine + feather: smoothstep mask, 48 fusion pixels / 96 source pixels at 1080p.
- Low-frequency correction: subtract a broad residual field (Gaussian sigma
  16 at 960×540), using normalized mask-weighted filtering near patch boundaries.
- Multiscale: blend residual bands at sigma 2, 8 and 24 with corresponding
  Gaussian masks; this is an undecimated band decomposition rather than the
  Python report's downsampled Laplacian pyramid.
- Protected: apply low-frequency correction, attenuate contribution where
  corrected residuals or gradients disagree, then multiscale blending.

These are experimental ports with deliberate boundary handling differences,
not pixel-identical implementations of the earlier Python image gallery.
A CPU reference uses the same algorithm as CUDA for numerical validation.

## Limits and resource costs

- Two model instances, additional inference, and additional VRAM; first VDA
  TensorRT load/build can take time. Loading occurs on the depth worker, not
  the tray/desktop forwarding thread. Depth updates pause during loading.
- Inference is serial for now, from one source frame; no asynchronous fusion
  or stale-map substitution. Existing newest-frame/rate-cap behavior applies.
- Full-frame readback/upload is still present; this is not a zero-copy path.
- Fusion output is normalized and quantized once without the usual range/pixel
  EMA. VDA retains temporal history; EdgePad fusion can fluctuate frame to frame.
  Temporal normalization stabilization is outstanding before production use.
- Geometry correction can weaken valid model detail, or move boundaries. A
  visually smooth depth map does not establish correct stereo reconstruction.
- Toggling off restores the usual decode target on subsequent decoded frames.
  Detail buffers are released when the depth worker next handles a frame.
- Model or stream changes reset the relevant histories. No auto-mode behavior
  or released defaults are changed.

## Validation / next work

Required: CPU fusion invariants and invalid-input checks; required-GPU numerical
comparison for all four modes; both feature configurations compile; standard
unit/GDScript verification; isolated replay using real models, checking 960×540
maps, frame tags, status and off/recovery behavior. Use generated input without
host gamescope/Vulkan UI sessions (prior host experiments reset the desktop).

Then manually compare final depth and stereo output, fast motion, crop-boundary
objects and model switches. Measure complete inference/preparation/blending and
frame-to-map latency rather than only the final kernel. GPU fusion timing alone
must not be presented as total dual-model cost.

Potential follow-ups: GPU-resident crop/preparation/readback removal, generic
Vulkan blend kernels, tunable crop/feather, stable range matching across frames,
and direct full-frame high-resolution VDA as a quality/cost baseline.

## First implementation validation (2026-11-03)

- Both default-feature and no-default-feature Rust builds checked; optimized
  release executable built at `meteor/target/release/nightfall-meteor`.
- CUDA required-GPU test passed: all four modes agree with the CPU reference
  within 0.0002 normalized depth on asymmetric synthetic input.
- Standard verification passed: 185 Rust tests, zero failures; GDScript suite
  passed. Summary: `build/verify/unit-20261103-113648/summary.json`.
  An earlier sandbox run failed in socket/process tests; the host-access rerun
  passed. No host gamescope or Vulkan UI tests were used.
- Isolated 1920×1080 generated replays passed for all four EdgePad-512 + VDA
  modes. All saved maps were 960×540, CUDA was reported, and no inference
  errors occurred. Protected blend/preparation reported ~9–12 ms; complete
  warmed frame-to-map median ~54 ms. This was a 12 fps input test, not a
  maximum-throughput benchmark; CPU crop/readback and transfers remain.
- VDA + VDA protected replay also passed with independent instances: ~9–10 ms
  blend/preparation and ~56 ms warmed frame-to-map median at 12 fps input.
- Replay summaries:
  `build/verify/depth-fusion-20261103-113857/summary.json`,
  `build/verify/depth-fusion-20261103-113929/summary.json`,
  `build/verify/depth-fusion-20261103-113959/summary.json`.
- Reproduce with host `/usr/bin/python3 meteor/tools/test_depth_fusion.py`;
  use `--background vda_s_518x294 --modes Protected` for VDA over VDA.
  The harness uses temporary settings and bounded child lifetimes; it does not
  restart the installed Meteor or change its saved settings/pairings.

Manual checks still needed: tray interaction, live final-depth/stereo quality,
model/stream switching, standby and failure recovery. The installed Meteor
instance was left running during implementation; it does not yet contain the
new menu. The new release executable must be launched for interactive testing.
No headset APK update is required for the existing depth transport.

## Pipeline latency comparison and new motion limitation

Same 1080p static desktop input at 72 fps, two 12-second runs each on RTX 3090,
normal alignment/cleanup enabled, no PNG writes during timing:

| Current pipeline | Typical median | Typical P95 | Delivered maps/s |
| --- | ---: | ---: | ---: |
| EdgePad-512 (ncnn Vulkan) | 8.9 ms | 11.8 ms | 71.2 |
| VDA (TensorRT) | 6.3 ms | 7.8 ms | 71.9 |
| VDA + VDA, protected CUDA blend | 58.1 ms | 66.4 ms | 19.2 |

Latency is compressed frame submission to finished host map, not end-to-end
headset latency. First second excluded; table summarizes per-run statistics.
Normal decode targets are retained (512×288, 1280×720, and 1920×1080 for
fusion). Fusion overhead includes CPU conversion/cropping, transfers and
preparation; do not attribute the entire difference to two model evaluations.

Evidence: `build/verify/depth-fusion-latency-20261103-114903/summary.json` and
`comparison.md`. Reproduce: `/usr/bin/python3
meteor/tools/benchmark_depth_fusion.py --static-reference`.

**New motion blocker:** the moving testsrc2 input at 72 fps produced an invalid
affine scale after several seconds, causing the existing guard to disable
fusion and resume normal VDA. Both repeats reproduced it. Mixed timings were
rejected, not reported as fusion performance. Static desktop runs remained in
fusion throughout. Need disagreement fallback that does not permanently disable
the experiment on ordinary motion, and temporal alignment stabilization, before
claiming robust live use. No application changes were made during benchmarking.

## Resident native VDA/VDA optimization (in validation)

The native TensorRT VDA pair can now use the NVDEC planar GPU tensor directly.
GPU crop feeds an independent detail instance; both raw depth maps stay resident.
GPU kernels compute robust histogram normalization, bilinear depth resampling,
trimmed affine alignment and blend preparation, then existing CUDA blending.
Only a 12-byte fit-validity result and the final 8-bit map return to the CPU.
Existing final refinement/transport still reads/uploads the finished map as
before; this is not a claim that every byte in the entire application stays
GPU-resident. Other model/backend pairs retain the earlier reference path.

The GPU fit uses parallel reductions and quantile bisection instead of a CPU
sort. New numeric tests compare all modes to the CPU reference; quality and
latency must be rechecked before claiming equivalent behavior or improvement.
Decoded RGB is no longer quantized to RGB8 and uploaded again for this route,
so model input retains the original decoder float precision. No resolution,
model, blend or refinement settings were reduced for this optimization.

### Resident path validated and rebenchmarked

Required-GPU checks pass for all blend modes and resident preparation within
~one L8 level on generated inputs. Crop-origin/planar-layout assertions pass.
Standard verification: 186 Rust tests and GDScript suite pass, summary
`build/verify/unit-20261103-121801/summary.json`. Release executable rebuilt.

Repeated identical static 1080p/72 fps benchmark with existing refinements:
EdgePad-512 ~9.0 ms median; VDA ~6.4 ms; resident VDA/VDA ~34.6 ms (P95 40.8 ms),
~39.8 maps/s. Earlier VDA/VDA was ~58.1 ms / 19.2 maps/s. No model, resolution
or blending-quality reductions. Fusion GPU preparation/blending is now roughly
15–17 ms rather than the old CPU-preparation route's 9–12 ms: moving the robust
fit to a one-block GPU algorithm removes large transfers but leaves substantial
compute cost. This is not the final optimized GPU fit/filter implementation.

Evidence: `build/verify/depth-fusion-latency-20261103-121820/summary.json` and
`comparison.md`. Both repeats verify resident mode and no inference errors.
The benchmark harness now requires resident mode for fusion runs to avoid
silently measuring a fallback. Moving-scene robustness/visual equivalence
still needs checking. Installed Meteor left running unchanged.

### Media-rate compute comparison

At 30 fps static 1080p input (two 12-second runs), GPU-resident VDA/VDA measured
24.7 ms median / 26.1 ms P95, ~28.8 maps/s including model startup. Ordinary
VDA: 6.6 ms / ~29.9 maps/s. EdgePad-512: 10.6 ms / ~29.7 maps/s. Current VDA
over EdgePad: 65.9 ms / ~20.3 maps/s, because this combination retains the
nonresident CPU preparation/transfers; it is not an optimized mixed comparison.

Board-wide GPU busy: ~12%, 18%, 71%, 25% respectively for EdgePad, VDA, VDA/VDA,
EdgePad/VDA. These are coarse nvidia-smi counters, not application-exclusive
compute/FLOPs. Approximate VRAM difference from single VDA to VDA/VDA ~726 MiB;
board idle memory drifted by ~339 MiB, so do not treat board delta figures as
precise per-process allocations. Existing installed Meteor remained running.
Evidence: `build/verify/depth-fusion-latency-20261103-124918/summary.json` and
`comparison.md`. Benchmark script adds optional `--include-mixed --gpu-metrics`.

## Work toward 60 updates/s (2026-11-03)

Preserve the models, resolutions, crop, five robust-fit iterations, trimming
rule and protected blend. The original one-block fit was separately profiled
at ~12 ms; an exact-quantile parallel GPU fit tested at ~0.6–2.1 ms, with
coefficients agreeing within 0.0001 on the generated comparison fixture.

Changes under validation:
- Sample the overlap once; parallel moment reduction across many GPU blocks.
- Select the exact double-precision error order statistic using parallel
  radix histograms, rather than rescanning image coordinates 32 times per
  iteration on one block. Skip the unused final trim without skipping a fit.
- Cache Gaussian coefficients per instance; no per-pixel exponential rebuild.
- Pack fit validity with the final L8 readback, removing CPU synchronization
  between alignment and blending.
- Run existing alignment/contour refinement while bytes are still resident,
  avoiding the previous full-map D2H/H2D/D2H sequence. CPU still performs
  orchestration, final map transmission and error handling.
- Add a steady-state map counter to replay (first two seconds and final drain
  excluded), so startup does not obscure the 60 updates/s target.

Validation includes CPU/GPU comparisons, old/new fit timing and coefficients,
byte-exact resident-vs-existing CUDA final refinement, plus full replay and
standard unit checks. The old fit kernel remains as a test/profiling reference.

### 60 updates/s target reached on static replay

Optimized release benchmark, RTX 3090, two 12-second runs per rate:

| Source rate | Steady map rate | Typical median | Typical P95 |
| --- | ---: | ---: | ---: |
| 60 fps | 60.0/s | 11.8 ms | 12.9 ms |
| 72 fps | 72.0/s | 11.9 ms | 12.8 ms |

Models, crop, protected blend, 960×540 output and final refinements retained.
Full preparation/blending/refinement ~1.9–2.1 ms instead of ~15–17 ms. The
final L8/status readback is now the sole full-map CPU transfer in this native
pair; transport/control still use the CPU. Normal CPU and mixed-backend
reference paths are retained. Old fit kernel remains for profiling.

Numeric/crop tests pass. Parallel fit coefficients agree within 0.0001 in
the generated profile; resident final refinement matches the previous CUDA
refinement byte-for-byte with cleanup both off/on. Unit/GDScript passed
(186 Rust tests), `build/verify/unit-20261103-131100/summary.json`.

Evidence: `build/verify/depth-fusion-latency-20261103-131206/summary.json`
and `.../depth-fusion-latency-20261103-131239/summary.json`, with matching
`comparison.md` reports and binary/kernel hashes. Reproduce using
`meteor/tools/benchmark_depth_fusion.py --static-reference --only fusion
--fps 60 --gpu-metrics` (or 72). Steady counter excludes startup and drain;
it must not be confused with delivered maps/s including initialization.

No live quality/comfort claim: static-reference performance only. Earlier
motion/disagreement failure still requires separate work. Installed Meteor
and headset unchanged; optimized release executable built for later testing.

## Two side-by-side VDA tiles — offline still comparison

Report: `tools/model_tester/output/edgepad-vda-centre-20261103/side-by-side/`.
Reproduce using `tools/model_tester/compare_vda_tiles.py` with the existing
centre-experiment output directory. All depth outputs are 1920×1080.

The deployed VDA export is 518×294, already widescreen. Two square
1080×1080 source crops (left x=0..1080, right x=840..1920) overlap by 240px.
Both predictions are independently normalized, the right is robust-affine
matched to the left over their common overlap, then smoothstep feathered.
No third full-frame inference anchors the tile pair. Final stitched depth
is normalized for display; absolute shade is not metric depth.

Compare full-frame VDA, full+centre VDA, stretched tile inputs, and square
content fitted/padded into the widescreen input. All use the original simple
affine/feather visual experiment, not the current optimized protected runtime.
Static cold-start inference only; no temporal stability or timing claims.

Observation on the desktop background: stretched tiles recover some detail
but alter scene interpretation and retain overlap disagreement; centre detail
looks stronger around the main object. Aspect-preserving padded tiles do not
show a convincing detail gain and alter relative depth distribution. This
is a single-image visual assessment, not an accuracy metric.

With overlap, stretching yields ~921 horizontal samples across the full frame
versus 518, but still 294 vertical samples. Padding leaves only 294×294 active
content per inference (~523 horizontal samples across frame), wasting much of
the sample budget. Neither is a uniform 2× spatial-resolution improvement.

A potentially fairer export is two 392×392 square VDA inputs: 307,328 total
input pixels vs 304,584 for two 518×294 inputs (~0.9% more); 392 is divisible
by the model's 14px patch size. Existing export tools accept such shapes, but
that export/quality/runtime test has NOT been performed here. Equal pixel
count is not a guarantee of identical GPU time or quality.

### 392×392 square-tile comparison exported

User finds the stretched 518×294 tiles promising and sees no distracting
mismatch in this example. Input aspect change alone must not be treated as
proof of visibly worse output. Added a direct test against 392×392 square
inputs using the same square source crops, overlap, normalization, robust
affine fit and feather.

Unchanged checkpoint exported via `meteor/tools/export_vda_resolution.py`,
source research checkout `experiments/video_depth_anything_small`. Outputs
retained in `.build-cache/vda-square-392x392-spike/{cold,step}.onnx`, with
contract/weights SHA and `weights_changed=false`. Not installed in Meteor's
model directory or headset; native VDA runtime is still 518×294.

Both graphs pass ONNX checker. Left-crop ONNX CPU output checked against the
source PyTorch CUDA cold wrapper: max absolute difference 0.00642 on a depth
range of 8.908 (~0.072% of range), mean absolute error 0.000204. Validation
JSON saved in the comparison output. This is not streaming-history validation.

Updated same local side-by-side report with square input and full-size output
PNG, plus native-pixel closeups. Main four-panel layout: full VDA, centre
VDA, stretched 518×294 tiles, square 392×392 tiles. Original 518-only sheet
retained as `comparison-518-only.png`; padded variant remains in the viewer.
Reproduce with `compare_vda_tiles.py <centre-output> --square-vda
.build-cache/vda-square-392x392-spike/cold.onnx`.

Square pair uses 307,328 input pixels vs 304,584 for widescreen pair; actual
GPU speed is unmeasured. Qualitatively both retain useful structure on this
image, with different broad depth distributions. No winner established from
one still image; normalization shade alone is not an accuracy metric.

### Four-tile still experiment (2026-11-03)

`tools/model_tester/compare_vda_four_tiles.py` adds a four-pass 518x294 cold
VDA comparison against full-frame VDA and the previous two-tile variants.
Outputs: `tools/model_tester/output/edgepad-vda-centre-20261103/four-tiles/`.
Four 1152x648 source crops cover 1920x1080, overlapping 384 pixels horizontally
and 216 vertically. Robust positive affine alignment fits each successive tile
to the accumulated overlap; separable smoothstep weights stitch the maps.
There is no fifth full-frame anchoring inference. Source proportions are
preserved apart from normal 518x294 aspect rounding. All output maps are
1920x1080, independently display-normalized. Raw predictions are retained.
This is a CPU still-quality experiment, not a measured GPU/temporal runtime.
Four inputs total 609,168 pixels versus 307,328 for two 392x392 inputs; expected
inference work is approximately twice the two-pass experiment, but end-to-end
latency and movie temporal consistency require measurement. Sequential affine
alignment can accumulate depth-scale drift; no production integration yet.

### Live square-pair spike (2026-11-03)

Meteor's experimental depth-fusion submenu now includes **Two square VDA tiles
— 392×392 each**. Select it, then enable experimental depth fusion. Turning the
square option off restores the centre-detail configuration. Background/detail
model and blend controls are disabled in square mode because this mode always
uses two native TensorRT VDA Small 392×392 instances and affine/feather stitching.
The saved setting defaults to false for existing configurations.

Local graphs live under the normal models directory at
`vda-square-392x392/{cold.onnx,step.onnx,contract.json}`; these are the unchanged-
weight exports from `.build-cache/vda-square-392x392-spike`. There is no public
model download for this experimental shape yet. Graph contents determine engine
cache keys. The loader validates square input/output/cache tensor shapes, sizes
all model/history/CUDA buffers accordingly, and keeps the existing 518×294
contract unchanged. Both square temporal histories reset on new streams and
fusion-setting changes. First use builds TensorRT engines; this should be warmed
before a short replay, because replay intentionally stops at its input deadline.

Source is decoded at 1920×1080 when fusion is enabled. The left and right
1080×1080 source crops overlap by 240 pixels, matching the still experiment.
CUDA crops remain full precision on-device; model preprocessing uses the existing
native VDA bicubic resize/ImageNet path. Two native GPU model passes run serially.
For this first live implementation, both 392×392 float depth maps are downloaded,
normalized, bilinearly sampled into 960×540 output coordinates, robustly affine-
aligned in the common overlap, smoothstep-feathered and display-normalized on CPU.
The normal optional final edge alignment/contour cleanup then applies. This CPU
stitch is explicitly shown in status and has NOT inherited the fully resident
centre-fusion performance claims. Fit disagreement is an explicit error (existing
fusion error handling disables the experiment and resumes the selected model).
No hidden full-frame anchoring pass or four-tile mode is used.

Validation additions: square graph contract, invalid/nonfinite/constant tiles,
monotonic shared-scene ramp alignment, CUDA left/right square crop coordinates,
and an explicit ignored native square streaming smoke test. Isolated replay:
`/usr/bin/python3 meteor/tools/test_depth_fusion.py --background vda_s_518x294 --square-tiles --static-reference --modes Feather --seconds 6`.

Square-mode disagreement handling differs from the earlier centre spike: a
non-positive overlap fit skips that frame and holds the last delivered depth,
retrying on the next frame without disabling the experiment. Other failures
still disable fusion with a visible status. A changing-frame replay exposed this
case; do not confuse an active mode with guaranteed fresh depth on every frame.
CPU trimming uses exact order-statistic selection (same 85th-percentile value)
rather than fully sorting errors, to reduce stitch overhead without changing fit.

Live validation completed:
- Unit verification `build/verify/unit-20261103-193255/summary.json`: 190 Rust
  tests pass, GDScript suite passes. Default-feature compilation also passes.
- CUDA fusion tests: three pass, including square crop coordinates and existing
  resident centre-fusion parity (profiling test intentionally not run).
- Explicit square TensorRT smoke passes: cold start, three temporal steps,
  finite 392×392 outputs, reset. Initial one-time engine compilation ~173 seconds;
  synthetic model-only warm steps ~3.2–3.6 ms, not full-pipeline latency.
- Static replay `depth-fusion-20261103-193037`: valid 960×540 maps, no errors.
- Changing-frame replay after disagreement recovery
  `depth-fusion-20261103-193317`: valid 960×540 maps throughout, no inference errors;
  54 maps from 72 inputs at 12 fps, 10 startup skips, remaining gaps include
  rejected overlap fits. This is not a maximum-throughput benchmark.
- Release-optimized checkout executable launched as PID 605709, preserving user
  settings/pairings. Actual DBus tray menu confirms the new option is present
  and selectable. Experimental mode remains opt-in, not automatically enabled.

### Re-enabling square fusion: stale warm-up flag (2026-11-03)

User found square mode worked initially but subsequent enables did not apply.
Runtime log showed repeated `warm-up: non-finite depth and temporal state` and
saved fusion `enabled=false, square_tiles=true`. Unlike live `run()`, `warm_up()`
did not clear the CUDA non-finite flag before its direct cold/step calls. Fresh
CUDA allocations can contain a prior allocation's flag, so valid model results
were reported as invalid and existing fusion error handling disabled the mode.
Warm-up now clears the flag before every cold and temporal inference; checks of
actual non-finite model outputs remain enabled. The explicit square GPU smoke
seeds a stale flag, confirms the old direct cold path fails despite finite depth,
and verifies three subsequent dirty-flag warm-ups recover correctly. No model
or TensorRT cache regeneration is needed.

Warm-up fix validation: `build/verify/unit-20261103-221028/summary.json` passes
190 Rust tests and the GDScript suite. Explicit square GPU smoke passes the
seeded-flag reproduction, three corrected warm-ups and subsequent temporal
frames/reset. Corrected release executable restarted as PID 988334. The actual
tray action re-enabled the user's already-selected square mode; no video frames
were arriving at that point, so live output still awaits their next playback.
