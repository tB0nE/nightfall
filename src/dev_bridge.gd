class_name DevBridge
extends Node

## Dev builds only: a local control port that lets an agent or script see and
## drive the running app (tools/nf.py; see docs/testing.md).
##
## Requests and replies are one JSON object per line. Every reply has "ok", and
## an "error" when ok is false; an "id" in the request is echoed back. It binds
## to 127.0.0.1 only: on the headset it's reached with
## `adb forward tcp:47950 tcp:47950`.
##
## Commands: ping, ui, press, select, set_text, state, eval, wait, pose,
## screenshot, log.

const PORT := 47950
const MAX_REQUEST_BYTES := 65536
# Controls the agent can act on; labels are listed too unless asked not to.
const INTERACTIVE := ["BaseButton", "LineEdit", "TextEdit", "Range", "ItemList", "TabBar"]

var main
var _server := TCPServer.new()
var _clients: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {}
var _queue: Array = []

static func enabled(args: PackedStringArray, dev_feature: bool, debug_build: bool) -> bool:
	return dev_feature or debug_build or "--nf-dev-bridge" in args

static func wanted() -> bool:
	return enabled(OS.get_cmdline_args() + OS.get_cmdline_user_args(), OS.has_feature("nightfall_dev"), OS.is_debug_build())

func _init(owner) -> void:
	main = owner
	name = "DevBridge"
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	var err := _server.listen(PORT, "127.0.0.1")
	if err != OK:
		main._log("[DEV-BRIDGE] Can't listen on 127.0.0.1:%d (error %d)" % [PORT, err])
		return
	main._log("[DEV-BRIDGE] Listening on 127.0.0.1:%d" % PORT)
	_run()

# One request at a time, so commands that wait a frame (press, wait) can't
# interleave.
func _run() -> void:
	while is_inside_tree():
		await get_tree().process_frame
		_accept()
		while not _queue.is_empty():
			var item: Array = _queue.pop_front()
			var client: StreamPeerTCP = item[0]
			var reply: Dictionary = await _reply(item[1])
			if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				client.put_data((JSON.stringify(reply) + "\n").to_utf8_buffer())

func _accept() -> void:
	while _server.is_connection_available():
		var client := _server.take_connection()
		_clients.append(client)
		_buffers[client] = PackedByteArray()
	for client: StreamPeerTCP in _clients.duplicate():
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(client)
			_buffers.erase(client)
			continue
		var available: int = client.get_available_bytes()
		if available <= 0:
			continue
		var result: Array = client.get_partial_data(available)
		if result[0] != OK:
			continue
		var buffer: PackedByteArray = _buffers[client] + result[1]
		var newline := buffer.find(10)
		while newline >= 0:
			_queue.append([client, buffer.slice(0, newline).get_string_from_utf8()])
			buffer = buffer.slice(newline + 1)
			newline = buffer.find(10)
		if buffer.size() > MAX_REQUEST_BYTES:
			client.disconnect_from_host()
			buffer = PackedByteArray()
		_buffers[client] = buffer

func _reply(line: String) -> Dictionary:
	var request = JSON.parse_string(line)
	if typeof(request) != TYPE_DICTIONARY:
		return {"ok": false, "error": "expected a JSON object per line"}
	var reply: Dictionary = await handle(request)
	if request.has("id"):
		reply["id"] = request["id"]
	return reply

func handle(request: Dictionary) -> Dictionary:
	match str(request.get("cmd", "")):
		"ping":
			return {"ok": true, "app": "nightfall", "platform": OS.get_name(),
				"xr": bool(main.get("is_xr_active")), "dev": OS.has_feature("nightfall_dev")}
		"ui":
			return {"ok": true, "viewports": ui_tree(bool(request.get("labels", true)), str(request.get("viewport", "")), bool(request.get("hidden", false)))}
		"press":
			return await press(str(request.get("target", "")))
		"select":
			return select(str(request.get("target", "")), str(request.get("option", "")))
		"set_text":
			return set_text(str(request.get("target", "")), str(request.get("text", "")), bool(request.get("submit", false)))
		"state":
			return {"ok": true, "state": state()}
		"eval":
			return evaluate(str(request.get("expr", "")))
		"wait":
			return await wait_for(str(request.get("expr", "")), float(request.get("timeout", 10.0)))
		"pose":
			return pose(str(request.get("node", "head")), request)
		"screenshot":
			return await screenshot(str(request.get("viewport", "ui")), int(request.get("max_width", 1280)))
		"log":
			return {"ok": true, "lines": log_tail(int(request.get("lines", 100)))}
	return {"ok": false, "error": "unknown cmd; try ping, ui, press, select, set_text, state, eval, wait, pose, screenshot, log"}

# --- UI -----------------------------------------------------------------

