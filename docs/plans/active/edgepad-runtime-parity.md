# EdgePad runtime quality and alignment investigation

Reference: `tools/model_tester/eg_input_1.png` (desktop blue stepped structure).
Branch: `feat/final-depth-map-view`. Started 2026-10-12.

## Completed checks

`tools/model_tester/check_edgepad_pipeline.py` runs the exact shipped TFLite
graphs on desktop CPU and compares matching local Meteor ONNX graphs using
identical RGB input. It preserves raw arrays and literal 480x270 comparison
tiles. This is graph parity, not a Quest GPU performance or precision test.

Results for this reference, mean absolute normalized-depth differences:

| Model | TFLite versus Meteor ONNX | Inverted input, output restored |
| --- | --- | --- |
| EdgePad-384 | 0.001479 | 0.118646 |
| EdgePad-512 | 0.000547 | 0.224527 |
| EdgePad-320 | No matching host graph tested | 0.140717 |

This substantially narrows, but does not eliminate, conversion differences.
Upside-down inference is especially damaging to the widescreen model on this
image; flipping its output back does not undo the semantic degradation.

Native capture uses the display-copy vertex shader's additional Y inversion,
then reverses framebuffer rows. Native video uses its own unmodified UVs and
the SurfaceTexture matrix. Establish the actual captured-image orientation
before changing either flip.

## Headset capture finding and correction (2026-10-12)

Actual 256 and 512 native-capture PNGs were upside down, including the taskbar
and clock. `tools/model_tester/compare_headset_capture.py` replays the exact
captured pixels, compares CPU inference against captured GPU float depth, and
then runs the model on upright input. Results:

| Model | GPU vs CPU normalized MAE, identical input | Upright vs inverted normalized MAE |
| --- | --- | --- |
| EdgePad-256 | 0.00584 | 0.12796 |
| EdgePad-512 | 0.00721 | 0.26483 |

CPU replay of the inverted 512 input reproduces the washed-out foreground.
Upright input restores considerably better depth. This supports orientation,
not graph conversion, as the primary cause in this example. These are single
captures, not a general guarantee of GPU numerical equivalence.

The same extra UV inversion plus row reversal exists in the v0.7.11 tag;
the square models were already affected, but the widescreen model is more
sensitive on this scene. Historical headset quality remains subjective;
we have not captured the old APK here.

Correction: preserve native glReadPixels row order because the shared blit
shader already reverses source UV.y. Inference then receives upright input.
Flip the on-device map at the GDScript texture-upload boundary when native
capture is active, matching the existing Meteor upload convention. Do not
change shared video blit UVs, Meteor processing, or viewport fallback.
Validate corrected capture orientation AND final colour/depth alignment on
the headset before considering this closed.

User testing of the optimized deployed build confirmed a substantial visual
improvement after the orientation correction. Additional feedback: square
EdgePad-256 looks better than widescreen EdgePad-320, which appears very
pixelated. Keep this as a separate quality/resampling investigation; model
choices and Auto defaults have not been changed by this fix. Corrected capture
replay and broader native/legacy alignment validation remain useful checks.

Java square/wide GPU models share percentile clipping and smoothing settings.
The 320 model repeats six border rows at each end of its 192-row tensor and
crops these after unpacking; 512 has no such padding.

## Opt-in headset snapshots

The release-optimized APK supports a one-shot startup marker named
`depth_capture_once` in external app files. Initialization consumes it and
enables one capture per GPU model asset for that process. Normal inference
does not check files or dump images. Restart without the marker to disable.

Snapshots in external app files under `depth-parity/` contain:

- The exact RGBA capture interpreted as an input PNG.
- Unpacked/cropped raw model depth, little-endian float32.
- Production normalized and temporally smoothed depth, uint8.
- Dimensions, asset name, padding and normalization range in JSON.

These files contain desktop content; keep local and do not include them in
ordinary diagnostic exports. The diagnostic write stalls one inference per
model, so do not use those samples for latency measurement. Filenames are
reused across diagnostic sessions; archive pulled output before another run.

## Remaining checks

1. Display the reference still and capture headset 384, 512 and 320 outputs.
2. Inspect input orientation and compare GPU raw output against the same
   graph on CPU with the *captured* input, reproducing Java's nearest-index
   sampling and repeated padding rather than resizing with Lanczos.
3. Compare production normalization with fresh histogram normalization;
   account for range smoothing immediately after switching models.
4. For Meteor alignment, compare a static depth map against the unwarped
   source and distinguish inference feature errors from geometry changes.
   Check SurfaceTexture cropping, decoded display area, model input aspect,
   map dimensions and any source-region/stereo mapping. A simple resize
   restores coordinates when both input and output use the same full-frame
   region; differing aspect ratios alone do not prove a mapping bug.
5. Validate any fix on square/wide models, headset/Meteor, and native/legacy
   presentation before changing production defaults.
