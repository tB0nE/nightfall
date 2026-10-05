# ZipDepth Quest tiers and retained experiments

This document records the September 2026 ZipDepth investigation and the final
Android tier policy. Generated model files remain ignored by git, but their
filenames, conversion paths, architecture, and reasons for retention are kept
here and in `models/README.md` so a useful experiment is not accidentally
repeated or discarded.

## Production Android models

Since 2026-10-04 the EdgePad classes run the widescreen EdgePad family:
one retrained checkpoint (SHA-256 `2dc8fddcef9ef22f45b6a1573b9cf66de0f39b1b5172e4284dd693790bd6309e`) exported at three 16:9
sizes by the model researcher (`nightfall-temporal-zipdepth`,
`reports/NIGHTFALL_WIDESCREEN_FAMILY_HANDOFF.md`). Android ships two of
them: EdgePad-512 and EdgePad-320. The family's 352x198 model (352x224
tensor) was dropped because it has 20% more pixels than the EdgePad-256 it
would have replaced, so Quest 2 Auto and the Quest 3 OpenCL fallback now use
EdgePad-320, which has 6% fewer. Saves that chose EdgePad-256 move to
EdgePad-320; the square exports described further down
remain in `models/` as the rollback (see `DepthEstimator.java`'s EdgePad
registrations).

| UI choice | Java index | Model | Image -> tensor | Default backend |
|---|---|---|---|---|
| Auto, Quest 3/3S | 25 | EdgePad-512 | 512x288 -> 512x288 | OpenCL |
| Auto, Quest 2 | 28 | EdgePad-320 | 320x180 -> 320x192 | OpenGL |
| EdgePad-512 | 25 | `zipdepth-wide-512x288-edgepad-gpu.tflite` | 512x288 -> 512x288 | User-selected |
| EdgePad-320 | 28 | `zipdepth-wide-320x180-t320x192-edgepad-gpu.tflite` | 320x180 -> 320x192 | User-selected |
| Any, Backend: CPU | 29 | EdgePad-256-CPU (square, unchanged) | 256x256 -> 256x256 | CPU (XNNPACK, no GPU delegate) |

EdgePad-320 takes a 16:9 image padded to a taller tensor: the capture is at
the image size, `runInferenceGpu()` repeats its top and bottom rows into 6
padding rows each side, and the output is unpacked to the full tensor and
only then cropped back to the image rows (cropping the packed tensor would
shift a row for an odd pad). Never pad with black
or stretch the image to the tensor height.

