# Meteor XR layer compatibility

Planned additions: [layer expansion implementation plan](meteor-xr-layer-expansion.md).
The restrictions below describe the current implementation, not the intended
final feature set.

Updated 2026-10-24 on `feat/meteor-xr-streaming`. This contract concerns the
isolated Linux host runtime, not the headset's own OpenXR compositor.

| Layer or feature | Advertised | Capture behaviour |
| --- | --- | --- |
| Stereo projection | Core | Multiple stereo projections in submitted order, independent source sizes/poses/FOVs |
| Quad | Core | Multiple overlays, source rect/slice, eye visibility, alpha and view/world poses |
| Equirect2 | Yes | Panoramic layers, alone or alongside projection/quads |
| Cylinder | Yes | Finite and zero/infinite-radius cylinders, source UVs, alpha and per-eye poses |
| Cube | No | Not implemented |
| Equirect1 | No | Not implemented |
| Projection depth extension | No | Colour-only internal conversion remains; depth is not used for composition |
| Layer colour-scale/bias extension | Yes | Projection, quad, cylinder and panorama transforms, clamping and alpha |
| Advanced blending, depth testing, image layout, inverted alpha | No | Not implemented consistently |
| Host layer filtering extension | No | Processing hints are not implemented by this host compositor |
| Host passthrough | No | Not implemented |

Output dimensions remain fixed by negotiation. Individual source layers may
use different extents or crops. The first projection defines output pose/FOV;
overlay-only frames use current tracking. No depth-based or translational
reprojection is introduced.

These restrictions do not disable AI 3D depth processing, headset passthrough,
or the headset compositor's PCVR sharpening/supersampling controls. Those use
different pipelines.

## Failure behaviour

The patched OpenXR frame-end path performs normal Monado validation first,
then checks the managed capture contract before submitting anything over IPC.
Malformed submissions return their relevant OpenXR validation errors. The
caller may correct and resubmit the same frame. Disabled extension layers are
rejected by Monado's existing validation. An application may still choose to
exit on that API error; the runtime does not deliberately crash it.

Unexpected capture rejection or pending synchronization no longer calls
`abort()` in the null compositor hook. It records `capture-failed`, logs the
layer layout and returns a compositor error. The owning supervisor detects
the marker, stops/reaps its game and runtime, and reports a capture failure.
This is not a blanket recovery guarantee for arbitrary driver/GPU failures;
the experimental native encoder still has fail-fast checks for those.

## Reproducible test

Build and run from the repository root:

```sh
bash tools/build_support/probe_monado_runtime.sh --build
.build-cache/model-tester-venv/bin/python test/smoke_xr_layer_compatibility.py .
```

Requires the existing Linux/NVIDIA runtime/encoder prerequisites. No headset,
Steam game, global runtime registration or Steam launch-option changes.

The suite checks the runtime's actual enumerated extensions, then runs quad,
panorama, patterned cylinder and ordered/colour-transformed stack fixtures with
both H.264 and HEVC. Two additional
HEVC cases cover zero and infinite cylinder radius. It decodes the delivered video and
checks stereo output, alpha, projection transitions, a 650 ms static loading
hold, encoder/image drain and live encoder controls in the quad cases.

Each session also accepts an empty frame and rejects seven malformed or
unsupported submissions: wrong stereo view count, unknown layer type, invalid
source rectangle, malformed cylinder, cube, old equirect and a null layer. A valid frame is submitted
immediately after each rejection in the same session to verify recovery.
The Python lifecycle test separately verifies supervisor cleanup on a capture
failure marker.

Results: `.build-cache/meteor-xr/layer-compatibility-report.json`, with links to
each run's logs, bitstream and metadata. All ten GPU cases passed locally.
An additional 2064×2208-per-eye HEVC cylinder run passed decoded UV/alpha checks.
Additional ordered-stack runs passed sRGB and BGRA sRGB conversion checks and
2064×2208-per-eye HEVC output. The independent pixel oracle checks colour
transforms on all supported types, both alpha representations, clamping,
multiple projections, overlay ordering, rotated/narrower FOVs, resized sources
and return to the fast path, including an identity colour-transform chain.
A head-locked projection case verifies world-pose metadata against tracked
positions. Explicit tracked head pose is retained with each encode job rather
than inferred from arbitrary application camera views.

These fixtures do not establish compatibility with every game's textures,
panorama geometry, rendering API or interaction profile. Alyx gameplay remains
a physical test.

## Cylinder implementation checkpoint

The host bridge now has tagged layer metadata and explicit ABI version/stride
validation. Geometry and colour fields are independent. A bounded, persistent
storage buffer supplies layer parameters to the existing GPU draw pass while
keeping push constants at 128 bytes. No extra headset layer, CPU image readback
or compositor pass was added. The direct-copy projection-only path remains
outside this layer compositor.

Cylinder ray intersection and mapping follow the pinned Monado reference.
Compositor-slot and retained-job image leases now include cylinders. The
patterned fixture verifies decoded horizontal/vertical texture mapping in both
eyes, finite/zero/infinite radius, alpha over projection and static loading
holds. Rotation, visibility, source slices/crops and broader combinations remain
additional coverage targets in the expansion plan.
