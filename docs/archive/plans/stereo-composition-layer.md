# Stereo Comp Layer Plan

## Phase 1: Fix smooth/sharpen in comp layer (immediate)
- Fix texel size bug in `yuv_display.gdshader` — `vec2(textureSize(tex_y, 0))` returns pixel dimensions (1920x1080), not texel size. Need `1.0 / vec2(textureSize(tex_y, 0))`. This is why smooth/sharpen has no visible effect — the blur offsets are ~1920 pixels wide instead of ~1 pixel.
- `filter_mode` and `sharpen` uniforms + `filtered_stream()` already added to comp shader — just the texel math is wrong.

## Phase 2: Upgrade to Godot 4.7 Beta 2 (for eye_visibility)
- Update `build.sh`:
  - `GODOT` → `/var/home/tyrone/Applications/Godot_v4.7-beta2_linux.x86_64`
  - Download 4.7-beta2 Android export templates and update `TEMPLATES` path
- Download Android export templates from https://godotengine.org/download/archive/beta2/ and install them in Godot 4.7's editor (Edit → Manage Export Templates)
- Verify the project opens and builds with 4.7

## Phase 3: Dual comp layers for SBS stereo
- In `_setup_comp_layer()`, create **two** `OpenXRCompositionLayerCylinder` nodes:
  - `comp_cylinder_left` — `set_eye_visibility(EYE_VISIBILITY_LEFT)`
  - `comp_cylinder_right` — `set_eye_visibility(EYE_VISIBILITY_RIGHT)`
- Create **two** SubViewports + two `yuv_display.gdshader` materials:
  - `comp_viewport_left` — shader with `stereo_mode` uniform; left eye UV remapping
  - `comp_viewport_right` — shader with `stereo_mode` uniform; right eye UV remapping
- Both cylinders positioned identically (same position, rotation, radius, central_angle)
- When `stereo_mode == 0` (2D): use a single cylinder with `EYE_VISIBILITY_BOTH` (current approach)
- When `stereo_mode == 1` (SBS stretch) or `2` (SBS crop): switch to dual cylinders with per-eye UV offsets in their shaders
- YUV textures bound to both comp shader materials

## Phase 4: AI 3D (MiDaS) depth-based stereo in comp layer
- Modes 3/4 require depth texture + parallax UV shifting per eye
- Add `depth_texture`, `convergence`, `balance_shift` uniforms to `yuv_display.gdshader`
- Left eye: UV shifted left by `half_parallax * depth_diff`
- Right eye: UV shifted right by `half_parallax * depth_diff`
- Same dual-cylinder approach as SBS

## Phase 5: Remove mesh rendering fallback for stereo
- Remove `_switch_to_mesh_rendering()` calls from `apply_stereo()`
- Remove `screen_mesh` material swapping for stereo modes
- Keep `_switch_to_mesh_rendering()` for other fallback scenarios but stereo no longer needs it

## Key risks/considerations
- Two comp cylinders means double the compositor work — but cylinder layers are efficient on Quest
- Need to test that `set_eye_visibility` actually works on Quest 3S with 4.7 beta2
- The Android export templates for 4.7-beta2 must be downloaded separately — they're not on Steam
