extends SceneTree

class FakeUploader extends RefCounted:
	var events: Array = []
	func browser_key(code: int, pressed: bool, modifiers: int):
		events.append([code, pressed, modifiers])
	func browser_pointer(x: float, y: float, action: int):
		events.append([x, y, action])

class FakeMain extends Node3D:
	var browser_prototype: RefCounted
	# A host send would fail: browser input must never reach this field.
	var stream_backend = null

func _init():
	var owner := FakeMain.new()
	var browser = preload("res://src/browser_prototype.gd").new(owner)
	var uploader := FakeUploader.new()
	owner.browser_prototype = browser
	browser.uploader = uploader
	browser.active = true
	assert(not browser.can_infer_depth())
	browser.texture = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	browser.set_activity(ContentProvider.Activity.VISIBLE)
	assert(browser.can_infer_depth())
	browser.set_activity(ContentProvider.Activity.SUSPENDED)
	assert(not browser.can_infer_depth())
	browser.pointer(Vector2(0.5, 0.25), true)
	assert(uploader.events[-1] == [960.0, 270.0, 0])
	browser.pointer(Vector2(0.6, 0.25), true)
	assert(uploader.events[-1][2] == 2)
	browser.cancel_pointer()
	assert(uploader.events[-1][2] == 3)
	browser.pointer(Vector2(0.5, 0.25), false)
	assert(uploader.events[-1][2] == 7)
	var keyboard := VirtualKeyboard.new(owner)
	keyboard._send_key(KEY_CTRL, 3)
	keyboard._send_key(KEY_C, 3)
	keyboard._send_key(KEY_C, 4)
	keyboard._send_key(KEY_CTRL, 4)
	assert(uploader.events[-4] == [113, true, 4096])
	assert(uploader.events[-3] == [31, true, 4096])
	assert(uploader.events[-2] == [31, false, 4096])
	assert(uploader.events[-1] == [113, false, 0])
	keyboard._send_shortcut(VirtualKeyboard.SHORTCUT_INSERT)
	assert(uploader.events[-2] == [124, true, 0])
	assert(uploader.events[-1] == [124, false, 0])
	browser.scroll(1)
	assert(uploader.events[-2] == [93, true, 0])
	browser.active = false
	browser.close()
	assert(browser.activity == ContentProvider.Activity.CLOSED)
	browser.start()
	assert(not browser.active, "A closed provider cannot be revived")
	keyboard.free()
	owner.free()
	print("All browser_prototype tests passed")
	quit()
