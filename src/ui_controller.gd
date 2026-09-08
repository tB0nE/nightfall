class_name UIController
extends RefCounted

var main: Node3D
var _tab_display: Control
var _tab_stream: Control
var _tab_control: Control
var _tab_monitors: Control
var _tab_ai3d: Control
var _tab_picture: Control
var _tab_advanced: Control
var _tab_btn_display: Button
var _tab_btn_stream: Button
var _tab_btn_control: Button
var _tab_btn_monitors: Button
var _tab_btn_ai3d: Button
var _tab_btn_picture: Button
var _tab_btn_advanced: Button
var _preset_row: HBoxContainer
var _current_tab: int = 0

const PRESET_CARD_SIZE := Vector2(96, 62)
const PRESET_DIAGRAM_SIZE := Vector2(84, 42)
const PRESET_PRIMARY_COLOR := Color(0.55, 0.78, 1.0, 0.9)
const PRESET_SECONDARY_COLOR := Color(1, 1, 1, 0.35)

func _init(owner: Node3D):
	main = owner

# ":" added (2026-08-26) so an optional custom port can be typed directly
# into %IPInput as "ip:port" - see main.gd's parse_ip_port().
func setup_numpad():
	var keys = ["7","8","9","4","5","6","1","2","3",".","0",":","DEL"]
	for key in keys:
		var btn = Button.new()
		btn.text = key
		btn.custom_minimum_size = Vector2(120, 70)
		btn.size_flags_stretch_ratio = 1.0
		btn.pressed.connect(on_numpad_key.bind(key))
		main.get_node("%Numpad").add_child(btn)

# Max length raised from 15 (bare "255.255.255.255") to 21
# ("255.255.255.255:65535", the longest possible ip:port string) to fit an
# optional port suffix.
func on_numpad_key(key: String):
	if key == "DEL":
		var text = main.get_node("%IPInput").text
		if text.length() > 0:
			main.get_node("%IPInput").text = text.substr(0, text.length() - 1)
	elif main.get_node("%IPInput").text.length() < 21:
		main.get_node("%IPInput").text += key

func on_ipinput_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		main.get_node("%Numpad").visible = true

func on_sbs_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_sbs_mode()

func on_ai_3d_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_model()

# Main-page On/Off toggle (2026-08-28) - was the old Off/Auto/Fast/Standard
# cycle; that tier selection moved to on_ai_3d_mode_toggled() below.
func on_ai_3d_speed_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.toggle_ai_3d_enabled()

func on_ai_3d_mode_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_mode()

func on_ai_3d_type_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_type()

func on_ai_3d_hz_cap_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_hz_cap()

func on_ai_3d_separation_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_separation()

func on_ai_3d_convergence_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_convergence()

func on_ai_3d_cursor_position_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_cursor_position()

func on_ai_3d_reset_pressed():
	main.settings_controller.reset_ai_3d_effect_settings()

func on_ai_3d_debug_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_debug()

func on_ai_3d_priority_toggled():
	main.settings_controller.cycle_ai_3d_gpu_priority()

func update_stereo_shader():
	if main.screen_mesh.material_override is ShaderMaterial:
		main.screen_mesh.material_override.set_shader_parameter("stereo_mode", main.settings_controller.get_stereo_mode())
	update_option_btn(main._ui_sbs_btn, main.settings_controller.sbs_labels[main.sbs_mode])
	# Main-page control is a plain On/Off toggle now (2026-08-28) - tier
	# selection moved to the AI 3D tab's own "3D Mode" control below.
	update_option_btn(main._ui_3d_speed_btn, "On" if main.ai_3d_speed != 0 else "Off")
	# Shows main.ai_3d_last_mode while Off (disabled/greyed, but still
	# reflects what the main-page toggle will restore to when turned back on).
	update_option_btn(main._ui_3d_mode_btn, main.settings_controller.ai_3d_speed_labels[main.ai_3d_speed if main.ai_3d_speed != 0 else main.ai_3d_last_mode])
	# get_depth_backend_label() already resolves Auto/no-GPU-variant
	# fallback correctly (see settings_controller.gd's get_depth_backend_index()) -
	# no separate Auto-display special-casing needed here.
	update_option_btn(main._ui_3d_type_btn, main.settings_controller.get_depth_backend_label())
	# Under Auto (ai_3d_speed==1) main.ai_3d_model is frozen/irrelevant - show
	# whichever model AUTO_TABLE actually picked instead (see
	# settings_controller.gd's get_auto_selection()/get_depth_model_index()).
	var model_idx = main.settings_controller.get_auto_selection().model_idx if main.ai_3d_speed == 1 else main.ai_3d_model
	update_option_btn(main._ui_3d_btn, main.settings_controller.ai_3d_models[model_idx].label)
	update_option_btn(main._ui_3d_hz_cap_btn, "%dhz" % main.settings_controller.get_effective_hz_cap())
	# Separation/Convergence are never Auto-overridden (they stay live under
	# Auto - see update_3d_btn_state()), so no Auto-aware branching needed.
	update_option_btn(main._ui_3d_separation_btn, "%d%%" % main.ai_3d_separation_pct)
	update_option_btn(main._ui_3d_convergence_btn, "%d%%" % main.ai_3d_convergence_pct)
	update_option_btn(main._ui_3d_cursor_position_btn, main.settings_controller.get_ai_3d_cursor_position_label())
	update_option_btn(main._ui_3d_debug_btn, main.settings_controller.ai_3d_debug_labels[main.ai_3d_debug])
	update_3d_btn_state()

