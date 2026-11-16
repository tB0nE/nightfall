class_name InputHandler
extends RefCounted

var main: Node3D
var _last_desktop_input_msec: int = -10000
var _forwarded_keys: Dictionary = {}
var _diagnostic_pad_system: Dictionary = {}
var _clipboard_keys: Dictionary = {}
var _forwarded_mouse_buttons: Dictionary = {}

func hand_desktop_suspended() -> bool:
	return Time.get_ticks_msec() - _last_desktop_input_msec < 2000

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
# moonlight-common-c LI_CCAP_ACCEL / LI_CCAP_GYRO and LI_MOTION_TYPE_*.
const CAP_ACCEL := 0x10
const CAP_GYRO := 0x20
const MOTION_TYPE_ACCEL := 0x01
const MOTION_TYPE_GYRO := 0x02

const JOY_BUTTON_NAMES := ["a", "b", "x", "y", "back", "guide", "start", "leftstick",
	"rightstick", "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright",
	"misc1", "paddle1", "paddle2", "paddle3", "paddle4", "touchpad"]

var gamepads := GamepadSlots.new()
# Godot device ID -> ControllerLayout, Android only (see controller_layout.gd).
var _layouts: Dictionary = {}
# Godot device ID -> {input name: true}, so the log records each button/axis a
# pad produces once per session - enough to diagnose a mis-mapped pad from a
# saved log without flooding it.
var _seen_pad_inputs: Dictionary = {}

func _init(owner: Node3D):
	main = owner

func handle_input(event: InputEvent):
	if desktop_input_blocked(): return
	# Physical desktop input takes priority without disabling hand menu access.
	if (event is InputEventKey and event.pressed) or event is InputEventMouseMotion or event is InputEventMouseButton:
		_last_desktop_input_msec = Time.get_ticks_msec()
	if main.is_xr_active and main.settings.tracking_mode == 2:
		if event is InputEventKey:
			if event.keycode == KEY_VOLUMEUP or event.keycode == KEY_VOLUMEDOWN:
				main.get_viewport().set_input_as_handled()
				if main.mouse_captured_by_stream and main.is_streaming:
					var button_idx = MOUSE_BUTTON_LEFT if event.keycode == KEY_VOLUMEUP else MOUSE_BUTTON_RIGHT
					var action = 7 if event.pressed else 8
					send_stream_mouse_button(action, button_idx)
				return

	if event is InputEventKey:
		if _clipboard_keys.has(event.keycode):
			if not event.pressed: _clipboard_keys.erase(event.keycode)
			return
		if main.ui_visible and main.ui_viewport.gui_get_focus_owner():
			main.ui_viewport.push_input(event)
			return
		var browser = main.screen_sources.focused_browser()
		var operation: String = {KEY_C: "copy", KEY_X: "cut", KEY_V: "paste"}.get(event.keycode, "")
		if event.pressed and not event.echo and event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed and operation != "":
			if (browser != null and browser.active) or main.is_streaming:
				_clipboard_keys[event.keycode] = true
				main.clipboard_sharing.perform(operation, _physical_edit.bind(browser, event.keycode))
				return
		if browser != null and browser.active:
			browser.physical_key(event)
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
			send_stream_mouse_button(action, event.button_index)
		elif event is InputEventKey:
			send_stream_key(event.keycode, 3 if event.pressed else 4)
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
			send_stream_key(event.keycode, 3 if event.pressed else 4)

func send_stream_key(code: int, action: int) -> void:
	if action == 3 and desktop_input_blocked(): return
	if action == 3: _forwarded_keys[code] = true
	elif action == 4: _forwarded_keys.erase(code)
	main.stream_backend.send_keyboard_event(code, action, 0)

func send_stream_mouse_button(action: int, button: int) -> void:
	if action == 7 and desktop_input_blocked(): return
	if action == 7: _forwarded_mouse_buttons[button] = true
	elif action == 8: _forwarded_mouse_buttons.erase(button)
	main.stream_backend.send_mouse_button_event(action, button)

func release_host_inputs() -> void:
	if main.is_streaming and main.stream_backend:
		for code in _forwarded_keys: main.stream_backend.send_keyboard_event(code, 4, 0)
		for button in _forwarded_mouse_buttons: main.stream_backend.send_mouse_button_event(8, button)
		neutral_host_gamepads()
	_forwarded_keys.clear()
	_forwarded_mouse_buttons.clear()

func desktop_input_blocked() -> bool:
	var handover = main.get("pcvr_handover")
	return handover != null and handover.blocks_workspace()

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
	_forwarded_keys.clear()
	_forwarded_mouse_buttons.clear()