func viewports() -> Array:
	var found: Array = [get_tree().root]
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			if child is SubViewport:
				found.append(child)
			stack.append(child)
	return found

func viewport_name(viewport: Viewport) -> String:
	if viewport == get_tree().root:
		return "root"
	if viewport == main.get("ui_viewport"):
		return "ui"
	if viewport == main.get("welcome_viewport"):
		return "welcome"
	return str(viewport.name)

# The 3D node showing a viewport: its nearest Node3D ancestor.
func panel_of(viewport: Viewport) -> Node3D:
	var node: Node = viewport.get_parent()
	while node and not node is Node3D:
		node = node.get_parent()
	return node as Node3D

func shown(viewport: Viewport) -> bool:
	var panel := panel_of(viewport)
	return panel == null or panel.is_visible_in_tree()

# Panels that are hidden (the keyboard, closed screens) are left out unless
# asked for, or named.
func ui_tree(labels: bool, only: String, hidden: bool) -> Array:
	var out: Array = []
	for viewport in viewports():
		var name := viewport_name(viewport)
		if not only.is_empty() and name != only:
			continue
		if only.is_empty() and not hidden and not shown(viewport):
			continue
		var controls: Array = []
		for control in controls_in(viewport):
			if is_interactive(control) or (labels and control is Label and not control.text.is_empty()):
				controls.append(describe(control, viewport))
		if controls.is_empty():
			continue
		var entry := {"name": name, "path": str(viewport.get_path()), "size": _vec(viewport.get_visible_rect().size), "controls": controls}
		var panel := panel_of(viewport)
		if panel:
			entry["panel"] = {"path": str(panel.get_path()), "visible": panel.is_visible_in_tree(),
				"position": _vec(panel.global_position), "distance": _round(panel.global_position.distance_to(_head().origin))}
		out.append(entry)
	return out

func controls_in(viewport: Viewport) -> Array:
	var found: Array = []
	var stack: Array = [viewport]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			if child is Viewport:
				continue
			if child is CanvasItem and not child.is_visible_in_tree():
				continue
			if child is Control:
				found.append(child)
			stack.append(child)
	return found

func is_interactive(control: Control) -> bool:
	for type in INTERACTIVE:
		if control.is_class(type):
			return true
	return false

func describe(control: Control, viewport: Viewport) -> Dictionary:
	var rect := control.get_global_rect()
	var entry := {"path": str(control.get_path()), "type": control.get_class(), "rect": [int(rect.position.x), int(rect.position.y), int(rect.size.x), int(rect.size.y)]}
	var text := _text(control)
	if not text.is_empty():
		entry["text"] = text
	if not control.tooltip_text.is_empty():
		entry["tooltip"] = control.atr(control.tooltip_text)
	if not on_screen(control, viewport):
		entry["on_screen"] = false
	if control is BaseButton:
		if control.disabled:
			entry["disabled"] = true
		if control.toggle_mode:
			entry["pressed"] = control.button_pressed
	if control is OptionButton:
		var items: Array = []
		for i in control.item_count:
			items.append(control.get_item_text(i))
		entry["items"] = items
		entry["selected"] = control.selected
	if control is LineEdit and not control.editable:
		entry["disabled"] = true
	if control is Range:
		entry["value"] = control.value
		entry["range"] = [control.min_value, control.max_value]
	return entry

func _text(control: Control) -> String:
	for property in ["text", "placeholder_text"]:
		var value = control.get(property)
		if typeof(value) == TYPE_STRING and not value.is_empty():
			return control.atr(value) if property == "text" and not control is LineEdit else value
	return ""

# Inside the viewport and every clipping ancestor (a scrolled-away row isn't).
func on_screen(control: Control, viewport: Viewport) -> bool:
	var center := control.get_global_rect().get_center()
	if not viewport.get_visible_rect().has_point(center):
		return false
	var node: Node = control.get_parent()
	while node and node is Control:
		if node.clip_contents and not node.get_global_rect().has_point(center):
			return false
		node = node.get_parent()
	return true

# A path (absolute, or ending in this), else visible text: exact, then partial,
# both ignoring case. Interactive controls win over labels.
func find_control(target: String) -> Array:
	if target.is_empty():
		return []
	var lower := target.to_lower()
	var exact: Array = []
	var partial: Array = []
	for viewport in viewports():
		for control in controls_in(viewport):
			var path := str(control.get_path())
			if path != target and not path.ends_with("/" + target) and not shown(viewport):
				continue
			if path == target or path.ends_with("/" + target):
				return [[control, viewport]]
			var text := _text(control).to_lower()
			if text.is_empty():
				continue
			if text == lower:
				exact.append([control, viewport])
			elif text.contains(lower):
				partial.append([control, viewport])
	for group in [exact, partial]:
		var interactive: Array = group.filter(func(c): return is_interactive(c[0]))
		if not interactive.is_empty():
			return interactive
		if not group.is_empty():
			return group
	return []