func update_3d_btn_state():
	var disabled = main.sbs_mode > 0 or main.screens.size() > 1
	if main._ui_3d_speed_btn:
		main._ui_3d_speed_btn.disabled = disabled
		main._ui_3d_speed_btn.modulate.a = 0.3 if disabled else 1.0
	# Type/Model/3D Mode are hidden entirely on Android (see
	# settings_controller.gd's ai3d_options_locked() comment) - Standard/GPU/
	# ZipDepth-384-GPU are enforced at the state level regardless of these
	# buttons, but hiding (paired with .disabled, matching 3D Debug's own
	# hide-and-disable pattern below) keeps a locked control from offering a
	# choice that does nothing.
	var locked = main.settings_controller.ai3d_options_locked()
	if _tab_ai3d:
		var ai3d_row1 = _tab_ai3d.get_node_or_null("Ai3dRow1")
		var ai3d_gap1 = _tab_ai3d.get_node_or_null("Ai3dGap1")
		if ai3d_row1:
			ai3d_row1.visible = true
		if ai3d_gap1:
			ai3d_gap1.visible = true
	# 3D Mode: greyed whenever AI-3D itself is off - unlike Type/Model/Hz
	# Cap below, NOT additionally greyed under Auto, since it's the only
	# control that can switch OUT of Auto.
	var mode_disabled = disabled or main.ai_3d_speed == 0 or locked
	if main._ui_3d_mode_btn:
		main._ui_3d_mode_btn.visible = not locked
		main._ui_3d_mode_btn.disabled = mode_disabled
		main._ui_3d_mode_btn.modulate.a = 0.3 if mode_disabled else 1.0
	# Model and Hz Cap are meaningless whenever AI-3D is off or Auto is
	# choosing them. Android's platform lock applies only to Model: Standard is
	# enforced there, but its explicit Hz Cap remains user-adjustable.
	var model_disabled = disabled or main.ai_3d_speed == 0 or main.ai_3d_speed == 1 or locked
	var hz_disabled = disabled or main.ai_3d_speed == 0 or main.ai_3d_speed == 1
	# Type is NOT included above (2026-08-30) - Auto was always meant to let
	# you pick GPU or CPU yourself (GPU as the default), not force GPU
	# unconditionally - only tier+model are the table's job. Only greys with
	# the same base conditions Mode itself uses (AI-3D off / sbs conflict),
	# same as effect_disabled below. See get_depth_backend_index()'s Auto
	# branch, which now reads main.ai_3d_backend_pref instead of hardcoding
	# GPU.
	var type_disabled = disabled or main.ai_3d_speed == 0 or locked
	if main._ui_3d_type_btn:
		main._ui_3d_type_btn.visible = not locked
		main._ui_3d_type_btn.disabled = type_disabled
		main._ui_3d_type_btn.modulate.a = 0.3 if type_disabled else 1.0
	if main._ui_3d_btn:
		main._ui_3d_btn.visible = not locked
		main._ui_3d_btn.disabled = model_disabled
		main._ui_3d_btn.modulate.a = 0.3 if model_disabled else 1.0
	if main._ui_3d_priority_btn:
		var priority_disabled = disabled or main.ai_3d_speed == 0 or main.settings_controller.get_depth_backend_index() != 2 or not main.settings_controller.depth_gpu_priority_available()
		main._ui_3d_priority_btn.disabled = priority_disabled
		main._ui_3d_priority_btn.modulate.a = 0.3 if priority_disabled else 1.0
	if main._ui_3d_hz_cap_btn:
		main._ui_3d_hz_cap_btn.disabled = hz_disabled
		main._ui_3d_hz_cap_btn.modulate.a = 0.3 if hz_disabled else 1.0
	# Separation/Convergence/Cursor Position stay live under Auto - they're
	# visual tuning controls, not something the Auto table decides. They grey
	# out whenever AI-3D itself is off; Cursor Position also has no rendering
	# effect outside the AI stereo modes (see main.gd's cursor update).
	var effect_disabled = disabled or main.ai_3d_speed == 0
	if main._ui_3d_separation_btn:
		main._ui_3d_separation_btn.disabled = effect_disabled
		main._ui_3d_separation_btn.modulate.a = 0.3 if effect_disabled else 1.0
	if main._ui_3d_convergence_btn:
		main._ui_3d_convergence_btn.disabled = effect_disabled
		main._ui_3d_convergence_btn.modulate.a = 0.3 if effect_disabled else 1.0
	if main._ui_3d_cursor_position_btn:
		main._ui_3d_cursor_position_btn.disabled = effect_disabled
		main._ui_3d_cursor_position_btn.modulate.a = 0.3 if effect_disabled else 1.0
	# Debug views depend on AI-3D producing depth, but are independent of the
	# Android model/type/mode lock. The lock hides selectors that cannot be
	# changed on Android; it must not disable this diagnostic control too.
	if main._ui_3d_debug_btn:
		main._ui_3d_debug_btn.visible = true
		main._ui_3d_debug_btn.disabled = effect_disabled
		main._ui_3d_debug_btn.modulate.a = 0.3 if effect_disabled else 1.0

func update_stats_btn_state():
	if not main._ui_stats_btn:
		return
	main._ui_stats_btn.text = "Stats"
	main._ui_stats_btn.add_theme_color_override(
		"font_color",
		Color(0.35, 0.65, 1.0, 1.0) if main.performance_overlay_enabled else Color(1, 1, 1, 0.5)
	)

func update_ambient_btn_state():
	var supported = main.comp != null and main.comp.ambient_supported()
	update_option_btn(main._ui_ambient_btn, main.ambient_mode_labels[clampi(main.ambient_mode, 0, main.ambient_mode_labels.size() - 1)])
	update_option_btn(main._ui_ambient_color_btn, main.ambient_color_labels[clampi(main.ambient_color, 0, main.ambient_color_labels.size() - 1)])

	if main._ui_ambient_btn:
		main._ui_ambient_btn.disabled = not supported
		main._ui_ambient_btn.modulate.a = 1.0 if supported else 0.3
	var tuning_disabled = not supported or main.ambient_mode == 0
	# Static uses the selected colour; Slow/Live derive their colour from the
	# rendered screen edges, so allowing this control there would be misleading.
	var color_disabled = not supported or main.ambient_mode != 1
	if main._ui_ambient_color_btn:
		main._ui_ambient_color_btn.disabled = color_disabled
		main._ui_ambient_color_btn.modulate.a = 0.3 if color_disabled else 1.0

func update_monitor_tab():
	if not main._ui_apply_preset_btn:
		return
	update_option_btn(main._ui_monitors_btn, "%d" % main._staged_physical_count)
	update_option_btn(main._ui_virtual_monitors_btn, "%d" % main._staged_virtual_count)
	update_option_btn(main._ui_grid_mode_btn, "On" if main.grid_mode_enabled else "Off")
	_refresh_preset_row()
	var selected = main._staged_preset_id != &""
	var selected_preset = MonitorPresets.find_preset(String(main._staged_preset_id)) if selected else {}
	# Multi-monitor capture/selection is Polaris-only (see
	# SettingsController.detect_polaris_host()) - every other host (Sunshine,
	# etc.) has no manifest to pick real monitors from, so none of this tab's
	# controls do anything meaningful for it. Grey the whole tab out rather
	# than let it look interactive and silently no-op (or restart the stream
	# for a change that can never actually take effect). Revisit once/if
	# non-Polaris multi-monitor selection is supported.
	var polaris = main.is_polaris_host
	main._ui_monitors_btn.disabled = not polaris
	main._ui_virtual_monitors_btn.disabled = not polaris
	main._ui_apply_preset_btn.disabled = not polaris
	main._ui_save_preset_btn.disabled = not polaris
	main._ui_grid_mode_btn.disabled = not polaris
	main._ui_remove_preset_btn.disabled = not polaris or not selected or selected_preset.get("built_in", true)
	for card in _preset_row.get_children():
		if card is Button:
			card.disabled = not polaris