func neutral_host_gamepads() -> void:
	if not main.is_streaming or not main.stream_backend: return
	var mask := gamepads.active_mask()
	for slot in GamepadSlots.MAX_SLOTS:
		if mask & (1 << slot):
			main.stream_backend.send_multi_controller_event(slot, mask, 0, 0, 0, 0, 0, 0, 0)

# Sends one source's full state as its own host controller, announcing it
# first if it is new this session. key: a Godot device ID, or
# GamepadSlots.QUEST_PAD for the Quest-controller PAD mode.
func send_pad_state(key: int, ctype: int, buttons: int, lt: int, rt: int,
		lx: int, ly: int, rx: int, ry: int, capabilities: int = ARRIVAL_CAPABILITIES) -> void:
	if desktop_input_blocked(): return
	var focused_browser = main.screen_sources.focused_browser() if main.get("screen_sources") != null else main.browser_prototype
	if key == GamepadSlots.QUEST_PAD and DevBridge.wanted():
		var system_buttons := buttons & (0x10 | 0x20)
		if system_buttons != int(_diagnostic_pad_system.get(key, 0)):
			_diagnostic_pad_system[key] = system_buttons
			main._log("[PAD-SYSTEM] t=%d route=%s start=%s back=%s" % [Time.get_ticks_msec(),
				"browser" if focused_browser != null and focused_browser.active else "host",
				(system_buttons & 0x10) != 0, (system_buttons & 0x20) != 0])
	if focused_browser != null and focused_browser.active:
		# Physical pads use original Android events directly. Only XR's virtual
		# pad needs the browser-specific state bridge; never announce it to a PC.
		if key == GamepadSlots.QUEST_PAD:
			focused_browser.gamepad_state(buttons, lt, rt, lx, ly, rx, ry)
		return
	var is_new := not gamepads.has(key)
	var slot := gamepads.acquire(key)
	if slot < 0:
		return
	if is_new:
		main.stream_backend.send_controller_arrival(slot, gamepads.active_mask(), ctype,
			ARRIVAL_BUTTON_FLAGS, capabilities)
		main._log("[PAD] %s -> host controller %d (type %d)" % [
			"Quest controllers" if key == GamepadSlots.QUEST_PAD else "pad %d" % key, slot, ctype])
	main.stream_backend.send_multi_controller_event(slot, gamepads.active_mask(), buttons,
		clampi(lt, 0, 255), clampi(rt, 0, 255), lx, ly, rx, ry)

## Gyro (deg/s) and accelerometer (m/s^2, gravity included) for a pad that
## was announced with LI_CCAP_GYRO/LI_CCAP_ACCEL (SDL's axes: +X right,
## +Y up, +Z towards the player).
func send_pad_motion(key: int, gyro: Vector3, accel: Vector3) -> void:
	if desktop_input_blocked() or not gamepads.has(key): return
	var slot := gamepads.acquire(key)
	if slot < 0: return
	main.stream_backend.send_controller_motion(slot, MOTION_TYPE_GYRO, gyro.x, gyro.y, gyro.z)
	main.stream_backend.send_controller_motion(slot, MOTION_TYPE_ACCEL, accel.x, accel.y, accel.z)

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
	main._log("[PAD] Android input devices: %s" % str(pads))
	var pad_name := Input.get_joy_name(device)
	var guid := Input.get_joy_guid(device)
	for info in pads:
		if info is Dictionary and ControllerLayout.matches_android_device(info, pad_name, guid):
			var layout := ControllerLayout.from_android_info(info)
			_layouts[device] = layout
			# Reconnecting can select Godot's built-in mapping again. Update
			# every connection, including when the device gets a new slot.
			Input.add_joy_mapping(layout.to_godot_mapping(guid), true)
			main._log("[PAD] Applied Android mapping: device=%d guid=%s" % [device, guid])
			return
	main._log("[PAD] Android layout unmatched: name=%s guid=%s candidates=%s" % [pad_name, guid, str(pads)])

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

func _physical_edit(browser: RefCounted, code: int) -> void:
	if browser != null and browser.active:
		browser._edit_raw({KEY_C: "copy", KEY_X: "cut", KEY_V: "paste"}[code])
	elif main.is_streaming:
		var held := _forwarded_keys.has(KEY_CTRL)
		if not held: send_stream_key(KEY_CTRL, 3)
		send_stream_key(code, 3)
		send_stream_key(code, 4)
		if not held: send_stream_key(KEY_CTRL, 4)
