extends SceneTree

func _init():
	_test_shortcut_row()
	_test_shortcut_chords()
	print("All virtual_keyboard tests passed")
	quit()

func _test_shortcut_row() -> void:
	var keyboard := VirtualKeyboard.new(Node3D.new())
	var shortcut_row: Array = keyboard._KEY_ROWS[0]
	assert(shortcut_row.size() == 11)
	assert(shortcut_row[0]["k"] == VirtualKeyboard.SHORTCUT_COPY)
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
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_ALT_TAB] == [KEY_ALT, KEY_TAB])
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_CLOSE_WINDOW] == [KEY_ALT, KEY_F4])
	assert(VirtualKeyboard.SHORTCUT_CHORDS[VirtualKeyboard.SHORTCUT_SECURITY] == [KEY_CTRL, KEY_ALT, KEY_DELETE])