func _cycle_monitors_btn():
	var real_total = maxi(main.settings_controller._real_monitor_count(), 1)
	var n = main._staged_physical_count + 1
	if n > real_total:
		n = 1
	main.settings_controller.stage_monitor_count(n)
	update_monitor_tab()

func _cycle_virtual_btn():
	var max_virtual = main.MAX_SCREENS - main._staged_physical_count
	var n = main._staged_virtual_count + 1
	if n > max_virtual:
		n = 0
	main.settings_controller.stage_virtual_count(n)
	update_monitor_tab()

func _on_apply_preset_pressed():
	main.settings_controller.apply_staged_monitor_config()
	update_monitor_tab()

func _on_save_preset_pressed():
	main.settings_controller.save_current_as_preset()
	update_monitor_tab()

func _on_remove_preset_pressed():
	main.settings_controller.remove_selected_preset()
	update_monitor_tab()

# Rebuilds Row 2 with one card per preset whose screen_count matches what's
# currently staged (Row 1) - a screen-count mismatch between a picked preset
# and the staged Monitors/Virtual total can then never happen through the UI,
# which is what lets apply_staged_monitor_config() apply a preset's positions
# directly without needing to reconcile a mismatch at Apply time.
func _refresh_preset_row():
	if not _preset_row:
		return
	for c in _preset_row.get_children():
		_preset_row.remove_child(c)
		c.queue_free()
	var total = main.settings_controller.staged_total()
	for preset in MonitorPresets.all_presets():
		if preset.get("screen_count", -1) != total:
			continue
		var is_selected = preset.get("id", "") == String(main._staged_preset_id)
		_preset_row.add_child(_build_preset_card(preset, is_selected))
	refresh_ui_buttons()

# Presets have no display name (per spec, identified purely by their layout
# picture) - each card is just a small grid diagram: one block per screen,
# light blue for primary (matching the primary grab bar color), dim white for
# secondaries.
func _build_preset_card(preset: Dictionary, is_selected: bool) -> Button:
	var card = Button.new()
	card.focus_mode = Control.FOCUS_NONE
	card.text = ""
	card.custom_minimum_size = PRESET_CARD_SIZE
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.16) if is_selected else Color(1, 1, 1, 0.04)
	style.set_corner_radius_all(10)
	if is_selected:
		style.set_border_width_all(2)
		style.border_color = PRESET_PRIMARY_COLOR
	card.add_theme_stylebox_override("normal", style)
	var hover = style.duplicate()
	hover.bg_color = Color(1, 1, 1, 0.22)
	card.add_theme_stylebox_override("hover", hover)
	card.add_theme_stylebox_override("pressed", hover)

	var diagram = Control.new()
	diagram.custom_minimum_size = PRESET_DIAGRAM_SIZE
	diagram.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	diagram.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	diagram.mouse_filter = Control.MOUSE_FILTER_IGNORE
	diagram.position = (PRESET_CARD_SIZE - PRESET_DIAGRAM_SIZE) * 0.5
	_draw_preset_blocks(diagram, preset)
	card.add_child(diagram)

	var id = preset.get("id", "")
	card.button_down.connect(func():
		main.settings_controller.select_monitor_preset(StringName(id))
		_refresh_preset_row()
	)
	return card

func _draw_preset_blocks(diagram: Control, preset: Dictionary):
	var cols = float(MonitorGrid.COLS)
	var rows = float(MonitorGrid.ROWS)
	var span = float(MonitorGrid.SPAN)
	var size = PRESET_DIAGRAM_SIZE
	var margin = 1.5
	for entry in preset.get("screens", []):
		var is_grid = entry.get("grid_mode", true)
		var gx = 3
		var gy = 1
		if is_grid and entry.get("grid_pos") != null:
			var gp: Array = entry["grid_pos"]
			gx = gp[0]
			gy = gp[1]
		# Free-mode entries have no grid cell - approximated at the grid
		# center purely for the picker's diagram (dimmed to signal it's not
		# exact); this never affects actual placement.
		var rect = ColorRect.new()
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var x0 = (gx / cols) * size.x
		var y0 = (gy / rows) * size.y
		var w = (span / cols) * size.x
		var h = (span / rows) * size.y
		rect.position = Vector2(x0 + margin, y0 + margin)
		rect.size = Vector2(w - margin * 2, h - margin * 2)
		rect.color = PRESET_PRIMARY_COLOR if entry.get("is_primary", false) else PRESET_SECONDARY_COLOR
		if not is_grid:
			rect.color.a *= 0.5
		diagram.add_child(rect)

func update_ui():
	main.get_node("%Crosshair").visible = (not main.is_xr_active and not main.mouse_captured_by_stream)
	main.get_node("%Laser").visible = main.is_xr_active

