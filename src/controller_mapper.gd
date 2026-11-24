class_name ControllerMapper
extends Node

enum CtrlType { GAMEPAD, PAD_ABXY, KBMOUSE }
enum BtnToggle { HEAD, TILT, NONE }
enum PrimaryHand { RIGHT, LEFT, AUTO }

var btn_toggle: int = BtnToggle.TILT
var btn_toggle_labels: Array = ["Head", "Tilt", "None"]

var primary_hand: int = PrimaryHand.RIGHT
var hand_policy = preload("res://src/controller_hand_policy.gd").new()
var primary_labels: Array = ["Right", "Left", "Auto"]

var main: Node3D
var active: bool = false
var ctrl_type: int = CtrlType.GAMEPAD
# PAD-HAND (GAMEPAD): face buttons split by hand - left hand's two buttons
# are the d-pad (swapped by alt), right hand's two are A/B (swapped to X/Y
# by alt). PAD-ABXY: face buttons always map to their real Xbox letter
# (left=X/Y, right=A/B); alt turns that HAND's two buttons into d-pad
# directions instead (b=left, a=right, y=up, x=down - see
# _send_gamepad_mode()'s abxy_layout branch). Both share is_gamepad_mode()/
# _send_gamepad_mode() below - only the four-face-button mapping differs.
var type_labels: Array = ["PAD-HAND", "PAD-ABXY", "KBM"]

var _active_key_dirs: Dictionary = {}
var _prev_button_flags: int = 0
var _prev_lt: int = 0
var _prev_rt: int = 0
var _prev_lx: int = 0
var _prev_ly: int = 0
var _prev_rx: int = 0
var _prev_ry: int = 0
var _was_both_sticks: bool = false
var _close_to_head: bool = false
var _close_dist: float = 0.25
var _poll_timer: float = 0.0
const MODE_ENABLED_HINT_SECONDS := -1.0 # Until a fresh button press.
var _guide_waiting := false
var _guide_armed := false
var _guide_consuming := false
var _last_delta: float = 0.0
# Motion (gyro/accelerometer) for the Steam Frame layout.
var _motion_prev_velocity := Vector3.ZERO
var _motion_accel := Vector3.ZERO
var _motion_logged := false

# Steam Frame controllers are a split gamepad (left: stick, D-pad, View,
# bumper, trigger; right: stick, A/B/X/Y, Menu, bumper, trigger), so they map
# 1:1 onto a pad instead of the Quest PAD-HAND/PAD-ABXY layouts.
const FRAME_PROFILE := "frame_controller"
const PAD_A := 0x1000
const PAD_B := 0x2000
const PAD_X := 0x4000
const PAD_Y := 0x8000
const PAD_UP := 0x0001
const PAD_DOWN := 0x0002
const PAD_LEFT := 0x0004
const PAD_RIGHT := 0x0008
const PAD_START := 0x0010
const PAD_BACK := 0x0020
const PAD_LS := 0x0040
const PAD_RS := 0x0080
const PAD_LB := 0x0100
const PAD_RB := 0x0200
const GRAVITY := 9.80665

var _KBM_DEFAULT = {
	"left_up": KEY_W,
	"left_down": KEY_S,
	"left_left": KEY_A,
	"left_right": KEY_D,
	"right_a": KEY_SPACE,
	"right_b": KEY_R,
	"left_x": KEY_E,
	"left_y": KEY_F,
	"left_trigger": KEY_SHIFT,
	"left_grip": KEY_CTRL,
	"left_menu": KEY_ESCAPE,
	"right_menu": KEY_TAB,
}

var _kbm_profile: Dictionary = {}
var _kb_held: Dictionary = {}

