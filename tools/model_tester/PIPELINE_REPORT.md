# Offline native depth pipeline report

Run from the repository root:

```sh
.build-cache/model-tester-venv/bin/python tools/model_tester/pipeline_report.py \
  tools/model_tester/eg_input_1.png \
  tools/model_tester/pipeline_models.example.json \
  tools/model_tester/output/my-comparison
```

Open the generated `index.html` directly in a browser. The landing page shows
embedded images, so the HTML can be moved or shared without sibling PNG files.
The landing page shows
all final depthmaps together in a responsive comparison grid. Click a model to
open its detailed view; Back to comparison returns to the grid. In detail view,
select models on the left;
hold the final-image button or Space to inspect warped colour, then release to
return to depth. Choose either colour eye, model input, normalized depth, final
depth, or warp offsets. The original image is available for alignment checks.
Use **Compare 2** on the overview, then select two distinct model cards to open
a side-by-side view with synchronized depth and colour controls. Click a
selected card again to deselect it before choosing the second. The image's
top-right fullscreen button expands either the single or paired view; Escape
exits fullscreen and Space still switches to warped colour.
Images retain the source resolution. Raw float depth and machine-readable
metadata are retained alongside the report. Reports contain desktop content:
review before sharing them publicly.

To include the three installed Meteor ONNX models (384, 512×288, 672×384):

```sh
.build-cache/model-tester-venv/bin/python tools/model_tester/pipeline_report.py \
  tools/model_tester/eg_input_1.png \
  tools/model_tester/pipeline_models.example.json \
  tools/model_tester/output/native-meteor-pipeline-report-20261012 \
  --meteor-models /home/tyrone/.local/share/nightfall-meteor/models --include-vda
```

These entries are labelled **controlled input**: ONNX and TFLite use the same
native capture/resampling/warp reference, not separate live transport pipelines.
Missing Meteor models fail explicitly rather than silently omitting entries.
`--include-vda` adds the actual Meteor VDA Small cold-start graph with ImageNet
normalization and a one-frame temporal input. This does not simulate recurrent
state or Meteor's bicubic VDA preprocessing/optional edge softening: it uses
the report's controlled 4×4 capture and common final processing. Consequently
it is useful for spatial alignment inspection, not a streaming VDA quality test.

## Environment

Requires NumPy, Pillow, ai-edge-litert, ONNX Runtime, ModernGL and an EGL driver
supporting OpenGL 4.3. The local environment uses the existing Python model
dependencies through `--system-site-packages`:

```sh
/home/tyrone/.pyenv/versions/3.12.2/bin/python3 -m venv --system-site-packages .build-cache/model-tester-venv
.build-cache/model-tester-venv/bin/pip install moderngl
.build-cache/model-tester-venv/bin/python -m unittest discover -s tools/model_tester -p test_pipeline_report.py
```

## Model manifest

The JSON file is a list of model specifications. Paths are relative to the
manifest. Input sizes are `[width,height]`; explicitly specify `input_layout`
(`nhwc`/`nchw`/`ntchw`) and `output_layout` (`packed2x2`/`nhwc`/`nchw`/`hw`).
`packed2x2` is Nightfall's NHWC four-channel pixel-shuffled output, **not** an
ordinary four-channel depth map. `pad_rows` replicates image-edge rows and crops
them after reconstruction. Optional `preprocessing` is `rgb01` (default) or
`imagenet`. Float32 TFLite only; unsupported quantized inputs fail explicitly.
ONNX example:

```json
{"name":"Meteor EdgePad-384, controlled input",
 "path":"/path/to/zipdepth_edgepad_384.onnx",
 "input_size":[384,384],"input_layout":"nchw","output_layout":"nchw"}
```

## What is reproduced, and what is not