func switch_tab(tab: int):
	var entering_monitors_tab = (tab == 5 and _current_tab != 5)
	_current_tab = tab
	_tab_display.visible = (tab == 0)
	_tab_stream.visible = (tab == 1)
	if _tab_control: _tab_control.visible = (tab == 2)
	if _tab_monitors: _tab_monitors.visible = (tab == 5)
	if _tab_ai3d: _tab_ai3d.visible = (tab == 3)
	if _tab_picture: _tab_picture.visible = (tab == 4)
	if _tab_advanced: _tab_advanced.visible = (tab == 6)
	var tab_active_style = StyleBoxFlat.new()
	tab_active_style.bg_color = Color(1, 1, 1, 0.12)
	tab_active_style.set_corner_radius_all(16)
	tab_active_style.set_content_margin_all(12)
	var tab_inactive_style = StyleBoxFlat.new()
	tab_inactive_style.bg_color = Color(1, 1, 1, 0.04)
	tab_inactive_style.set_corner_radius_all(16)
	tab_inactive_style.set_content_margin_all(12)
	_tab_btn_display.add_theme_stylebox_override("normal", tab_active_style if tab == 0 else tab_inactive_style)
	_tab_btn_display.add_theme_stylebox_override("hover", tab_active_style)
	_tab_btn_stream.add_theme_stylebox_override("normal", tab_active_style if tab == 1 else tab_inactive_style)
	_tab_btn_stream.add_theme_stylebox_override("hover", tab_active_style)
	if _tab_btn_control:
		_tab_btn_control.add_theme_stylebox_override("normal", tab_active_style if tab == 2 else tab_inactive_style)
		_tab_btn_control.add_theme_stylebox_override("hover", tab_active_style)
		_tab_btn_control.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 2 else Color(1, 1, 1, 0.5))
	if _tab_btn_monitors:
		_tab_btn_monitors.add_theme_stylebox_override("normal", tab_active_style if tab == 5 else tab_inactive_style)
		_tab_btn_monitors.add_theme_stylebox_override("hover", tab_active_style)
		_tab_btn_monitors.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 5 else Color(1, 1, 1, 0.5))
	if _tab_btn_ai3d:
		_tab_btn_ai3d.add_theme_stylebox_override("normal", tab_active_style if tab == 3 else tab_inactive_style)
		_tab_btn_ai3d.add_theme_stylebox_override("hover", tab_active_style)
		_tab_btn_ai3d.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 3 else Color(1, 1, 1, 0.5))
	if _tab_btn_picture:
		_tab_btn_picture.add_theme_stylebox_override("normal", tab_active_style if tab == 4 else tab_inactive_style)
		_tab_btn_picture.add_theme_stylebox_override("hover", tab_active_style)
		_tab_btn_picture.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 4 else Color(1, 1, 1, 0.5))
	if _tab_btn_advanced:
		_tab_btn_advanced.add_theme_stylebox_override("normal", tab_active_style if tab == 6 else tab_inactive_style)
		_tab_btn_advanced.add_theme_stylebox_override("hover", tab_active_style)
		_tab_btn_advanced.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 6 else Color(1, 1, 1, 0.5))
	_tab_btn_display.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 0 else Color(1, 1, 1, 0.5))
	_tab_btn_stream.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 1 else Color(1, 1, 1, 0.5))

	if tab == 5:
		if entering_monitors_tab:
			main.settings_controller.sync_staged_from_current_layout()
		update_monitor_tab()

	var ui_buttons = []
	_collect_buttons(main.get_node("%UIRoot"), ui_buttons)
	main.xr_interaction.populate_ui_buttons(ui_buttons)

