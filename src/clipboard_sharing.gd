class_name ClipboardSharing
extends RefCounted

const MAX_BYTES := 65536
var main: Node3D
var _busy := false
var _queue: Array = []
var _last_remote := ""
var _epoch := 0
var _java: Object

func _init(owner: Node3D): main = owner

func _context() -> Array:
	var browser = main.screen_sources.focused_browser()
	var in_browser: bool = browser != null and browser.active
	return [main.current_host_id, in_browser, browser.get_instance_id() if in_browser else 0,
		browser.selected_page if in_browser else 0, main.primary_screen.get_instance_id(), main.primary_screen.content_tabs.selected_id, _epoch]

func _bridge() -> Object:
	if _java == null:
		var wrapper: Object = Engine.get_singleton("JavaClassWrapper")
		if wrapper != null: _java = wrapper.wrap("com.godot.game.GodotApp")
	return _java

func _read_local() -> Dictionary:
	if OS.get_name() == "Android":
		var bridge := _bridge()
		var value = JSON.parse_string(str(bridge.browserClipboardRead())) if bridge != null else null
		return value if value is Dictionary else {"ok":false}
	var text := DisplayServer.clipboard_get()
	return {"ok":true,"text":text,"stamp":text,"local":text != _last_remote}

func _write_local(text: String, expected: Variant) -> bool:
	if OS.get_name() == "Android":
		var bridge := _bridge()
		return bridge != null and bridge.browserClipboardWrite(text,int(expected))
	if DisplayServer.clipboard_get() != str(expected): return false
	DisplayServer.clipboard_set(text)
	_last_remote = text
	return true

func _request(host_id: int, write: bool, text := "") -> Dictionary:
	var reply := {"done":false,"result":{}}
	main.stream_backend.request_clipboard(host_id,write,text,func(value):
		reply.result = value
		reply.done = true)
	var deadline := Time.get_ticks_msec()+3500
	while not reply.done and Time.get_ticks_msec()<deadline: await main.get_tree().process_frame
	return reply.result

func _copy_settle() -> void:
	await main.get_tree().create_timer(0.15).timeout

func _same_host(context: Array) -> bool:
	return main.is_streaming and main.current_host_id == context[0] and context[-1] == _epoch

func _status() -> void:
	main.ui_controller.set_status("Host clipboard sharing unavailable; check host support and clipboard permissions")

# User-triggered operations only. No clipboard polling, logging or persistence.
func cancel() -> void:
	_epoch += 1
	_queue.clear()

func perform(operation: String, send: Callable) -> void:
	if _queue.size() >= 8: return
	_queue.append({"operation":operation,"send":send,"context":_context()})
	if _busy: return
	_busy = true
	while not _queue.is_empty():
		var item: Dictionary = _queue.pop_front()
		if item.context == _context(): await _execute(item.operation,item.send,item.context)
	_busy = false

func _execute(operation: String, send: Callable, context: Array) -> void:
	var local := _read_local()
	if operation in ["copy","cut"]:
		send.call()
		if context[1] or not _same_host(context) or not local.get("ok",false): return
		await _copy_settle()
		if not _same_host(context): return
		var response := await _request(context[0],false)
		if _same_host(context) and response.get("ok",false):
			var text := str(response.get("text",""))
			if text.to_utf8_buffer().size() <= MAX_BYTES: _write_local(text,local.stamp)
		return
	if operation != "paste": return
	if not _same_host(context) or not local.get("ok",false):
		send.call()
		return
	var text := str(local.get("text",""))
	if text.to_utf8_buffer().size()>MAX_BYTES:
		main.ui_controller.set_status("Clipboard sharing supports text up to 64 KiB")
		return
	if context[1]:
		# A local browser copy wins. Otherwise refresh lazily, which also
		# handles Copy from the desktop application's own context menu.
		if not local.get("local",false):
			var response := await _request(context[0],false)
			if context != _context(): return
			if response.get("ok",false):
				var remote := str(response.get("text",""))
				if remote.to_utf8_buffer().size()<=MAX_BYTES: _write_local(remote,local.stamp)
		if context == _context(): send.call()
	elif local.get("local",false):
		var response := await _request(context[0],true,text)
		if context != _context() or not _same_host(context): return
		if not response.get("ok",false):
			_status()
			return # Never paste unrelated old host contents after a failed write.
		_write_local(text,local.stamp)
		send.call()
	else:
		send.call() # Host-to-host paste: preserve its current clipboard.