# DEV-only input/focus evidence. Signal callbacks can observe a system-button
# edge even when Horizon takes focus before the next gamepad polling frame.
func _ready() -> void:
	if not DevBridge.wanted(): return
	for side in ["left", "right"]:
		var hand = main.get(side + "_hand")
		if hand == null: continue
		hand.button_pressed.connect(_diagnostic_button.bind(side, true))
		hand.button_released.connect(_diagnostic_button.bind(side, false))
	var xr = XRServer.find_interface("OpenXR")
	if xr != null:
		for signal_name in ["session_focussed", "session_visible", "session_synchronized", "session_stopping"]:
			xr.connect(signal_name, _diagnostic_focus.bind(signal_name))
	_log("[PAD-SYSTEM] diagnostics enabled; right system/menu -> Start, left menu -> Back")

func _diagnostic_button(action: String, side: String, pressed: bool) -> void:
	if action not in ["menu_button", "select_button", "primary_click", "ax_button"]: return
	_log("[PAD-SYSTEM] t=%d action side=%s name=%s pressed=%s mapping_active=%s type=%d" % [
		Time.get_ticks_msec(), side, action, pressed, active, ctrl_type])

func _diagnostic_focus(event: String) -> void:
	var right = main.get("right_hand")
	_log("[PAD-SYSTEM] t=%d XR=%s active=%s right_menu=%s right_select=%s previous_start=%s" % [
		Time.get_ticks_msec(), event, active,
		right != null and right.is_button_pressed("menu_button"),
		right != null and right.is_button_pressed("select_button"),
		(_prev_button_flags & PAD_START) != 0])

func _init(owner: Node3D):
	main = owner
	_kbm_profile = _KBM_DEFAULT.duplicate()

func write_settings(config: ConfigFile) -> void:
	config.set_value("controller", "active", active)
	config.set_value("controller", "ctrl_type", ctrl_type)
	config.set_value("controller", "btn_toggle", btn_toggle)
	config.set_value("controller", "primary_hand", primary_hand)

func read_settings(config: ConfigFile) -> void:
	if config.has_section_key("controller", "active"):
		active = config.get_value("controller", "active", false)
		ctrl_type = clampi(config.get_value("controller", "ctrl_type", CtrlType.GAMEPAD), 0, 2)
	else:
		# Preserve the legacy mapping exactly: 0=off, 1=PAD-ABXY, 2=PAD-HAND.
		var old_mode := clampi(config.get_value("controller", "mode", 0), 0, 2)
		active = old_mode != 0
		if active:
			ctrl_type = CtrlType.PAD_ABXY if old_mode == 1 else CtrlType.GAMEPAD
	btn_toggle = clampi(config.get_value("controller", "btn_toggle", BtnToggle.TILT), 0, 2)
	primary_hand = clampi(config.get_value("controller", "primary_hand", PrimaryHand.RIGHT), 0, 2)

func _process(_delta):
	if active and _process_gamepad_guide(): return
	var handover = main.get("pcvr_handover")
	if handover != null and handover.blocks_workspace():
		release_for_focus_loss()
		return
	var focused_browser = main.screen_sources.focused_browser() if main.get("screen_sources") != null else main.browser_prototype
	var browser_pad: bool = focused_browser != null and focused_browser.active and is_gamepad_mode()
	if main.browser_prototype and (not active or not browser_pad or main.ui_visible or main.virtual_keyboard.visible):
		var browser = main.browser_prototype
		if main.get("screen_sources") != null: browser = main.screen_sources.focused_browser()
		browser.clear_gamepad()
	if (not main.is_streaming and not browser_pad) or not main.is_xr_active or not active \
			or (browser_pad and (main.ui_visible or main.virtual_keyboard.visible)):
		if _kb_held.size() > 0:
			for kc in _kb_held.keys():
				main.stream_backend.send_keyboard_event(kc, 4, 0)
			_kb_held.clear()
		return

	_poll_timer += _delta
	_last_delta = _delta

	if is_gamepad_mode():
		_send_gamepad_mode(ctrl_type == CtrlType.PAD_ABXY)
	elif ctrl_type == CtrlType.KBMOUSE:
		_send_kbm_mode()