The runner extracts shader sources from the current native renderer on every
run, rather than maintaining approximate copies. Only GLES-to-desktop syntax
and external-video-to-2D sampler adaptation are applied. It uses production
4x4 capture filtering, edge padding, packed-output decoding, first-frame
2% histogram normalization and 8-bit truncation. It executes the production
plain-linear resampling, RGBA8 intermediate grids, occlusion search and Full
warp shaders, with default 75% separation / 50% convergence. The working-grid
selection follows native linear mode. Override UI percentages with
`--separation` and `--convergence`.
Matching-aspect maps use at least the quarter-stream grid: at 1080p,
EdgePad-320 is resized to 480×270 while EdgePad-512 stays at 512×288.
Offset textures use nearest sampling, matching native production (earlier
report versions incorrectly used linear offset sampling).

This is a **controlled native SDR still-image reference**, not a claim of exact
live-device equivalence. All models use the same canonical upright native
capture input, including ONNX; Meteor's live capture/normalization/transport
are not simulated. Inference is CPU, not Quest OpenCL/OpenGL or Meteor CUDA.
There is no temporal history, frame synchronization, HDR conversion,
SurfaceTexture transform, picture adjustment, compositor or stream encoding.
Desktop floating-point/compiler differences remain. Source checksums, driver,
model checksums, settings and intermediate dimensions are recorded; desktop
load-plus-inference timings are **not headset benchmarks**.

These boundaries matter for investigating the current widescreen issue:
compare exported headset capture/raw/processed snapshots with these inputs and
outputs before attributing a discrepancy to conversion or shader processing.
Video temporal evaluation and a faithful Meteor-specific processing profile
remain follow-up work, not part of this first still-image report.

## Static edge-alignment experiment (local only)

```sh
.build-cache/model-tester-venv/bin/python tools/model_tester/pipeline_report.py \
  tools/model_tester/eg_input_1.png \
  tools/model_tester/edge_alignment_models.example.json \
  tools/model_tester/output/edge-alignment-comparison --edge-alignment
```

Each model gets a production **linear** baseline, **bounded-2** (two native
depth-texel search radius, 75% correction) and **bounded-3** (the same search
radius/strength plus the quality refinements below). Bounded-1 is no longer
listed or generated; old output folders are retained for reference.
Inference and normalization are shared; only the post-model resize/refinement
differs. The experimental GLSL is NOT deployed to the headset or Meteor.

### Bounded-3 changes

- Generate a signed displacement/confidence field instead of applying each
  pixel's proposed correction immediately. A broad/multi-peak colour match
  reduces confidence using the weighted candidate-position variance; this is
  a heuristic, not a guarantee that ambiguous edges are correctly classified.
- Regularize that field along the local depth-edge tangent with four adjacent
  working-grid neighbours. Depth/confidence/displacement agreement weights
  limit mixing across unrelated boundaries. Reproject onto the local normal;
  the maximum correction remains 1.5 native depth texels (2 × 75%).
- Store both the signed correction field and refined depth in RGBA16F, rather
  than rounding the refined result to RGBA8 before the offset/warp passes.
  Model output normalization/input remains the SAME uint8 map as Bounded-2;
  this does not recover information already lost there. PNG previews are
  still 8-bit. Inference, model weights and final warp algorithms are unchanged.
- No global blur or temporal smoothing is introduced. This adds a second
  local shader pass; runtime optimization/Quest benchmarking remain future
  work. Do not attribute every quality difference to coherence alone, since
  precision and ambiguity handling change too.

The extra GPU tests cover signed field storage, precision, competing colour
boundaries and an injected alternating-pixel correction wobble. The wobble
test caught native-texel neighbour spacing skipping alternating pixels on
integer-upscaled grids; smoothing now samples adjacent working-grid pixels.

To add VDA alone (without the other Meteor EdgePad exports), append:

```sh
--vda-model /home/tyrone/.local/share/nightfall-meteor/models/vda_s_518x294_cold.onnx
```

