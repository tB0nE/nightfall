class_name UIController
extends RefCounted

var main: Node3D
var _tab_display: Control
var _tab_stream: Control
var _tab_control: Control
var _tab_monitors: Control
var _tab_btn_display: Button
var _tab_btn_stream: Button
var _tab_btn_control: Button
var _tab_btn_monitors: Button
var _mon_icon_row: HBoxContainer
var _current_tab: int = 0

func _init(owner: Node3D):
	main = owner

func setup_numpad():
	var keys = ["7","8","9","4","5","6","1","2","3",".","0","DEL"]
	for key in keys:
		var btn = Button.new()
		btn.text = key
		btn.custom_minimum_size = Vector2(120, 70)
		btn.size_flags_stretch_ratio = 1.0
		btn.pressed.connect(on_numpad_key.bind(key))
		main.get_node("%Numpad").add_child(btn)

func on_numpad_key(key: String):
	if key == "DEL":
		var text = main.get_node("%IPInput").text
		if text.length() > 0:
			main.get_node("%IPInput").text = text.substr(0, text.length() - 1)
	elif main.get_node("%IPInput").text.length() < 15:
		main.get_node("%IPInput").text += key

func on_ipinput_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		main.get_node("%Numpad").visible = true

func on_sbs_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_sbs_mode()

func on_ai_3d_toggled():
	main.auto_detect_enabled = false
	main.settings_controller.cycle_ai_3d_mode()

func update_stereo_shader():
	if main.screen_mesh.material_override is ShaderMaterial:
		main.screen_mesh.material_override.set_shader_parameter("stereo_mode", main.settings_controller.get_stereo_mode())
	update_option_btn(main._ui_sbs_btn, main.settings_controller.sbs_labels[main.sbs_mode])
	update_option_btn(main._ui_3d_btn, main.settings_controller.ai_3d_labels[main.ai_3d_mode])
	update_3d_btn_state()

func update_3d_btn_state():
	if main._ui_3d_btn:
		var disabled = main.sbs_mode > 0 or main.screens.size() > 1
		main._ui_3d_btn.disabled = disabled
		main._ui_3d_btn.modulate.a = 0.3 if disabled else 1.0

func update_monitor_tab():
	if not _mon_icon_row or not main._ui_mon_remove_btn:
		return
	for c in _mon_icon_row.get_children():
		_mon_icon_row.remove_child(c)
		c.queue_free()
	for i in main.layout.monitors.size():
		var m = main.layout.monitors[i]
		var btn = Button.new()
		btn.text = "Monitor " + str(i + 1)
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", 26)
		btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
		var bg = Color(1, 1, 1, 0.12) if i == main._edit_monitor_idx else Color(1, 1, 1, 0.04)
		var style = StyleBoxFlat.new()
		style.bg_color = bg
		style.set_corner_radius_all(8)
		btn.add_theme_stylebox_override("normal", style)
		var hover = style.duplicate()
		hover.bg_color = Color(1, 1, 1, 0.18)
		btn.add_theme_stylebox_override("hover", hover)
		btn.custom_minimum_size = Vector2(200, 60)
		var idx = i
		btn.button_down.connect(func(): main.settings_controller.select_monitor(idx))
		_mon_icon_row.add_child(btn)
	if main.layout.monitors.size() < 4:
		var add_btn = Button.new()
		add_btn.text = "+"
		add_btn.focus_mode = Control.FOCUS_NONE
		add_btn.add_theme_font_size_override("font_size", 26)
		add_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		add_btn.custom_minimum_size = Vector2(60, 60)
		var add_style = StyleBoxFlat.new()
		add_style.bg_color = Color(1, 1, 1, 0.06)
		add_style.set_corner_radius_all(8)
		add_btn.add_theme_stylebox_override("normal", add_style)
		var add_hover = add_style.duplicate()
		add_hover.bg_color = Color(1, 1, 1, 0.18)
		add_btn.add_theme_stylebox_override("hover", add_hover)
		add_btn.button_down.connect(func(): main.settings_controller.add_monitor())
		_mon_icon_row.add_child(add_btn)
	main._edit_monitor_idx = clampi(main._edit_monitor_idx, 0, main.layout.monitors.size() - 1)
	var m = main.layout.monitors[main._edit_monitor_idx]
	update_option_btn(main._ui_mon_enabled_btn, "On" if m.enabled else "Off")
	update_option_btn(main._ui_mon_primary_btn, "Yes" if m.is_primary else "No")
	update_option_btn(main._ui_mon_remove_btn, "Remove")
	main._ui_mon_enabled_btn.disabled = m.is_primary
	main._ui_mon_primary_btn.disabled = not m.enabled
	main._ui_mon_remove_btn.disabled = main.layout.monitors.size() <= 1