func build_ui():
	main.ui_panel_3d.mesh.size = main._ui_mesh_size
	main.ui_viewport.size = main._ui_viewport_size
	var col_shape = main.ui_panel_3d.get_node("Area3D/CollisionShape3D")
	if col_shape and col_shape.shape:
		# Increase the hitbox size by 0.2m on width and height to make clicking much easier
		col_shape.shape.size = Vector3(main._ui_mesh_size.x + 0.20, main._ui_mesh_size.y + 0.20, 0.05)
	var root = main.get_node("%UIRoot")
	for child in root.get_children():
		if child.name != "IPInput" and child.name != "Numpad":
			child.queue_free()

	main._btn_style = StyleBoxFlat.new()
	main._btn_style.bg_color = Color(1, 1, 1, 0.06)
	main._btn_style.set_corner_radius_all(20)
	main._btn_style.set_content_margin_all(16)

	main._btn_hover = StyleBoxFlat.new()
	main._btn_hover.bg_color = Color(1, 1, 1, 0.12)
	main._btn_hover.set_corner_radius_all(20)
	main._btn_hover.set_content_margin_all(16)

	var panel_bg = StyleBoxFlat.new()
	panel_bg.bg_color = Color(0.06, 0.06, 0.1, 0.92)
	panel_bg.set_corner_radius_all(32)
	panel_bg.set_content_margin_all(0)

	var panel = PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", panel_bg)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var brand = Label.new()
	brand.name = "Brand"
	brand.text = "Nightfall"
	brand.add_theme_font_size_override("font_size", 30)
	brand.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	brand.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brand.anchor_left = 0.0
	brand.anchor_right = 1.0
	brand.anchor_top = 0.0
	brand.anchor_bottom = 0.0
	brand.offset_top = 0.0
	brand.offset_bottom = 30.0
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(brand)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 0)
	vbox.size_flags_vertical = Control.SIZE_FILL
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vbox)

	var top_row = HBoxContainer.new()
	top_row.name = "TopRow"
	top_row.add_theme_constant_override("separation", 0)
	top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(top_row)

	main._ui_center_btn = Button.new()
	main._ui_center_btn.text = "\u25C9"
	main._ui_center_btn.focus_mode = Control.FOCUS_NONE
	main._ui_center_btn.custom_minimum_size = Vector2(60, 36)
	main._ui_center_btn.add_theme_font_size_override("font_size", 22)
	main._ui_center_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0, 0.6))
	main._ui_center_btn.add_theme_color_override("font_hover_color", Color(0.6, 0.8, 1.0, 1.0))
	var center_style = main._btn_style.duplicate()
	center_style.content_margin_left = 10
	center_style.content_margin_right = 10
	center_style.content_margin_top = 2
	center_style.content_margin_bottom = 2
	center_style.set_corner_radius_all(0)
	center_style.set_corner_radius(CORNER_TOP_LEFT, 32)
	var center_hover = main._btn_hover.duplicate()
	center_hover.content_margin_left = 10
	center_hover.content_margin_right = 10
	center_hover.content_margin_top = 2
	center_hover.content_margin_bottom = 2
	center_hover.bg_color = Color(0.2, 0.5, 0.86, 0.3)
	center_hover.set_corner_radius_all(0)
	center_hover.set_corner_radius(CORNER_TOP_LEFT, 32)
	main._ui_center_btn.add_theme_stylebox_override("normal", center_style)
	main._ui_center_btn.add_theme_stylebox_override("hover", center_hover)
	main._ui_center_btn.add_theme_stylebox_override("pressed", center_hover)
	top_row.add_child(main._ui_center_btn)

	main._ui_stats_btn = Button.new()
	main._ui_stats_btn.text = "Stats"
	main._ui_stats_btn.focus_mode = Control.FOCUS_NONE
	main._ui_stats_btn.custom_minimum_size = Vector2(100, 36)
	main._ui_stats_btn.add_theme_font_size_override("font_size", 22)
	main._ui_stats_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	main._ui_stats_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	var stats_style = main._btn_style.duplicate()
	stats_style.content_margin_left = 12
	stats_style.content_margin_right = 12
	stats_style.content_margin_top = 2
	stats_style.content_margin_bottom = 2
	stats_style.set_corner_radius_all(0)
	stats_style.set_corner_radius(CORNER_BOTTOM_RIGHT, 32)
	var stats_hover = main._btn_hover.duplicate()
	stats_hover.content_margin_left = 12
	stats_hover.content_margin_right = 12
	stats_hover.content_margin_top = 2
	stats_hover.content_margin_bottom = 2
	stats_hover.set_corner_radius_all(0)
	stats_hover.set_corner_radius(CORNER_BOTTOM_RIGHT, 32)
	main._ui_stats_btn.add_theme_stylebox_override("normal", stats_style)
	main._ui_stats_btn.add_theme_stylebox_override("hover", stats_hover)
	main._ui_stats_btn.add_theme_stylebox_override("pressed", stats_hover)
	top_row.add_child(main._ui_stats_btn)

	main._ui_host_label = Label.new()
	main._ui_host_label.name = "HostLabel"
	main._ui_host_label.add_theme_font_size_override("font_size", 26)
	main._ui_host_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	main._ui_host_label.custom_minimum_size = Vector2(0, 60)
	main._ui_host_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	main._ui_host_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var host_pad = Control.new()
	host_pad.custom_minimum_size = Vector2(24, 0)
	host_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(host_pad)
	top_row.add_child(main._ui_host_label)

	var left_spacer = Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(left_spacer)

	var right_spacer = Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(right_spacer)

	main._ui_exit_btn = Button.new()
	main._ui_exit_btn.text = "Exit"
	main._ui_exit_btn.focus_mode = Control.FOCUS_NONE
	main._ui_exit_btn.custom_minimum_size = Vector2(100, 36)
	main._ui_exit_btn.add_theme_font_size_override("font_size", 22)
	main._ui_exit_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	main._ui_exit_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	var exit_style = main._btn_style.duplicate()
	exit_style.content_margin_left = 14
	exit_style.content_margin_right = 14
	exit_style.content_margin_top = 2
	exit_style.content_margin_bottom = 2
	exit_style.set_corner_radius_all(0)
	exit_style.set_corner_radius(CORNER_BOTTOM_LEFT, 32)
	var exit_hover = main._btn_hover.duplicate()
	exit_hover.content_margin_left = 14
	exit_hover.content_margin_right = 14
	exit_hover.content_margin_top = 2
	exit_hover.content_margin_bottom = 2
	exit_hover.set_corner_radius_all(0)
	exit_hover.set_corner_radius(CORNER_BOTTOM_LEFT, 32)
	main._ui_exit_btn.add_theme_stylebox_override("normal", exit_style)
	main._ui_exit_btn.add_theme_stylebox_override("hover", exit_hover)
	main._ui_exit_btn.add_theme_stylebox_override("pressed", exit_hover)
	top_row.add_child(main._ui_exit_btn)

	main._ui_disconnect_btn = Button.new()
	main._ui_disconnect_btn.text = "Disconnect"
	main._ui_disconnect_btn.focus_mode = Control.FOCUS_NONE
	main._ui_disconnect_btn.custom_minimum_size = Vector2(140, 36)
	main._ui_disconnect_btn.add_theme_font_size_override("font_size", 22)
	main._ui_disconnect_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	main._ui_disconnect_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	var disc_style = main._btn_style.duplicate()
	disc_style.content_margin_left = 10
	disc_style.content_margin_right = 10
	disc_style.content_margin_top = 2
	disc_style.content_margin_bottom = 2
	disc_style.set_corner_radius_all(0)
	var disc_hover = main._btn_hover.duplicate()
	disc_hover.content_margin_left = 10
	disc_hover.content_margin_right = 10
	disc_hover.content_margin_top = 2
	disc_hover.content_margin_bottom = 2
	disc_hover.set_corner_radius_all(0)
	main._ui_disconnect_btn.add_theme_stylebox_override("normal", disc_style)
	main._ui_disconnect_btn.add_theme_stylebox_override("hover", disc_hover)
	main._ui_disconnect_btn.add_theme_stylebox_override("pressed", disc_hover)
	main._ui_disconnect_btn.visible = false
	top_row.add_child(main._ui_disconnect_btn)

	main._ui_close_btn = Button.new()
	main._ui_close_btn.text = "\u2715"
	main._ui_close_btn.focus_mode = Control.FOCUS_NONE
	main._ui_close_btn.custom_minimum_size = Vector2(60, 36)
	main._ui_close_btn.add_theme_font_size_override("font_size", 22)
	main._ui_close_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	main._ui_close_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	var close_style = main._btn_style.duplicate()
	close_style.content_margin_left = 10
	close_style.content_margin_right = 10
	close_style.content_margin_top = 2
	close_style.content_margin_bottom = 2
	close_style.set_corner_radius_all(0)
	close_style.set_corner_radius(CORNER_TOP_RIGHT, 32)
	var close_hover = main._btn_hover.duplicate()
	close_hover.content_margin_left = 10
	close_hover.content_margin_right = 10
	close_hover.content_margin_top = 2
	close_hover.content_margin_bottom = 2
	close_hover.bg_color = Color(0.86, 0.2, 0.2, 0.3)
	close_hover.set_corner_radius_all(0)
	close_hover.set_corner_radius(CORNER_TOP_RIGHT, 32)
	main._ui_close_btn.add_theme_stylebox_override("normal", close_style)
	main._ui_close_btn.add_theme_stylebox_override("hover", close_hover)
	main._ui_close_btn.add_theme_stylebox_override("pressed", close_hover)
	top_row.add_child(main._ui_close_btn)

	var top_margin = Control.new()
	top_margin.custom_minimum_size = Vector2(0, 44)
	top_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(top_margin)

	var tab_bar = HBoxContainer.new()
	tab_bar.name = "TabBar"
	tab_bar.add_theme_constant_override("separation", 8)
	tab_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	tab_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tab_bar)

	_build_tab_buttons(tab_bar)

	var tab_margin = Control.new()
	tab_margin.custom_minimum_size = Vector2(0, 12)
	tab_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tab_margin)

	# Uniform option grids are data-driven. AI 3D and Monitors remain custom
	# below because their rows are rearranged dynamically or contain non-option
	# controls.
	_tab_display = _build_menu_tab(vbox, MenuSchema.get_tab(&"display"))
	_tab_stream = _build_menu_tab(vbox, MenuSchema.get_tab(&"stream"))
	_tab_control = _build_menu_tab(vbox, MenuSchema.get_tab(&"control"))

	_tab_ai3d = VBoxContainer.new()
	_tab_ai3d.name = "TabAi3d"
	_tab_ai3d.add_theme_constant_override("separation", 0)
	_tab_ai3d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_ai3d.visible = false
	vbox.add_child(_tab_ai3d)

	var ai3d_row1 = HBoxContainer.new()
	ai3d_row1.name = "Ai3dRow1"
	ai3d_row1.add_theme_constant_override("separation", 12)
	ai3d_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	ai3d_row1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ai3d_row1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ai3d_row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_ai3d.add_child(ai3d_row1)

	main._ui_3d_mode_btn = make_option_btn("3D Mode", "Auto")
	# Hidden on Android (updated for real by update_3d_btn_state(), which
	# also runs during this same init - set here too so there's no
	# one-frame flash before that first fires, matching 3D Debug's own
	# construction-time pattern below).
	var ai3d_options_locked = main.settings_controller.ai3d_options_locked()
	ai3d_row1.visible = not ai3d_options_locked
	main._ui_3d_mode_btn.visible = not ai3d_options_locked
	ai3d_row1.add_child(main._ui_3d_mode_btn)
	main._ui_3d_type_btn = make_option_btn("Type", "GPU")
	main._ui_3d_type_btn.visible = not ai3d_options_locked
	ai3d_row1.add_child(main._ui_3d_type_btn)
	main._ui_3d_btn = make_option_btn("Model", main.settings_controller.ai_3d_models[0].label)
	main._ui_3d_btn.visible = not ai3d_options_locked
	ai3d_row1.add_child(main._ui_3d_btn)
	main._ui_3d_priority_btn = make_option_btn("GPU Priority", main.settings_controller.ai_3d_gpu_priority_labels[main.ai_3d_gpu_priority])
	if not ai3d_options_locked:
		ai3d_row1.add_child(main._ui_3d_priority_btn)

	var ai3d_gap1 = Control.new()
	ai3d_gap1.name = "Ai3dGap1"
	ai3d_gap1.custom_minimum_size = Vector2(0, 20)
	ai3d_gap1.visible = not ai3d_options_locked
	ai3d_gap1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_ai3d.add_child(ai3d_gap1)

	var ai3d_row2 = HBoxContainer.new()
	ai3d_row2.name = "Ai3dRow2"
	ai3d_row2.add_theme_constant_override("separation", 12)
	ai3d_row2.alignment = BoxContainer.ALIGNMENT_CENTER
	ai3d_row2.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ai3d_row2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ai3d_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_ai3d.add_child(ai3d_row2)

	main._ui_3d_hz_cap_btn = make_option_btn("Hz Cap", "20hz")
	ai3d_row2.add_child(main._ui_3d_hz_cap_btn)
	main._ui_3d_separation_btn = make_option_btn("Separation", "100%")
	ai3d_row2.add_child(main._ui_3d_separation_btn)
	main._ui_3d_convergence_btn = make_option_btn("Convergence", "50%")
	ai3d_row2.add_child(main._ui_3d_convergence_btn)
	main._ui_3d_cursor_position_btn = make_option_btn("Cursor Position", "Default")
	ai3d_row2.add_child(main._ui_3d_cursor_position_btn)
	if ai3d_options_locked:
		# Android locks Mode/Type/Model, leaving two controls for row 1 and
		# three for row 2. Keep the layout at four buttons or fewer per row.
		ai3d_row2.remove_child(main._ui_3d_hz_cap_btn)
		ai3d_row1.add_child(main._ui_3d_priority_btn)
		ai3d_row1.add_child(main._ui_3d_hz_cap_btn)

	_tab_picture = _build_menu_tab(
		vbox,
		MenuSchema.get_tab(&"picture"),
		{&"_ui_sharpen_btn": main.settings_controller.get_sharpen_label(main.sharpen_mode)}
	)

	_tab_monitors = VBoxContainer.new()
	_tab_monitors.name = "TabMonitors"
	_tab_monitors.add_theme_constant_override("separation", 0)
	_tab_monitors.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.visible = false
	vbox.add_child(_tab_monitors)

	var mon_row1 = HBoxContainer.new()
	mon_row1.name = "MonRow1"
	mon_row1.add_theme_constant_override("separation", 12)
	mon_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	mon_row1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mon_row1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mon_row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_row1)

	main._ui_monitors_btn = make_compact_option_btn("Monitors", "1")
	mon_row1.add_child(main._ui_monitors_btn)
	main._ui_virtual_monitors_btn = make_compact_option_btn("Virtual", "0")
	mon_row1.add_child(main._ui_virtual_monitors_btn)

	var mon_gap1 = Control.new()
	mon_gap1.custom_minimum_size = Vector2(0, 10)
	mon_gap1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_gap1)

	_preset_row = HBoxContainer.new()
	_preset_row.name = "PresetRow"
	_preset_row.add_theme_constant_override("separation", 10)
	_preset_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_preset_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_preset_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_preset_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(_preset_row)

	var mon_gap2 = Control.new()
	mon_gap2.custom_minimum_size = Vector2(0, 10)
	mon_gap2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_gap2)

	var mon_actions_row1 = HBoxContainer.new()
	mon_actions_row1.name = "MonActionsRow1"
	mon_actions_row1.add_theme_constant_override("separation", 12)
	mon_actions_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	mon_actions_row1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mon_actions_row1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mon_actions_row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_actions_row1)

	main._ui_apply_preset_btn = make_action_btn("Apply")
	mon_actions_row1.add_child(main._ui_apply_preset_btn)
	main._ui_save_preset_btn = make_action_btn("Save")
	mon_actions_row1.add_child(main._ui_save_preset_btn)
	main._ui_remove_preset_btn = make_action_btn("Remove")
	mon_actions_row1.add_child(main._ui_remove_preset_btn)
	main._ui_grid_mode_btn = make_compact_option_btn("Grid Mode", "On")
	mon_actions_row1.add_child(main._ui_grid_mode_btn)

	_tab_advanced = _build_menu_tab(vbox, MenuSchema.get_tab(&"advanced"))

	main._ui_status_label = Label.new()
	main._ui_status_label.name = "StatusLabel"
	main._ui_status_label.text = "Ready"
	main._ui_status_label.add_theme_font_size_override("font_size", 22)
	main._ui_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	main._ui_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main._ui_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	main._ui_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main._ui_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	main._ui_status_label.clip_text = false
	# clip_contents was true here - a leaf Label has no children to clip, so
	# this only risked the compatibility renderer computing a bad/zero clip
	# rect for its own text draw call (2026-08-24: this label was invisible
	# under GLES despite fully correct layout/visibility/alpha - every other
	# Label in the menu, e.g. the host-address label, works fine and none of
	# them set clip_contents). Removed as the prime suspect.
	main._ui_status_label.custom_minimum_size = Vector2(0, 56)
	main._ui_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(main._ui_status_label)

	var grab_gap = Control.new()
	grab_gap.custom_minimum_size = Vector2(0, 16)
	grab_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(grab_gap)

	var grab_bar_center = HBoxContainer.new()
	grab_bar_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grab_bar_center.add_theme_constant_override("separation", 0)
	vbox.add_child(grab_bar_center)

	var grab_left_spacer = Control.new()
	grab_left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grab_left_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grab_bar_center.add_child(grab_left_spacer)

	var grab_bar = PanelContainer.new()
	grab_bar.name = "CompGrabBar"
	grab_bar.custom_minimum_size = Vector2(0, 24)
	grab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grab_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grab_style = StyleBoxFlat.new()
	grab_style.bg_color = Color(1, 1, 1, 0.08)
	grab_style.set_corner_radius_all(14)
	grab_bar.add_theme_stylebox_override("panel", grab_style)
	grab_bar_center.add_child(grab_bar)

	var grab_right_spacer = Control.new()
	grab_right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grab_right_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grab_bar_center.add_child(grab_right_spacer)

	var bottom_margin = Control.new()
	bottom_margin.custom_minimum_size = Vector2(0, 32)
	bottom_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(bottom_margin)

	main._ui_exit_btn.button_down.connect(func(): main.exit_app())
	main._ui_disconnect_btn.button_down.connect(func(): main.disconnect_stream())
	main._ui_close_btn.button_down.connect(func(): main._toggle_ui())
	main._ui_center_btn.button_down.connect(func(): main._reset_positions())
	main._ui_stats_btn.button_down.connect(func(): main.toggle_performance_overlay())
	main._ui_disconnect_btn.visible = main.is_streaming
	update_stats_btn_state()
	main._ui_3d_mode_btn.button_down.connect(func(): on_ai_3d_mode_toggled())
	main._ui_3d_type_btn.button_down.connect(func(): on_ai_3d_type_toggled())
	main._ui_3d_btn.button_down.connect(func(): on_ai_3d_toggled())
	main._ui_3d_hz_cap_btn.button_down.connect(func(): on_ai_3d_hz_cap_toggled())
	main._ui_3d_separation_btn.button_down.connect(func(): on_ai_3d_separation_toggled())
	main._ui_3d_convergence_btn.button_down.connect(func(): on_ai_3d_convergence_toggled())
	main._ui_3d_cursor_position_btn.button_down.connect(func(): on_ai_3d_cursor_position_toggled())
	main._ui_3d_priority_btn.button_down.connect(func(): on_ai_3d_priority_toggled())
	main._ui_monitors_btn.button_down.connect(func(): _cycle_monitors_btn())
	main._ui_virtual_monitors_btn.button_down.connect(func(): _cycle_virtual_btn())
	main._ui_apply_preset_btn.button_down.connect(func(): _on_apply_preset_pressed())
	main._ui_save_preset_btn.button_down.connect(func(): _on_save_preset_pressed())
	main._ui_remove_preset_btn.button_down.connect(func(): _on_remove_preset_pressed())
	main._ui_grid_mode_btn.button_down.connect(func(): main.settings_controller.toggle_grid_mode())
	switch_tab(0)
	update_ctrl_mode_btn()
	update_ctrl_type_btn()
	update_host_cursor_btn_state()
	update_host_label()

	var ui_buttons = []
	_collect_buttons(root, ui_buttons)
	main.xr_interaction.populate_ui_buttons(ui_buttons)

