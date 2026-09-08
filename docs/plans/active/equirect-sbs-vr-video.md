# 180° SBS / 360° SBS VR Video Mode

> Status: Active proposal

## What It Is

Current Nightfall SBS modes (Stretch/Crop) split the frame left/right and display each eye's half on a **flat/curved screen**. This is for 3D movies — stereoscopic depth but you're still looking at a screen.

**180° SBS** and **360° SBS** are VR video formats where the frame is encoded with **equirectangular projection**. The content wraps around you — you can **look around** freely inside a hemisphere (180°) or full sphere (360°). This is how VR porn, VR concerts, and VR sports are distributed.

The key difference: our current SBS just splits and stretches flat. Equirect SBS needs the frame mapped onto a **sphere/hemisphere** using equirectangular UV projection.

## How VR Video Players Do It

Skybox VR, DeoVR, Bigscreen all work the same way:
1. Split SBS frame into left/right halves
2. Map each half onto an **inverted hemisphere** (180°) or **full sphere** (360°) using equirectangular projection
3. Render each hemisphere/sphere to the corresponding eye

## Godot 4.7 Support — OpenXRCompositionLayerEquirect

Godot 4.7 **already has** `OpenXRCompositionLayerEquirect` class:
- Backed by `XR_KHR_composition_layer_equirect2` (supported on all Quest devices)
- Properties: `radius`, `central_horizontal_angle`, `upper_vertical_angle`, `lower_vertical_angle`, `fallback_segments`
- Same base class as our existing Cylinder/Quad layers: `OpenXRCompositionLayer`
- Supports `set_eye_visibility()` for per-eye stereo (like our cylinder layers)
- Supports `set_layer_viewport()` to assign a SubViewport
- Has `is_natively_supported()` check
- `fallback_segments` controls mesh quality when runtime doesn't support native equirect (same as cylinder fallback)

For WiVRn (Linux): like cylinder, equirect comp layer likely not natively supported — Godot will fall back to rendering as a 3D mesh. User confirmed this fallback quality is acceptable for cylinder.

## Implementation Plan

### 1. New SBS Mode Cycle

Current: `Off → Stretch → Crop`
New: `Off → Stretch → Crop → 180° → 360°`

- `sbs_mode = 3` → 180° equirect SBS
- `sbs_mode = 4` → 360° equirect SBS
- `sbs_labels = ["Off", "Stretch", "Crop", "180°", "360°"]`

### 2. Equirect Composition Layer Setup (`main.gd`)

Add in `_setup_comp_layer()`:

```
comp_equirect_left = OpenXRCompositionLayerEquirect.new()
comp_equirect_left.set_eye_visibility(EYE_VISIBILITY_LEFT)
comp_equirect_left.set_radius(0)  # infinite sphere
comp_equirect_left.set_central_horizontal_angle(PI)  # 180° horizontal
comp_equirect_left.set_upper_vertical_angle(PI/2)    # 90° up
comp_equirect_left.set_lower_vertical_angle(-PI/2)   # 90° down
comp_equirect_left.set_fallback_segments(64)          # smooth fallback mesh
comp_equirect_left.visible = false

comp_equirect_right = OpenXRCompositionLayerEquirect.new()
# Same but EYE_VISIBILITY_RIGHT
```

For 360° mode, change `central_horizontal_angle` to `2*PI`.

### 3. Equirect SubViewports

Same pattern as stereo cylinder layers:
- `comp_viewport_left` / `comp_viewport_right` already exist for SBS stereo
- Reuse them — when equirect mode is active, assign them to equirect layers instead of cylinder layers
- The YUV→RGB shader (`yuv_display.gdshader`) already handles SBS UV offset per eye
- The shader's UV remapping (`uv.x *= 0.5` + eye offset) works for the left/right half selection
- **No new shader needed** — equirect projection is handled by the OpenXR comp layer itself

### 4. Stereo Switching Logic (`settings_controller.gd`)

In `apply_stereo()`:
- When `sbs_mode == 3` (180°) or `sbs_mode == 4` (360°):
  - Hide cylinder comp layers
  - Show equirect comp layers (left + right)
  - Set equirect angles: 180° → `central_horizontal_angle = PI`, 360° → `2*PI`
  - Position equirect layers at camera origin (viewer is inside the sphere)

### 5. Per-Frame Updates

Equirect layers need to track the camera position:
- `comp_equirect_left.global_position = xr_camera.global_position`
- `comp_equirect_right.global_position = xr_camera.global_position`
- This ensures the sphere follows the user's head (they stay at the center)

### 6. UI/Keyboard/Pointer Handling

In equirect mode:
- **No screen mesh** — the content wraps around you, there's no flat screen to point at
- **No UI panel, no keyboard** — these don't make sense inside a sphere
- **No cursor on stream** — no flat surface to click
- Still need a way to pause/exit — could use B button as usual, or a floating HUD
- The stream still receives mouse/keyboard from physical input devices (desktop mode)
- Consider: show a small HUD comp layer quad at a fixed position in front of user for pause/exit/settings

### 7. Host Interaction

For VR video use case:
- User launches a VR video player (like Skybox, DeoVR, or VLC) on the host PC
- The video plays full-screen, Sunshine captures it
- Nightfall receives the equirect-encoded frame and maps it onto the sphere
- **The host app handles playback controls** — Nightfall just displays the frame
- Input still works — user can move mouse/click on host's video player controls via pointer

### 8. YUV Shader Considerations

The existing `yuv_display.gdshader` already handles:
- SBS UV offset (left eye sees left half, right eye sees right half)
- Smooth/sharpen filters
- YUV→RGB conversion

The shader doesn't need to do equirect projection — that's the comp layer's job. The shader just prepares the flat texture. The OpenXR runtime handles the sphere mapping natively.

### 9. Non-Comp-Layer Fallback

If equirect comp layer isn't available:
- Godot's `fallback_segments` creates a 3D sphere mesh in the projection layer
- Quality should be acceptable (user confirmed this for cylinder fallback)
- The mesh is rendered by Godot, not the OpenXR compositor

### 10. State Management

- Save `sbs_mode` to `app_state.cfg` (already saved, just new values 3/4)
- Restore on launch
- AI-3D mode should be disabled when in 180°/360° mode (same as current SBS modes)

## Files to Modify

| File | Changes |
|------|---------|
| `main.gd` | Add `comp_equirect_left`/`right` vars, create in `_setup_comp_layer()`, position in `_process()`, hide screen/UI/keyboard in equirect mode |
| `src/settings_controller.gd` | Extend `sbs_labels` to `["Off", "Stretch", "Crop", "180°", "360°"]`, handle modes 3/4 in `apply_stereo()`, set equirect params |
| `src/state_manager.gd` | Clamp `sbs_mode` to 0-4 instead of 0-2 |
| `src/xr_interaction.gd` | Skip screen pointer/click when in equirect mode |
| `src/ui_controller.gd` | Update SBS button label for new modes |

## Open Questions

1. **HUD overlay in equirect mode**: Should we show a floating UI panel (comp quad layer) in front of the user for pause/exit/settings? Or just rely on B button to toggle a menu?
2. **360° mode aspect ratio**: 360° equirect is typically 2:1 (equirectangular). 180° is typically 1:1 per eye. Should we auto-detect from frame aspect ratio?
3. **Mouse input in equirect mode**: Since there's no flat screen to click, should controller pointer move the host's mouse cursor (like a laser pointer in 3D space), or should we emulate head-look as mouse position?
4. **Audio**: No changes needed — audio pipeline is independent of display mode.
