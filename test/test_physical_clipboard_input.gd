extends SceneTree
class Browser extends RefCounted:
	var active := true
	var edits: Array = []
	var keys: Array = []
	func _edit_raw(operation): edits.append(operation)
	func physical_key(event): keys.append([event.keycode,event.pressed])
class Sources extends RefCounted:
	var browser: RefCounted
	func focused_browser(): return browser
class Sharing extends RefCounted:
	var operations: Array = []
	var pending: Callable
	func perform(operation, send):
		operations.append(operation)
		pending = send
class Backend extends RefCounted:
	var keys: Array = []
	func send_keyboard_event(code, action, _modifiers): keys.append([code,action])
class Owner extends Node3D:
	var pcvr_handover = null
	var is_xr_active := false
	var ui_visible := false
	var is_streaming := true
	var mouse_captured_by_stream := false
	var suppress_input_frames := 0
	var ui_viewport := SubViewport.new()
	var screen_sources := Sources.new()
	var clipboard_sharing := Sharing.new()
	var stream_backend := Backend.new()
func event(code, pressed := true, ctrl := false):
	var value := InputEventKey.new()
	value.keycode = code
	value.pressed = pressed
	value.ctrl_pressed = ctrl
	return value
func _init(): call_deferred("run")
func run():
	var owner := Owner.new()
	root.add_child(owner)
	owner.add_child(owner.ui_viewport)
	var handler := InputHandler.new(owner)
	# A delayed host paste must synthesize Ctrl after the physical key releases.
	handler.handle_input(event(KEY_CTRL))
	handler.handle_input(event(KEY_V,true,true))
	handler.handle_input(event(KEY_V,false,true))
	handler.handle_input(event(KEY_CTRL,false))
	assert(owner.clipboard_sharing.operations == ["paste"])
	owner.clipboard_sharing.pending.call()
	assert(owner.stream_backend.keys == [[KEY_CTRL,3],[KEY_CTRL,4],[KEY_CTRL,3],[KEY_V,3],[KEY_V,4],[KEY_CTRL,4]])
	# Browser typing works without a desktop connection; copy uses shared routing.
	owner.is_streaming = false
	var browser := Browser.new()
	owner.screen_sources.browser = browser
	handler.handle_input(event(KEY_A))
	handler.handle_input(event(KEY_A,false))
	handler.handle_input(event(KEY_C,true,true))
	handler.handle_input(event(KEY_C,false,true))
	owner.clipboard_sharing.pending.call()
	assert(browser.keys == [[KEY_A,true],[KEY_A,false]])
	assert(browser.edits == ["copy"])
	owner.free()
	print("Physical clipboard input tests passed")
	quit()