VDA gets the same three processing variants and overlays. This is the actual
Meteor VDA Small cold-start graph with ImageNet input normalization, but still
a single-frame, controlled-input comparison: it excludes live recurrent state,
Meteor's bicubic capture, model-specific edge softening and temporal processing.
It tests spatial refinement, not full live VDA equivalence.

The experiment looks along an existing depth-gradient direction, estimates
nearby depth/colour boundary positions, and shifts the depth sampling position
toward their alignment. Depth strength, colour contrast, gradient orientation
and proximity gate the change. It cannot introduce depth into a flat region,
but colour texture/shadows near a real depth boundary can still mislead it.
It cannot recover missing geometry or resolve ambiguous object boundaries.
This is a heuristic to compare, not a production recommendation or proven win.

Select **Original + depth edges (cyan)** in the overview or detail view to see
depth-gradient ridges drawn on the unwarped source. These are diagnostic depth
edges, not ground-truth object masks; quantization can make the contour speckled.
Use Compare 2 for baseline versus bounded versions of the SAME model. The
Space/hold button intentionally shows a warped eye image; do not use its shift
relative to unwarped depth as a spatial-alignment error measurement.

Tests now check the production GL resize against pixel-centre coordinates,
an intentionally misplaced synthetic boundary, flat depth with colour edges,
and depth with a flat colour guide, plus the Bounded-3 tests above. A passing synthetic test does not establish
quality on real content or headset processing cost. The report remains a
first-frame/static test without temporal smoothing. Runtime/model timings in
these reports are not Quest benchmarks.

The first generated suite lives under
`tools/model_tester/output/edge-alignment-20261014/index.html`, with separate
desktop, animation/hair and live-action/shadow reports, including VDA alongside
the three EdgePad models. Existing October 12
reports are preserved. Initial desktop inspection shows subtle boundary changes,
not an established overall quality win; review individual edges and warped
artifacts before deciding whether to pursue or deploy either variant.

### Bounded-4: focused EdgePad-384 contour cleanup

```sh
.build-cache/model-tester-venv/bin/python tools/model_tester/pipeline_report.py \
  tools/model_tester/output/native-meteor-pipeline-report-20261012/original.png \
  tools/model_tester/edge_alignment_384.example.json \
  tools/model_tester/output/edge-alignment-20261014/384-contour-desktop \
  --edge-alignment --contour-cleanup
.build-cache/model-tester-venv/bin/python tools/model_tester/build_contour_inspection.py \
  tools/model_tester/output/edge-alignment-20261014/384-contour-desktop
```

Bounded-4 starts from the unchanged RGBA8 Bounded-2 result. A separate RGBA16F
pass estimates its contour direction with a Sobel gradient, then filters depth
only along the tangent (four neighbours, binomial weights), not across the
foreground/background boundary. A narrow-ridge/valley guard protects thin
features, and gradient/local-range limits bound the change. No colour guide is
used in the cleanup itself. This is not a replacement for model training or a
general silhouette reconstruction method; curved corners can still be altered.

Initial manually selected desktop-region measurements (pixels at 2560×1440):

| Region | Bounded-2 roughness | Bounded-3 | Bounded-4 |
| --- | ---: | ---: | ---: |
| Back-left edge | 0.521 | 0.493 | 0.500 |
| Middle-left edge | 0.413 | 0.167 | 0.219 |
| Rounded front-left lip | 0.361 | 0.414 | 0.358 |

These estimate residual after a quadratic fit to an image-gradient contour,
NOT ground-truth depth accuracy. Bounded-4 helps the middle edge versus 2 but
does not beat 3 there; the rounded lip barely changes. Do not call this an
overall quality win. The close-up page includes original, depth, overlay and
warped-colour crops at 1×/2×/4× nearest-neighbour pixel zoom, with reproducible
measurement boxes/metrics in `contour-metrics.json`.

Only the new 384 reports include Bounded-4. The prior all-model reports, 512/VDA
results, headset and Meteor runtime remain unchanged. GPU tests also exercise
injected depth-contour wobble and preservation of flat/straight/thin features.
