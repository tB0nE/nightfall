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
