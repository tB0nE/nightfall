class_name XRInteraction
extends RefCounted

var main: Node3D
var pointer_on_ui: bool = false

var _active_hand: String = "right"
var _pinch_start_time: float = 0.0
var _pinch_start_pos: Vector2 = Vector2.ZERO
var _pinch_start_screen: VRScreen = null
var _click_pending_release: bool = false
var _corner_resize_started: bool = false
var _auto_primary: String = ""
var _auto_reset_timer: float = 0.0
var _right_on_screen: bool = false
var _left_on_screen: bool = false
var _other_hand_clicking: bool = false
var _secondary_press_viewport: SubViewport = null
var _secondary_press_was_keyboard: bool = false
var _right_inactive_time: float = 0.0
var _left_inactive_time: float = 0.0
var _last_known_right_pos: Vector3 = Vector3.ZERO
var _last_known_left_pos: Vector3 = Vector3.ZERO
var _last_known_right_rot: Vector3 = Vector3.ZERO
var _last_known_left_rot: Vector3 = Vector3.ZERO

var _primary_ui_pixel: Vector2 = Vector2(-1, -1)
var _secondary_ui_pixel: Vector2 = Vector2(-1, -1)
var _ui_button_states: Array = []
var _last_ui_style: Dictionary = {}

func populate_ui_buttons(buttons: Array):
	_ui_button_states = buttons

func _init(owner: Node3D):
	main = owner

func get_active_raycast() -> RayCast3D:
	if not main.is_xr_active:
		return main.mouse_raycast
	if _active_hand == "left" and main.left_hand_raycast:
		return main.left_hand_raycast
	return main.hand_raycast

func _get_hand_raycast(hand: String) -> RayCast3D:
	if hand == "left" and main.left_hand_raycast:
		return main.left_hand_raycast
	return main.hand_raycast

func _get_hand_pinch_strength(tracker_name: String) -> float:
	var tracker = XRServer.get_tracker(tracker_name)
	if not tracker:
		return 0.0
	var thumb_flags = tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_THUMB_TIP)
	var index_flags = tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	if (thumb_flags & 8) == 0 or (index_flags & 8) == 0:
		return 0.0
	var thumb_tip = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
	var index_tip = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
	var dist = (index_tip - thumb_tip).length()
	return clampf(1.0 - (dist - 0.015) / (0.045 - 0.015), 0.0, 1.0)

func _get_hand_grasp_strength(tracker_name: String) -> float:
	var tracker = XRServer.get_tracker(tracker_name)
	if not tracker:
		return 0.0
	# Prevent right-click if left-click is fully active
	if _get_hand_pinch_strength(tracker_name) > 0.85:
		return 0.0
	var thumb_flags = tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_THUMB_TIP)
	var middle_flags = tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP)
	if (thumb_flags & 8) == 0 or (middle_flags & 8) == 0:
		return 0.0
	var thumb_tip = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
	var middle_tip = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP).origin
	var dist = (middle_tip - thumb_tip).length()
	return clampf(1.0 - (dist - 0.015) / (0.045 - 0.015), 0.0, 1.0)

func _update_active_hand():
	if not main.is_xr_active:
		return
	if main._is_using_hands:
		var right_has_data = false
		var left_has_data = false
		var right_tracker = XRServer.get_tracker("/user/hand_tracker/right")
		var left_tracker = XRServer.get_tracker("/user/hand_tracker/left")
		if right_tracker and right_tracker is XRHandTracker and right_tracker.get_has_tracking_data():
			right_has_data = true
		if left_tracker and left_tracker is XRHandTracker and left_tracker.get_has_tracking_data():
			left_has_data = true
		if right_has_data and left_has_data:
			var right_pinch = _get_hand_pinch_strength("/user/hand_tracker/right")
			var left_pinch = _get_hand_pinch_strength("/user/hand_tracker/left")
			if left_pinch > 0.5 and right_pinch <= 0.5:
				_active_hand = "left"
			elif right_pinch > 0.5 and left_pinch <= 0.5:
				_active_hand = "right"
		elif left_has_data and not right_has_data:
			_active_hand = "left"
		elif right_has_data:
			_active_hand = "right"
		return
	var primary = main.controller_mapper.primary_hand if main.controller_mapper else 0
	match primary:
		ControllerMapper.PrimaryHand.RIGHT:
			_active_hand = "right"
		ControllerMapper.PrimaryHand.LEFT:
			_active_hand = "left"
		_:
			_active_hand = _get_auto_primary()

func _get_auto_primary() -> String:
	if _auto_primary != "":
		return _auto_primary
	if _right_on_screen and not _left_on_screen:
		_auto_primary = "right"
		_auto_reset_timer = 0.2
	elif _left_on_screen and not _right_on_screen:
		_auto_primary = "left"
		_auto_reset_timer = 0.2
	return _active_hand if _active_hand != "" else "right"

func _process_auto_primary(delta: float):
	if not _right_on_screen and not _left_on_screen:
		_auto_reset_timer -= delta
		if _auto_reset_timer <= 0.0:
			_auto_primary = ""
			_auto_reset_timer = 0.0
	else:
		_auto_reset_timer = 0.2

