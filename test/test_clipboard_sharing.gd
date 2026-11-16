extends SceneTree
const Sharing = preload("res://src/clipboard_sharing.gd")
class UI extends RefCounted:
	var messages: Array = []
	func set_status(value): messages.append(value)
class Owner extends Node3D:
	var is_streaming := true
	var current_host_id := 1
	var ui_controller := UI.new()
class Bridge extends Sharing:
	var context: Array = [1,false,0,0,123,"monitor:m0"]
	var clipboard := {"ok":true,"text":"browser text","stamp":1,"local":true}
	var replies: Array = []
	var trace: Array = []
	var replace_on_request := false
	var switch_on_request := false
	var pause_on_request := false
	func _context() -> Array: return context.duplicate()+[_epoch]
	func _read_local() -> Dictionary: return clipboard.duplicate()
	func _write_local(text: String, expected: Variant) -> bool:
		if clipboard.stamp != expected: return false
		trace.append("mark")
		clipboard = {"ok":true,"text":text,"stamp":int(expected)+1,"local":false}
		return true
	func _request(_host: int, write: bool, _text := "") -> Dictionary:
		trace.append("post" if write else "get")
		if replace_on_request: clipboard = {"ok":true,"text":"newer local copy","stamp":99,"local":true}
		if switch_on_request: context[5] = "monitor:v1"
		if pause_on_request: cancel()
		return replies.pop_front()
	func _copy_settle() -> void: pass

func _init(): call_deferred("run")
func run():
	var owner := Owner.new()
	root.add_child(owner)
	var bridge := Bridge.new(owner)
	bridge.replies = [{"ok":true}]
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["post","mark","paste"], "Host clipboard must be set before sending Ctrl+V")
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["paste"], "Ordinary host-to-host paste must preserve the host clipboard")
	bridge.trace.clear()
	bridge.replies = [{"ok":true,"text":"desktop text"}]
	await bridge.perform("copy",func():bridge.trace.append("copy"))
	assert(bridge.trace == ["copy","get","mark"] and bridge.clipboard.text == "desktop text")
	bridge.trace.clear()
	bridge.replace_on_request = true
	bridge.replies = [{"ok":true,"text":"late desktop text"}]
	await bridge.perform("cut",func():bridge.trace.append("cut"))
	assert(bridge.clipboard.text == "newer local copy", "A newer copy wins over delayed network responses")
	bridge.replace_on_request = false
	bridge.context[1] = true
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["paste"], "Browser-to-browser paste needs no host request")
	bridge.clipboard.local = false
	bridge.replies = [{"ok":true,"text":"host context-menu copy"}]
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["get","mark","paste"] and bridge.clipboard.text == "host context-menu copy")
	bridge.context[1] = false
	bridge.clipboard.local = true
	bridge.replies = [{"ok":false,"status":403}]
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["post"] and owner.ui_controller.messages.size() == 1, "Failed writes must not paste stale host contents")
	bridge.replies = [{"ok":true}]
	bridge.switch_on_request = true
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["post"], "Never inject delayed paste into a different tab")
	bridge.switch_on_request = false
	bridge.pause_on_request = true
	bridge.replies = [{"ok":true}]
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["post"], "Headset pause must cancel pending paste")
	bridge.pause_on_request = false
	bridge.clipboard.text = "é".repeat(40000)
	bridge.trace.clear()
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace.is_empty(), "The limit is UTF-8 bytes, not characters")
	bridge.clipboard = {"ok":false}
	await bridge.perform("paste",func():bridge.trace.append("paste"))
	assert(bridge.trace == ["paste"], "Leave existing non-text paste behavior alone")
	owner.free()
	print("All explicit clipboard direction, ordering, limit and stale-target tests passed")
	quit()