func _resolve(target: String) -> Variant:
	var matches := find_control(target)
	if matches.is_empty():
		return {"ok": false, "error": "no visible control matches %s" % JSON.stringify(target)}
	if matches.size() > 1:
		var paths: Array = matches.map(func(c): return str(c[0].get_path()))
		return {"ok": false, "error": "%d controls match; use a path" % matches.size(), "matches": paths.slice(0, 10)}
	return matches[0]

# Clicks the centre of the control the way the pointer does: motion, press,
# then release a frame later, all pushed into its viewport.
func press(target: String) -> Dictionary:
	var found = _resolve(target)
	if found is Dictionary:
		return found
	var control: Control = found[0]
	var viewport: Viewport = found[1]
	if control is BaseButton and control.disabled:
		return {"ok": false, "error": "disabled", "control": describe(control, viewport)}
	if not on_screen(control, viewport):
		var scroll := _scroll_parent(control)
		if scroll:
			scroll.ensure_control_visible(control)
			await get_tree().process_frame
	var center := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = center
	motion.global_position = center
	viewport.push_input(motion)
	var hovered := viewport.gui_get_hovered_control()
	var hit := hovered == control or (hovered != null and control.is_ancestor_of(hovered))
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.position = center
		click.global_position = center
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		viewport.push_input(click)
		await get_tree().process_frame
	var reply := {"ok": true, "pressed": str(control.get_path()), "hit": hit}
	if not hit:
		reply["hovered"] = str(hovered.get_path()) if hovered else ""
	return reply

func _scroll_parent(control: Control) -> ScrollContainer:
	var node: Node = control.get_parent()
	while node:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return null

# Option lists open a popup; this picks the item and emits what the popup would.
func select(target: String, option: String) -> Dictionary:
	var found = _resolve(target)
	if found is Dictionary:
		return found
	var control: Control = found[0]
	if not control is OptionButton:
		return {"ok": false, "error": "%s is a %s, not an OptionButton" % [control.get_path(), control.get_class()]}
	if control.disabled:
		return {"ok": false, "error": "disabled"}
	for i in control.item_count:
		if control.get_item_text(i).to_lower() == option.to_lower() or str(i) == option:
			control.select(i)
			control.item_selected.emit(i)
			return {"ok": true, "selected": control.get_item_text(i)}
	var items: Array = []
	for i in control.item_count:
		items.append(control.get_item_text(i))
	return {"ok": false, "error": "no item %s" % JSON.stringify(option), "items": items}

func set_text(target: String, text: String, submit: bool) -> Dictionary:
	var found = _resolve(target)
	if found is Dictionary:
		return found
	var control: Control = found[0]
	if not control is LineEdit:
		return {"ok": false, "error": "%s is not a LineEdit" % control.get_path()}
	control.text = text
	control.text_changed.emit(text)
	if submit:
		control.text_submitted.emit(text)
	return {"ok": true}

# --- State --------------------------------------------------------------

func _head() -> Transform3D:
	var camera = main.get("xr_camera")
	return camera.global_transform if camera is Node3D else Transform3D()

func state() -> Dictionary:
	var head := _head()
	var out := {
		"xr": bool(main.get("is_xr_active")),
		"streaming": bool(main.get("is_streaming")),
		"head": {"position": _vec(head.origin), "yaw_deg": _round(rad_to_deg(head.basis.get_euler().y))},
		"fps": Engine.get_frames_per_second(),
	}
	var status_label = main.get("_ui_status_label")
	if status_label is Label:
		out["status_line"] = status_label.text
	var telemetry = main.get("telemetry")
	if telemetry and "app_fps" in telemetry:
		out["app_fps"] = _round(telemetry.app_fps)
	var lifecycle = main.get("session_lifecycle")
	if lifecycle and lifecycle.has_method("phase_name"):
		out["phase"] = lifecycle.phase_name()
	var panel = main.get("ui_panel_3d")
	if panel is Node3D:
		out["menu"] = {"visible": panel.is_visible_in_tree(), "position": _vec(panel.global_position), "distance": _round(panel.global_position.distance_to(head.origin))}
	var welcome = main.get("welcome_screen")
	if welcome is Node:
		out["welcome_visible"] = welcome.is_visible_in_tree() if welcome is Node3D else true
	var screens = main.get("screens")
	if screens is Array:
		var listed: Array = []
		for screen in screens:
			if screen is Node3D:
				listed.append({"name": str(screen.name), "visible": screen.is_visible_in_tree(), "primary": screen == main.get("primary_screen"),
					"position": _vec(screen.global_position), "distance": _round(screen.global_position.distance_to(head.origin))})
		out["screens"] = listed
	var depth = main.get("depth_estimator")
	if depth and "enabled" in depth:
		out["depth"] = {"enabled": depth.enabled}
		if depth.has_method("meteor_in_use") and depth.meteor_in_use():
			out["depth"]["meteor"] = depth.meteor_stats
	return out

