class_name VirtualTrackpad
extends VRPanelBase

func _init(owner: Node3D):
	super(owner)
	mesh_size = Vector2(0.25, 0.25)
	viewport_size = Vector2i(500, 500)
var _tp_root: Control
var _border: PanelContainer
var _bg: PanelContainer

var trackpad_active: bool = false
var _trackpad_hand: XRController3D = null
var _last_hand_pos: Vector3 = Vector3.ZERO
var _sensitivity: float = 20000.0
var _dead_zone: float = 0.001

func build():
	_setup_viewport("TPViewport")

	_tp_root = Control.new()
	_tp_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tp_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(_tp_root)

	_bg = PanelContainer.new()
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.06, 0.06, 0.12, 0.85)
	bg_style.set_corner_radius_all(24)
	bg_style.set_border_width_all(3)
	bg_style.border_color = Color(0.3, 0.3, 0.4, 0.5)
	_bg.add_theme_stylebox_override("panel", bg_style)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(_bg)

	_build_arrows()

	_border = PanelContainer.new()
	_border.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var border_style = StyleBoxFlat.new()
	border_style.bg_color = Color(0, 0, 0, 0)
	border_style.set_corner_radius_all(24)
	border_style.set_border_width_all(3)
	border_style.border_color = Color(0.3, 0.3, 0.4, 0.5)
	_border.add_theme_stylebox_override("panel", border_style)
	_border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(_border)

	_setup_grab_bar(viewport, 28, -40, -8, 14)
	_setup_mesh("TPPanel")
	_setup_collision()
	_hide_initially()

func _build_arrows():
	var cw = viewport_size.x
	var ch = viewport_size.y
	var cx = cw / 2.0
	var cy = ch / 2.0 - 20

	var arrow_color = Color(0.4, 0.4, 0.5, 0.35)
	var arrow_len = 60
	var arrow_head = 16

	var up_label = Label.new()
	up_label.text = "▲"
	up_label.position = Vector2(cx - 10, cy - arrow_len - arrow_head)
	up_label.size = Vector2(20, 20)
	up_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	up_label.add_theme_font_size_override("font_size", 22)
	up_label.add_theme_color_override("font_color", arrow_color)
	up_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(up_label)

	var down_label = Label.new()
	down_label.text = "▼"
	down_label.position = Vector2(cx - 10, cy + arrow_len)
	down_label.size = Vector2(20, 20)
	down_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	down_label.add_theme_font_size_override("font_size", 22)
	down_label.add_theme_color_override("font_color", arrow_color)
	down_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(down_label)

	var left_label = Label.new()
	left_label.text = "◀"
	left_label.position = Vector2(cx - arrow_len - arrow_head - 10, cy - 10)
	left_label.size = Vector2(20, 20)
	left_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left_label.add_theme_font_size_override("font_size", 22)
	left_label.add_theme_color_override("font_color", arrow_color)
	left_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(left_label)

	var right_label = Label.new()
	right_label.text = "▶"
	right_label.position = Vector2(cx + arrow_len, cy - 10)
	right_label.size = Vector2(20, 20)
	right_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right_label.add_theme_font_size_override("font_size", 22)
	right_label.add_theme_color_override("font_color", arrow_color)
	right_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(right_label)

	var title = Label.new()
	title.text = "TRACKPAD"
	title.position = Vector2(0, 12)
	title.size = Vector2(cw, 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.6))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(title)

	var hint = Label.new()
	hint.text = "Hold trigger &\nmove controller"
	hint.position = Vector2(0, cy - 16)
	hint.size = Vector2(cw, 40)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5, 0.4))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tp_root.add_child(hint)

func handle_pointer(pixel_pos: Vector2, clicking: bool, was_clicking: bool, hand: XRController3D = null):
	if not visible:
		return

	if clicking and not was_clicking:
		trackpad_active = true
		_trackpad_hand = hand if hand else main.right_hand
		_last_hand_pos = _trackpad_hand.global_position
		_set_active_visual(true)

	if not clicking and was_clicking:
		trackpad_active = false
		_trackpad_hand = null
		_set_active_visual(false)

func _set_active_visual(active: bool):
	_apply_border_active(_border, active, Color(0.3, 0.3, 0.4, 0.5), Color(0.3, 0.6, 1.0, 0.9))

func _process(_delta):
	if not is_visible_in_tree() or not main.is_streaming:
		if trackpad_active:
			trackpad_active = false
			_trackpad_hand = null
			_set_active_visual(false)
		return

	if trackpad_active:
		var hand := _trackpad_hand
		if not is_instance_valid(hand):
			trackpad_active = false
			_trackpad_hand = null
			_set_active_visual(false)
			return
		var trigger = hand.get_float("trigger")
		if trigger < 0.5:
			trackpad_active = false
			_trackpad_hand = null
			_set_active_visual(false)
			return

		var hand_pos = hand.global_position
		var delta_3d = hand_pos - _last_hand_pos

		if delta_3d.length() < _dead_zone:
			_last_hand_pos = hand_pos
			return

		var cam_right = main.xr_camera.global_transform.basis.x
		var cam_up = main.xr_camera.global_transform.basis.y

		var dx = delta_3d.dot(cam_right) * _sensitivity
		var dy = -delta_3d.dot(cam_up) * _sensitivity

		var idx = int(dx)
		var idy = int(dy)

		if idx != 0 or idy != 0:
			main.stream_backend.send_mouse_move_event(idx, idy)

		_last_hand_pos = hand_pos

func _place_default():
	var cam_pos = main.xr_camera.global_position
	var cam_fwd = -main.xr_camera.global_transform.basis.z
	global_position = cam_pos + cam_fwd * 1.0 + Vector3(0, -0.35, 0)
	var to_cam = (cam_pos - global_position).normalized()
	rotation = Vector3.ZERO
	rotation.y = atan2(to_cam.x, to_cam.z)
	rotation.x = -PI / 4.0

func _on_hide():
	trackpad_active = false
	_trackpad_hand = null
	_set_active_visual(false)
