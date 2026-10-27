# Meteor XR: expand compositor layer support

Status: implementation plan, 2026-10-24.
Branch: `feat/meteor-xr-streaming`.

Implementation checkpoint: the core compositor work is implemented. Cylinders,
colour transforms, ordered stacks and multiple projections have passed the
expanded ten-case GPU suite. Additional stack runs passed sRGB/BGRA and native
Quest 3 resolution checks. Tagged, versioned host-local metadata and the existing
GPU draw path are used; ordinary opaque/identity projections retain direct copy.
Physical Alyx/VRChat regression checks remain before calling the plan complete.
Optional skybox formats and separate product features remain follow-up work.

## Goal

Expand compatibility with real XR games and applications instead of stopping
at hiding unsupported extensions. First reach the layer coverage used by our
pinned WiVRn reference, then consider additional skybox formats.

The headset continues receiving one encoded stereo projection. Additional
application layers are composed on the PC, without adding headset composition
layers, changing the video protocol or requiring Sunshine changes.

Capability restrictions and submission guards remain temporary protection:
enable each capability when its implementation and tests pass. Keep clear,
controlled failure for capabilities that are still missing.

## Reference and current state

Reference: `.build-cache/meteor-xr/WiVRn`, commit
`f0fa8613aff2387636cabfaed115103c5e275a1d`.

Relevant code:

- `server/compositor/layer_squasher.cpp`: per-eye ordered layer composition,
  `do_projection_layer`, `do_quad_layer`, `do_cylinder_layer`,
  `do_equirect2_layer`, colour transforms and hardware sampler limits.
- `server/CMakeLists.txt`: enables colour-scale/bias, disables projection-depth
  and quad-view extensions, compiles Monado's `layer.comp` shader.
- Our pinned Monado's `src/xrt/auxiliary/render/shaders/layer.comp`: projection,
  quad, cylinder and equirect2 sampling and blending implementations.

WiVRn does not implement cubemap or Equirect1 rendering in this compositor.
Its projection-depth rendering code exists, but the corresponding extension
is disabled in the inspected build configuration.

Nightfall currently supports one stereo projection followed by quads and/or
equirect2 layers, plus overlay-only frames. The projection is copied into the
packed stereo output and the remaining layers are drawn over it. This cannot
handle arbitrary layer order or multiple projection layers correctly.
Panoramas reuse push-constant fields for geometry, preventing simultaneous
colour transforms. These are architectural limits to remove, not just flags
to switch on.

## Scope and priority

| Priority | Addition | Result |
| --- | --- | --- |
| 1 | Cylinder layers | Curved menus and screens render correctly |
| 2 | Complete colour scale/bias | Fades and colour adjustments work on every supported layer |
| 3 | Ordered composition, including multiple projections | Application layer stacks render in their submitted order |
| 4 | Broader geometry, source-image and lifecycle coverage | Supported types work beyond the initial synthetic fixtures |
| Optional follow-up | Equirect1, then cubemap skyboxes | Additional compatibility beyond the inspected WiVRn path |

Projection-depth reprojection/occlusion, advanced blend equations, passthrough,
host compositor sharpening/supersampling and quad-view rendering are separate
projects. Do not advertise them as part of this work. Ordinary alpha blending
and colour transforms are in scope. This does not change the existing headset
PCVR filtering controls or Nightfall's AI 3D pipeline.

## Phase 1: establish the composition data model and baseline

1. Record current simple-projection and projection-plus-overlay timings at
   representative Quest 3 settings, with codec, bitrate, resolution, source
   format and hardware recorded. Separate GPU composition from NVENC time.
2. Introduce a tagged, ordered host-local layer description rather than treating
   everything after the first projection as a quad. Represent projection,
   quad, cylinder and equirect2 with common image, pose, visibility, colour and
   alpha metadata plus type-specific geometry. No geometry/colour field aliases.
3. Update the local bridge ABI and all producers/consumers together, retaining
   explicit size/version checks. No wire-format change is needed.
4. Retain owned copies of all layer metadata and references/leases for every
   source image through GPU completion, including shared images, array slices,
   replaced queued jobs and rejected submissions. Extend bounds to the whole
   layer stack rather than only an overlay array.
5. Size buffers and descriptor use from device limits. Report unsupported
   capacity explicitly; never silently truncate a layer stack.

Rendering approach: use Monado's layer shader and WiVRn's preparation logic as
the primary reference. Prototype direct reuse of the pinned Monado compute
shader for the general path. If its descriptor requirements are unsuitable,
adapt the relevant sampling functions to our existing draw pipeline rather
than assuming WiVRn's entire server can be copied in. Preserve upstream
attribution/licences for reused code.

Keep the current direct-copy path for a single, untransformed opaque projection
when source format, dimensions, pose/FOV and ordering make it equivalent. The
general compositor handles cases that do not satisfy those conditions.
Do not add full-frame work to ordinary streaming without measuring it.

Exit: source ownership tests pass; the selected general rendering approach
produces the same existing projection/quad/panorama output within defined
numerical tolerances. Record the approach and measured baseline in the report.

## Phase 2: cylinder layers

- Implement per-eye ray/cylinder intersection and angular/vertical texture
  coordinates using the Monado/WiVRn conventions.
- Handle central angle, aspect ratio, radius and supported limiting cases
  according to the OpenXR definition. Check zero/infinite-radius behaviour
  against the reference before implementing it.
- Apply layer pose, view/world space, eye visibility, image subrect, array
  slice, vertical flip and ordinary source-alpha blending.
