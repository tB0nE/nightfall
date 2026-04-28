class_name XRInteraction
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func handle_pointer_interaction():
	var active_raycast = main.hand_raycast if main.is_xr_active else main.mouse_raycast

	if not main.grabbed_node:
		main.get_node("%ScreenGrabBar").visible = false
		main.get_node("%MenuGrabBar").visible = false
		if main.grabbed_bar:
			_set_grab_bar_color(main.grabbed_bar, Color.WHITE)
			main.grabbed_bar = null

	if active_raycast.is_colliding():
		var collider = active_raycast.get_collider()
		var parent = collider.get_parent()

		if parent == main.screen_mesh or parent == main.get_node("%ScreenGrabBar"):
			main.get_node("%ScreenGrabBar").visible = true
		if parent == main.ui_panel_3d or parent == main.get_node("%MenuGrabBar"):
			main.get_node("%MenuGrabBar").visible = true

		var is_now_clicking = main.right_hand.get_float("trigger") > 0.5 if main.is_xr_active else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

		if parent == main.ui_panel_3d:
			var hit_pos = active_raycast.get_collision_point()
			var local_pos = main.ui_panel_3d.to_local(hit_pos)
			var pixel_pos = Vector2((local_pos.x + 0.5) * 500, (0.5 - local_pos.y) * 500)
			main.hit_dot.position = pixel_pos - (main.hit_dot.size / 2.0)
			main.hit_dot.color = Color(1, 0, 0) if is_now_clicking else Color(0, 1, 0)

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

		elif parent == main.screen_mesh and main.is_streaming:
			var hit_pos = active_raycast.get_collision_point()
			var local_pos = main.screen_mesh.to_local(hit_pos)
			var mesh_size = main.screen_mesh.mesh.size
			var uv_x = clampf((local_pos.x + mesh_size.x * 0.5) / mesh_size.x, 0.0, 1.0)
			var uv_y = clampf((mesh_size.y * 0.5 - local_pos.y) / mesh_size.y, 0.0, 1.0)
			var host_x = int(uv_x * main.stream_viewport.size.x)
			var host_y = int(uv_y * main.stream_viewport.size.y)

			main.get_node("%StreamHitDot").position = Vector2(host_x - 10, host_y - 10)
			main.get_node("%StreamHitDot").size = Vector2(20, 20)
			main.get_node("%StreamHitDot").color = Color(0, 1, 0)

			if main.is_xr_active:
				main.moon.send_mouse_position_event(host_x, host_y, main.stream_viewport.size.x, main.stream_viewport.size.y)
				if is_now_clicking and not main.was_clicking:
					main.moon.send_mouse_button_event(7, MOUSE_BUTTON_LEFT)
					main.was_clicking = true
				elif not is_now_clicking and main.was_clicking:
					main.moon.send_mouse_button_event(8, MOUSE_BUTTON_LEFT)
					main.was_clicking = false
			else:
				if is_now_clicking and not main.was_clicking:
					main.moon.send_mouse_position_event(host_x, host_y, main.stream_viewport.size.x, main.stream_viewport.size.y)
					main.suppress_input_frames = 3
					main.input_handler.capture_stream_mouse()
					main.was_clicking = true
			return

		elif parent == main.get_node("%ScreenGrabBar") or parent == main.get_node("%MenuGrabBar"):
			if is_now_clicking and not main.grabbed_node:
				main.grabbed_node = parent.get_parent()
				main.grabbed_bar = parent
				var grab_point = active_raycast.get_collision_point()
				main.grab_distance = (grab_point - active_raycast.global_position).length()
				main.grab_offset = main.grabbed_node.global_position - grab_point
				_set_grab_bar_color(parent, Color(0.2, 0.5, 1.0))
				main.was_clicking = true
			elif not main.grabbed_node:
				_set_grab_bar_color(parent, Color(0, 1, 0))
			return

	elif main.was_clicking:
		main.was_clicking = false

	main.hit_dot.position = Vector2(-20, -20)
	main.get_node("%StreamHitDot").position = Vector2(-30, -30)

func handle_grab():
	if not main.grabbed_node:
		return
	var active_raycast = main.hand_raycast if main.is_xr_active else main.mouse_raycast
	var ray_tip = active_raycast.global_position + (-active_raycast.global_transform.basis.z * main.grab_distance)
	main.grabbed_node.global_position = ray_tip + main.grab_offset
	var cam_pos = main.xr_camera.global_position
	main.grabbed_node.rotation.y = atan2(cam_pos.x - main.grabbed_node.global_position.x, cam_pos.z - main.grabbed_node.global_position.z)

	var still_clicking = main.right_hand.get_float("trigger") > 0.5 if main.is_xr_active else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not still_clicking:
		if main.grabbed_bar:
			_set_grab_bar_color(main.grabbed_bar, Color.WHITE)
			main.grabbed_bar = null
		main.grabbed_node = null

func _push_ui_click(pos: Vector2, pressed: bool):
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	main.ui_viewport.push_input(event)

func _set_grab_bar_color(bar: MeshInstance3D, color: Color):
	bar.material_override.albedo_color = color