func _build_tab_buttons(parent: HBoxContainer) -> void:
	for definition in MenuSchema.get_tab_buttons():
		var button := Button.new()
		button.text = definition["label"]
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(160, 44)
		button.add_theme_font_size_override("font_size", 22)
		button.add_theme_color_override(
			"font_color",
			Color(1, 1, 1, 1.0) if definition["index"] == 0 else Color(1, 1, 1, 0.5)
		)
		button.visible = definition["visible"]
		button.disabled = definition["disabled"]
		button.modulate.a = definition["alpha"]
		set(definition["field"], button)
		parent.add_child(button)
		button.button_down.connect(switch_tab.bind(definition["index"]))

func _build_menu_tab(
	parent: VBoxContainer,
	schema: Dictionary,
	value_overrides: Dictionary = {}
) -> VBoxContainer:
	var tab := VBoxContainer.new()
	tab.name = schema["node_name"]
	tab.add_theme_constant_override("separation", 0)
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab.visible = schema["id"] == &"display"
	parent.add_child(tab)

	var rows: Array = schema["rows"]
	for row_index in rows.size():
		if row_index > 0:
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(0, 20)
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tab.add_child(gap)
		var row_schema: Dictionary = rows[row_index]
		var row := HBoxContainer.new()
		row.name = row_schema["node_name"]
		row.add_theme_constant_override("separation", 12)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab.add_child(row)
		for option in row_schema["options"]:
			var field: StringName = option["field"]
			var value: String = value_overrides.get(field, option["value"])
			var button := make_option_btn(option["label"], value)
			button.visible = option["visible"]
			button.disabled = option["disabled"]
			main.set(field, button)
			row.add_child(button)
			_connect_menu_action(button, option)
	return tab