func _is_now_clicking() -> bool:
	if not main.is_xr_active:
		return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if main._is_using_hands:
		var tracker_name = "/user/hand_tracker/left" if _active_hand == "left" else "/user/hand_tracker/right"
		return _get_hand_pinch_strength(tracker_name) > 0.85
	else:
		var hand = main.left_hand if _active_hand == "left" else main.right_hand
		if hand:
			return hand.get_float("trigger") > 0.5
		return false

func _is_now_gripping() -> bool:
	if not main.is_xr_active:
		return false
	if main._is_using_hands:
		var tracker_name = "/user/hand_tracker/left" if _active_hand == "left" else "/user/hand_tracker/right"
		return _get_hand_grasp_strength(tracker_name) > 0.85
	var hand = main.left_hand if _active_hand == "left" else main.right_hand
	if not hand:
		return false
	if hand.is_button_pressed("grip_click"):
		return true
	if hand.is_button_pressed("grip"):
		return true
	if hand.get_float("grip") > 0.2:
		return true
	return false

func handle_pointer_interaction():
	_update_active_hand()
	_update_on_screen_tracking()
	_process_auto_primary(main.get_process_delta_time())
	var active_raycast = get_active_raycast()
	pointer_on_ui = false

	_primary_ui_pixel = Vector2(-1, -1)

	var is_now_clicking = _is_now_clicking()
	if is_now_clicking and not main.was_clicking and not _click_pending_release:
		_pinch_start_time = Time.get_ticks_msec()
		var col = active_raycast.get_collider() if active_raycast.is_colliding() else null
		var t0 = PointerTarget.resolve(col) if col else {"role": &""}
		if t0.role == &"screen":
			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
			var uv = t0.screen.hit_point_to_uv(hit_pos)
			var uv_x = uv.x
			if main.settings_controller.get_stereo_mode() >= 3:
				var shift = _compute_parallax_shift(uv_x)
				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
			_pinch_start_pos = Vector2(main.layout.uv_to_host_point(t0.screen.monitor, Vector2(uv_x, uv.y)))
			_pinch_start_screen = t0.screen
			_click_pending_release = true

	if main.is_xr_active and main.is_streaming and main.controller_mapper:
		main.controller_mapper.check_toggle()

	if main.is_xr_active and main.is_streaming:
		var is_gripping = _is_now_gripping()
		var pad_blocking = main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD
		var tp_blocking = main.virtual_keyboard and main.virtual_keyboard.trackpad_active
		if not pad_blocking and not tp_blocking and is_gripping and not main.was_right_clicking and main.right_click_cooldown <= 0.0:
			var col = active_raycast.get_collider() if active_raycast.is_colliding() else null
			var t1 = PointerTarget.resolve(col) if col else {"role": &""}
			if t1.role == &"screen":
				var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
				var uv = t1.screen.hit_point_to_uv(hit_pos)
				var uv_x = uv.x
				var uv_y = uv.y
				if main.settings_controller.get_stereo_mode() >= 3:
					var shift = _compute_parallax_shift(uv_x)
					uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
				var host_pt = main.layout.uv_to_host_point(t1.screen.monitor, Vector2(uv_x, uv_y))
				var ref = main.layout.host_ref()
				main.stream_backend.send_mouse_position_event(host_pt.x, host_pt.y, ref.x, ref.y)
			main.stream_backend.send_mouse_button_event(7, 3)
			main.was_right_clicking = true
			main.right_click_cooldown = 0.5
		elif not is_gripping and main.was_right_clicking:
			main.stream_backend.send_mouse_button_event(8, 3)
			main.was_right_clicking = false

	for s in main.screens:
		s.grab_bar.visible = true
		for ch in s.corner_handles:
			ch.visible = false
			var ch_area = ch.get_node_or_null("Area3D")
			if ch_area:
				ch_area.monitoring = false
				ch_area.monitorable = false

	if main.grabbed_corner_idx >= 0 and main.grabbed_corner_screen:
		var gh = main.grabbed_corner_screen.corner_handles[main.grabbed_corner_idx]
		gh.visible = true
		var gh_area = gh.get_node_or_null("Area3D")
		if gh_area:
			gh_area.monitoring = true
			gh_area.monitorable = true

	if not main.grabbed_node and main.grabbed_corner_idx < 0:
		for s in main.screens:
			_set_grab_bar_color(s.grab_bar, Color.WHITE, 0.05)
		main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.08))
		if main.virtual_keyboard and main.virtual_keyboard.visible:
			main.set_comp_grab_bar_color(main.virtual_keyboard.viewport, Color(1, 1, 1, 0.08))
		for s in main.screens:
			for ch in s.corner_handles:
				_set_corner_color(ch, Color.WHITE, 0.05)
	elif main.grabbed_node and main.grabbed_bar:
		_set_grab_bar_color(main.grabbed_bar, Color.WHITE, 0.4)
	elif main.grabbed_node == main.ui_panel_3d:
		main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.8))
	elif main.grabbed_node == main.virtual_keyboard:
		main.set_comp_grab_bar_color(main.virtual_keyboard.viewport, Color(1, 1, 1, 0.8))
	elif main.grabbed_corner_idx >= 0 and main.grabbed_corner_screen:
		_set_corner_color(main.grabbed_corner_screen.corner_handles[main.grabbed_corner_idx], Color.WHITE, 0.4)

	var right_laser = main.get_node("%Laser")
	var left_laser = null
	if main.left_hand_raycast:
		left_laser = main.left_hand_raycast.get_node_or_null("Laser")
	if main.is_xr_active:
		var right_hit = main.hand_raycast and main.hand_raycast.is_colliding()
		var left_hit = main.left_hand_raycast and main.left_hand_raycast.is_colliding()
		var right_on_ui = _is_hand_on_ui("right")
		var left_on_ui = _is_hand_on_ui("left")
		if main._is_using_hands:
			var has_data = main.get_hand_tracking_has_data()
			if right_laser:
				right_laser.visible = has_data and _active_hand == "right" and right_hit
			if left_laser:
				left_laser.visible = has_data and _active_hand == "left" and left_hit
		else:
			if right_laser:
				right_laser.visible = (_active_hand == "right" and right_hit) or (_active_hand != "right" and right_on_ui)
			if left_laser:
				left_laser.visible = (_active_hand == "left" and left_hit) or (_active_hand != "left" and left_on_ui)
	else:
		if right_laser:
			right_laser.visible = false
		if left_laser:
			left_laser.visible = false
	var on_screen = false
	var tp_capturing = main.virtual_keyboard and main.virtual_keyboard.trackpad_active
	var pad_mode_active = main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD
	if tp_capturing:
		if main.contact_dot:
			main.contact_dot.visible = false
		if main.pointer_cursor:
			main.pointer_cursor.visible = false
		if main.comp_cursor:
			main.comp_cursor.visible = false
		right_laser.visible = false
		if left_laser:
			left_laser.visible = false
	if not tp_capturing and active_raycast.is_colliding():
		var raw_hit = active_raycast.get_collision_point()
		var _col = active_raycast.get_collider()
		var t_hover = PointerTarget.resolve(_col) if _col else {"role": &""}
		on_screen = (t_hover.role == &"screen")
		var hide_on_screen = on_screen and pad_mode_active
		var hit_point = main._get_steady_hit(raw_hit) if on_screen else raw_hit
		var col_normal = active_raycast.get_collision_normal()
		var dot_offset = col_normal * 0.025 if col_normal != Vector3() else (main.xr_camera.global_position - hit_point).normalized() * 0.025
		if main.cursor_mode == 0 or not on_screen or hide_on_screen:
			if main.contact_dot:
				main.contact_dot.global_position = hit_point + dot_offset
				main.contact_dot.visible = not hide_on_screen
			if main.pointer_cursor:
				main.pointer_cursor.visible = false
			if main.comp_cursor and hide_on_screen:
				main.comp_cursor.visible = false
		else:
			if main.pointer_cursor:
				main.pointer_cursor.global_position = hit_point
				var to_cam = (main.xr_camera.global_position - hit_point).normalized()
				main.pointer_cursor.look_at(main.pointer_cursor.global_position + to_cam, Vector3.UP)
				main.pointer_cursor.rotate_object_local(Vector3.UP, PI)
				var face = -main.pointer_cursor.global_transform.basis.z
				var right = main.pointer_cursor.global_transform.basis.x
				var up = main.pointer_cursor.global_transform.basis.y
				main.pointer_cursor.global_position = hit_point + face * 0.002 + right * 0.03 - up * 0.04
				main.pointer_cursor.visible = true
			if main.contact_dot:
				main.contact_dot.visible = false
	else:
		if main.contact_dot:
			main.contact_dot.visible = false
		if main.pointer_cursor:
			main.pointer_cursor.visible = false

	if active_raycast.is_colliding():
		var collider = active_raycast.get_collider()
		var parent = collider.get_parent()
		var t = PointerTarget.resolve(collider)
		pointer_on_ui = false
		if t.role == &"panel" and parent == main.ui_panel_3d:
			pointer_on_ui = true
		if t.role == &"grab_bar" and main.ui_visible:
			pointer_on_ui = true
		if main.virtual_keyboard and main.virtual_keyboard.visible and t.role == &"panel" and parent == main.virtual_keyboard.mesh_instance:
			pointer_on_ui = true

		if t.role == &"grab_bar" and parent != main.grabbed_bar:
			_set_grab_bar_color(parent, Color.WHITE, 0.15)

		is_now_clicking = _is_now_clicking()

		var hit_ui = false
		if main.ui_visible and main.ui_panel_3d and main.ui_panel_3d.visible:
			var area = main.ui_panel_3d.get_node_or_null("Area3D")
			if area and area.monitoring and t.role == &"panel" and parent == main.ui_panel_3d:
				hit_ui = true

		if (t.role == &"panel" and parent == main.ui_panel_3d) or hit_ui:
			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
			var local_pos = main.ui_panel_3d.to_local(hit_pos)
			var half_w = main._ui_mesh_size.x / 2.0
			var half_h = main._ui_mesh_size.y / 2.0
			var nx = clampf((local_pos.x / half_w + 1.0) / 2.0, 0.0, 1.0)
			var ny = clampf(1.0 - (local_pos.y / half_h + 1.0) / 2.0, 0.0, 1.0)
			var pixel_pos = Vector2(nx * main._ui_viewport_size.x, ny * main._ui_viewport_size.y)
			_primary_ui_pixel = pixel_pos

			var is_grab_bar = _is_ui_grab_bar(pixel_pos)
			if main.grabbed_node == main.ui_panel_3d:
				main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.8))
			elif is_grab_bar and main.grabbed_corner_idx < 0:
				main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.25))
				if is_now_clicking and not main.was_clicking:
					main.grabbed_node = main.ui_panel_3d
					main.grabbed_bar = null
					var grab_point = active_raycast.get_collision_point()
					main.grab_distance = (grab_point - active_raycast.global_position).length()
					main.grab_offset = main.grabbed_node.global_position - grab_point
					main.grab_start_hand_pos = active_raycast.global_position
					main.grab_start_node_pos = main.grabbed_node.global_position
					main.grab_forward = -active_raycast.global_transform.basis.z
					if main.is_xr_active:
						main.grab_start_hand_basis = active_raycast.global_transform.basis
						main.grab_start_node_basis = main.grabbed_node.global_transform.basis
						main.grab_start_node_euler = main.grabbed_node.rotation
					main.was_clicking = true
					return
			else:
				main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.08))

			if not is_grab_bar:
				var motion = InputEventMouseMotion.new()
				motion.position = pixel_pos
				motion.global_position = pixel_pos
				motion.button_mask = MOUSE_BUTTON_MASK_LEFT if is_now_clicking else 0
				main.ui_viewport.push_input(motion)

				if is_now_clicking and not main.was_clicking:
					_push_ui_click(pixel_pos, true)
					main.was_clicking = true
				elif not is_now_clicking and main.was_clicking:
					_push_ui_click(pixel_pos, false)
					main.was_clicking = false
			return

		if main.virtual_keyboard and main.virtual_keyboard.visible and t.role == &"panel" and parent == main.virtual_keyboard.mesh_instance:
			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
			var local_pos = main.virtual_keyboard.mesh_instance.to_local(hit_pos)
			var half_w = main.virtual_keyboard.mesh_size.x / 2.0
			var half_h = main.virtual_keyboard.mesh_size.y / 2.0
			var nx = (local_pos.x / half_w + 1.0) / 2.0
			var ny = 1.0 - (local_pos.y / half_h + 1.0) / 2.0
			var pixel_pos = Vector2(nx * main.virtual_keyboard.viewport_size.x, ny * main.virtual_keyboard.viewport_size.y)

			var is_kb_grab = _is_kb_grab_bar(pixel_pos)
			if main.grabbed_node == main.virtual_keyboard:
				main.set_comp_grab_bar_color(main.virtual_keyboard.viewport, Color(1, 1, 1, 0.8))
			elif is_kb_grab and main.grabbed_corner_idx < 0:
				main.set_comp_grab_bar_color(main.virtual_keyboard.viewport, Color(1, 1, 1, 0.25))
				if is_now_clicking and not main.was_clicking:
					main.grabbed_node = main.virtual_keyboard
					main.grabbed_bar = null
					main.grab_distance = (hit_pos - active_raycast.global_position).length()
					main.grab_offset = main.grabbed_node.global_position - hit_pos
					main.grab_start_hand_pos = active_raycast.global_position
					main.grab_start_node_pos = main.grabbed_node.global_position
					main.grab_forward = -active_raycast.global_transform.basis.z
					if main.is_xr_active:
						main.grab_start_hand_basis = active_raycast.global_transform.basis
						main.grab_start_node_basis = main.grabbed_node.global_transform.basis
						main.grab_start_node_euler = main.grabbed_node.rotation
					main.was_clicking = true
					return
			else:
				main.set_comp_grab_bar_color(main.virtual_keyboard.viewport, Color(1, 1, 1, 0.08))

			if not is_kb_grab:
				var active_hand_node = main.left_hand if _active_hand == "left" else main.right_hand
				main.virtual_keyboard.handle_pointer(pixel_pos, is_now_clicking, main.was_clicking, active_hand_node)
				if is_now_clicking:
					main.was_clicking = true
				else:
					main.was_clicking = false
			return

		elif t.role == &"screen" and not main.is_streaming:
			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
			var uv = t.screen.hit_point_to_uv(hit_pos)
			var wv = main.welcome_viewport
			var pixel_pos = Vector2(uv.x * wv.size.x, uv.y * wv.size.y)

			var motion = InputEventMouseMotion.new()
			motion.position = pixel_pos
			motion.global_position = pixel_pos
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT if is_now_clicking else 0
			wv.push_input(motion)

			if is_now_clicking and not main.was_clicking:
				var ev = InputEventMouseButton.new()
				ev.position = pixel_pos
				ev.global_position = pixel_pos
				ev.button_index = MOUSE_BUTTON_LEFT
				ev.pressed = true
				wv.push_input(ev)
				main.was_clicking = true
			elif not is_now_clicking and main.was_clicking:
				var ev = InputEventMouseButton.new()
				ev.position = pixel_pos
				ev.global_position = pixel_pos
				ev.button_index = MOUSE_BUTTON_LEFT
				ev.pressed = false
				wv.push_input(ev)
				main.was_clicking = false
			return

		elif t.role == &"screen" and main.is_streaming:
			if main.virtual_keyboard and main.virtual_keyboard.trackpad_active:
				return
			if main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD:
				return
			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
			var uv = t.screen.hit_point_to_uv(hit_pos)
			var uv_x = uv.x
			var uv_y = uv.y
			if main.settings_controller.get_stereo_mode() >= 3:
				var shift = _compute_parallax_shift(uv_x)
				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
			var host_pt = main.layout.uv_to_host_point(t.screen.monitor, Vector2(uv_x, uv_y))
			var ref = main.layout.host_ref()

			if main.is_xr_active:
				if is_now_clicking:
					var hold_time = Time.get_ticks_msec() - _pinch_start_time
					var dist = Vector2(host_pt).distance_to(_pinch_start_pos)
					if hold_time > 150 or dist > 15:
						main.stream_backend.send_mouse_position_event(host_pt.x, host_pt.y, ref.x, ref.y)
						if not main.was_clicking:
							main.stream_backend.send_mouse_button_event(7, 1)
							main.was_clicking = true
				elif main.was_clicking:
					main.stream_backend.send_mouse_button_event(8, 1)
					main.was_clicking = false
					_click_pending_release = false
				elif _click_pending_release:
					if _pinch_start_screen == t.screen:
						main.stream_backend.send_mouse_position_event(int(_pinch_start_pos.x), int(_pinch_start_pos.y), ref.x, ref.y)
						main.stream_backend.send_mouse_button_event(7, 1)
						main.stream_backend.send_mouse_button_event(8, 1)
					_click_pending_release = false
			else:
				if is_now_clicking and not main.was_clicking:
					main.stream_backend.send_mouse_position_event(host_pt.x, host_pt.y, ref.x, ref.y)
					main.suppress_input_frames = 3
					main.input_handler.capture_stream_mouse()
					main.was_clicking = true
			return

		if t.role == &"corner":
			var corner_idx = t.corner_idx
			parent.visible = true
			var p_area = parent.get_node_or_null("Area3D")
			if p_area:
				p_area.monitoring = true
				p_area.monitorable = true
			if is_now_clicking and main.grabbed_corner_idx < 0 and not main.grabbed_node:
				main.grabbed_corner_idx = corner_idx
				main.grabbed_corner_screen = t.screen
				var opposite_idx = 3 - corner_idx
				var opposite = t.screen.corner_handles[opposite_idx]
				main.corner_anchor_world = opposite.global_position
				_set_corner_color(parent, Color.WHITE, 0.4)
				main.was_clicking = true
			elif main.grabbed_corner_idx < 0 and corner_idx != main.grabbed_corner_idx:
				_set_corner_color(parent, Color.WHITE, 0.15)
			return

		elif t.role == &"grab_bar":
			if is_now_clicking and not main.grabbed_node and main.grabbed_corner_idx < 0:
				main.grabbed_node = parent.get_parent()
				main.grabbed_bar = parent
				var grab_point = active_raycast.get_collision_point()
				main.grab_distance = (grab_point - active_raycast.global_position).length()
				main.grab_offset = main.grabbed_node.global_position - grab_point
				main.grab_start_hand_pos = active_raycast.global_position
				main.grab_start_node_pos = main.grabbed_node.global_position
				main.grab_forward = -active_raycast.global_transform.basis.z
				if main.is_xr_active:
					main.grab_start_hand_basis = active_raycast.global_transform.basis
					main.grab_start_node_basis = main.grabbed_node.global_transform.basis
					main.grab_start_node_euler = main.grabbed_node.rotation
				main.grab_group_start_transforms.clear()
				if main.grabbed_node == main.primary_screen:
					main.grab_start_primary_transform = main.primary_screen.global_transform
					for other in main.screens:
						if other != main.primary_screen:
							main.grab_group_start_transforms[other] = other.global_transform
				_set_grab_bar_color(parent, Color.WHITE, 0.3)
				main.was_clicking = true
			return

	elif main.was_clicking:
		# The raycast hit nothing at all this frame - could be the physical trigger/
		# pinch actually releasing, or just the ray passing through the gap between
		# two adjacent screens (or off the edge into empty space) mid-drag. Only treat
		# it as a real release when the physical input itself let go; otherwise keep
		# the click held server-side and simply skip sending a position update this
		# frame. Once the ray lands on a screen again (this one or another), the
		# t.role == &"screen" branch above resumes sending positions from wherever it
		# is now - which is exactly "drag onto another screen" for free, since it maps
		# through whichever screen is currently hit, not just the one the drag started on.
		var mid_screen_drag = _pinch_start_screen != null and main.grabbed_node == null and main.grabbed_corner_idx < 0
		if is_now_clicking and mid_screen_drag and main.is_streaming:
			pass
		else:
			if main.is_streaming:
				main.stream_backend.send_mouse_button_event(8, 1)
			main.was_clicking = false
			_click_pending_release = false
			_pinch_start_screen = null