# True for either PAD-HAND or PAD-ABXY - both drive InputHandler.send_pad_state
# via the shared _send_gamepad_mode() below and need the same UI/interaction
# gating (laser pointer disabled, "PAD" status indicator, etc.) elsewhere in
# the codebase - see xr_interaction.gd/main.gd/stream_manager.gd's callers.
func is_gamepad_mode() -> bool:
	return ctrl_type == CtrlType.GAMEPAD or ctrl_type == CtrlType.PAD_ABXY

func check_toggle():
	if not main.is_xr_active:
		return
	var l_click = false
	var r_click = false
	if frame_controllers():
		# Frame controllers: both grips (unmapped in the Frame layout), so both
		# stick clicks stay free for L3+R3 in games.
		l_click = main.left_hand != null and main.left_hand.get_float("grip") > 0.8
		r_click = main.right_hand != null and main.right_hand.get_float("grip") > 0.8
	else:
		if main.left_hand:
			l_click = main.left_hand.is_button_pressed("primary_click")
		if main.right_hand:
			r_click = main.right_hand.is_button_pressed("primary_click")
	var both = l_click and r_click
	if both and not _was_both_sticks:
		main.screen_shortcuts.invoke(ScreenShortcutBar.ACTION_PAD)
	_was_both_sticks = both

func check_toggle_ui():
	if active:
		_deactivate()
	else:
		_activate()
	main.state_manager.save_state()
	if main.ui_controller:
		main.ui_controller.update_ctrl_mode_btn()

func _guide_buttons_down() -> bool:
	for hand in [main.left_hand, main.right_hand]:
		if hand == null: continue
		for action in ["ax_button", "by_button", "menu_button", "select_button", "primary_click", "secondary_click"]:
			if hand.is_button_pressed(action): return true
		if hand.get_float("trigger") > 0.5 or hand.get_float("grip") > 0.8: return true
	return false

func _process_gamepad_guide() -> bool:
	return _advance_gamepad_guide(_guide_buttons_down()) if _guide_waiting or _guide_consuming else false

func _advance_gamepad_guide(down: bool) -> bool:
	if _guide_consuming:
		_guide_consuming = down
		return true
	if not _guide_waiting: return false
	if not down: _guide_armed = true
	elif _guide_armed:
		_guide_waiting = false
		_guide_consuming = true
		main.composition_toast.hide()
	return true

func _activate():
	active = true
	if is_gamepad_mode():
		_prev_button_flags = -1
		_prev_lt = -1
		_prev_rt = -1
		_prev_lx = -1
		_prev_ly = -1
		_prev_rx = -1
		_prev_ry = -1
		_poll_timer = 1.0
	_log("[CTRL] Activated: " + type_labels[ctrl_type])
	if is_gamepad_mode() and main.is_xr_active:
		_guide_waiting = true
		_guide_armed = false
		_guide_consuming = false
		main.composition_toast.show(gamepad_help_text(), main.xr_camera, MODE_ENABLED_HINT_SECONDS)
	if main.ui_controller:
		main.ui_controller.update_ctrl_mode_btn()
		main.ui_controller.update_ctrl_type_btn()

func release_for_focus_loss() -> void:
	for code in _kb_held: main.stream_backend.send_keyboard_event(code, 4, 0)
	_kb_held.clear()
	_active_key_dirs.clear()
	_prev_button_flags = -1 # Force current pad state to be sent after focus returns.

