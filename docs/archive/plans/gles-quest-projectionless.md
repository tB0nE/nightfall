# GLES-first Quest performance and projectionless polish

## Summary

Switch development to the GLES branch for Quest builds, while retaining Vulkan for Linux and experimental Android testing. Preserve the existing backend-selection architecture and port only the portable performance improvements from Vulkan.

Priorities:

- Make GLES projectionless mode fully functional and polished.
- Keep the quality tiers during migration and testing.
- Add validated GPU model variants incrementally.
- Simplify depth/menu controls without changing saved model IDs.
- Prototype lightweight controller indicators first.
- Audit runtime controller and hand-model support without making it a performance dependency.

The upstream `moonlight-android-xr` project uses lightweight controller rays and interaction visuals; its virtual keyboard is still future work rather than a reusable implementation.

## Implementation

### Branch and renderer policy

- Create the working branch from `android-gles-depth-inference`.
- Make GLES the default Android Quest renderer.
- Keep Vulkan as the Linux renderer and an opt-in Android comparison path.
- Port shared Vulkan improvements where renderer-independent: separate model/backend settings, scheduled GPU inference, low-priority Qualcomm OpenCL, GPU boost requests, telemetry, and fallback handling.
- Do not port Vulkan-specific decoder, AHB, or projectionless implementation changes into the GLES streaming path wholesale.

### Projectionless GLES polish

- Audit welcome screen, stream surfaces, menu, keyboard, status/performance text, cursors, bezel/grab controls, loading/reconnect states, and passthrough in composition mode.
- Keep projectionless runtime-controlled and default it on for supported Quest builds.
- Fall back automatically to normal projection rendering if composition layers are unavailable or initialization fails.
- Verify layer ordering, stereo alignment, reconnect behavior, and passthrough before performance tuning.

### Menu and depth settings

- Keep the existing model list and persisted model IDs unchanged.
- Keep `3D AI`, `3D Backend`, and `3D Quality` as separate controls.
- Retain `Auto`, `Fastest`, `Fast`, and `Standard` quality modes during migration; remove or simplify them only if one default mode reliably meets the performance target at all required resolutions.
- Display explicit backend states: `Auto (GPU)`, `Auto (CPU)`, `CPU`, `GPU`, and `GPU→CPU`.
- Unsupported GPU selections remain saved but visibly fall back to CPU.

### GPU model expansion

Use a validated phased approach:

1. Inventory every current CPU model and LiteRT delegate compatibility.
2. Add GPU variants only when Quest loading, output quality, cadence, and rendering budget are validated.
3. Start with MiDaS-256, then evaluate MiDaS-192, YOLO26 variants, and DA-V2 variants individually.
4. Keep per-model capability reporting and CPU fallback for every failure.
5. Do not expose a model in the user menu until it passes functional and performance checks.

### Controller and hand experiment

First implement a low-cost projectionless controller indicator:

- Render small left/right position markers or short rays in a composition-space UI layer.
- Drive them from each controller's grip pose.
- Show them while controllers are tracked and hide them when tracking is unavailable.
- Keep the visual lightweight; do not add a 3D controller viewport or depth interaction.
- Do not add another menu toggle initially; show indicators automatically in projectionless mode.

Separately prototype runtime controller models only in normal projection mode:

- Use the existing Godot `OpenXRFbRenderModel` support through `XR_FB_render_model`.
- Attach left/right render-model nodes beneath the existing `XRController3D` nodes using the grip pose.
- Retain local controller models as fallback when the extension or runtime model is unavailable.
- Keep this behind a runtime/debug flag until tested.

Do not attempt full 3D controller composition layers in the first pass. They require transparent 3D viewports, extra rendering, explicit layer ordering, and do not naturally share depth with the stream.

Audit existing hand-tracking and vendor extensions for future runtime hand meshes, but keep hands and keyboard outside the critical performance path.

## Validation

- Build and install a release GLES APK on Quest.
- Confirm projectionless rendering, passthrough, menu, keyboard, cursor, reconnect, and all CPU models.
- Test MiDaS-256 GPU, CPU selection, unsupported GPU fallback, and initialization-failure fallback.
- Measure 1440p/72 and 4K/72 after a 30-second warm-up for at least 120 seconds:
  - at least 95% of one-second windows at 72 FPS;
  - no recurring drops below 65 FPS;
  - average depth completion at least 19.5 Hz;
  - no five consecutive windows below 19 Hz;
  - bounded depth latency with latest-frame replacement.
- Compare every candidate GPU model against its CPU counterpart for quality and cadence.
- Test controller indicators with both controllers, one controller, tracking loss, hand-tracking mode, and projection fallback.
- Confirm Linux remains Vulkan-only and contains no Android JNI, AAR, Qualcomm, or OpenXR GPU-boost dependencies.

## Assumptions

- GLES is the Quest default.
- Vulkan remains available for Linux and experimental Android comparisons.
- Quality tiers remain user-facing until the resolution/performance matrix proves they are unnecessary.
- Controller indicators are the first projectionless controller solution.
- Runtime controller models are optional and not a release requirement.
- Virtual keyboard integration is deferred until rendering and performance work is stable.
