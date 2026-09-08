# Rendering boundary

Nightfall currently supports three video presentation paths:

- the scene mesh renderer, used when OpenXR composition layers are unavailable;
- Godot OpenXR composition layers, used for the portable mono/stereo path and
  as the Android fallback;
- the native Android OpenXR renderer, used for eligible single-screen streams.

`VideoPresentation` is the renderer-facing selection contract. It resolves mesh,
legacy mono, legacy stereo, and native paths, then delegates transitions and
per-frame work to `CompositionLayerManager` or `NativeXrRendererManager`.
Resource allocation and teardown remain inside those implementations.

## Composition overlays

Composition overlays are being separated from legacy video presentation by
resource type. `CompositionPanelLayers` owns the UI and keyboard layer nodes and
accepts only their OpenXR parent, viewport, and geometry. Compatibility getters
on `main.gd` preserve existing positioning and visibility consumers while those
call sites are migrated incrementally.

`CompositionEnvironmentLayer` similarly owns the environment's equirect layer,
3D capture viewport, and capture camera. Background selection and particle
instance synchronization remain in the application coordinator for now.

`CompositionPointerLayers` owns the primary pointer quad and the secondary-hand
cursor quad together with their small 2D viewports. Pointer hit testing and
world-space positioning remain in the interaction modules.

`CompositionControllerRays` owns both controller-ray layers, their backing
viewports, and the generated capsule-gradient texture. Ray pose and visibility
remain driven by the existing XR interaction state.
