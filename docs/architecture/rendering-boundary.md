# Rendering boundary

Nightfall currently supports three video presentation paths:

- the scene mesh renderer, used when OpenXR composition layers are unavailable;
- Godot OpenXR composition layers, used for the portable mono/stereo path and
  as the Android fallback;
- the native Android OpenXR renderer, used for eligible single-screen streams.

`CompositionLayerManager` still coordinates the legacy video path while
`NativeXrRendererManager` owns the native swapchain and frame submission. Phase
5 will put path selection behind one renderer-facing contract before changing
either implementation's resource lifetime.

## Composition overlays

Composition overlays are being separated from legacy video presentation by
resource type. `CompositionPanelLayers` owns the UI and keyboard layer nodes and
accepts only their OpenXR parent, viewport, and geometry. Compatibility getters
on `main.gd` preserve existing positioning and visibility consumers while those
call sites are migrated incrementally.
