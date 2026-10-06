extends SceneTree

func _init():
	_test_xbox_trigger_axes()
	_test_gas_brake_sort_order()
	_test_generic_layout_triggers_on_z_rz()
	_test_sony_triggers_on_rx_ry()
	_test_mapping_string()
	_test_trigger_value()
	_test_controller_type()
	_test_slots()
	print("All controller_layout tests passed")
	quit()

static func _info(axis_ids: Array, centered: Array = [], vendor: int = 0) -> Dictionary:
	var axes := []
	for id in axis_ids:
		axes.append({"id": id, "min": -1.0 if centered.has(id) else 0.0, "max": 1.0})
	return {"name": "Test Pad", "vendor": vendor, "product": 1, "axes": axes, "hat": true}

# X, Y, Z, RZ, LTRIGGER, RTRIGGER, plus the BRAKE/GAS duplicates many Xbox pads
# also report: the default Android mapping happens to be right for this one.
func _test_xbox_trigger_axes():
	var l := ControllerLayout.from_android_info(_info([0, 1, 11, 14, 17, 18, 22, 23], [0, 1, 11, 14]))
	assert(l.left_x == 0 and l.left_y == 1)
	assert(l.right_x == 2 and l.right_y == 3)
	assert(l.left_trigger == 4 and l.right_trigger == 5)
	assert(not l.left_trigger_centered and not l.right_trigger_centered)

# Triggers only as GAS (22) and BRAKE (23): GAS sorts first, so the default
# mapping's "left trigger = axis 4" would read the RIGHT trigger.
func _test_gas_brake_sort_order():
	var l := ControllerLayout.from_android_info(_info([0, 1, 11, 14, 22, 23], [0, 1, 11, 14]))
	assert(l.left_trigger == 5)  # BRAKE
	assert(l.right_trigger == 4)  # GAS

# Android's generic key layout for an X-input pad: triggers on Z/RZ (centred),
# right stick on RX/RY.
func _test_generic_layout_triggers_on_z_rz():
	var l := ControllerLayout.from_android_info(_info([0, 1, 11, 12, 13, 14], [0, 1, 11, 12, 13, 14]))
	assert(l.right_x == 3 and l.right_y == 4)  # RX, RY
	assert(l.left_trigger == 2 and l.right_trigger == 5)  # Z, RZ
	assert(l.left_trigger_centered and l.right_trigger_centered)

func _test_sony_triggers_on_rx_ry():
	var l := ControllerLayout.from_android_info(
		_info([0, 1, 11, 12, 13, 14], [0, 1, 11, 12, 13, 14], ControllerLayout.VENDOR_SONY))
	assert(l.right_x == 2 and l.right_y == 5)  # Z, RZ
	assert(l.left_trigger == 3 and l.right_trigger == 4)  # RX, RY

func _test_mapping_string():
	var l := ControllerLayout.from_android_info(_info([0, 1, 11, 14, 22, 23]))
	l.name = "Pad, With Comma"
	var mapping := l.to_godot_mapping("abcd")
	assert(mapping.begins_with("abcd,Pad  With Comma,"))
	assert(mapping.contains("lefttrigger:a5"))
	assert(mapping.contains("righttrigger:a4"))
	assert(mapping.contains("guide:b5"))
	assert(mapping.ends_with("platform:Android"))
	# A pad with no right stick leaves those outputs out entirely.
	var bare := ControllerLayout.from_android_info(_info([0, 1]))
	assert(not bare.to_godot_mapping("x").contains("rightx"))

func _test_trigger_value():
	assert(ControllerLayout.trigger_value(-1.0, true) == 0.0)
	assert(ControllerLayout.trigger_value(1.0, true) == 1.0)
	assert(is_equal_approx(ControllerLayout.trigger_value(0.0, true), 0.5))
	assert(is_equal_approx(ControllerLayout.trigger_value(0.25, false), 0.25))
	assert(ControllerLayout.trigger_value(-0.2, false) == 0.0)

func _test_controller_type():
	assert(ControllerLayout.controller_type(ControllerLayout.VENDOR_SONY, "") == ControllerLayout.CTYPE_PS)
	assert(ControllerLayout.controller_type(0, "Wireless Controller") == ControllerLayout.CTYPE_PS)
	assert(ControllerLayout.controller_type(0, "DualSense Wireless Controller") == ControllerLayout.CTYPE_PS)
	assert(ControllerLayout.controller_type(ControllerLayout.VENDOR_NINTENDO, "") == ControllerLayout.CTYPE_NINTENDO)
	assert(ControllerLayout.controller_type(ControllerLayout.VENDOR_MICROSOFT, "Xbox Wireless Controller") == ControllerLayout.CTYPE_XBOX)
	assert(ControllerLayout.controller_type(0, "Generic X-Box pad") == ControllerLayout.CTYPE_XBOX)

func _test_slots():
	var slots := GamepadSlots.new()
	assert(slots.acquire(GamepadSlots.QUEST_PAD) == 0)
	assert(slots.acquire(0) == 1)  # physical pad 0 no longer collides with PAD mode
	assert(slots.acquire(0) == 1)
	assert(slots.active_mask() == 0b11)
	assert(slots.release(GamepadSlots.QUEST_PAD) == 0)
	assert(slots.active_mask() == 0b10)
	assert(slots.acquire(3) == 0)  # lowest free slot is reused
	assert(slots.release(7) == -1)
	for key in range(10, 30):
		slots.acquire(key)
	assert(slots.acquire(99) == -1)
	assert(slots.active_mask() == 0xFFFF)
	slots.clear()
	assert(slots.active_mask() == 0)
