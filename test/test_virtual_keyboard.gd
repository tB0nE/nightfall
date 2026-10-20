extends SceneTree

class Stream extends RefCounted:
	var keys: Array = []
	var buttons: Array = []
	func send_keyboard_event(code: int, action: int, _modifiers: int) -> void: keys.append([code, action])
	func send_mouse_button_event(action: int, button: int) -> void: buttons.append([action, button])

class Owner extends Node3D:
	var is_streaming := true
	var browser_prototype = null
	var screen_sources = null
	var stream_backend := Stream.new()
	var input_handler: InputHandler
	var pcvr_handover = null
	func _init() -> void: input_handler = InputHandler.new(self)

class Handover extends RefCounted:
	func blocks_workspace() -> bool: return true

func _init():
	_test_shortcut_row()
	_test_shortcut_chords()
	_test_focus_loss()
	print("All virtual_keyboard tests passed")
	quit()

func _test_focus_loss() -> void:
	var owner := Owner.new()
	var keyboard := VirtualKeyboard.new(owner)
	keyboard._on_key_press(KEY_SHIFT)
	keyboard._on_key_press(KEY_A)
	owner.input_handler.send_stream_key(KEY_B, 3)
	owner.input_handler.send_stream_mouse_button(7, 1)
	owner.pcvr_handover = Handover.new()
	var count := owner.stream_backend.keys.size()
	owner.input_handler.send_stream_key(KEY_C, 3)
	assert(owner.stream_backend.keys.size() == count)
	owner.input_handler.send_stream_mouse_button(7, 2)
	assert(owner.stream_backend.buttons == [[7, 1]])
	owner.input_handler.release_host_inputs()
	keyboard.release_for_focus_loss()
	assert([KEY_A, 4] in owner.stream_backend.keys)
	assert([KEY_B, 4] in owner.stream_backend.keys)
	assert([KEY_SHIFT, 4] in owner.stream_backend.keys)
	assert([8, 1] in owner.stream_backend.buttons)
	assert(owner.input_handler._forwarded_keys.is_empty())
	assert(owner.input_handler._forwarded_mouse_buttons.is_empty())
	assert(keyboard._held_keys.is_empty() and not keyboard._shift_on)
	owner.free()
	keyboard.free()

func _test_shortcut_row() -> void:
	var keyboard := VirtualKeyboard.new(Node3D.new())
	var shortcut_row: Array = keyboard._KEY_ROWS[0]
	assert(shortcut_row.size() == 11)
	assert(shortcut_row[0]["k"] == VirtualKeyboard.SHORTCUT_COPY)
	assert(shortcut_row[4]["k"] == VirtualKeyboard.SHORTCUT_INSERT)
	assert(shortcut_row[4]["l"] == "Ins")
	assert(shortcut_row[-1]["k"] == VirtualKeyboard.SHORTCUT_SECURITY)
	var shortcut_units := 0.0
	for key_data in shortcut_row:
		shortcut_units += float(key_data.get("w", 1.0))
	# The build-time scale widens this shorter row to the same 15-unit span as
	# every conventional keyboard row, aligning both outer edges.
	assert(shortcut_units < VirtualKeyboard.KEY_ROW_UNITS)
	assert(VirtualKeyboard.KEY_ROW_UNITS / shortcut_units > 1.08)
	# The existing function-key row remains directly below the shortcuts.
	assert(keyboard._KEY_ROWS[1][1]["k"] == KEY_F1)
	assert(keyboard._KEY_ROWS[1][12]["k"] == KEY_F12)
	keyboard.main.free()
	keyboard.free()

func _test_shortcut_chords() -> void:
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_COPY] == [KEY_CTRL, KEY_C])
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_INSERT] == [KEY_INSERT])
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_ALT_TAB] == [KEY_ALT, KEY_TAB])
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_CLOSE_WINDOW] == [KEY_ALT, KEY_F4])
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_SECURITY] == [KEY_CTRL, KEY_ALT, KEY_DELETE])