func _deactivate():
	_guide_waiting = false
	_guide_consuming = false
	for kc in _kb_held.keys():
		main.stream_backend.send_keyboard_event(kc, 4, 0)
	_kb_held.clear()
	_active_key_dirs.clear()
	_prev_button_flags = 0
	_prev_lt = 0
	_prev_rt = 0
	_prev_lx = 0
	_prev_ly = 0
	_prev_rx = 0
	_prev_ry = 0
	if main.is_streaming:
		main.input_handler.neutral_pad_state(GamepadSlots.QUEST_PAD)
	active = false
	_log("[CTRL] Deactivated")
	if main.is_xr_active:
		main.composition_toast.show("Controller mode off.", main.xr_camera, 2.0)
	if main.ui_controller:
		main.ui_controller.update_ctrl_mode_btn()

func cycle_type():
	set_type((ctrl_type + 1) % 3)

func set_type(value: int):
	if value < 0 or value >= type_labels.size() or value == ctrl_type: return
	ctrl_type = value
	if active:
		_deactivate_silent()
		if is_gamepad_mode():
			_prev_button_flags = -1
			_prev_lt = -1
			_prev_rt = -1
			_prev_lx = -1
			_prev_ly = -1
			_prev_rx = -1
			_prev_ry = -1
			_poll_timer = 1.0
	main.state_manager.save_state()
	if main.ui_controller:
		main.ui_controller.update_ctrl_mode_btn()
		main.ui_controller.update_ctrl_type_btn()
	_log("[CTRL] Type: " + type_labels[ctrl_type])

func _deactivate_silent():
	for kc in _kb_held.keys():
		main.stream_backend.send_keyboard_event(kc, 4, 0)
	_kb_held.clear()
	_active_key_dirs.clear()
	_prev_button_flags = 0
	_prev_lt = 0
	_prev_rt = 0
	_prev_lx = 0
	_prev_ly = 0
	_prev_rx = 0
	_prev_ry = 0
	if main.is_streaming:
		main.input_handler.neutral_pad_state(GamepadSlots.QUEST_PAD)

func _log(msg: String):
	if main and main.has_method("_log"):
		main._log(msg)

# abxy_layout=false: PAD-HAND (left hand = d-pad/swaps to X/Y under alt,
# right hand = A/B/swaps to d-pad under alt - the original single "PAD" mode).
# abxy_layout=true: PAD-ABXY (each hand's two buttons always map to their
# real Xbox letter; that hand's own alt state turns THAT hand's pair into
# d-pad directions instead - b=left, a=right, y=up, x=down, per-hand
# independent exactly like PAD-HAND's alt, just a different base mapping).
# Bit values below are moonlight-common-c's standard XInput-style button
# flags (0x0001/2/4/8 = d-pad up/down/left/right, 0x1000/2000/4000/8000 =
# A/B/X/Y).
## True when SteamVR reports Steam Frame controllers (XR_VALVE_frame_controller_interaction).
func frame_controllers() -> bool:
	for name in [&"right_hand", &"left_hand"]:
		var tracker = XRServer.get_tracker(name)
		if tracker and String(tracker.profile).contains(FRAME_PROFILE):
			return true
	return false

## How to switch controller mode off with the controllers in hand.
func toggle_hint() -> String:
	return "Squeeze both grips" if frame_controllers() else "Click both thumbsticks"

func _pressed(hand: XRController3D, action: String) -> bool:
	return hand != null and hand.is_button_pressed(action)

func _frame_button_flags() -> int:
	var l: XRController3D = main.left_hand
	var r: XRController3D = main.right_hand
	var flags := 0
	if _pressed(r, "ax_button"): flags |= PAD_A
	if _pressed(r, "by_button"): flags |= PAD_B
	if _pressed(r, "x_button"): flags |= PAD_X
	if _pressed(r, "y_button"): flags |= PAD_Y
	if _pressed(l, "dpad_up"): flags |= PAD_UP
	if _pressed(l, "dpad_down"): flags |= PAD_DOWN
	if _pressed(l, "dpad_left"): flags |= PAD_LEFT
	if _pressed(l, "dpad_right"): flags |= PAD_RIGHT
	if _pressed(l, "bumper"): flags |= PAD_LB
	if _pressed(r, "bumper"): flags |= PAD_RB
	if _pressed(l, "select_button"): flags |= PAD_BACK
	if _pressed(r, "menu_button"): flags |= PAD_START
	if _pressed(l, "primary_click"): flags |= PAD_LS
	if _pressed(r, "primary_click"): flags |= PAD_RS
	return flags

