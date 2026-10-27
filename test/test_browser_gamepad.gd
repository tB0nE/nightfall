extends SceneTree

class FakeBrowser extends RefCounted:
	var active := true
	var states: Array = []
	var cleared := 0
	func gamepad_state(buttons, lt, rt, lx, ly, rx, ry): states.append([buttons, lt, rt, lx, ly, rx, ry])
	func clear_gamepad(): cleared += 1

class FakeMain extends Node3D:
	var browser_prototype := FakeBrowser.new()
	var input_handler: InputHandler
	var stream_backend = null # Any accidental PC send must fail this test.
	var is_streaming := false
	var is_xr_active := true
	var ui_visible := false
	var virtual_keyboard := Node3D.new()
	var xr_camera := Node3D.new()
	var left_hand = null
	var right_hand = null
	var xr_interaction = null
	func browser_content_active(): return true

func _init():
	_run.call_deferred()

func _run():
	var owner := FakeMain.new()
	root.add_child(owner)
	owner.add_child(owner.xr_camera)
	owner.add_child(owner.virtual_keyboard)
	owner.virtual_keyboard.visible = false
	owner.input_handler = InputHandler.new(owner)
	owner.input_handler.send_pad_state(GamepadSlots.QUEST_PAD, 0, 0x1000, 255, 0, 1, 2, 3, 4)
	assert(owner.browser_prototype.states[-1] == [0x1000, 255, 0, 1, 2, 3, 4])
	owner.input_handler.send_pad_state(3, 0, 0, 0, 0, 0, 0, 0, 0)
	assert(owner.browser_prototype.states.size() == 1, "Physical Android input must not duplicate the Quest bridge")
	var mapper := ControllerMapper.new(owner)
	mapper.main = owner
	mapper.active = true
	mapper._process(0.2)
	assert(owner.browser_prototype.states.size() == 2, "Quest pad must run without a PC stream")
	owner.ui_visible = true
	mapper._process(0.2)
	assert(owner.browser_prototype.cleared == 1)
	assert(owner.browser_prototype.states.size() == 2, "Menu interaction must not reach the game")
	owner.ui_visible = false
	mapper.active = false
	mapper._process(0.2)
	assert(owner.browser_prototype.cleared == 2)
	mapper.free()
	owner.free()
	print("All browser gamepad routing tests passed")
	quit()