func _update_on_screen_tracking():
	_right_on_screen = _is_hand_on_screen("right")
	_left_on_screen = _is_hand_on_screen("left")

func process_pointer_frame(delta: float):
	_update_active_hand()
	_update_on_screen_tracking()
	_process_auto_primary(delta)
	if not main.mouse_captured_by_stream:
		handle_pointer_interaction()
	_process_other_hand_ui()
	_apply_ui_hover_states()

func _is_hand_on_screen(hand: String) -> bool:
	var rc = main.hand_raycast if hand == "right" else main.left_hand_raycast
	if not rc or not rc.is_colliding():
		return false
	var t = PointerTarget.resolve(rc.get_collider())
	if t.role == &"screen":
		return true
	return t.role == &"panel"

func _is_hand_on_ui(hnd: String) -> bool:
	var rc = main.hand_raycast if hnd == "right" else main.left_hand_raycast
	if not rc or not rc.is_colliding():
		return false
	return PointerTarget.resolve(rc.get_collider()).role == &"panel"

func _process_other_hand_ui():
	if not main.is_xr_active or main._is_using_hands:
		_hide_other_hand_ui()
		return
	var other = "left" if _active_hand == "right" else "right"
	var rc = _get_hand_raycast(other)
	if not rc or not rc.is_colliding():
		_hide_other_hand_ui()
		return
	var col = rc.get_collider()
	if not col:
		_hide_other_hand_ui()
		return
	var parent = col.get_parent()
	var t_other = PointerTarget.resolve(col)
	if t_other.role != &"panel":
		_hide_other_hand_ui()
		return
	var panel = parent
	var wv = main.ui_viewport if panel == main.ui_panel_3d else (main.virtual_keyboard.viewport if main.virtual_keyboard else null)
	if not wv:
		return
	var hit_pos = rc.get_collision_point()
	var local_pos = panel.to_local(hit_pos)
	var half_w = main._ui_mesh_size.x / 2.0 if panel == main.ui_panel_3d else (main.virtual_keyboard.mesh_size.x / 2.0 if main.virtual_keyboard else 1.0)
	var half_h = main._ui_mesh_size.y / 2.0 if panel == main.ui_panel_3d else (main.virtual_keyboard.mesh_size.y / 2.0 if main.virtual_keyboard else 1.0)
	var nx = clampf((local_pos.x / half_w + 1.0) / 2.0, 0.0, 1.0)
	var ny = clampf(1.0 - (local_pos.y / half_h + 1.0) / 2.0, 0.0, 1.0)
	var vp_size = main._ui_viewport_size if panel == main.ui_panel_3d else (main.virtual_keyboard.viewport_size if main.virtual_keyboard else Vector2i(800, 400))
	var pixel_pos = Vector2(nx * vp_size.x, ny * vp_size.y)

	if panel == main.ui_panel_3d:
		_secondary_ui_pixel = pixel_pos
		if main.grabbed_node != main.ui_panel_3d:
			var primary_on_grab = _primary_ui_pixel.x >= 0 and _is_ui_grab_bar(_primary_ui_pixel)
			if not primary_on_grab:
				var is_sec_grab_bar = _is_ui_grab_bar(pixel_pos)
				main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.25) if (is_sec_grab_bar and main.grabbed_corner_idx < 0) else Color(1, 1, 1, 0.08))
	else:
		_secondary_ui_pixel = Vector2(-1, -1)
	var col_normal = rc.get_collision_normal()
	var dot_offset = col_normal * 0.025 if col_normal != Vector3() else (main.xr_camera.global_position - hit_pos).normalized() * 0.025
	if main.left_contact_dot:
		main.left_contact_dot.visible = false
	if main.comp.in_use and main.left_comp_cursor_layer:
		var to_cam = (main.xr_camera.global_position - hit_pos).normalized()
		main.left_comp_cursor_layer.global_position = hit_pos + to_cam * 0.002
		main.left_comp_cursor_layer.look_at(main.left_comp_cursor_layer.global_position + to_cam, Vector3.UP)
		main.left_comp_cursor_layer.rotate_object_local(Vector3.UP, PI)
		main.left_comp_cursor_layer.visible = true
		if main.left_comp_cursor:
			main.left_comp_cursor.visible = false
	elif main.left_comp_cursor:
		var to_cam = (main.xr_camera.global_position - hit_pos).normalized()
		main.left_comp_cursor.global_position = hit_pos + to_cam * 0.002
		main.left_comp_cursor.look_at(main.left_comp_cursor.global_position + to_cam, Vector3.UP)
		main.left_comp_cursor.rotate_object_local(Vector3.UP, PI)
		main.left_comp_cursor.visible = true
	if panel != main.ui_panel_3d and main.virtual_keyboard:
		main.virtual_keyboard.handle_secondary_pointer(pixel_pos)
	var hand = main.left_hand if other == "left" else main.right_hand
	if panel == main.ui_panel_3d and hand:
		var motion = InputEventMouseMotion.new()
		motion.position = pixel_pos
		motion.global_position = pixel_pos
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT if (hand and hand.get_float("trigger") > 0.5) else 0
		wv.push_input(motion)
	if hand and hand.get_float("trigger") > 0.5:
		if not _other_hand_clicking:
			_other_hand_clicking = true
			_secondary_press_viewport = wv
			_secondary_press_was_keyboard = (main.virtual_keyboard and parent == main.virtual_keyboard.mesh_instance)
			var btn = InputEventMouseButton.new()
			btn.position = pixel_pos
			btn.global_position = pixel_pos
			btn.button_index = MOUSE_BUTTON_LEFT
			btn.pressed = true
			wv.push_input(btn)
			if _secondary_press_was_keyboard:
				main.virtual_keyboard.handle_secondary_key(pixel_pos, true)
	elif _other_hand_clicking:
		_end_secondary_press(pixel_pos)