## Gyro and accelerometer from the primary controller's tracking, in the
## controller's own frame. The aim pose has +X right, +Y up, +Z back: SDL's
## gamepad axes, sent as they are. Games fuse gyro and accelerometer, so
## if the gyro's pitch sign ever disagrees with the accelerometer the aim is
## both upside down and slowly pulled back after each movement (seen in the
## TOTK recompilation). On 2026-11-15 that needed the pitch negated; by
## 2026-11-17 the same setup needed it sent unchanged, cause not found.
## gyro_invert_pitch negates only the gyro's X (never the accelerometer) and
## can be switched live (dev bridge) to compare.
var gyro_invert_pitch := false

func _send_frame_motion() -> void:
	var hand: XRController3D = main.left_hand if effective_primary_hand() == PrimaryHand.LEFT else main.right_hand
	if hand == null or _last_delta <= 0.0:
		return
	var pose: XRPose = hand.get_pose()
	if pose == null or not pose.has_tracking_data:
		return
	var to_local: Basis = pose.transform.basis.orthonormalized().transposed()
	var gyro: Vector3 = to_local * pose.angular_velocity
	gyro = Vector3(rad_to_deg(gyro.x) * (-1.0 if gyro_invert_pitch else 1.0), rad_to_deg(gyro.y), rad_to_deg(gyro.z))
	# Linear acceleration from the velocity's change, smoothed (tracking
	# velocities are noisy), plus the reaction to gravity an accelerometer reads.
	var linear: Vector3 = (pose.linear_velocity - _motion_prev_velocity) / _last_delta
	_motion_prev_velocity = pose.linear_velocity
	_motion_accel = _motion_accel.lerp(linear, 0.3)
	var accel: Vector3 = to_local * (_motion_accel + Vector3(0.0, GRAVITY, 0.0))
	main.input_handler.send_pad_motion(GamepadSlots.QUEST_PAD, gyro, accel)
	if not _motion_logged:
		_motion_logged = true
		_log("[MOTION] Sending controller gyro/accelerometer (first: gyro=%s deg/s accel=%s m/s^2)" % [str(gyro), str(accel)])

static func quest_menu_flags(alternate: bool, pressed: bool) -> int:
	return (PAD_START if alternate else PAD_BACK) if pressed else 0

func gamepad_help_text() -> String:
	if frame_controllers():
		return "\n".join([
			"Controller mode on - Steam Frame",
			"A/B/X/Y, D-pad and bumpers use their normal mapping.",
			"Left View: Select (Back)  |  Right Menu: Start",
			"Stick clicks: L3/R3  |  Triggers: LT/RT",
			"Grips are reserved for toggling controller mode.",
			"Squeeze both grips to turn controller mode off.",
			"Press any button to continue."])
	var gesture := "Alternate mapping is disabled in Control settings."
	if btn_toggle == BtnToggle.TILT:
		gesture = "Tilt each controller outward for alternate keys."
	elif btn_toggle == BtnToggle.HEAD:
		gesture = "Move each controller near your head for alternate keys."
	var left := "Left X/Y: Left/Right  |  alternate: Down/Up"
	var right := "Right A/B: A/B  |  alternate: X/Y"
	if ctrl_type == CtrlType.PAD_ABXY:
		left = "Left X/Y: X/Y  |  alternate: Down/Up"
		right = "Right A/B: A/B  |  alternate: Right/Left"
	if btn_toggle == BtnToggle.NONE:
		left = "Left X/Y: X/Y" if ctrl_type == CtrlType.PAD_ABXY else "Left X/Y: Left/Right"
		right = "Right A/B: A/B"
	var menu := "Left Menu: Select (Back)  |  alternate: Start" if btn_toggle != BtnToggle.NONE else "Left Menu: Select (Back)"
	return "\n".join(["Controller mode on - " + type_labels[ctrl_type], gesture, left, right, menu,
		"Click both thumbsticks to turn controller mode off.", "Press any button to continue."])