- Extend submission validation and image leases to cylinders. Enable
  `XRT_FEATURE_OPENXR_LAYER_CYLINDER` only after the GPU tests pass.

Tests: known colour/UV grid on a cylinder; off-centre and rotated views; each
eye separately; asymmetric FOV; cropped/array images; transparency over a
projection; cylinder-only loading frames; static holds and teardown/relaunch.
Verify actual decoded output, not only that the API accepts the layer.

Exit: cylinder extension enumerates, valid cylinder frames render, invalid
geometry fails cleanly, and existing fixtures remain correct.

## Phase 3: colour transforms across supported types

- Keep geometry and colour scale/bias in independent storage. The current
  128-byte push-constant layout cannot simply grow beyond the portable limit;
  use bounded uniform/storage data where appropriate.
- Apply transforms in the correct sequence relative to source alpha,
  premultiplication, clamping and blending, following the reference shader.
- Route transformed projection layers through the compositor instead of the
  raw copy path. Verify sRGB/UNORM image-view handling and preserve the existing
  encoder colour signalling.
- Test and enable `XRT_FEATURE_OPENXR_LAYER_COLOR_SCALE_BIAS` for projection,
  quad, cylinder and equirect2 together.

Tests: identity, RGB fade/tint, additive bias, alpha fade and clamping using
known pixel values. Cover straight and premultiplied alpha, transparent borders,
and mixed-layer fades to expose dark fringes or double premultiplication.

Exit: all supported layer types can use transforms simultaneously; ordinary
identity layers retain their baseline appearance and eligible fast path.

## Phase 4: arbitrary supported order and multiple projections

- Compose the submitted stack in order rather than selecting the first layer
  as a special background. Support overlays before, between and after
  projections, including transparent projection layers.
- For projection sampling, use each source view's submitted pose and FOV to
  sample into the chosen output views. Raw resizing is insufficient when
  projections have different poses or FOVs.
- Separate fixed negotiated output dimensions from individual source image
  extents. Support valid source crops/resolutions through sampling; retain
  explicit format/size limits instead of requiring every source to equal the
  encoder resolution.
- Choose output pose/FOV/timestamp metadata consistently with the rendered
  frame. Overlay-only output must continue using current tracking while static
  source images remain unchanged. Do not introduce a new timewarp policy here.
- Replace the first-and-unique projection restriction only when ordered
  composition tests pass. Two-view stereo remains the supported view count.

Tests: two projections with different colours, opacity, poses, FOVs, source
sizes and subrects; quad/cylinder/panorama between projections; shared images;
occluded backgrounds; eye visibility; empty frames and overlay-only transitions.
Check expected sampled pixels and pose metadata. Convert previous negative
ordering cases into positive tests; retain malformed-data rejection tests.

Exit: supported layers are order-independent in implementation, but retain
the application's requested visual stacking. No silent layer omission.

## Phase 5: compatibility and performance gate

Expand `test/smoke_xr_layer_compatibility.py` into a matrix that enumerates and
submits every newly advertised capability. Cover H.264 and HEVC, rectangular
eyes, source formats, static loading holds, live bitrate/foveation changes,
headset disconnect, game exit and repeated launches. Verify balanced image
leases, queue bounds, encoder drain and same-session recovery after invalid
submissions. Use automated numerical checks, including spatially varied
panorama textures rather than only a uniform sky.

Capture before/after CPU and GPU composition times, encoder times, queue waits
and delivered frame rate. Compare like-for-like settings after warm-up. Establish
acceptable budgets from Phase 1 measurements rather than promising a fixed
overhead before profiling. If the general path slows the common case, fix or
restore its fast path before considering the phase complete.

Physical checks: Alyx loading-to-gameplay, menus/fades and exit/relaunch;
VRChat startup, world entry, menus, wristwatch/desktop interactions and relaunch.
Synthetic tests do not replace those application checks.

Update capability documentation and leave deferred extensions disabled with
actionable diagnostics. Test builds remain optimized release-signed DEV builds.
Host-only changes normally need a runtime rebuild, not a new headset APK.

## Optional expansion after WiVRn-equivalent coverage

**Equirect1:** feasible as a separate addition using the existing spherical
sampler with its own radius/scale/bias texture mapping. Validate its conventions,
image ownership, geometry and colour-transform interactions before enabling
the extension. Do not assume it is identical to Equirect2.

**Cubemaps:** feasible but more work: six-face/cube image views, orientation,
array indexing, Vulkan image capabilities and seams require a dedicated path.
Add directional face-colour fixtures and cross-face seam tests. Verify the
runtime can create/import the required cube-compatible images before committing
to the implementation. WiVRn's inspected compositor is not a working reference
for this type; use the relevant Monado implementation and OpenXR definitions.

These should be separate changes after the main compatibility/performance gate,
not prerequisites for cylinder and ordered-composition support.

## Completion checkpoints

- [x] Composition representation and rendering approach validated.
- [x] Cylinder implemented, tested and advertised (broader geometry coverage remains).
- [x] Colour transforms complete, tested and advertised.
- [x] Ordered/multiple projection composition implemented and tested.
- [x] Expanded GPU matrix and image-lifetime checks pass.
- [ ] Controlled sustained performance check in actual games (synthetic copy/general timing evidence collected).
- [ ] Alyx and VRChat physical regression checks complete.
- [x] Capability inventory updated to the implemented state.
- [ ] Optional Equirect1/cubemap work assessed separately.