# Any expression with main as `self`, e.g. "screens.size()" or
# "settings.host.stream_fps". Dev builds only, like the rest of this.
func evaluate(text: String) -> Dictionary:
	var expression := Expression.new()
	if expression.parse(text) != OK:
		return {"ok": false, "error": expression.get_error_text()}
	var value = expression.execute([], main, false)
	if expression.has_execute_failed():
		return {"ok": false, "error": expression.get_error_text()}
	return {"ok": true, "value": _json_safe(value)}

func wait_for(text: String, timeout: float) -> Dictionary:
	var expression := Expression.new()
	if expression.parse(text) != OK:
		return {"ok": false, "error": expression.get_error_text()}
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < int(timeout * 1000.0):
		var value = expression.execute([], main, false)
		if not expression.has_execute_failed() and value:
			return {"ok": true, "value": _json_safe(value), "waited_s": _round((Time.get_ticks_msec() - start) / 1000.0)}
		await get_tree().process_frame
	return {"ok": false, "error": "timed out after %ss" % timeout}

# Moves the head or a hand. With a real headset the runtime moves them back
# every frame, so this is for desktop runs (--nf-no-xr or a simulated HMD).
func pose(which: String, request: Dictionary) -> Dictionary:
	var nodes := {"head": main.get("xr_camera"), "left": main.get("left_hand"), "right": main.get("right_hand"), "origin": main.get("xr_origin")}
	var node = nodes.get(which)
	if not node is Node3D:
		return {"ok": false, "error": "pose node is head, left, right or origin"}
	var position = request.get("position")
	if position is Array and position.size() == 3:
		node.global_position = Vector3(position[0], position[1], position[2])
	var rotation = request.get("rotation_deg")
	if rotation is Array and rotation.size() == 3:
		node.global_rotation_degrees = Vector3(rotation[0], rotation[1], rotation[2])
	return {"ok": true, "position": _vec(node.global_position), "rotation_deg": _vec(node.global_rotation_degrees)}

func screenshot(which: String, max_width: int) -> Dictionary:
	var viewport: Viewport = null
	for candidate in viewports():
		if viewport_name(candidate) == which or str(candidate.get_path()) == which:
			viewport = candidate
	if viewport == null:
		return {"ok": false, "error": "no viewport %s; names come from the ui command" % JSON.stringify(which)}
	# Panels stop rendering while hidden or unchanged; draw one frame for the
	# picture, then put the mode back.
	var sub := viewport as SubViewport
	var mode := sub.render_target_update_mode if sub else SubViewport.UPDATE_ALWAYS
	if sub and mode != SubViewport.UPDATE_ALWAYS:
		sub.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if sub and sub.render_target_update_mode != mode:
		sub.render_target_update_mode = mode
	if image == null or image.is_empty():
		return {"ok": false, "error": "viewport %s has no image (with XR on, root renders to the headset)" % which}
	# Transparent panels are read on a dark backdrop, as in the headset.
	if sub and sub.transparent_bg:
		var backdrop := Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
		backdrop.fill(Color(0.12, 0.12, 0.12))
		image.convert(Image.FORMAT_RGBA8)
		backdrop.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
		image = backdrop
	if max_width > 0 and image.get_width() > max_width:
		image.resize(max_width, int(image.get_height() * float(max_width) / image.get_width()))
	return {"ok": true, "width": image.get_width(), "height": image.get_height(), "png_base64": Marshalls.raw_to_base64(image.save_png_to_buffer())}

# The session log file plus lines not yet written to it.
func log_tail(count: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var file := FileAccess.open(main.LOG_CURRENT_PATH, FileAccess.READ)
	if file:
		lines = file.get_as_text().split("\n", false)
	lines.append_array(main._log_lines)
	return lines.slice(maxi(0, lines.size() - count))

# --- helpers ------------------------------------------------------------

func _vec(v) -> Array:
	if v is Vector2:
		return [_round(v.x), _round(v.y)]
	return [_round(v.x), _round(v.y), _round(v.z)]

func _round(x: float) -> float:
	return snappedf(x, 0.001)

func _json_safe(value) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2, TYPE_VECTOR3:
			return _vec(value)
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			return Array(value).map(func(v): return _json_safe(v))
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[str(key)] = _json_safe(value[key])
			return out
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Node:
				return "<%s %s>" % [value.get_class(), value.get_path()]
			return "<%s>" % value.get_class()
	return str(value)