func _end_secondary_press(pixel_pos := Vector2.ZERO):
	if not _other_hand_clicking:
		return
	_other_hand_clicking = false
	var btn = InputEventMouseButton.new()
	btn.position = pixel_pos
	btn.global_position = pixel_pos
	btn.button_index = MOUSE_BUTTON_LEFT
	btn.pressed = false
	if is_instance_valid(_secondary_press_viewport):
		_secondary_press_viewport.push_input(btn)
	if _secondary_press_was_keyboard and main.virtual_keyboard:
		main.virtual_keyboard.handle_secondary_key(pixel_pos, false)
	_secondary_press_viewport = null
	_secondary_press_was_keyboard = false

func _hide_other_hand_ui():
	_secondary_ui_pixel = Vector2(-1, -1)
	if _other_hand_clicking:
		_end_secondary_press()
	if main.virtual_keyboard:
		main.virtual_keyboard.handle_secondary_pointer(Vector2(-1, -1))
	if main.left_contact_dot:
		main.left_contact_dot.visible = false
	if main.left_comp_cursor:
		main.left_comp_cursor.visible = false
	if main.left_comp_cursor_layer:
		main.left_comp_cursor_layer.visible = false

func _apply_ui_hover_states():
	if not main.ui_visible:
		return
	for entry in _ui_button_states:
		var btn: Button = entry["btn"]
		if not btn.is_visible_in_tree():
			continue
		var hovered = _point_in_ui_rect(_primary_ui_pixel, btn) or _point_in_ui_rect(_secondary_ui_pixel, btn)
		var use_style = entry["hover"] if hovered else entry["norm"]
		if _last_ui_style.get(btn) != use_style:
			_last_ui_style[btn] = use_style
			btn.add_theme_stylebox_override("normal", use_style)

