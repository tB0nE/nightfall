# Training the ZipDepth Hybrid-v2 mobile head

Status: experimental, first trained checkpoint produced 2026-09-25.

Hybrid-v2 is a small learned improvement to Nightfall's fast ZipDepth mobile
upsampler. It is intended to move the Hybrid model toward the sharper Standard
model without changing the encoder, decoder, or half-resolution depth
prediction that account for almost all inference cost.

## What is being trained

The Standard and Hybrid models share the same standard ZipDepth backbone and
decoder. Their final 2x upsampling heads differ:

- Standard predicts nine neighbor weights for each of four output subpixels.
  This is sharp and expressive, but its softmax/reduction-heavy head costs much
  more on the Quest GPU.
- Hybrid predicts one half-resolution alpha map and blends nearest-neighbor and
  bilinear depth. It is fast and mobile-safe, but one smooth alpha value cannot
  position all four pixels in each 2x2 output cell independently.
- Hybrid-v2 keeps the complete pretrained Hybrid path and predicts four cheap
  corrections per half-resolution pixel. `pixel_shuffle` maps those corrections
  to the four output subpixels before they adjust Hybrid's blend.

The added branch is:

```text
32-channel half-resolution feature map
  -> 1x1 convolution (8 channels)
  -> ReLU
  -> 1x1 convolution (4 channels)
  -> depth-to-space / pixel shuffle (one full-resolution correction)
  -> bounded correction to Hybrid alpha
```

The final projection starts at zero. Before training, Hybrid-v2 therefore
produces exactly the same output as Hybrid-v1. This gives the experiment a safe
baseline: any output change was learned rather than introduced by random head
initialization.

The new branch contains 300 parameters. Including Hybrid's existing
`where_conv`, training updates 1,260 of ZipDepth's 6,142,134 parameters
(`0.0205%`). This resembles parameter-efficient fine-tuning in spirit, but it
is not LoRA: the small output head itself is trained while the main network is
frozen.

## Teacher/student distillation

`tools/train_zipdepth_hybrid_v2.py` loads two models:

1. The unchanged Standard checkpoint is the teacher. It generates the desired
   sharp depth map for each RGB frame.
2. The Hybrid-v2 model is the student. Its backbone and decoder are frozen;
   only the mobile upsampling head receives gradients.

The first experiment generates teacher depth online. This is practical because
the RTX 3090 can run both small ZipDepth networks comfortably and the corpus is
small. A larger custom-model run should cache teacher maps once, especially if
DA-V2 Large or Marigold becomes the teacher.

The objective combines:

- Scale-and-shift invariant depth loss, which teaches relative scene geometry
  without requiring teacher and student to share an absolute depth scale.
- A strongly weighted multiscale gradient loss, which targets the boundary
  sharpness that Hybrid-v1 lacks.
- A small relative raw-output loss, which discourages needless changes to the
  teacher's output range.

Training and validation must be split by complete source title or recording,
not individual frames. Adjacent video frames on both sides of a random split
would leak nearly identical scenes into validation.

## Preparing a media corpus

The corpus builder samples sparse timestamps, limits the contribution from any
one title/category, and assigns complete titles to train or validation:

```bash
python3 tools/prepare_zipdepth_media_corpus.py \
  /path/to/video/library \
  model-training/v1 \
  --titles-per-category 14 \
  --videos-per-title 2 \
  --frames-per-video 10 \
  --workers 4
```

Inspect the generated contact sheets or a broad random sample before training.
Remove broken decodes and corpora dominated by black transitions, credits, or
near-duplicate footage. The initial Nightfall run used 990 training and 190
held-out validation frames across films, series, games, animation, music
videos, 3D video, and YouTube. A future serious run should add a clean desktop
UI subset because entertainment media does not adequately cover small text,
windows, icons, and application chrome.

Frames are currently resized to 384x384 on purpose. That reproduces Nightfall's
current square model input, including the aspect distortion applied to a
widescreen stream. Widescreen-model training should preserve its chosen target
aspect ratio instead.

## Training

```bash
MPLCONFIGDIR=/tmp/matplotlib-nightfall \
python3 tools/train_zipdepth_hybrid_v2.py \
  --train-dir model-training/v1/train \
  --val-dir model-training/v1/validation \
  --output .build-cache/model-training/zipdepth-hybrid-v2.pth \
  --epochs 12 \
  --batch-size 16 \
  --workers 4
```

The trainer saves the checkpoint with the best validation loss, not merely the
last epoch. Watch the individual SSI and gradient values as well as total loss.
A lower training loss paired with a rising validation loss indicates
overfitting; more epochs are not automatically better.

The first media run improved held-out total loss from `0.074668` to `0.073711`
and multiscale gradient error from `0.014544` to `0.014298`. This is a modest,
conservative result and still requires visual and on-device performance
comparison before the architecture is accepted.

## Exporting for LiteRT

```bash
NIGHTFALL_MODEL_PYTHON=python3 \
python3 tools/convert_zipdepth.py \
  --shape 384x384 \
  --head-mode hybrid-v2 \
  --weights-mode hybrid \
  --hybrid-v2-checkpoint .build-cache/model-training/zipdepth-hybrid-v2.pth \
  --force
```

The output is `models/zipdepth-base-384-hybrid-v2-gpu.tflite`. The exporter
applies Nightfall's existing Adreno-safe graph rewrites and checks the rewritten
PyTorch graph before ONNX/TFLite conversion. LiteRT compatibility is necessary
but not sufficient: the final acceptance test is matching raw output from the
Quest GPU and desktop TFLite CPU for the same captured input.

## How to judge the experiment

Compare Hybrid-v1, Hybrid-v2, Standard-v2, and Standard under identical stream,
backend, GPU-priority, and Hz-cap settings. Evaluate:

- Fine boundaries and small text in `DMap-Raw`.
- Warm inference latency and achieved depth cadence.
- Stream frame pacing while inference runs.
- Edge-transition width, multiscale gradient error, and false edges in flat
  regions on held-out frames.
- Stability while switching models, reconnecting, and resuming from standby.

Do not select a model from aggregate loss alone. A small metric improvement may
be invisible, while an aggressive edge loss can create sharp-looking false
geometry. The model is useful only if its visible gain is worth its measured
Quest cost.

## Relevant files

- `tools/zipdepth_hybrid_v2.py`: mobile head architecture.
- `tools/train_zipdepth_hybrid_v2.py`: teacher/student training loop.
- `tools/prepare_zipdepth_media_corpus.py`: balanced media sampling.
- `tools/prepare_zipdepth_video_frames.py`: extraction from one clean recording.
- `tools/export_zipdepth_gpu_safe.py`: checkpoint loading and GPU-safe export.
- `tools/convert_zipdepth.py`: end-to-end conversion entry point.
