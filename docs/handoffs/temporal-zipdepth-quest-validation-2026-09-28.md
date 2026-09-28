# Temporal ZipDepth Quest validation handoff

Updated: 2026-09-28

## Purpose

This report hands the 512x288 temporal/widescreen ZipDepth experiment back to
the training project. Nightfall device integration has proved that the proposed
packed-output architecture can run through LiteRT/OpenCL on Quest 3. The pilot
checkpoint does not have acceptable visual quality and must not be promoted to
Auto, a production tier, or a release.

Nightfall development is now returning to Linux testing and release
preparation. Continue model training independently in:

`/var/home/tyrone/Development/Personal/nightfall-temporal-zipdepth`

Do not make further experimental model changes in Nightfall unless a new
checkpoint has passed the offline quality gates described below.

## Tested artifact

- Source: `local-data/exports/tiny_overfit_512x288/tflite/student_512x288_edgepad_float16.tflite`
- SHA-256: `eb049eec051725fb4618ca97990af53ab6c87f995c578bddede3e18de28b7d22`
- Size: 12,342,180 bytes
- Input: float32 NHWC `[1, 288, 512, 3]`
- Output: float32 NHWC `[1, 144, 256, 4]`
- Output packing: 2x2 spatial subpixels in channel order:
  1. even row, even column
  2. even row, odd column
  3. odd row, even column
  4. odd row, odd column

The final ReLU included by the export was retained.

## Nightfall test environment

- Device: Quest 3, Adreno 740
- Runtime backend: Qualcomm OpenCL through LiteRT GPU
- Nightfall branch: `refactor/linux-restoration-and-cleanup`
- Branch base at test time: `b9585fb` (`feat(depth): add experimental EdgePad-224 tier`)
- Build type: Android release
- Test model was manually selected; Auto was not modified
- GPU priority and backend were held consistent for the direct comparison
- Production reference: EdgePad-384, model index 25
- Pilot: EdgePad-512x288 Experimental, model index 15
- Exported report: `Nightfall-diagnostics-20260928-203131.txt`

## Device compatibility result

The architecture passed the device/runtime gate:

- Model mapped successfully from the APK.
- LiteRT created the OpenCL GPU delegate successfully.
- No CPU fallback occurred.
- No delegate partitioning or tensor-contract warning was logged.
- Runtime tensors matched the contract exactly:
  - input `[1, 288, 512, 3]`
  - output `[1, 144, 256, 4]`
- Nightfall reconstructed the packed output into a dense 512x288 map.
- Full-warp rendering ran without packing seams, channel inversion, crashes,
  or backend failure.
- Thermal status during both 100-sample measurements was `none(0)`.

The model took approximately 3.6-4.4 seconds to initialize and compile on the
Quest in the observed runs. This was a lazy first-load cost, not per-frame
latency.

## Performance results

The most directly comparable warmed runs from the same session were:

| Model | Mean invoke | p50 | p95 | Achieved rate | Thermal |
| --- | ---: | ---: | ---: | ---: | --- |
| EdgePad-384 | 21.609 ms | 21.578 ms | 23.191 ms | 20.03 Hz | none |
| EdgePad-512x288 pilot | 22.773 ms | 22.705 ms | 25.167 ms | 20.08 Hz | none |

The pilot was approximately 5.4% slower by mean invoke time and 8.5% slower at
p95. A later standalone sustained pilot run measured:

- mean: 23.625 ms
- p50: 23.696 ms
- p95: 26.363 ms
- achieved rate: 20.05 Hz
- thermal: none

The achieved rate was constrained by Nightfall's 20 Hz test cap. Invoke time
indicates that a trained model using the same graph structure should have
enough raw inference headroom for a higher cadence, subject to stream/render
contention testing.

## Quest-versus-desktop numerical check

Nightfall captured one exact preprocessed Quest input tensor and the raw packed
OpenCL output before unpacking or post-processing. The same input was run
through the identical float16 TFLite artifact on desktop CPU/XNNPACK.

Results:

- Quest and desktop output shapes: `[1, 144, 256, 4]`
- Pearson correlation: `0.9847238082`
- Mean absolute difference: `0.0027326616`
- RMSE: `0.0037162793`
- Maximum absolute difference: `0.0699498132`
- Best channel permutation: identity `[0, 1, 2, 3]`
- Desktop output range: `0.0` to `0.1019402146`
- Quest OpenCL output range: `0.0` to `0.1076660156`

This rules out a swapped packed-channel order or gross runtime unpacking bug.
The remaining numerical difference is consistent with a GPU delegate executing
the float16-weight graph with different arithmetic/tuning than desktop CPU.
Future candidates should repeat this check, but the current visual failure is
not explained by channel ordering.

## Visual result and decision

The model's visual quality on the headset was described as terrible. This was
not surprising: the checkpoint was a tiny overfit/pipeline pilot intended to
prove export, delegation, packed reconstruction, and latency—not generalization.

Decision:

- Device architecture: **pass**
- OpenCL delegation: **pass**
- Tensor/packing contract: **pass**
- Performance feasibility: **pass**
- General visual quality: **fail, expected for this pilot**
- Production/Auto eligibility: **fail**

Do not spend more time tuning Nightfall post-processing around this checkpoint.
The next improvement must come from training and validation.

## Next training work

1. Replace the tiny-overfit dataset with a broad 16:9 corpus covering games,
   films/animation, desktop text and UI, fine geometry, particles, foliage,
   faces/hair, rapid camera motion, scene cuts, and static scenes.
2. Generate deterministic Marigold v2 teacher labels with pinned revisions,
   preprocessing, seeds, and manifests.
3. Retain the validated 512x288 input and packed 2x2 EdgePad output contract.
4. Train with spatial objectives that preserve thin structures and boundaries
   without introducing the overly sharp/disruptive warp edges previously seen
   in Nightfall's sharper models.
5. Add explicit temporal objectives or sequence supervision for frame-to-frame
   depth stability. Validate motion, camera pans, scene cuts, and disocclusion.
6. Maintain a fully unseen validation suite. Do not judge progress using only
   training clips or adjacent frames from the same source.
7. Compare every candidate against Nightfall EdgePad-384 and EdgePad-256 using:
   - normalized depth accuracy against teacher labels;
   - boundary/thin-structure metrics;
   - temporal flicker and flow-warp consistency;
   - Nightfall-equivalent final warp previews, not raw depth alone;
   - representative video sequences, not only still comparison sheets.
8. Reject candidates offline unless they clearly improve visual quality and
   temporal stability. Nightfall users have already reported quality problems
   with the previous ZipDepth release, so merely matching it is insufficient.
9. For a candidate that passes offline gates, provide:
   - TFLite artifact and SHA-256;
   - exact tensor contract and packing order;
   - ONNX/TFLite parity report;
   - GPU analyzer output;
   - still and motion comparison reports against EdgePad-384/256;
   - expected Quest latency based on the validated architecture.
10. Only then request another Nightfall Quest integration build. The reusable
    packed-output path now exists, so a compatible replacement artifact should
    require minimal application work.

## Nightfall-side disposition

The current test build contains the pilot as a manual experimental option and
has diagnostic hooks for a warmed 100-sample benchmark and one exact raw tensor
pair. Auto still selects production EdgePad-384/OpenCL on Quest 3/3S and the
existing EdgePad-256/OpenGL compatibility path on Quest 2.

Before the next Nightfall release, remove the pilot asset/manual selector and
keep the generic packed-output runtime support available for future trained
checkpoints. Nightfall's immediate priorities are Linux validation, regression
testing, and release preparation.