func _send_gamepad_mode(abxy_layout: bool):
	var head_pos = main.xr_camera.global_position
	var left_pos = main.left_hand.global_position if main.left_hand else Vector3.ZERO
	var right_pos = main.right_hand.global_position if main.right_hand else Vector3.ZERO

	var left_alt = false
	var right_alt = false
	if btn_toggle == BtnToggle.HEAD:
		_close_to_head = left_pos.distance_to(head_pos) < _close_dist or right_pos.distance_to(head_pos) < _close_dist
		left_alt = left_pos.distance_to(head_pos) < _close_dist
		right_alt = right_pos.distance_to(head_pos) < _close_dist
	elif btn_toggle == BtnToggle.TILT:
		if main.left_hand:
			var left_roll = atan2(-main.left_hand.global_basis.x.y, main.left_hand.global_basis.x.x)
			left_alt = left_roll > 0.5
		if main.right_hand:
			var right_roll = atan2(-main.right_hand.global_basis.x.y, main.right_hand.global_basis.x.x)
			right_alt = right_roll < -0.5
		_close_to_head = left_alt or right_alt

	var button_flags: int = 0

	var lv = main.left_hand.get_vector2("primary") if main.left_hand else Vector2.ZERO
	var rv = main.right_hand.get_vector2("primary") if main.right_hand else Vector2.ZERO

	var lt_val = main.left_hand.get_float("trigger") if main.left_hand else 0.0
	var rt_val = main.right_hand.get_float("trigger") if main.right_hand else 0.0
	var lg_val = main.left_hand.get_float("grip") if main.left_hand else 0.0
	var rg_val = main.right_hand.get_float("grip") if main.right_hand else 0.0

	var left_a = main.left_hand.is_button_pressed("ax_button") if main.left_hand else false
	var left_b = main.left_hand.is_button_pressed("by_button") if main.left_hand else false
	var right_a = main.right_hand.is_button_pressed("ax_button") if main.right_hand else false
	var right_b = main.right_hand.is_button_pressed("by_button") if main.right_hand else false
	var left_menu = main.left_hand.is_button_pressed("menu_button") if main.left_hand else false
	var right_menu = main.right_hand.is_button_pressed("menu_button") if main.right_hand else false
	var l_click = main.left_hand.is_button_pressed("primary_click") if main.left_hand else false
	var r_click = main.right_hand.is_button_pressed("primary_click") if main.right_hand else false

	var frame := frame_controllers()
	if frame:
		button_flags = _frame_button_flags()
	elif abxy_layout:
		# left_a/left_b are physically X/Y; right_a/right_b are physically A/B
		# (see the ax_button/by_button reads above - same "_a"/"_b" naming as
		# PAD-HAND, just interpreted differently here).
		if left_alt:
			if left_a: button_flags |= 0x0002 # X -> DOWN
			if left_b: button_flags |= 0x0001 # Y -> UP
		else:
			if left_a: button_flags |= 0x4000 # X -> X
			if left_b: button_flags |= 0x8000 # Y -> Y

		if right_alt:
			if right_a: button_flags |= 0x0008 # A -> RIGHT
			if right_b: button_flags |= 0x0004 # B -> LEFT
		else:
			if right_a: button_flags |= 0x1000 # A -> A
			if right_b: button_flags |= 0x2000 # B -> B
	else:
		if left_alt:
			if left_a: button_flags |= 0x0002
			if left_b: button_flags |= 0x0001
		else:
			if left_a: button_flags |= 0x0004
			if left_b: button_flags |= 0x0008

		if right_alt:
			if right_a: button_flags |= 0x4000
			if right_b: button_flags |= 0x8000
		else:
			if right_a: button_flags |= 0x1000
			if right_b: button_flags |= 0x2000

	if not frame:
		if lg_val > 0.5: button_flags |= 0x0100
		if rg_val > 0.5: button_flags |= 0x0200
		if left_menu: button_flags |= quest_menu_flags(left_alt, true)
		if right_menu: button_flags |= 0x0010
		if l_click: button_flags |= 0x0040
		if r_click: button_flags |= 0x0080

	var lt = int(clampf(lt_val, 0.0, 1.0) * 255.0)
	var rt = int(clampf(rt_val, 0.0, 1.0) * 255.0)
	if main.xr_interaction and main.xr_interaction.pointer_on_ui:
		rt = 0
	var lx = int(clampf(lv.x, -1.0, 1.0) * 32767.0)
	var ly = int(clampf(lv.y, -1.0, 1.0) * 32767.0)
	var rx = int(clampf(rv.x, -1.0, 1.0) * 32767.0)
	var ry = int(clampf(rv.y, -1.0, 1.0) * 32767.0)

	var changed = button_flags != _prev_button_flags or lt != _prev_lt or rt != _prev_rt \
		or lx != _prev_lx or ly != _prev_ly or rx != _prev_rx or ry != _prev_ry
	if changed or _poll_timer >= 0.1:
		if frame:
			# A PlayStation-type pad with motion: Sunshine emulates a DualSense,
			# whose gyro games such as the TOTK recomp read through SDL.
			main.input_handler.send_pad_state(GamepadSlots.QUEST_PAD, ControllerLayout.CTYPE_PS, button_flags, lt, rt, lx, ly, rx, ry,
				main.input_handler.ARRIVAL_CAPABILITIES | main.input_handler.CAP_ACCEL | main.input_handler.CAP_GYRO)
		else:
			main.input_handler.send_pad_state(GamepadSlots.QUEST_PAD, ControllerLayout.CTYPE_XBOX, button_flags, lt, rt, lx, ly, rx, ry)
		_prev_button_flags = button_flags
		_prev_lt = lt
		_prev_rt = rt
		_prev_lx = lx
		_prev_ly = ly
		_prev_rx = rx
		_prev_ry = ry
		_poll_timer = 0.0
	if frame:
		_send_frame_motion()

