# PR #12 Review — Left-controller and secondary-hand support

PR: [#12 — `fix: add OpenXR composition layer cursor for secondary hand`](https://github.com/tB0nE/nightfall/pull/12)  
Range reviewed: `main...left-controller-fix`  
Scope: 10 files, 608 insertions, 93 deletions

## Overall assessment

**Recommendation: request changes before merging.**

The PR makes useful progress toward dual-controller interaction and includes some good efficiency work, especially guarding repeated keyboard/UI hover style changes and sharing the contact-dot material. However, the current branch has several correctness regressions in release handling and environment state, plus a high-cost controller-fade implementation on the XR frame path.

The most important issues are:

1. A secondary-hand keyboard key can remain pressed indefinitely.
2. Controller fading traverses both controller trees every frame, repeatedly duplicates materials, and can replace multi-surface controller materials with surface 0.
3. A saved/default Passthrough=Off state is not actually applied at startup on alpha-blend-capable runtimes.
4. The newly configurable left primary hand does not control the virtual trackpad after activating it.
5. Virtual backgrounds are hidden when streaming despite the new independent background setting.

## Positive observations

- `src/virtual_keyboard.gd:293-300` and `src/xr_interaction.gd:645-656` avoid reapplying style overrides when the selected resource has not changed.
- `main.gd:1362-1375` shares the contact-dot material rather than allocating one material per dot.
- `src/xr_interaction.gd:276-281` uses the collision normal for contact-dot offset, which is more stable than a hand-to-hit direction.
- `src/state_manager.gd:117-178` attempts backward-compatible migration rather than silently dropping old settings.
- `git diff --check main...HEAD` passes.

---

## Findings

### 1. High — Secondary keyboard keys can remain held after the pointer leaves the key

**References:** `src/virtual_keyboard.gd:260-280`, `src/xr_interaction.gd:624-635`

`handle_secondary_key()` validates `visible`, trackpad bounds, and the key under `pixel_pos` before handling a release. `_hide_other_hand_ui()` intentionally calls it with `Vector2.ZERO`; a release over a key gap has the same problem. `_key_from_pos()` then returns `-1`, so the method exits without sending key-up events or clearing `_held_keys_secondary`.

The host can therefore retain a pressed ordinary key indefinitely.

Release must be based on owned state, not the pointer's current position:

```gdscript
func handle_secondary_key(pixel_pos: Vector2, pressed: bool) -> void:
	if not pressed:
		for key_code in _held_keys_secondary.keys():
			if key_code not in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_CAPSLOCK]:
				main.stream_backend.send_keyboard_event(key_code, 4, 0)
		_held_keys_secondary.clear()
		return

	if not visible or pixel_pos.x >= _kb_width:
		return

	var key_code := _key_from_pos(pixel_pos)
	if key_code < 0:
		return

	# Existing press handling follows.
```

Also release `_held_keys_secondary` when the keyboard is hidden, the stream disconnects, or the secondary pointer is cancelled. Input ownership should guarantee cleanup regardless of which lifecycle transition ends the gesture.

### 2. High — Controller fading creates frame-path resource churn and can destroy per-surface materials

**References:** `main.gd:983-1043`, `main.gd:1334-1355`

Every rendered frame, both controller trees are recursively traversed once to read alpha and again to write alpha. During a fade, `_set_alpha_recursive()` duplicates every encountered material whenever alpha changes. A roughly 0.49-second transition can create about 35/44/59 generations of materials at 72/90/120 Hz, per affected mesh and per hand.

There is also a correctness problem: `_apply_controller_textures()` configures each surface independently, but `_set_alpha_recursive()` reads only surface 0 and assigns its duplicate as `material_override`. A mesh-wide override can replace every surface's distinct material/texture with surface 0.

Prepare unique per-surface materials once after loading each controller model, cache those references, and only update cached colors while alpha is changing:

```gdscript
var _fade_materials := {"left": [], "right": []}
var _hand_alpha := {"left": 1.0, "right": 1.0}

func _prepare_fade_materials(root: Node, side: String) -> void:
	_fade_materials[side].clear()
	_collect_fade_materials(root, _fade_materials[side])

func _collect_fade_materials(node: Node, result: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.name != "Laser":
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.mesh:
				for surface_idx in range(mesh_instance.mesh.get_surface_count()):
					var source := mesh_instance.get_active_material(surface_idx) as BaseMaterial3D
					if source:
						var material := source.duplicate() as BaseMaterial3D
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						mesh_instance.set_surface_override_material(surface_idx, material)
						result.append(material)
		_collect_fade_materials(child, result)

func _set_hand_alpha(side: String, alpha: float) -> void:
	if is_equal_approx(_hand_alpha[side], alpha):
		return
	_hand_alpha[side] = alpha
	for material: BaseMaterial3D in _fade_materials[side]:
		var color := material.albedo_color
		color.a = alpha
		material.albedo_color = color
```

This moves discovery and duplication out of `_process()`, preserves per-surface textures, and makes the hot operation proportional only to the cached material count while a fade is active.

The same area also has behavior problems: `main.gd:1000-1013` treats only translation as activity. Rotation, trigger/grip use, and thumbstick/button input do not reset inactivity. Since recursion includes `HandRayCast/Laser`, the active laser is also faded and its initial alpha can be driven from `0.5` toward `1.0`. Track pose rotation and input activity, and fade controller-model roots only—not laser/cursor nodes.

### 3. High — Passthrough Off is not applied during startup

**References:** `main.gd:822-843`, `main.gd:864-872`, `src/settings_controller.gd:79-105`

`_init_xr()` selects alpha blend and enables a transparent root viewport whenever the runtime supports alpha blend. `_init_post_xr()` applies the loaded passthrough setting only when it is `true`. For the default or saved `false` state, it calls only `apply_background()`, which does not restore opaque blend mode or clear `transparent_bg`.

A non-black virtual background also uses zero environment alpha at `src/settings_controller.gd:105`, so physical passthrough may remain visible even though the UI says Passthrough is Off.

Always apply the loaded boolean and let the disabling path apply the selected background:

```gdscript
func _init_post_xr() -> void:
	state_manager.load_state()

	if comp.available:
		_switch_to_comp_layer()

	settings_controller.apply_passthrough(passthrough_enabled)

	ui_visible = false
	_set_ui_visible(false)
	_ui_has_saved_offset = false
	_startup_ready = true
```

The separate `apply_background(background_mode)` call is then unnecessary because `apply_passthrough(false)` already invokes it.

### 4. High — Passthrough can be selected when alpha blend is unsupported

**References:** `main.gd:828-843`, `src/settings_controller.gd:69-94`, `src/state_manager.gd:129-134`

`_init_xr()` discovers support for `XR_ENV_BLEND_MODE_ALPHA_BLEND`, but the result is local and discarded. The UI always exposes Passthrough, and `apply_passthrough(true)` unconditionally requests alpha blend and makes the viewport transparent.

Legacy migration also assumes the alpha-capable old labels (`0=On`, `1=Off`, `2=Starfield`, ...). On opaque-only runtimes, the old labels were instead `0=Off`, `1=Starfield`, ...; the new migration turns old Off into Passthrough On and shifts backgrounds.

Keep capability and effective state together, and normalize unsupported requests before persistence/UI updates:

```gdscript
var passthrough_supported: bool = false

func initialize_passthrough(interface: XRInterface) -> void:
	passthrough_supported = (
		interface != null
		and XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
			in interface.get_supported_environment_blend_modes()
	)

func set_passthrough(requested: bool) -> void:
	main.passthrough_enabled = requested and passthrough_supported
	_apply_environment()
	main.state_manager.save_state()
```

Disable or hide the Passthrough button when unsupported. For old settings, branch migration by the retained capability:

```gdscript
if main.passthrough_supported:
	main.passthrough_enabled = old_mode == 0
	main.background_mode = maxi(old_mode - 1, 0)
else:
	main.passthrough_enabled = false
	main.background_mode = old_mode # Old 0=Off/Black, 1=Starfield, ...
```

This defines invalid states out of existence instead of allowing UI, saved state, and OpenXR state to disagree.

### 5. Medium — Left-primary trackpad activation still controls the right controller

**References:** `src/xr_interaction.gd:100-138`, `src/virtual_keyboard.gd:214-232`, `src/virtual_keyboard.gd:318-380`

Primary pointer routing now respects `_active_hand`, so a left-primary controller can activate the virtual trackpad. Activation nevertheless records `main.right_hand.global_position`, and the trackpad loop reads exit click, trigger, grip, thumbstick, scroll, and motion exclusively from `main.right_hand`.

Capture the activating controller and retain it until deactivation:

```gdscript
var _trackpad_hand: XRController3D

func activate_trackpad(hand: XRController3D) -> void:
	if not hand:
		return
	_trackpad_hand = hand
	_last_hand_pos = hand.global_position
	trackpad_active = true
	_set_tp_active_visual(true)

func _process_trackpad() -> void:
	var hand := _trackpad_hand
	if not is_instance_valid(hand):
		_deactivate_trackpad()
		return

	var trigger := hand.get_float("trigger")
	var grip := hand.get_float("grip")
	var stick := hand.get_vector2("primary")
	var hand_pos := hand.global_position
	# Use `hand` consistently for the remaining trackpad behavior.
```

`XRInteraction` should expose an active-controller accessor or pass the active controller into `handle_pointer()`. `VirtualKeyboard` should not infer handedness independently.

### 6. Medium — Secondary mouse-up is sent to the viewport under the ray, not the press owner

**References:** `src/xr_interaction.gd:562-620`

`_other_hand_clicking` records only a boolean. Mouse-down is sent to the current settings or keyboard viewport; mouse-up is later sent to whichever viewport happens to be under the ray. Moving a held trigger directly between the settings panel and keyboard can leave the original `Button` captured while the second viewport receives an unmatched release.

Store press ownership explicitly:

```gdscript
var _secondary_press_viewport: SubViewport
var _secondary_press_was_keyboard := false

func _begin_secondary_press(viewport: SubViewport, pixel_pos: Vector2, on_keyboard: bool) -> void:
	_secondary_press_viewport = viewport
	_secondary_press_was_keyboard = on_keyboard
	_other_hand_clicking = true
	_secondary_press_viewport.push_input(_mouse_button(pixel_pos, true))

func _end_secondary_press(pixel_pos := Vector2.ZERO) -> void:
	if not _other_hand_clicking:
		return
	_other_hand_clicking = false
	if is_instance_valid(_secondary_press_viewport):
		_secondary_press_viewport.push_input(_mouse_button(pixel_pos, false))
	if _secondary_press_was_keyboard and main.virtual_keyboard:
		main.virtual_keyboard.handle_secondary_key(pixel_pos, false)
	_secondary_press_viewport = null
	_secondary_press_was_keyboard = false
```

Call the same end operation when the ray leaves UI, the keyboard/panel is hidden, streaming stops, or active-hand roles change.

### 7. Medium — The secondary composition cursor violates mesh-fallback lifecycle

**References:** `src/composition_layer_manager.gd:633-642`, `src/xr_interaction.gd:586-593`, `main.gd:945-950`, `main.gd:456-459`

`switch_to_mesh_rendering()` hides `left_comp_cursor_layer`, but `_process_other_hand_ui()` re-enables it on the next secondary UI hit without checking `main.comp.in_use`. A mesh fallback (`left_comp_cursor`) is constructed, but no path ever shows it; `_update_cursor_layer()` hides it later in the same frame.

Use one owner for secondary-cursor visibility and respect the active rendering mode:

```gdscript
func _show_secondary_cursor(hit_pos: Vector3, surface_normal: Vector3) -> void:
	var to_camera := (main.xr_camera.global_position - hit_pos).normalized()

	if main.comp.in_use and main.left_comp_cursor_layer:
		main.left_comp_cursor_layer.global_position = hit_pos + surface_normal * 0.002
		main.left_comp_cursor_layer.look_at(
			main.left_comp_cursor_layer.global_position + to_camera,
			Vector3.UP
		)
		main.left_comp_cursor_layer.rotate_object_local(Vector3.UP, PI)
		main.left_comp_cursor_layer.visible = true
		if main.left_comp_cursor:
			main.left_comp_cursor.visible = false
	elif main.left_comp_cursor:
		# Position/orient the mesh cursor here.
		main.left_comp_cursor.visible = true
```

Do not unconditionally hide the mesh cursor after secondary-pointer processing. Better still, have `_update_cursor_layer()` own both primary and secondary cursor rendering so render-mode decisions are centralized.

### 8. Medium — The static secondary cursor viewport renders every XR frame

**References:** `src/composition_layer_manager.gd:149-176`, `src/shaders/circle_cursor.gdshader:1-9`

The new 256×256 transparent `SubViewport` contains only a static `ColorRect` with a shader that has no `TIME` use or changing uniform. It is configured as `UPDATE_ALWAYS`, including while its composition layer is hidden.

That schedules a redundant offscreen canvas render at 72–120 Hz. The fill area is small, but render-pass/setup overhead matters on mobile XR.

Render it once:

```gdscript
main.left_comp_cursor_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
```

If content later becomes dynamic, request `UPDATE_ONCE` only after a change or toggle update mode together with visibility.

### 9. Medium — Grab-bar hover still allocates a StyleBox every frame

**References:** `src/xr_interaction.gd:215-219`, `src/xr_interaction.gd:575-581`, `src/composition_layer_manager.gd:683-692`

The secondary hand calls `set_comp_grab_bar_color()` every frame while pointing at the menu. The helper recursively searches for `CompGrabBar`, duplicates its current `StyleBoxFlat`, and reapplies an override even when alpha is unchanged. The primary path already does this; the PR adds another possible hot-path invocation.

At headset refresh rates, the new secondary path alone can create 72–120 StyleBox resources per second and repeatedly invalidate Control theming.

At minimum, guard unchanged state and avoid duplication when the style is already unique to the bar:

```gdscript
static func set_grab_bar_color(viewport: SubViewport, color: Color) -> void:
	if not viewport:
		return
	var bar := viewport.find_child("CompGrabBar", true, false) as PanelContainer
	if not bar:
		return
	var style := bar.get_theme_stylebox("panel") as StyleBoxFlat
	if not style or is_equal_approx(style.bg_color.a, color.a):
		return
	style.bg_color.a = color.a
```

A deeper fix is to cache the bar reference and expose a stateful `set_grab_bar_hovered(viewport, hovered)` operation, avoiding both `find_child()` and color/resource knowledge in the pointer loop.

### 10. Medium — Quick Start chooses the first configured host, not the saved host

**References:** `main.gd:879-898`, `main.gd:906-921`

`_init_textures_and_ui()` loads the last connection into `%IPInput`, but `_try_auto_connect()` always selects `v2_hosts[0]`. The saved IP is used only when that first host lacks `localaddress`. With multiple paired hosts, Quick Start can connect to a different machine than the user's last connection.

Resolve the saved host first:

```gdscript
func _find_quick_start_host(hosts: Array, saved_ip: String) -> Dictionary:
	for host in hosts:
		if host.get("localaddress", "") == saved_ip:
			return host
	return {}

func _try_auto_connect() -> void:
	var saved_ip := %IPInput.text
	var hosts := stream_backend.get_config_manager().get_hosts()
	var host := _find_quick_start_host(hosts, saved_ip)
	if host.is_empty():
		_log("[QUICK-START] Saved host is unavailable: %s" % saved_ip)
		return
	# Connect using this host's id and address.
```

If command-line auto-connect intentionally means “first configured host,” split it from Quick Start rather than giving two behaviors one ambiguous helper.

### 11. Medium — Stream startup hides every selected virtual background

**References:** `main.gd:508-533`, `main.gd:615-622`, `src/settings_controller.gd:79-112`

The settings split says `passthrough_enabled == false` plus `background_mode > 0` should display Starfield/Ash/Snow/Data. `_on_stream_started()` instead hides all backgrounds whenever passthrough is off—the only state in which virtual backgrounds are available. Disconnect cleanup later reimplements the index mapping and restores them.

Before the split, only old modes On/Off hid backgrounds on stream start; particle modes remained visible. The new condition therefore regresses existing behavior and makes the effective environment depend on the last lifecycle transition.

Remove transition-specific environment derivation and centralize it:

```gdscript
func apply_environment() -> void:
	_hide_all_backgrounds()
	_apply_openxr_blend_mode()

	if main.passthrough_enabled:
		return
	if main.background_mode > 0:
		var background := _background_for_mode(main.background_mode)
		if background:
			background.visible = true
			background.emitting = true
```

Call this idempotent operation after state load, option changes, stream start, and disconnect. `main.gd` should not duplicate background index mapping.

### 12. Medium — Manual hover snapshots can affect hidden controls and preserve a hover style as normal

**References:** `src/ui_controller.gd:63-90`, `src/ui_controller.gd:566-581`, `src/xr_interaction.gd:645-663`

The manual hover loop checks `btn.visible`, which reflects local visibility. A button below a hidden tab may still have `visible == true`; use `is_visible_in_tree()` when ancestor visibility matters.

Every tab switch also recollects `get_theme_stylebox("normal")`. The hover system itself replaces the normal override with the hover resource. If a tab switch occurs while a control is manually hovered, the next snapshot can record the hover resource as its normal style and leave the control highlighted later.

Immediate correction:

```gdscript
if not btn.is_visible_in_tree():
	continue
```

For a durable design, store immutable base/hover resources once when each button is created (or as metadata) and do not rediscover base state from a property the hover implementation mutates:

```gdscript
btn.set_meta("dual_hover_normal", normal_style)
btn.set_meta("dual_hover_hover", hover_style)
```

`UIController` should own `set_dual_hovered(button, hovered)`; `XRInteraction` should report hit targets rather than know theme override representation.

### 13. Medium — The pointer interface is order-sensitive and exposes private frame phases

**References:** `main.gd:945-950`, `src/xr_interaction.gd:158-165`, `src/xr_interaction.gd:545-656`

`main.gd` must call `handle_pointer_interaction()`, `_process_other_hand_ui()`, and `_apply_ui_hover_states()` in exactly that order. The latter methods are underscore-prefixed implementation details, and they depend on transient pixel state reset by the first method. This temporal decomposition is fragile; one follow-up commit in the PR already had to move secondary processing around primary early returns.

Expose one deep operation and keep ordering/state inside `XRInteraction`:

```gdscript
func process_pointer_frame(delta: float) -> void:
	_update_active_hand()
	_update_on_screen_tracking()
	_process_auto_primary(delta)
	_process_primary_pointer()
	_process_secondary_pointer()
	_apply_ui_hover_states()
```

Then `main.gd` has one call:

```gdscript
xr_interaction.process_pointer_frame(delta)
```

Keep controller fading either wholly in a controller-visual module or wholly in `main.gd`; currently `main.gd` reads and writes `XRInteraction`'s private timers and positions, leaking ownership in both directions.

### 14. Low — Dead cursor resources and an unused shader add startup work and clutter

**References:** `main.gd:1395-1425`, `main.gd:717-731`, `main.gd:1566-1571`, `src/shaders/laser_fade.gdshader:1-18`

`left_comp_cursor` procedurally creates a 64×64 image, uploads it, and adds a mesh, but no path sets it visible. The active secondary path uses `left_comp_cursor_layer`, and `_update_cursor_layer()` forces the mesh hidden.

The newly added `laser_fade.gdshader` is also not referenced; the laser uses the generated gradient texture instead.

After resolving finding 7, keep only resources that are part of the chosen fallback design. Either wire the shader through a preloaded `ShaderMaterial` or remove it and retain the gradient texture—not both.

---

## Efficiency summary

### Confirmed hot-path issues

- Two recursive controller-tree walks per hand per frame, plus material duplication during fades (`main.gd:983-1043`).
- Per-frame StyleBox lookup/allocation and theme invalidation for grab-bar hover (`src/composition_layer_manager.gd:683-692`).
- An always-rendering static 256×256 secondary cursor viewport (`src/composition_layer_manager.gd:158-176`).

### Lower-priority observations

- `src/xr_interaction.gd:545-620` allocates an `InputEventMouseMotion` every active secondary-pointer frame and reads the trigger twice. Reusing one motion object may be possible, but only optimize this after fixing the larger resource churn and confirming with the Godot profiler.
- `_is_hand_on_screen()` and `_is_hand_on_ui()` repeat raycast/collider queries in the same frame. A per-frame `HandHit` snapshot could reduce calls and simplify logic, but the expected gain is smaller than removing resource allocation from the render loop.
- Avoid optimizing by suppressing required motion events; continuous motion delivery may be necessary for Godot hover and drag semantics.

## Validation and test recommendations

No GDScript/UI tests were added in the PR. Neither `godot` nor `godot4` is installed in the review environment, so GDScript/shader import, headless startup, and runtime XR checks could not be executed.

Before merging, run at least this device/runtime matrix:

1. **Secondary keyboard release**
   - Press a normal key, drag off the keyboard, then release.
   - Press a key, move over a gap, then release.
   - Press on the keyboard, move directly to settings UI, then release.
   - Hide the keyboard/disconnect while a key is held.
   - Verify the host receives exactly one key-down and one key-up.

2. **Handed trackpad**
   - Repeat activation, pointer movement, click, right-click, scroll, and exit with Primary Hand = Right and Left.

3. **Cross-viewport ownership**
   - Hold a settings button, move to the keyboard, and release; repeat in reverse.
   - Verify neither viewport retains a pressed/captured control.

4. **Environment state**
   - Cold-start with Passthrough On and Off.
   - Cold-start each virtual background with Passthrough Off.
   - Start and stop a stream without changing the selected background.
   - Test a runtime/device without alpha-blend support if available.
   - Test migration from both old alpha-capable and opaque-only settings layouts.

5. **Composition fallback**
   - Exercise normal composition mode and forced mesh fallback.
   - Confirm the secondary cursor is visible only through the active rendering path.

6. **Quick Start**
   - Pair at least two hosts, make the second host the last connection, and restart.
   - Verify Quick Start selects the saved host and fails clearly if it is unavailable.

7. **Performance**
   - Profile frame time and allocations at headset refresh rate with both controllers present.
   - Leave controllers idle until faded, wake each independently, and repeat.
   - Verify no continuing `Material`/`StyleBox` resource growth and no per-frame redraw of a static hidden cursor viewport.

## Final recommendation

Address findings 1–5 before merge. Findings 6–12 are also concrete correctness or frame-path concerns and should preferably be included in the same pass because they touch the new dual-hand state model. Findings 13–14 are design/cleanup work that can be handled immediately with low risk or tracked explicitly if the PR must remain narrowly scoped.
