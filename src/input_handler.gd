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
	JOY_BUTTON_BACK: 0x0020,
	JOY_BUTTON_START: 0x0010,
	JOY_BUTTON_LEFT_STICK: 0x0040,
	JOY_BUTTON_RIGHT_STICK: 0x0080,
	JOY_BUTTON_GUIDE: 0x0400,
	JOY_BUTTON_DPAD_UP: 0x0001,
	JOY_BUTTON_DPAD_DOWN: 0x0002,
	JOY_BUTTON_DPAD_LEFT: 0x0004,
	JOY_BUTTON_DPAD_RIGHT: 0x0008,
}

# Every button the host's virtual pad should expose, and analog triggers +
# rumble (moonlight-common-c LI_CCAP_*).
const ARRIVAL_BUTTON_FLAGS := 0x1000 | 0x2000 | 0x4000 | 0x8000 | 0x0001 | 0x0002 | 0x0004 \
	| 0x0008 | 0x0100 | 0x0200 | 0x0010 | 0x0020 | 0x0040 | 0x0080 | 0x0400
const ARRIVAL_CAPABILITIES := 0x01 | 0x02

const JOY_BUTTON_NAMES := ["a", "b", "x", "y", "back", "guide", "start", "leftstick",
	"rightstick", "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright",
	"misc1", "paddle1", "paddle2", "paddle3", "paddle4", "touchpad"]

var gamepads := GamepadSlots.new()
# Godot device ID -> ControllerLayout, Android only (see controller_layout.gd).
var _layouts: Dictionary = {}
var _mapped_guids: Dictionary = {}
# Godot device ID -> {input name: true}, so the log records each button/axis a
# pad produces once per session - enough to diagnose a mis-mapped pad from a
# saved log without flooding it.
var _seen_pad_inputs: Dictionary = {}

func _init(owner: Node3D):
	main = owner

func handle_input(event: InputEvent):
	if main.is_xr_active and main.settings.tracking_mode == 2:
		if event is InputEventKey:
			if event.keycode == KEY_VOLUMEUP or event.keycode == KEY_VOLUMEDOWN:
				main.get_viewport().set_input_as_handled()
				if main.mouse_captured_by_stream and main.is_streaming:
					var button_idx = MOUSE_BUTTON_LEFT if event.keycode == KEY_VOLUMEUP else MOUSE_BUTTON_RIGHT
					var action = 7 if event.pressed else 8
					main.stream_backend.send_mouse_button_event(action, button_idx)
				return

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
			main.stream_backend.send_mouse_move_event(int(event.relative.x), int(event.relative.y))
		elif event is InputEventMouseButton:
			var action = 7 if event.pressed else 8
			main.stream_backend.send_mouse_button_event(action, event.button_index)
		elif event is InputEventKey:
			main.stream_backend.send_keyboard_event(event.keycode, 3 if event.pressed else 4, 0)
		elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
			_handle_pad_event(event)
		return

	if not main.is_xr_active and event is InputEventMouseMotion:
		main.xr_origin.rotate_y(-event.relative.x * main.mouse_sensitivity)
		main.xr_camera.rotate_x(-event.relative.y * main.mouse_sensitivity)
		main.xr_camera.rotation.x = clamp(main.xr_camera.rotation.x, -PI/2, PI/2)

	if event is InputEventKey and main.ui_viewport.gui_get_focus_owner():
		main.ui_viewport.push_input(event)
		return

	if main.is_streaming:
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			_handle_pad_event(event)
			return

		if event is InputEventKey:
			main.stream_backend.send_keyboard_event(event.keycode, 3 if event.pressed else 4, 0)

func capture_stream_mouse():
	main.mouse_captured_by_stream = true
	main.was_clicking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.get_node("%Crosshair").visible = false

func release_stream_mouse():
	main.mouse_captured_by_stream = false
	if OS.get_name() == "Android":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	main.ui_controller.update_ui()

# --- Gamepads ---------------------------------------------------------------

# A new stream session has no host-side pads yet; each source announces itself
# again on its first input.
func reset_gamepads() -> void:
	gamepads.clear()

# Sends one source's full state as its own host controller, announcing it
# first if it is new this session. key: a Godot device ID, or
# GamepadSlots.QUEST_PAD for the Quest-controller PAD mode.
func send_pad_state(key: int, ctype: int, buttons: int, lt: int, rt: int,
		lx: int, ly: int, rx: int, ry: int) -> void:
	var is_new := not gamepads.has(key)
	var slot := gamepads.acquire(key)
	if slot < 0:
		return
	if is_new:
		main.stream_backend.send_controller_arrival(slot, gamepads.active_mask(), ctype,
			ARRIVAL_BUTTON_FLAGS, ARRIVAL_CAPABILITIES)
		main._log("[PAD] %s -> host controller %d (type %d)" % [
			"Quest controllers" if key == GamepadSlots.QUEST_PAD else "pad %d" % key, slot, ctype])
	main.stream_backend.send_multi_controller_event(slot, gamepads.active_mask(), buttons,
		clampi(lt, 0, 255), clampi(rt, 0, 255), lx, ly, rx, ry)

