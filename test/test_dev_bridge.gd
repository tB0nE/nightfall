extends SceneTree

const Bridge = preload("res://src/dev_bridge.gd")

class Owner extends Node3D:
	const LOG_CURRENT_PATH := "user://test-dev-bridge.log"
	var _log_lines: PackedStringArray = []
	var ui_viewport: SubViewport
	var xr_camera: Camera3D
	var is_xr_active := false
	var is_streaming := false
	func _log(message: String) -> void: _log_lines.append(message)

var presses := 0
var picked := -1

func _initialize() -> void:
	assert(Bridge.enabled(PackedStringArray(), true, false), "dev builds have it")
	assert(Bridge.enabled(PackedStringArray(), false, true), "debug builds have it")
	assert(Bridge.enabled(PackedStringArray(["--nf-dev-bridge"]), false, false), "the flag turns it on")
	assert(not Bridge.enabled(PackedStringArray(), false, false), "release builds don't")

	var owner := Owner.new()
	root.add_child(owner)
	owner.xr_camera = Camera3D.new()
	owner.add_child(owner.xr_camera)
	owner.xr_camera.position = Vector3(0, 1.6, 0)
	# A menu panel 1.5 m ahead showing a viewport, as main.tscn does.
	var panel := Node3D.new()
	panel.position = Vector3(0, 1.6, -1.5)
	owner.add_child(panel)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(400, 300)
	panel.add_child(viewport)
	owner.ui_viewport = viewport
	var box := VBoxContainer.new()
	box.size = Vector2(400, 300)
	viewport.add_child(box)
	var settings := Button.new()
	settings.text = "Settings"
	settings.custom_minimum_size = Vector2(200, 60)
	settings.pressed.connect(func(): presses += 1)
	box.add_child(settings)
	var locked := Button.new()
	locked.text = "Screens"
	locked.disabled = true
	box.add_child(locked)
	var options := OptionButton.new()
	options.name = "Background"
	for item in ["Black", "Ash", "Cinema"]:
		options.add_item(item)
	options.item_selected.connect(func(index): picked = index)
	box.add_child(options)
	var label := Label.new()
	label.text = "Settings saved"
	box.add_child(label)
	# A hidden panel's buttons are neither listed nor matched by text.
	var hidden_panel := Node3D.new()
	hidden_panel.visible = false
	owner.add_child(hidden_panel)
	var keyboard := SubViewport.new()
	hidden_panel.add_child(keyboard)
	var key := Button.new()
	key.text = "Settings"
	keyboard.add_child(key)

	var bridge := Bridge.new(owner)
	owner.add_child(bridge)
	await process_frame
	await process_frame

	var tree: Array = bridge.ui_tree(true, "", false)
	assert(tree.size() == 1, "only the shown panel: %s" % [tree.map(func(v): return v["name"])])
	var menu: Dictionary = tree[0]
	assert(menu["name"] == "ui")
	assert(is_equal_approx(menu["panel"]["distance"], 1.5), "distance from the head: %s" % menu["panel"]["distance"])
	var texts: Array = menu["controls"].map(func(c): return c.get("text", ""))
	assert("Settings" in texts and "Settings saved" in texts, str(texts))
	assert(menu["controls"].any(func(c): return c.get("text") == "Screens" and c.get("disabled")))
	assert(bridge.ui_tree(false, "", false)[0]["controls"].size() == 3, "labels left out on request")
	assert(bridge.ui_tree(true, "", true).size() == 2, "hidden panels on request")

	# Exact text beats a partial match, and interactive controls beat labels.
	var found: Array = bridge.find_control("settings")
	assert(found.size() == 1 and found[0][0] == settings)
	assert(bridge.find_control("Background")[0][0] == options, "by node name")
	assert(bridge.find_control("nothing like it").is_empty())

	var reply: Dictionary = await bridge.handle({"cmd": "press", "target": "Settings"})
	assert(reply["ok"] and reply["hit"], str(reply))
	assert(presses == 1, "the click reached the button")
	reply = await bridge.handle({"cmd": "press", "target": "Screens"})
	assert(not reply["ok"] and reply["error"] == "disabled")

	reply = await bridge.handle({"cmd": "select", "target": "Background", "option": "cinema"})
	assert(reply["ok"] and picked == 2 and options.selected == 2, str(reply))
	reply = await bridge.handle({"cmd": "select", "target": "Background", "option": "Snow"})
	assert(not reply["ok"] and reply["items"] == ["Black", "Ash", "Cinema"])

	reply = await bridge.handle({"cmd": "eval", "expr": "ui_viewport.size.x * 2"})
	assert(reply["ok"] and reply["value"] == 800, str(reply))
	reply = await bridge.handle({"cmd": "eval", "expr": "no_such_thing("})
	assert(not reply["ok"])
	reply = await bridge.handle({"cmd": "wait", "expr": "is_streaming", "timeout": 0.1})
	assert(not reply["ok"] and reply["error"].begins_with("timed out"))

	var state: Dictionary = (await bridge.handle({"cmd": "state"}))["state"]
	assert(state["head"]["position"] == [0.0, 1.6, 0.0], str(state["head"]))
	assert(not state["streaming"])
	reply = await bridge.handle({"cmd": "pose", "node": "head", "position": [1, 1.7, 0]})
	assert(reply["ok"] and owner.xr_camera.global_position.is_equal_approx(Vector3(1, 1.7, 0)))

	owner._log("bridge test line")
	assert((await bridge.handle({"cmd": "log", "lines": 1}))["lines"] == PackedStringArray(["bridge test line"]))
	assert(not (await bridge.handle({"cmd": "dance"}))["ok"])

	print("All dev_bridge tests passed")
	quit()