func update_ui():
	main.get_node("%Crosshair").visible = (not main.is_xr_active and not main.mouse_captured_by_stream)
	main.get_node("%Laser").visible = main.is_xr_active

func switch_tab(tab: int):
	_current_tab = tab
	_tab_display.visible = (tab == 0)
	_tab_stream.visible = (tab == 1)
	if _tab_control: _tab_control.visible = (tab == 2)
	if _tab_monitors: _tab_monitors.visible = (tab == 3)
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
		_tab_btn_monitors.add_theme_stylebox_override("normal", tab_active_style if tab == 3 else tab_inactive_style)
		_tab_btn_monitors.add_theme_stylebox_override("hover", tab_active_style)
		_tab_btn_monitors.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 3 else Color(1, 1, 1, 0.5))
	_tab_btn_display.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 0 else Color(1, 1, 1, 0.5))
	_tab_btn_stream.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if tab == 1 else Color(1, 1, 1, 0.5))

	if tab == 3:
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

	_tab_btn_display = Button.new()
	_tab_btn_display.text = "Display"
	_tab_btn_display.focus_mode = Control.FOCUS_NONE
	_tab_btn_display.custom_minimum_size = Vector2(160, 44)
	_tab_btn_display.add_theme_font_size_override("font_size", 22)
	_tab_btn_display.add_theme_color_override("font_color", Color(1, 1, 1, 1.0))
	tab_bar.add_child(_tab_btn_display)

	_tab_btn_stream = Button.new()
	_tab_btn_stream.text = "Stream"
	_tab_btn_stream.focus_mode = Control.FOCUS_NONE
	_tab_btn_stream.custom_minimum_size = Vector2(160, 44)
	_tab_btn_stream.add_theme_font_size_override("font_size", 22)
	_tab_btn_stream.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	tab_bar.add_child(_tab_btn_stream)

	_tab_btn_control = Button.new()
	_tab_btn_control.text = "Control"
	_tab_btn_control.focus_mode = Control.FOCUS_NONE
	_tab_btn_control.custom_minimum_size = Vector2(160, 44)
	_tab_btn_control.add_theme_font_size_override("font_size", 22)
	_tab_btn_control.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	tab_bar.add_child(_tab_btn_control)

	_tab_btn_monitors = Button.new()
	_tab_btn_monitors.text = "Monitors"
	_tab_btn_monitors.focus_mode = Control.FOCUS_NONE
	_tab_btn_monitors.custom_minimum_size = Vector2(160, 44)
	_tab_btn_monitors.add_theme_font_size_override("font_size", 22)
	_tab_btn_monitors.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	tab_bar.add_child(_tab_btn_monitors)

	var tab_margin = Control.new()
	tab_margin.custom_minimum_size = Vector2(0, 12)
	tab_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tab_margin)

	_tab_display = VBoxContainer.new()
	_tab_display.name = "TabDisplay"
	_tab_display.add_theme_constant_override("separation", 0)
	_tab_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_tab_display)

	var disp_row1 = HBoxContainer.new()
	disp_row1.name = "DispRow1"
	disp_row1.add_theme_constant_override("separation", 12)
	disp_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	disp_row1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	disp_row1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	disp_row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_display.add_child(disp_row1)

	main._ui_pt_btn = make_option_btn("Passthrough", "On")
	disp_row1.add_child(main._ui_pt_btn)
	main._ui_sbs_btn = make_option_btn("SBS", "Off")
	disp_row1.add_child(main._ui_sbs_btn)
	main._ui_3d_btn = make_option_btn("3D AI", "2D")
	disp_row1.add_child(main._ui_3d_btn)

	var disp_gap1 = Control.new()
	disp_gap1.custom_minimum_size = Vector2(0, 20)
	disp_gap1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_display.add_child(disp_gap1)

	var disp_row2 = HBoxContainer.new()
	disp_row2.name = "DispRow2"
	disp_row2.add_theme_constant_override("separation", 12)
	disp_row2.alignment = BoxContainer.ALIGNMENT_CENTER
	disp_row2.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	disp_row2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	disp_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_display.add_child(disp_row2)

	main._ui_sharpen_btn = make_option_btn("Sharpen", "0%")
	disp_row2.add_child(main._ui_sharpen_btn)
	main._ui_render_btn = make_option_btn("Blur", "0%")
	disp_row2.add_child(main._ui_render_btn)
	main._ui_bg_btn = make_option_btn("Background", "Black")
	disp_row2.add_child(main._ui_bg_btn)

	_tab_stream = VBoxContainer.new()
	_tab_stream.name = "TabStream"
	_tab_stream.add_theme_constant_override("separation", 0)
	_tab_stream.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_stream.visible = false
	vbox.add_child(_tab_stream)

	var stream_row1 = HBoxContainer.new()
	stream_row1.name = "StreamRow1"
	stream_row1.add_theme_constant_override("separation", 12)
	stream_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	stream_row1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stream_row1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stream_row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_stream.add_child(stream_row1)

	main._ui_res_btn = make_option_btn("Resolution", "HD")
	stream_row1.add_child(main._ui_res_btn)
	main._ui_fps_btn = make_option_btn("FPS", "60")
	stream_row1.add_child(main._ui_fps_btn)
	main._ui_bitrate_btn = make_option_btn("Bitrate", "Auto")
	stream_row1.add_child(main._ui_bitrate_btn)

	var stream_gap1 = Control.new()
	stream_gap1.custom_minimum_size = Vector2(0, 20)
	stream_gap1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_stream.add_child(stream_gap1)

	var stream_row2 = HBoxContainer.new()
	stream_row2.name = "StreamRow2"
	stream_row2.add_theme_constant_override("separation", 12)
	stream_row2.alignment = BoxContainer.ALIGNMENT_CENTER
	stream_row2.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stream_row2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stream_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_stream.add_child(stream_row2)

	main._ui_codec_btn = make_option_btn("Codec", "HEVC")
	stream_row2.add_child(main._ui_codec_btn)
	main._ui_reconnect_btn = make_option_btn("Auto-Reconnect", "On")
	stream_row2.add_child(main._ui_reconnect_btn)
	main._ui_idle_btn = make_option_btn("Idle Disconnect", "Off")
	stream_row2.add_child(main._ui_idle_btn)
	main._ui_quick_start_btn = make_option_btn("Quick Start", "Off")
	stream_row2.add_child(main._ui_quick_start_btn)

	_tab_control = VBoxContainer.new()
	_tab_control.name = "TabControl"
	_tab_control.add_theme_constant_override("separation", 0)
	_tab_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_control.visible = false
	vbox.add_child(_tab_control)

	var control_row1 = HBoxContainer.new()
	control_row1.name = "ControlRow1"
	control_row1.add_theme_constant_override("separation", 12)
	control_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	control_row1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	control_row1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	control_row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_control.add_child(control_row1)

	main._ui_cursor_btn = make_option_btn("Cursor Type", "Circle")
	control_row1.add_child(main._ui_cursor_btn)
	main._ui_steady_btn = make_option_btn("Cursor Steady", "Low")
	control_row1.add_child(main._ui_steady_btn)
	main._ui_hand_tracking_btn = make_option_btn("Tracking", "Off")
	control_row1.add_child(main._ui_hand_tracking_btn)

	var control_gap1 = Control.new()
	control_gap1.custom_minimum_size = Vector2(0, 20)
	control_gap1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_control.add_child(control_gap1)

	var control_row2 = HBoxContainer.new()
	control_row2.name = "ControlRow2"
	control_row2.add_theme_constant_override("separation", 12)
	control_row2.alignment = BoxContainer.ALIGNMENT_CENTER
	control_row2.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	control_row2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	control_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_control.add_child(control_row2)

	main._ui_ctrl_mode_btn = make_option_btn("Mapping", "Off")
	control_row2.add_child(main._ui_ctrl_mode_btn)
	main._ui_ctrl_type_btn = make_option_btn("Device Mode", "PAD")
	control_row2.add_child(main._ui_ctrl_type_btn)
	main._ui_btn_toggle_btn = make_option_btn("Alternate Mode", "Head")
	control_row2.add_child(main._ui_btn_toggle_btn)
	main._ui_primary_btn = make_option_btn("Primary Hand", "Right")
	control_row2.add_child(main._ui_primary_btn)

	_tab_monitors = VBoxContainer.new()
	_tab_monitors.name = "TabMonitors"
	_tab_monitors.add_theme_constant_override("separation", 0)
	_tab_monitors.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.visible = false
	vbox.add_child(_tab_monitors)

	var mon_gap = Control.new()
	mon_gap.custom_minimum_size = Vector2(0, 20)
	mon_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_gap)

	_mon_icon_row = HBoxContainer.new()
	_mon_icon_row.name = "MonIconRow"
	_mon_icon_row.add_theme_constant_override("separation", 8)
	_mon_icon_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_mon_icon_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_mon_icon_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(_mon_icon_row)

	var mon_gap2 = Control.new()
	mon_gap2.custom_minimum_size = Vector2(0, 20)
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

	main._ui_mon_enabled_btn = make_option_btn("Enabled", "On")
	mon_actions_row1.add_child(main._ui_mon_enabled_btn)
	main._ui_mon_primary_btn = make_option_btn("Primary", "Yes")
	mon_actions_row1.add_child(main._ui_mon_primary_btn)
	main._ui_mon_remove_btn = make_option_btn("Remove", "Remove")
	mon_actions_row1.add_child(main._ui_mon_remove_btn)

	var mon_gap3 = Control.new()
	mon_gap3.custom_minimum_size = Vector2(0, 12)
	mon_gap3.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_gap3)

	var mon_actions_row2 = HBoxContainer.new()
	mon_actions_row2.name = "MonActionsRow2"
	mon_actions_row2.add_theme_constant_override("separation", 12)
	mon_actions_row2.alignment = BoxContainer.ALIGNMENT_CENTER
	mon_actions_row2.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mon_actions_row2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mon_actions_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_monitors.add_child(mon_actions_row2)

	main._ui_curve_btn = make_option_btn("Curve", "Flat")
	mon_actions_row2.add_child(main._ui_curve_btn)
	main._ui_bezel_btn = make_option_btn("Bezel", "On")
	mon_actions_row2.add_child(main._ui_bezel_btn)

	main._ui_status_label = Label.new()
	main._ui_status_label.name = "StatusLabel"
	main._ui_status_label.text = "Ready"
	main._ui_status_label.add_theme_font_size_override("font_size", 22)
	main._ui_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	main._ui_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main._ui_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	main._ui_status_label.custom_minimum_size = Vector2(0, 56)
	main._ui_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	main._ui_disconnect_btn.visible = main.is_streaming
	main._ui_pt_btn.button_down.connect(func(): main.settings_controller.toggle_passthrough())
	main._ui_curve_btn.button_down.connect(func(): main.screen_manager.cycle_curvature())
	main._ui_bg_btn.button_down.connect(func(): main.settings_controller.cycle_background())
	main._ui_bezel_btn.button_down.connect(func(): main.screen_manager.toggle_bezel())
	main._ui_hand_tracking_btn.button_down.connect(func(): main.settings_controller.toggle_hand_tracking())
	main._ui_sbs_btn.button_down.connect(func(): on_sbs_toggled())
	main._ui_3d_btn.button_down.connect(func(): on_ai_3d_toggled())
	main._ui_mon_remove_btn.button_down.connect(func(): main.settings_controller.remove_monitor())
	main._ui_mon_enabled_btn.button_down.connect(func(): main.settings_controller.toggle_edit_monitor_enabled())
	main._ui_mon_primary_btn.button_down.connect(func(): main.settings_controller.set_edit_monitor_primary())
	main._ui_res_btn.button_down.connect(func(): main.settings_controller.cycle_resolution())
	main._ui_fps_btn.button_down.connect(func(): main.settings_controller.cycle_fps())
	main._ui_bitrate_btn.button_down.connect(func(): main.settings_controller.cycle_bitrate())
	main._ui_render_btn.button_down.connect(func(): main.settings_controller.cycle_smooth_mode())
	main._ui_sharpen_btn.button_down.connect(func(): main.settings_controller.cycle_sharpen_mode())
	main._ui_cursor_btn.button_down.connect(func(): main.settings_controller.cycle_cursor_mode())
	main._ui_steady_btn.button_down.connect(func(): main.settings_controller.cycle_steady())
	main._ui_codec_btn.button_down.connect(func(): main.settings_controller.cycle_codec())
	main._ui_ctrl_mode_btn.button_down.connect(func(): main.controller_mapper.check_toggle_ui())
	main._ui_ctrl_type_btn.button_down.connect(func(): main.controller_mapper.cycle_type())
	main._ui_btn_toggle_btn.button_down.connect(func(): main.controller_mapper.cycle_btn_toggle())
	main._ui_primary_btn.button_down.connect(func(): main.controller_mapper.cycle_primary_hand())
	main._ui_reconnect_btn.button_down.connect(func(): main.settings_controller.cycle_auto_reconnect())
	main._ui_quick_start_btn.button_down.connect(func(): main.settings_controller.cycle_quick_start())
	main._ui_idle_btn.button_down.connect(func(): main.settings_controller.cycle_idle_timeout())
	_tab_btn_display.button_down.connect(func(): switch_tab(0))
	_tab_btn_stream.button_down.connect(func(): switch_tab(1))
	_tab_btn_control.button_down.connect(func(): switch_tab(2))
	_tab_btn_monitors.button_down.connect(func(): switch_tab(3))
	switch_tab(0)
	update_ctrl_mode_btn()
	update_ctrl_type_btn()
	update_host_label()

	var ui_buttons = []
	_collect_buttons(root, ui_buttons)
	main.xr_interaction.populate_ui_buttons(ui_buttons)

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
			var ip = main.get_node("%IPInput").text
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

func set_status(text: String):
	if main._ui_status_label:
		main._ui_status_label.text = text

func set_disconnect_visible(vis: bool):
	if main._ui_disconnect_btn:
		main._ui_disconnect_btn.visible = vis