func _point_in_ui_rect(p: Vector2, btn: Button) -> bool:
	if p.x < 0 or p.y < 0:
		return false
	var gp = btn.global_position
	return p.x >= gp.x and p.x <= gp.x + btn.size.x \
		and p.y >= gp.y and p.y <= gp.y + btn.size.y

func handle_grab():
	if not main.grabbed_node:
		return
	var active_raycast = get_active_raycast()
	var hand_pos = active_raycast.global_position
	var hand_delta = hand_pos - main.grab_start_hand_pos
	var depth = hand_delta.dot(main.grab_forward) * main.grab_forward
	var lateral = hand_delta - depth
	main.grabbed_node.global_position = main.grab_start_node_pos + lateral * 6.0 + depth * 12.0
	var cam_pos = main.xr_camera.global_position
	main.grabbed_node.rotation.y = atan2(cam_pos.x - main.grabbed_node.global_position.x, cam_pos.z - main.grabbed_node.global_position.z)

	if main.grabbed_node is VRScreen:
		main.comp.update_cylinder_params()

	if main.is_xr_active and main.grab_start_hand_basis != Basis():
		var hand_fwd = -active_raycast.global_transform.basis.z
		var hand_pitch = atan2(-hand_fwd.y, Vector2(hand_fwd.x, hand_fwd.z).length())
		var start_fwd = -main.grab_start_hand_basis.z
		var start_pitch = atan2(-start_fwd.y, Vector2(start_fwd.x, start_fwd.z).length())
		var pitch_delta = start_pitch - hand_pitch
		var euler = main.grabbed_node.rotation
		euler.x = main.grab_start_node_euler.x + pitch_delta * 0.66
		euler.z = 0.0
		if absf(euler.x) < 0.052:
			euler.x = 0.0
		main.grabbed_node.rotation = euler

	if main.grabbed_node == main.primary_screen and not main.grab_group_start_transforms.is_empty():
		var group_delta = main.grabbed_node.global_transform * main.grab_start_primary_transform.affine_inverse()
		for other in main.grab_group_start_transforms:
			other.global_transform = group_delta * main.grab_group_start_transforms[other]

	if main.grabbed_node is VRScreen:
		main.comp.update_cylinder_params()
		main._debug_log_cyl("grab")

	var still_clicking = _is_now_clicking()
	if not still_clicking:
		if main.grabbed_bar:
			_set_grab_bar_color(main.grabbed_bar, Color.WHITE, 0.01)
			main.grabbed_bar = null
		if main.grabbed_node == main.ui_panel_3d:
			main.set_comp_grab_bar_color(main.ui_viewport, Color(1, 1, 1, 0.08))
		if main.grabbed_node == main.virtual_keyboard:
			main.set_comp_grab_bar_color(main.virtual_keyboard.viewport, Color(1, 1, 1, 0.08))
		main.grabbed_node = null
		main.grab_start_hand_basis = Basis()
		main.grab_start_node_basis = Basis()
		main.grab_start_node_euler = Vector3.ZERO
		main.grab_group_start_transforms.clear()
		main.state_manager.save_state()