# Releases everything a source holds without announcing it to the host if it
# never sent anything this session.
func neutral_pad_state(key: int) -> void:
	if gamepads.has(key):
		send_pad_state(key, ControllerLayout.CTYPE_XBOX, 0, 0, 0, 0, 0, 0, 0)

func on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		_layouts.erase(device)
		_apply_android_layout(device)
		main._log("[PAD] Connected %d: %s guid=%s info=%s" % [
			device, Input.get_joy_name(device), Input.get_joy_guid(device), str(Input.get_joy_info(device))])
		if _layouts.has(device):
			main._log("[PAD] Layout %d: %s" % [device, _layouts[device].describe()])
		return
	_layouts.erase(device)
	_seen_pad_inputs.erase(device)
	main._log("[PAD] Disconnected %d" % device)
	var slot := gamepads.release(device)
	if slot >= 0 and main.is_streaming:
		# A packet whose active mask lacks its own controller's bit removes
		# that pad on the host.
		main.stream_backend.send_multi_controller_event(slot, gamepads.active_mask(), 0, 0, 0, 0, 0, 0, 0)

func scan_connected_pads() -> void:
	for device in Input.get_connected_joypads():
		on_joy_connection_changed(device, true)

# Replaces Godot's positional default mapping with one built from the pad's
# real Android axes (see controller_layout.gd).
func _apply_android_layout(device: int) -> void:
	if OS.get_name() != "Android":
		return
	var wrapper: Object = Engine.get_singleton("JavaClassWrapper")
	var info_class: Object = wrapper.wrap("com.godot.game.GamepadInfo") if wrapper else null
	if not info_class:
		return
	var pads = JSON.parse_string(str(info_class.describe()))
	if not pads is Array:
		return
	var pad_name := Input.get_joy_name(device)
	for info in pads:
		if info is Dictionary and str(info.get("name", "")) == pad_name:
			var layout := ControllerLayout.from_android_info(info)
			_layouts[device] = layout
			var guid := Input.get_joy_guid(device)
			if not _mapped_guids.has(guid):
				_mapped_guids[guid] = true
				Input.add_joy_mapping(layout.to_godot_mapping(guid), true)
			return

func _pad_type(device: int) -> int:
	var layout: ControllerLayout = _layouts.get(device)
	var vendor: int = layout.vendor if layout else int(Input.get_joy_info(device).get("vendor_id", 0))
	return ControllerLayout.controller_type(vendor, Input.get_joy_name(device))

func _handle_pad_event(event: InputEvent) -> void:
	_note_pad_input(event)
	_send_controller(event.device)

func _note_pad_input(event: InputEvent) -> void:
	var input_name := ""
	if event is InputEventJoypadButton and event.pressed:
		var idx: int = event.button_index
		input_name = "button %d (%s)" % [idx, JOY_BUTTON_NAMES[idx] if idx < JOY_BUTTON_NAMES.size() else "?"]
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.5:
		input_name = "axis %d %s" % [event.axis, "+" if event.axis_value > 0.0 else "-"]
	if input_name.is_empty():
		return
	var seen: Dictionary = _seen_pad_inputs.get_or_add(event.device, {})
	if not seen.has(input_name):
		seen[input_name] = true
		main._log("[PAD] %d first %s" % [event.device, input_name])

func _send_controller(device: int):
	var layout: ControllerLayout = _layouts.get(device)
	var lx = Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
	var ly = Input.get_joy_axis(device, JOY_AXIS_LEFT_Y)
	var rx = Input.get_joy_axis(device, JOY_AXIS_RIGHT_X)
	var ry = Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y)
	var lt = ControllerLayout.trigger_value(Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT),
		layout.left_trigger_centered if layout else false)
	var rt = ControllerLayout.trigger_value(Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT),
		layout.right_trigger_centered if layout else false)
	var mapped_buttons = 0
	for btn in _BTN_MAP:
		if Input.is_joy_button_pressed(device, btn):
			mapped_buttons |= _BTN_MAP[btn]
	send_pad_state(device, _pad_type(device), mapped_buttons, int(lt * 255.0), int(rt * 255.0),
		_float_to_short(lx), -_float_to_short(ly), _float_to_short(rx), -_float_to_short(ry))

func _float_to_short(val: float) -> int:
	return int(clampf(val, -1.0, 1.0) * 32767.0)