func _send_kbm_mode():
	var lv = main.left_hand.get_vector2("primary") if main.left_hand else Vector2.ZERO
	var stick_threshold = 0.5
	var profile = _kbm_profile

	_handle_thumbstick_key(lv.y < -stick_threshold, "left_up", profile.get("left_up", KEY_W))
	_handle_thumbstick_key(lv.y > stick_threshold, "left_down", profile.get("left_down", KEY_S))
	_handle_thumbstick_key(lv.x < -stick_threshold, "left_left", profile.get("left_left", KEY_A))
	_handle_thumbstick_key(lv.x > stick_threshold, "left_right", profile.get("left_right", KEY_D))

	var trigger_threshold = 0.5
	var lt = main.left_hand.get_float("trigger") if main.left_hand else 0.0
	_handle_analog_key(lt > trigger_threshold, "left_trigger", profile.get("left_trigger", KEY_SHIFT))

	var grip_threshold = 0.5
	var lg = main.left_hand.get_float("grip") if main.left_hand else 0.0
	_handle_analog_key(lg > grip_threshold, "left_grip", profile.get("left_grip", KEY_CTRL))

	_handle_button_key(main.right_hand.is_button_pressed("ax_button") if main.right_hand else false, "right_a", profile.get("right_a", KEY_SPACE))
	_handle_button_key(main.right_hand.is_button_pressed("by_button") if main.right_hand else false, "right_b", profile.get("right_b", KEY_R))
	_handle_button_key(main.left_hand.is_button_pressed("ax_button") if main.left_hand else false, "left_x", profile.get("left_x", KEY_E))
	_handle_button_key(main.left_hand.is_button_pressed("by_button") if main.left_hand else false, "left_y", profile.get("left_y", KEY_F))
	_handle_button_key(main.left_hand.is_button_pressed("menu_button") if main.left_hand else false, "left_menu", profile.get("left_menu", KEY_ESCAPE))
	_handle_button_key(main.right_hand.is_button_pressed("menu_button") if main.right_hand else false, "right_menu", profile.get("right_menu", KEY_TAB))