func _connect_menu_action(button: Button, option: Dictionary) -> void:
	var target := _menu_action_target(option["target"])
	var action: StringName = option["action"]
	if target == null or not target.has_method(action):
		push_error("Invalid menu action %s.%s" % [option["target"], action])
		return
	button.button_down.connect(Callable(target, action))

func _menu_action_target(target: StringName) -> Object:
	match target:
		MenuSchema.TARGET_UI:
			return self
		MenuSchema.TARGET_SETTINGS:
			return main.settings_controller
		MenuSchema.TARGET_SCREEN:
			return main.screen_manager
		MenuSchema.TARGET_CONTROLLER:
			return main.controller_mapper
	return null

func make_option_btn(label_text: String, value_text: String) -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = label_text + "\n" + value_text
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	btn.add_theme_stylebox_override("normal", main._btn_style)
	btn.add_theme_stylebox_override("hover", main._btn_hover)
	var pressed_style = main._btn_hover.duplicate()
	pressed_style.bg_color = Color(1, 1, 1, 0.18)
	btn.add_theme_stylebox_override("pressed", pressed_style)
	btn.custom_minimum_size = Vector2(250, 132)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return btn

# Shorter variant of make_option_btn() for the Monitors tab, which packs 3
# rows into the same vertical budget every other tab spends on 2 (132px each)
# - smaller font/margins so a "Label\nValue" pair still fits legibly at ~64px.
func make_compact_option_btn(label_text: String, value_text: String) -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = label_text + "\n" + value_text
	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	var style = main._btn_style.duplicate()
	style.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", style)
	var hover = main._btn_hover.duplicate()
	hover.set_content_margin_all(8)
	btn.add_theme_stylebox_override("hover", hover)
	var pressed_style = hover.duplicate()
	pressed_style.bg_color = Color(1, 1, 1, 0.18)
	btn.add_theme_stylebox_override("pressed", pressed_style)
	btn.custom_minimum_size = Vector2(150, 64)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return btn