func handle_corner_resize():
	if main.grabbed_corner_idx < 0 or not main.grabbed_corner_screen:
		return
	var s = main.grabbed_corner_screen
	var active_raycast = get_active_raycast()
	var ray_origin = active_raycast.global_position
	var ray_dir = -active_raycast.global_transform.basis.z
	var tile_aspect = float(s.monitor.frame_rect.size.x) / float(s.monitor.frame_rect.size.y) if s.monitor and s.monitor.frame_rect.size.y > 0 else 16.0 / 9.0

	if not _corner_resize_started:
		s.begin_corner_resize()
		_corner_resize_started = true
	s.apply_corner_resize(ray_origin, ray_dir, main.grabbed_corner_idx, tile_aspect)

	main.comp.update_layer_size()

	var still_clicking = _is_now_clicking()
	if not still_clicking:
		var handle = s.corner_handles[main.grabbed_corner_idx]
		_set_corner_color(handle, Color.WHITE, 0.05)
		main.grabbed_corner_idx = -1
		main.grabbed_corner_screen = null
		_corner_resize_started = false
		s.end_corner_resize()
		main.state_manager.save_state()



func _push_ui_click(pos: Vector2, pressed: bool):
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	main.ui_viewport.push_input(event)

func _set_grab_bar_color(bar: MeshInstance3D, color: Color, alpha: float = 1.0):
	bar.material_override.albedo_color = Color(color.r, color.g, color.b, alpha)

