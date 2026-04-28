class_name InputHandler
extends RefCounted

var main: Node3D

var _BTN_MAP = {
	JOY_BUTTON_A: 0x1000,
	JOY_BUTTON_B: 0x2000,
	JOY_BUTTON_X: 0x4000,
	JOY_BUTTON_Y: 0x8000,
	JOY_BUTTON_LEFT_SHOULDER: 0x0100,
	JOY_BUTTON_RIGHT_SHOULDER: 0x0200,
	JOY_BUTTON_BACK: 0x0400,
	JOY_BUTTON_START: 0x0800,
	JOY_BUTTON_LEFT_STICK: 0x0040,
	JOY_BUTTON_RIGHT_STICK: 0x0080,
	JOY_BUTTON_GUIDE: 0x0400,
}

var pad_buttons: int = 0
var pad_active: int = 0

func _init(owner: Node3D):
	main = owner

func handle_input(event: InputEvent):
	if main.mouse_captured_by_stream and main.is_streaming:
		if event is InputEventKey and event.pressed \
			and event.keycode == KEY_ESCAPE \
			and Input.is_key_pressed(KEY_CTRL) \
			and Input.is_key_pressed(KEY_ALT):
				release_stream_mouse()
				return
		if main.suppress_input_frames > 0:
			main.suppress_input_frames -= 1
			return
		if event is InputEventMouseMotion:
			main.moon.send_mouse_move_event(int(event.relative.x), int(event.relative.y))
		elif event is InputEventMouseButton:
			var action = 7 if event.pressed else 8
			main.moon.send_mouse_button_event(action, event.button_index)
		elif event is InputEventKey:
			main.moon.send_keyboard_event(event.keycode, 3 if event.pressed else 4, 0)
		elif event is InputEventJoypadButton:
			if event.pressed:
				pad_buttons |= (1 << event.button_index)
			else:
				pad_buttons &= ~(1 << event.button_index)
			pad_active |= (1 << event.device)
			print("[GAMEPAD] Button dev=%d btn=%d pressed=%s mask=%d" % [event.device, event.button_index, event.pressed, pad_buttons])
			_send_controller(event.device)
		elif event is InputEventJoypadMotion:
			pad_active |= (1 << event.device)
			_send_controller(event.device)
		return

	if not main.is_xr_active and event is InputEventMouseMotion:
		main.xr_origin.rotate_y(-event.relative.x * main.mouse_sensitivity)
		main.xr_camera.rotate_x(-event.relative.y * main.mouse_sensitivity)
		main.xr_camera.rotation.x = clamp(main.xr_camera.rotation.x, -PI/2, PI/2)

	if event is InputEventKey and main.ui_viewport.gui_get_focus_owner():
		main.ui_viewport.push_input(event)
		return

	if main.is_streaming:
		if event is InputEventJoypadButton:
			if event.pressed:
				pad_buttons |= (1 << event.button_index)
			else:
				pad_buttons &= ~(1 << event.button_index)
			pad_active |= (1 << event.device)
			print("[GAMEPAD] Button dev=%d btn=%d pressed=%s mask=%d" % [event.device, event.button_index, event.pressed, pad_buttons])
			_send_controller(event.device)
			return
		elif event is InputEventJoypadMotion:
			pad_active |= (1 << event.device)
			_send_controller(event.device)
			return

		if event is InputEventKey:
			main.moon.send_keyboard_event(event.keycode, 3 if event.pressed else 4, 0)

func capture_stream_mouse():
	main.mouse_captured_by_stream = true
	main.was_clicking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.get_node("%Crosshair").visible = false
	main.get_node("%StreamHitDot").position = Vector2(-30, -30)
	print("[MOUSE] Stream captured - move/click controls remote. Shift+F1 to release.")

func release_stream_mouse():
	main.mouse_captured_by_stream = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	main.ui_controller.update_ui()
	print("[MOUSE] Released - back to pointer mode.")

func _send_controller(device: int):
	var lx = Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
	var ly = Input.get_joy_axis(device, JOY_AXIS_LEFT_Y)
	var rx = Input.get_joy_axis(device, JOY_AXIS_RIGHT_X)
	var ry = Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y)
	var lt = Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)
	var rt = Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT)
	var mapped_buttons = 0
	for btn in _BTN_MAP:
		if Input.is_joy_button_pressed(device, btn):
			mapped_buttons |= _BTN_MAP[btn]
	var active_mask = 1 << device
	main.moon.send_multi_controller_event(device, active_mask, mapped_buttons, int(lt * 255.0), int(rt * 255.0), _float_to_short(lx), -_float_to_short(ly), _float_to_short(rx), -_float_to_short(ry))

func _float_to_short(val: float) -> int:
	return int(clampf(val, -1.0, 1.0) * 32767.0)