# Single-line pure-action button (Apply/Save/Remove) - unlike make_option_btn's
# buttons, these have no persistent value to show, so "Label\nLabel" would
# just be redundant text.
func make_action_btn(text: String) -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = text
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	var style = main._btn_style.duplicate()
	style.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", style)
	var hover = main._btn_hover.duplicate()
	hover.set_content_margin_all(8)
	btn.add_theme_stylebox_override("hover", hover)
	var pressed_style = hover.duplicate()
	pressed_style.bg_color = Color(1, 1, 1, 0.18)
	btn.add_theme_stylebox_override("pressed", pressed_style)
	btn.custom_minimum_size = Vector2(110, 64)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return btn

func _collect_buttons(node: Control, result: Array):
	if node is Button:
		var btn: Button = node
		var norm = btn.get_meta("dual_hover_norm", null)
		if norm == null:
			norm = btn.get_theme_stylebox("normal")
			btn.set_meta("dual_hover_norm", norm)
		var hover = btn.get_theme_stylebox("hover")
		btn.set_meta("dual_hover_hover", hover)
		result.append({"btn": btn, "norm": norm, "hover": hover})
	for i in range(node.get_child_count()):
		var ch = node.get_child(i)
		if ch is Control:
			_collect_buttons(ch, result)

func refresh_ui_buttons():
	var root = main.get_node("%UIRoot")
	var btns = []
	_collect_buttons(root, btns)
	main.xr_interaction.populate_ui_buttons(btns)

func update_option_btn(btn: Button, value: String):
	if btn == null:
		return
	var parts = btn.text.split("\n")
	if parts.size() >= 2:
		btn.text = parts[0] + "\n" + value

func update_codec_btn():
	main.ui_controller.update_option_btn(main._ui_codec_btn, main.codec_labels[main.codec_preference])

func update_ctrl_mode_btn():
	if main._ui_ctrl_mode_btn and main.controller_mapper:
		update_option_btn(main._ui_ctrl_mode_btn, main.controller_mapper.get_mode_label())

func update_ctrl_type_btn():
	if main._ui_ctrl_type_btn and main.controller_mapper:
		update_option_btn(main._ui_ctrl_type_btn, main.controller_mapper.type_labels[main.controller_mapper.ctrl_type])
		if main._ui_btn_toggle_btn:
			var is_kbm = (main.controller_mapper.ctrl_type == 2)
			main._ui_btn_toggle_btn.disabled = is_kbm
			main._ui_btn_toggle_btn.modulate = Color(1, 1, 1, 0.3) if is_kbm else Color(1, 1, 1, 1)

func update_host_cursor_btn_state():
	if not main._ui_host_cursor_btn:
		return
	var supported = main._host_cursor_toggle_supported
	main._ui_host_cursor_btn.disabled = not supported
	main._ui_host_cursor_btn.modulate = Color(1, 1, 1, 0.3) if not supported else Color(1, 1, 1, 1)
	update_option_btn(main._ui_host_cursor_btn, "On" if main.host_cursor_visible else "Off")

func update_btn_toggle_btn():
	if main._ui_btn_toggle_btn and main.controller_mapper:
		update_option_btn(main._ui_btn_toggle_btn, main.controller_mapper.btn_toggle_labels[main.controller_mapper.btn_toggle])

func update_primary_btn():
	if main._ui_primary_btn and main.controller_mapper:
		update_option_btn(main._ui_primary_btn, main.controller_mapper.primary_labels[main.controller_mapper.primary_hand])

func update_host_label():
	if not main.is_streaming:
		if main._ui_host_label:
			main._ui_host_label.text = "Not connected"
		return
	if main._ui_host_label:
		if not main._last_hostname.is_empty():
			main._ui_host_label.text = main._last_hostname
		else:
			var ip = main.parse_ip_port(main.get_node("%IPInput").text)[0]
			var host_name = ""
			for h in main.stream_backend.get_config_manager().get_hosts():
				if h.has("localaddress") and h.localaddress == ip:
					var hname = h.get("hostname", "")
					if hname != ip and not hname.is_empty():
						host_name = hname
					break
			main._ui_host_label.text = host_name if not host_name.is_empty() else ip

func make_indicator_btn(label_text: String, value_text: String) -> Button:
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = label_text + ": " + value_text
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 0.7))
	var ind_style = StyleBoxFlat.new()
	ind_style.bg_color = Color(1, 1, 1, 0.0)
	ind_style.set_corner_radius_all(12)
	ind_style.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", ind_style)
	var ind_hover = StyleBoxFlat.new()
	ind_hover.bg_color = Color(1, 1, 1, 0.06)
	ind_hover.set_corner_radius_all(12)
	ind_hover.set_content_margin_all(8)
	btn.add_theme_stylebox_override("hover", ind_hover)
	btn.add_theme_stylebox_override("pressed", ind_hover)
	btn.custom_minimum_size = Vector2(140, 36)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return btn

func update_indicator_btn(btn: Button, label: String, value: String):
	btn.text = label + ": " + value

const STATUS_TEXT_MAX_LEN = 160

func set_status(text: String):
	if main._ui_status_label:
		if text.length() > STATUS_TEXT_MAX_LEN:
			text = text.substr(0, STATUS_TEXT_MAX_LEN - 1) + "…"
		main._ui_status_label.text = text

func set_disconnect_visible(vis: bool):
	if main._ui_disconnect_btn:
		main._ui_disconnect_btn.visible = vis