func _set_corner_color(handle: MeshInstance3D, color: Color, alpha: float = 1.0):
	var c = Color(color.r, color.g, color.b, alpha)
	if handle.material_override:
		handle.material_override.albedo_color = c
	for child in handle.get_children():
		if child is MeshInstance3D:
			child.material_override.albedo_color = c

func _compute_parallax_shift(uv_x: float) -> float:
	if not main.depth_estimator or not main.depth_estimator.depth_texture:
		return 0.0
	var mat = main.screen_mesh.material_override
	if not mat or not mat is ShaderMaterial:
		return 0.0
	var tex = main.depth_estimator.depth_texture
	var img = tex.get_image()
	if not img or img.is_empty():
		return 0.0
	var parallax = 0.042
	var half_parallax = parallax * 0.5
	var convergence = mat.get_shader_parameter("convergence")
	if convergence == null:
		convergence = 0.5
	var balance_shift = mat.get_shader_parameter("balance_shift")
	if balance_shift == null:
		balance_shift = 0.5
	var depth_x = int(clampf(uv_x - half_parallax, 0.0, 1.0) * (img.get_width() - 1))
	var depth_y = int(img.get_height() * 0.5)
	depth_x = clampi(depth_x, 0, img.get_width() - 1)
	depth_y = clampi(depth_y, 0, img.get_height() - 1)
	var depth = img.get_pixel(depth_x, depth_y).r
	var depth_diff = clampf(depth - convergence, -convergence, 1.0 - convergence)
	var dist_from_convergence = absf(depth - convergence)
	var zone_radius = 0.70
	var fade_multiplier = smoothstep(0.0, zone_radius, dist_from_convergence)
	depth_diff *= fade_multiplier
	var shift = parallax * depth_diff
	if (depth - convergence) < 0.0:
		shift *= (1.0 - balance_shift)
	else:
		shift *= balance_shift
	var h_dist = absf(uv_x - 0.5) * 2.0
	var vignette_start = 0.7
	var vignette = 1.0 - smoothstep(vignette_start, 1.0, pow(h_dist, 1.5))
	shift *= vignette
	return shift

