class_name StreamBackend
extends RefCounted

var _v2: Node = null

var config_mgr: RefCounted = null
var comp_mgr: RefCounted = null

signal log_message(msg: String)
signal connection_started
signal connection_terminated(err, msg)
signal pair_completed(success: bool, msg: String)

func _init(v2_node: Node):
	_v2 = v2_node

func set_config_manager(cm: RefCounted):
	config_mgr = cm
	if _v2:
		var nf_cm = _v2.get_config_manager()
		if nf_cm:
			nf_cm.load_config()

func set_computer_manager(cm: RefCounted):
	comp_mgr = cm

func get_config_manager() -> RefCounted:
	if _v2:
		var nf_cm = _v2.get_config_manager()
		if nf_cm:
			return nf_cm
	return config_mgr

func get_computer_manager() -> RefCounted:
	if _v2:
		var nf_cm = _v2.get_computer_manager()
		if nf_cm:
			return nf_cm
	return comp_mgr

func get_hosts() -> Array:
	var cm = get_config_manager()
	if cm:
		return cm.get_hosts()
	return []

func get_apps(host_id: int) -> Array:
	var cm = get_config_manager()
	if cm:
		return cm.get_apps(host_id)
	return []

func start_pair(ip: String, port: int = 47989) -> String:
	var cm = get_computer_manager()
	if cm:
		return cm.start_pair(ip, port)
	return ""

func get_app_list(host_id: int, callback: Callable):
	var cm = get_computer_manager()
	if cm:
		cm.get_app_list(host_id, callback)

func establish_stream(host_id: int, app_id: int, options: Dictionary, callback: Callable):
	var cm = get_computer_manager()
	if cm:
		cm.establish_stream(host_id, app_id, options, callback)

func start_stream_v2(host: String, server_info: Dictionary, stream_config: Dictionary, disable_hw: bool = false):
	if _v2:
		_v2.start_stream(host, server_info, stream_config, disable_hw)

func set_local_capture_mode(enabled: bool):
	if _v2 and _v2.has_method("set_local_capture_mode"):
		_v2.set_local_capture_mode(enabled)

func stop_play_stream():
	if _v2:
		_v2.stop_stream()

func cancel_host_stream(host_id: int):
	var cm = get_computer_manager()
	if not cm:
		return
	var hosts = get_hosts()
	var ip = ""
	var port = 47984
	for h in hosts:
		if h.has("id") and h.id == host_id:
			ip = h.get("localaddress", "")
			port = h.get("https_port", 47984)
			break
	if ip.is_empty():
		return
	cm.cancel_host_stream(host_id, ip, port)

func set_cursor_visible(host_id: int, visible: bool, callback: Callable):
	var cm = get_computer_manager()
	if cm:
		cm.set_cursor_visible(host_id, visible, callback)

func is_streaming() -> bool:
	if _v2:
		return _v2.get_state() == 2
	return false

func send_mouse_position_event(x: int, y: int, ref_w: int, ref_h: int):
	if _v2:
		_v2.get_input_bridge().send_mouse_position(x, y, ref_w, ref_h)

func send_mouse_move_event(dx: int, dy: int):
	if _v2:
		_v2.get_input_bridge().send_mouse_move(dx, dy)

func send_mouse_button_event(action: int, button: int):
	if _v2:
		if action == 7:
			_v2.get_input_bridge().send_mouse_button_pressed(button)
		else:
			_v2.get_input_bridge().send_mouse_button_released(button)

func send_keyboard_event(keycode: int, action: int, modifiers: int):
	if _v2:
		_v2.get_input_bridge().send_keyboard_event(keycode, action, modifiers)

func send_scroll_event(clicks: int):
	if _v2:
		_v2.get_input_bridge().send_scroll(clicks)

func send_multi_controller_event(device: int, active_mask: int, buttons: int, lt: int, rt: int, lx: int, ly: int, rx: int, ry: int):
	if _v2:
		_v2.get_input_bridge().send_multi_controller_event(device, active_mask, buttons, lt, rt, lx, ly, rx, ry)

func send_controller_arrival(device: int, active_mask: int, ctype: int, button_flags: int, capabilities: int):
	if _v2:
		_v2.get_input_bridge().send_controller_arrival(device, active_mask, ctype, button_flags, capabilities)

func get_decoder_name() -> String:
	if _v2:
		return _v2.get_decoder_name()
	return ""

func get_video_width() -> int:
	if _v2:
		return _v2.get_video_width()
	return 0

func get_video_height() -> int:
	if _v2:
		return _v2.get_video_height()
	return 0

func is_hw_decode() -> bool:
	if _v2:
		return _v2.is_hw_decode()
	return false

func get_frames_dropped() -> int:
	if _v2:
		return _v2.get_frames_dropped()
	return 0

func get_frames_decoded() -> int:
	if _v2:
		return _v2.get_frames_decoded()
	return 0

func get_decode_queue_size() -> int:
	if _v2:
		return _v2.get_decode_queue_size()
	return 0

func get_last_frame_latency() -> int:
	if _v2:
		return _v2.get_last_frame_latency_us()
	return 0

func set_depth_model(model_id: int):
	if _v2:
		var db = _v2.get_depth_bridge()
		if db:
			db.set_depth_model(model_id)

func submit_depth_frame(data: PackedByteArray, w: int, h: int):
	if _v2:
		var db = _v2.get_depth_bridge()
		if db:
			db.submit_depth_frame(data, w, h)

func get_depth_map() -> PackedByteArray:
	if _v2:
		var db = _v2.get_depth_bridge()
		if db:
			return db.get_depth_map()
	return PackedByteArray()

func probe_video_format(codec_pref: int, disable_hw: bool) -> int:
	if _v2:
		return _v2.probe_video_format(codec_pref, disable_hw)
	return 1

func probe_all_video_formats() -> Dictionary:
	if _v2 and _v2.has_method("probe_all_video_formats"):
		return _v2.probe_all_video_formats()
	var result = {}
	result["h264"] = true
	result["hevc"] = false
	result["av1"] = false
	result["raw"] = true
	return result

func get_server_codec_mode_support() -> int:
	if _v2 and _v2.has_method("get_server_codec_mode_support"):
		return _v2.get_server_codec_mode_support()
	return 0

func get_shader_material():
	if _v2:
		return _v2.get_shader_material()
	return null

func consume_new_frame() -> bool:
	if _v2:
		var uploader = _v2.get_texture_uploader()
		if uploader:
			return uploader.consume_new_frame()
	return false

func browse_mdns(timeout: float) -> Array:
	if ClassDB.class_exists("MdnsBrowser"):
		var mdns_browser = ClassDB.instantiate("MdnsBrowser")
		if mdns_browser:
			return mdns_browser.browse(timeout)
	return []