func _handle_thumbstick_key(active: bool, dir_id: String, keycode: int):
	if active and not _active_key_dirs.get(dir_id, false):
		main.stream_backend.send_keyboard_event(keycode, 3, 0)
		_active_key_dirs[dir_id] = true
		_kb_held[keycode] = true
	elif not active and _active_key_dirs.get(dir_id, false):
		main.stream_backend.send_keyboard_event(keycode, 4, 0)
		_active_key_dirs[dir_id] = false
		_kb_held.erase(keycode)

func _handle_analog_key(active: bool, id: String, keycode: int):
	if active and not _kb_held.has(keycode):
		main.stream_backend.send_keyboard_event(keycode, 3, 0)
		_kb_held[keycode] = true
	elif not active and _kb_held.has(keycode):
		main.stream_backend.send_keyboard_event(keycode, 4, 0)
		_kb_held.erase(keycode)

func _handle_button_key(pressed: bool, id: String, keycode: int):
	var held = _kb_held.has(keycode)
	if pressed and not held:
		main.stream_backend.send_keyboard_event(keycode, 3, 0)
		_kb_held[keycode] = true
	elif not pressed and held:
		main.stream_backend.send_keyboard_event(keycode, 4, 0)
		_kb_held.erase(keycode)

func is_active() -> bool:
	return active

func effective_primary_hand() -> int:
	return primary_hand if main._is_using_hands else hand_policy.effective(primary_hand)

func update_available_hands(delta: float) -> void:
	if not main.is_xr_active or main._is_using_hands: return
	var policy = preload("res://src/startup_hand_fallback.gd")
	var right := policy.physical_controller_available(XRServer.get_tracker(&"/user/hand/right"))
	var left := policy.physical_controller_available(XRServer.get_tracker(&"/user/hand/left"))
	var busy: bool = main.was_clicking or main.was_right_clicking or main.grabbed_node != null or main.grabbed_corner_idx >= 0
	if hand_policy.step(delta, right, left, busy):
		main._log("[CTRL] Tracked controller selection: " + (primary_labels[hand_policy.single_hand] if hand_policy.single_hand >= 0 else "saved preference"))
		if main.ui_controller: main.ui_controller.update_primary_btn()

func get_mode_label() -> String:
	if not active:
		return "Off"
	return type_labels[ctrl_type]

func get_close_to_head() -> bool:
	return _close_to_head

func cycle_btn_toggle():
	set_btn_toggle((btn_toggle + 1) % 3)

func set_btn_toggle(value: int):
	if value < 0 or value >= btn_toggle_labels.size() or value == btn_toggle: return
	btn_toggle = value
	main.state_manager.save_state()
	if main.ui_controller:
		main.ui_controller.update_btn_toggle_btn()
	_log("[CTRL] Button toggle: " + btn_toggle_labels[btn_toggle])

func cycle_primary_hand():
	set_primary_hand((primary_hand + 1) % 3)

func set_primary_hand(value: int):
	if value < 0 or value >= primary_labels.size() or value == primary_hand: return
	primary_hand = value
	main.state_manager.save_state()
	if main.ui_controller:
		main.ui_controller.update_primary_btn()
	_log("[CTRL] Primary hand: " + primary_labels[primary_hand])