var _scroll_cooldown: float = 0.0

func handle_scroll():
	if not main.is_xr_active or not main.is_streaming:
		return
	if main.controller_mapper and main.controller_mapper.is_active():
		if main.controller_mapper.ctrl_type != ControllerMapper.CtrlType.KBMOUSE:
			return
	if main.virtual_keyboard and main.virtual_keyboard.trackpad_active:
		return
	var now = Time.get_ticks_msec() / 1000.0
	if _scroll_cooldown > now:
		return
	var right_stick_y = 0.0
	if main.right_hand:
		right_stick_y = main.right_hand.get_vector2("primary").y
	if absf(right_stick_y) < 0.1:
		for pad in Input.get_connected_joypads():
			var val = Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
			if absf(val) > 0.1:
				right_stick_y = val
				break
	if absf(right_stick_y) > 0.5:
		main.stream_backend.send_scroll_event(1 if right_stick_y > 0 else -1)
		_scroll_cooldown = now + 0.15

func _is_ui_grab_bar(pixel_pos: Vector2) -> bool:
	var bar = main.ui_viewport.find_child("CompGrabBar", true, false)
	if not bar or not bar is Control:
		return false
	var bar_rect = bar.get_global_rect()
	return pixel_pos.x >= bar_rect.position.x and pixel_pos.x <= bar_rect.end.x and pixel_pos.y >= bar_rect.position.y and pixel_pos.y <= bar_rect.end.y

func _is_kb_grab_bar(pixel_pos: Vector2) -> bool:
	if not main.virtual_keyboard or not main.virtual_keyboard.viewport:
		return false
	var bar = main.virtual_keyboard.viewport.find_child("CompGrabBar", true, false)
	if not bar or not bar is Control:
		return false
	var bar_rect = bar.get_global_rect()
	return pixel_pos.x >= bar_rect.position.x and pixel_pos.x <= bar_rect.end.x and pixel_pos.y >= bar_rect.position.y and pixel_pos.y <= bar_rect.end.y