The "Backend" control's third state (`tools/quantize_zipdepth_cpu.py --size
256`, int8 weights/float32 activations) overrides whatever Model is currently
selected and runs EdgePad-256-CPU instead - the only AI 3D option on Android
that uses zero GPU time, for when the stream and passthrough need all of it.

Quest 3/3S Auto falls back to EdgePad-256/OpenGL for the current session if
the EdgePad-384 OpenCL delegate fails. Quest 2 starts there directly because
its firmware does not expose the Qualcomm OpenCL library available on Quest 3.

“Linear” changes only the depth conversion into Nightfall's quarter-stream
working surface. Standard still runs the production Full path: occlusion
search and Newton refinement remain enabled. It is implemented as native
process stage 6 (`Full+Linear`), not the visually similar debug `Raw` stage,
which would disable those later reconstruction steps.

## What the two models actually change

Both derive from the standard ZipDepth checkpoint and retain its complete
learned convex reconstruction head:

- EdgePad-384 takes 384x384 input. Its shared trunk predicts a 192x192
  half-depth map, then the learned convex reconstruction head predicts masks,
  combines neighbouring depth values, and reconstructs 384x384 output.
- EdgePad-256 applies the same graph and weights at 256x256. Its trunk predicts
  128x128 half-depth and reconstructs 256x256 output. This reduces work across
  the complete network while retaining the head that proved essential to
  clean full-screen geometry.

## Standard-head optimization findings

The original Standard reconstruction used replicate padding, a 36-channel
mask convolution, a five-dimensional softmax/layout tail, and
`DEPTH_TO_SPACE`. Several mathematically exact rewrites were tested:

1. Emit packed 192x192x4 output and interleave the four subpixels in Java.
2. Reorder channels into four ordinary nine-channel softmax branches.
3. Split the final 36-channel mask convolution into four nine-channel
   convolutions.
4. Express the weighted reductions as fixed 1x1 convolutions.
5. Replace delegate-hostile `MIRROR_PAD`.

The important bottleneck was not reconstruction arithmetic. Unsupported
replicate padding split the LiteRT graph and read approximately 5.06 MiB of
intermediate softmax tensors back to the CPU every inference. ZeroPad kept all
217 operations in one OpenCL partition and reduced a roughly 29.2 ms candidate
to about 17.6 ms on Quest 3, but changed the outermost one-pixel border.

EdgePad reconstructs exact replicate padding from edge slices and
concatenation while remaining delegate-compatible. Local comparison against
Standard-v1 measured correlation `0.9999999999999908`, normalized MAE
`3.59e-8`, and edge MAE `2.38e-8`. It therefore became Standard.

Standard-v2 and Standard-v3 are retained references. They were equal to or
slower than Standard-v1 on the headset and offer no quality advantage.
ZeroPad is retained because it proved the full-GPU graph and may still be
useful on a backend where its tiny border difference is irrelevant.

## 256-input head comparison

Two 256x256 standard-checkpoint variants were exported to compare directly
with the existing 256x256 Hybrid/NPU-head model:

- Standard EdgePad-256 runs the complete learned reconstruction head. It
  emits packed 128x128x4 output, which is interleaved exactly to 256x256, and
  originally used linear conversion to Nightfall's 480x270 working surface.
- Direct-128 keeps the same 256x256 standard-checkpoint trunk but ends at the
  native 128x128 half-depth tensor. It uses the guided 5x5 conversion.
- Existing ZipDepth-256 takes and outputs 256x256 through the Hybrid/NPU head
  and also uses guided 5x5 conversion.

Across a desktop scene, room, dog, and basketball scene, all three produced
very similar large-scale depth. Relative to EdgePad-256 at 480x270,
Direct-128 correlation ranged from 0.9958 to 0.9980 and existing ZipDepth-256
from 0.9955 to 0.9980. Direct-128 and ZipDepth-256 were visually almost
indistinguishable after guided conversion; EdgePad-256 produced slightly
cleaner, smoother reconstructed boundaries while the guided variants showed
slightly stronger edge response. Desktop XNNPACK timings are not a proxy for
Quest GPU latency, so these exports remain local comparison models until an
on-headset profile justifies changing the production tiers.

An expanded four-scene sheet added Standard EdgePad-384 as the quality
ceiling. The 384-input model recovered materially more scene structure—notably
small furniture, lamp geometry, and separation between nearby people—than all
three 256-input paths. A temporary release test build exposed `EdgePad-256`
and `Direct-128` alongside Auto, Standard, Fast, and Fastest so their actual
OpenCL/OpenGL latency could be measured on Quest.

## Final headset comparison and decision

The five-way Quest 3 comparison produced these approximate steady inference
times (milliseconds):

| Model | OpenCL | OpenGL |
|---|---:|---:|
| ZipDepth-256 Hybrid | 13.5 | 23.8 |
| EdgePad-256 | 14.8 | 24.4 |
| Direct-128 | 13.3 | 23.1 |
| Direct-192 | 16.5 | 41.0 |
| EdgePad-384 | 18.0 | 43.0 |

The raw and resized local comparison sheets understated the practical quality
difference. In-headset, the Direct outputs became visibly blocky when their
coarse depth and displacement fields were expanded across the full stream.
Guided 5x5 conversion improved the quarter-stream depth texture, and linear
sampling of the final displacement field softened its grid, but neither could
recover geometry omitted with the learned reconstruction head. The Hybrid
head was fast and surprisingly close in static comparisons, yet the final
warp still showed a large loss of fine structure compared with EdgePad.

`DMap-Warp` made this distinction clear by exposing the final occlusion offset
field rather than only the raw or resized depth map. The EdgePad models were
the only candidates that remained consistently clean at actual viewing size.
Their reconstruction cost was small—about 1.3–2 ms in these comparisons—while
the perceived quality improvement was substantial. EdgePad-384 and
EdgePad-256 therefore became the original production Android models. A later
manual-only EdgePad-224 tier was added to investigate sustained 60Hz inference. Direct,
Hybrid, and intermediate Standard exports remain retained references, not APK
assets or UI choices.

## Reconstruction and resizing findings

The native production conversion writes a quarter-stream depth surface (for
example 480x270 for a 1920x1080 stream). The old guided pass examines a 5x5
neighbourhood: 25 depth and 26 colour lookups per output pixel.

Local comparisons evaluated linear, bicubic, guided 3x3, depth-gated 3x3, and
guided 5x5 conversion:

- Standard already contains a strong learned reconstruction head. Linear
  retained its sharp output consistently and avoids applying a second broad
  smoothing filter. Bicubic was similarly good but offered only a tiny visual
  change and can ring around abrupt depth boundaries.
- Direct-192 was different. Its coarse output visibly benefited from the
  larger 5x5 guided neighbourhood; it approached Standard-5x5 more closely
  than linear, bicubic, 3x3, or depth-gated conversion.
- The guided pass previously produced a filtered 480x270 depth texture, but
  the later occlusion pass wrote an offset texture sampled with nearest
  filtering during the full-resolution warp. At 1080p, one offset texel can
  therefore cover roughly a 4x4 output block. A Direct-only process stage kept
  guided 5x5 conversion but sampled that offset field linearly. This was a
  clean, zero-extra-pass experiment for reducing visible block boundaries.
  It softened transitions but did not repair the Direct models' missing
  reconstruction detail and was removed from the production renderer.
  The Android `DMap-Warp` debug view displays this final offset field after
  sampling. Mid-grey is zero displacement, lighter and darker values are the
  two horizontal directions, and contrast is amplified four times. Each eye
  displays its own offset channel, with the right-eye debug polarity inverted
  so corresponding geometry has the same brightness in both eyes.
- Hybrid ZipDepth-256 remains a retained reference but is no longer bundled.
- Hard neighbour selection was rejected because it sharpened edges by adding
  contouring.
- Depth-gated 3x3 uses high-resolution colour only where the model itself
  reports a depth discontinuity. It remains a retained experiment, but its
  inconsistent gain did not justify replacing linear for Standard.

### Temporal/guided retest (2026-09-27)

The exact native `DMap-Final` view exposed two motion issues hidden by the old
debug paths: visible 20 Hz stepping and unstable frame-to-frame normalization.
The production EdgePad variants now restore Moonlight Android XR's intended
smoothing behavior using cadence-independent equivalents:
depth tau 0.055 seconds (60% new data at 20 Hz) and range tau 0.308 seconds
(15% new range at 20 Hz). A native scale-matched 5x5 colour-guided conversion
was retried independently but looked blocky in-headset, so production returned
to hardware-linear conversion while retaining the new temporal settings. A
second conservative guided-linear test reweighted only the four bilinear taps,
used a depth-span gate to protect flat text and texture, and blended guidance
at 65% only across an existing 0.025-0.08 depth discontinuity. It produced
practically no visible improvement while requiring ten texture lookups and
four exponential weights per output pixel, so production remains plain linear.
The implementation and local comparison preset are retained for reference.

## Widescreen and resolution findings

480x270 cannot be a native ZipDepth input because both dimensions must be
divisible by the network's stride of 32. 512x288 is the clean exact-16:9
alternative and has the same pixel count as 384x384.

The 512x288 EdgePad output retained attractive direct-sampled edges, but its
overall depth prediction regressed. The dominant problem was not resizing
512x288 to 480x270; guided and direct versions were close. The pretrained
weights were learned at square 384x384, and changing the inference shape
changed the model's depth behaviour. A future 512x288 model needs widescreen
fine-tuning/distillation rather than another post-processing filter.

## Files to retain

Do not delete the following local exports merely because normal APKs no longer
bundle them:

- `zipdepth-base-384-standard-mobile-gpu.tflite` (Standard-v1 reference)
- `zipdepth-base-384-standard-mobile-v2-gpu.tflite`
- `zipdepth-base-384-standard-mobile-v3-gpu.tflite`
- `zipdepth-base-384-standard-packed-gpu.tflite`
- `zipdepth-base-384-standard-packed-softmax4-gpu.tflite`
- `zipdepth-base-384-standard-packed-conv4-gpu.tflite`
- `zipdepth-base-384-standard-packed-conv4-reduceconv-gpu.tflite`
- `zipdepth-base-384-standard-packed-conv4-reduceconv-zeropad-gpu.tflite`
- `zipdepth-base-384-standard-packed-conv4-reduceconv-edgepad-gpu.tflite`
- `zipdepth-base-384-direct-half-gpu.tflite`
- `zipdepth-base-384-gpu.tflite` (Hybrid-v1 reference)
- `zipdepth-base-384-hybrid-v2-gpu.tflite`
- `zipdepth-base-256-gpu.tflite`
- `zipdepth-base-256-standard-packed-conv4-reduceconv-edgepad-gpu.tflite`
- `zipdepth-base-256-direct-half-gpu.tflite`
- `zipdepth-base-512x288-gpu.tflite`
- `zipdepth-base-512x288-standard-packed-conv4-reduceconv-edgepad-gpu.tflite`
- `zipdepth-base-672x384-gpu.tflite`

The exporter and comparison tools remain in `tools/export_zipdepth_gpu_safe.py`,
`tools/convert_zipdepth.py`, and `tools/model_tester/`. Detailed profiling
history is retained in
`docs/plans/active/zipdepth-standard-direct-profiling.md`.

## Next measurements

1. Confirm Auto selects EdgePad-384/OpenCL on Quest 3 and Quest 3S.
2. Confirm Auto selects EdgePad-256/OpenGL on Quest 2.
3. Measure EdgePad-256/OpenGL inference and end-to-end quality on Quest 2.
4. Pursue future speed gains through training/distillation or graph/backend
   optimization while retaining a learned reconstruction head; cheap filters
   on a coarse Direct output are not an adequate substitute.
