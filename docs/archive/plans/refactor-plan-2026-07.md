# Refactoring Plan — July 2026

## Current State

- **18 GDScript files**, 7,456 lines total
- `main.gd`: 2,028 lines (god object)
- 3 virtual input files with ~255 lines of duplication
- Settings propagation uses manual 4-step boilerplate

---

## P1: Extract `CompositionLayerManager` from `main.gd`

**Removes ~300+ lines from `main.gd`.**

Move into a new `src/composition_layer_manager.gd`:

| From `main.gd` | Method |
|---|---|
| Lines 238–493 | `_setup_comp_layer()` — node hierarchy construction |
| Lines 497–606 | `_update_comp_bezel()` — symmetric bezel adjustment |
| Lines 608–642 | `_update_cylinder_params()` — cylinder geometry |
| Lines 645–667 | `_make_screen_transparent()`, `_restore_screen_material()`, `_make_ui_transparent()`, `_restore_ui_material()`, `_make_kb_transparent()`, `_restore_kb_material()` |
| Lines 896–948 | `_bind_yuv_textures()`, `_bind_comp_yuv_textures()` — shader parameter binding |
| Lines 986–1076 | `_switch_to_comp_layer()`, `_switch_to_stereo_comp_layer()`, `_switch_to_mesh_rendering()` |
| Lines 1078–1079 | `_update_comp_layer_size()` |
| Lines 1157–1168 | `_clear_comp_yuv_textures()` |
| Lines 768–862 | `_update_cursor_layer()` — cursor positioning (or move to XRInteraction) |

The manager holds all comp layer node references that are currently member vars on `main.gd`.

---

## P1: Create `VRPanel` base class for virtual input files

**Eliminates ~255 duplicated lines.**

Extract common logic into `src/vr_panel.gd`:

- Viewport + QuadMesh + StandardMaterial3D setup
- Area3D + BoxShape3D collision setup
- Initial visibility disable
- Grab bar creation with `HBoxContainer` + `CompGrabBar`
- Position save/restore (`_saved_offset`, `_save_offset()`, `toggle()`)
- Mouse movement tracking (shared between keyboard/trackpad)
- Border active visual state

Then `virtual_keyboard.gd`, `virtual_trackpad.gd`, `virtual_gamepad.gd` extend `VRPanel` and only implement their unique content.

---

## P2: Complete `UIController` API

**Stop `main.gd` from reaching past `UIController` into raw UI nodes.**

Current anti-patterns to replace:
```
main._ui_status_label.text = "..."     →  ui_controller.set_status("...")
main._ui_disconnect_btn.visible = ...   →  ui_controller.set_disconnect_visible(...)
main._ui_connect_btn.disabled = ...     →  ui_controller.set_connect_enabled(...)
```
Move `%IPInput` signal connection into `UIController.setup_numpad()`.

---

## P2: Extract `BackgroundManager`

**Isolates background particle systems.**

Move into `src/background_manager.gd`:
- `_create_starfield()`, `_create_ash()`, `_create_snow()`, `_create_data()`
- `_create_backgrounds()`, `_hide_all_backgrounds()`
- Background member vars (`bg_names`, `bg_offsets`)

---

## P3: Signal-based settings propagation

**Removes ~50 lines of boilerplate.**

Replace the manual 4-step pattern:
```
main.curvature = new_value
screen_manager.apply_curvature()
ui_controller.update_option_btn(...)
state_manager.save_state()
```

With:
```
setting_changed.emit("curvature", new_value)  // UI, screen, state all react via signals
```

---

## P3: Break up `_process()` and `_ready()`

**Readability improvement.**

Split `_process()` into:
- `_process_hand_tracking(delta)`
- `_process_input(delta)`
- `_process_stats(delta)`
- `_process_idle_timeout()`

Split `_ready()` into:
- `_init_xr()`
- `_init_stream()`
- `_init_ui()`
- `_init_backgrounds()`
- `_init_auto_connect()`
