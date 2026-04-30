class_name StreamManager
extends RefCounted

var main: Node3D
var http_request: HTTPRequest
var bitrate: int = 20000

func _init(owner: Node3D):
	main = owner

func start_stream(host_id: int, app_id: int):
	var w = main.host_resolution.x
	var h = main.host_resolution.y
	main._log("[STREAM] Starting stream host_id=%d app_id=%d res=%dx%d@%d" % [host_id, app_id, w, h, main.stream_fps])
	bitrate = 20000
	if w >= 3840:
		bitrate = 80000
	elif w >= 2560:
		bitrate = 40000
	var stream_cfg = MoonlightStreamConfigurationResource.new()
	stream_cfg.set_width(w)
	stream_cfg.set_height(h)
	stream_cfg.set_fps(main.stream_fps)
	stream_cfg.set_bitrate(bitrate)
	var stream_opts = MoonlightAdditionalStreamOptions.new()
	stream_opts.set_disable_hw_acceleration(false)
	stream_opts.set_disable_audio(false)
	stream_opts.set_disable_video(false)
	stream_opts.set_video_codec(0)
	main.moon.set_render_target(main.stream_target)
	main.moon.start_play_stream(host_id, app_id, stream_cfg, stream_opts)
	main._log("[STREAM] start_play_stream called (%dx%d@%d %dMbps)" % [w, h, main.stream_fps, bitrate])
	await main.get_tree().create_timer(0.1).timeout
	bind_texture()

func query_host_resolution(ip: String):
	if http_request == null:
		http_request = HTTPRequest.new()
		http_request.timeout = 5.0
		main.add_child(http_request)
		http_request.request_completed.connect(_on_serverinfo_response)
	var url = "http://%s:47989/serverinfo" % ip
	main._log("[RES] Querying host resolution: %s" % url)
	var err = http_request.request(url)
	main._log("[RES] HTTP request error: %d (OK=%d)" % [err, OK])
	await main.get_tree().create_timer(5.0).timeout
	if main.resolution_idx == -1 and main.host_resolution == Vector2i(1920, 1080):
		main._log("[RES] HTTP failed, trying comp_mgr")
		_try_comp_mgr_resolution()
	main._log("[RES] Final resolution: %dx%d" % [main.host_resolution.x, main.host_resolution.y])

func _try_comp_mgr_resolution():
	var hosts = main.config_mgr.get_hosts()
	main._log("[RES] comp_mgr hosts count: %d" % hosts.size())
	for h in hosts:
		main._log("[RES] host: id=%d name=%s" % [h.id if h.has("id") else -1, h.name if h.has("name") else "?"])
		if h.has("localaddress") and h.localaddress != "":
			main._log("[RES] Found host with address: %s" % h.localaddress)

func _on_serverinfo_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
	main._log("[RES] Response: result=%d code=%d body_len=%d" % [_result, code, body.size()])
	if code != 200 or body.size() == 0:
		main._log("[RES] serverinfo request failed (result=%d code=%d)" % [_result, code])
		return
	var xml = body.get_string_from_utf8()
	main._log("[RES] serverinfo full XML: %s" % xml)
	var display_data = _extract_display_info(xml)
	if display_data != Vector2i.ZERO:
		if main.resolution_idx == -1:
			main.host_resolution = display_data
		main._log("[RES] Detected host resolution: %dx%d" % [display_data.x, display_data.y])
		main.get_node("%StatusLabel").text = "Host: %dx%d" % [display_data.x, display_data.y]
	else:
		main._log("[RES] Could not detect resolution from XML, using default 1920x1080")

func _extract_display_info(xml: String) -> Vector2i:
	if xml.find("<Display0>") == -1 and xml.find("<display0>") == -1:
		main._log("[RES] No Display0 tag in XML")
		var hevc_match = xml.find("<MaxLumaPixelsHEVC>")
		if hevc_match >= 0:
			var start = hevc_match + len("<MaxLumaPixelsHEVC>")
			var end = xml.find("</MaxLumaPixelsHEVC>", start)
			if end > start:
				var pixels = xml.substr(start, end - start).to_int()
				main._log("[RES] MaxLumaPixelsHEVC: %d" % pixels)
				if pixels >= 8847360:
					return Vector2i(3840, 2160)
				elif pixels >= 3686400:
					return Vector2i(2560, 1440)
		return Vector2i.ZERO
	var display_idx = 0
	while true:
		var tag_open = "<Display%d>" % display_idx
		var start = xml.find(tag_open)
		if start == -1:
			break
		start += tag_open.length()
		var tag_close = "</Display%d>" % display_idx
		var end = xml.find(tag_close, start)
		if end == -1:
			break
		var value = xml.substr(start, end - start).strip_edges()
		main._log("[RES] Display%d raw: '%s'" % [display_idx, value])
		var parts = value.split("x")
		if parts.size() >= 2:
			var w = parts[0].to_int()
			var h = parts[1].to_int()
			if w > 0 and h > 0:
				return Vector2i(w, h)
		display_idx += 1
	return Vector2i.ZERO

func on_pair_pressed():
	var ip = main.get_node("%IPInput").text
	main.get_node("%Numpad").visible = false
	if ip.is_empty(): ip = "127.0.0.1"
	var save = ConfigFile.new()
	save.set_value("connection", "ip", ip)
	save.save("user://last_connection.cfg")
	main.config_mgr.load_config()
	await query_host_resolution(ip)
	var paired_host_id = -1
	for h in main.config_mgr.get_hosts():
		if h.has("localaddress") and h.localaddress == ip:
			paired_host_id = h.id
			break
	if paired_host_id != -1:
		main.current_host_id = paired_host_id
		main.get_node("%StatusLabel").text = "Already paired, starting stream..."
		await start_stream(paired_host_id, 881448767)
	else:
		main.get_node("%StatusLabel").text = "Pairing with " + ip + "..."
		main._log("[PAIR] Starting pair with %s:47989..." % ip)
		var pin = main.comp_mgr.start_pair(ip, 47989)
		main._log("[PAIR] start_pair returned: %s (type=%s)" % [str(pin), str(typeof(pin))])
		if str(pin) == "" or str(pin) == "0":
			main.get_node("%StatusLabel").text = "Failed to connect to " + ip
			main.get_node("%PairButton").text = "Pair & Start Stream"
			main.get_node("%PairButton").disabled = false
			main._log("[PAIR] FAILED - no pin returned")
			return
		main.get_node("%StatusLabel").text = "PIN: " + str(pin) + "\nEnter on Sunshine host"
		main.get_node("%PairButton").text = "Waiting for pair..."
		main.get_node("%PairButton").disabled = true

func on_pair_completed(success: bool, _msg: String):
	main._log("[PAIR] pair_completed: success=%s msg=%s" % [str(success), str(_msg)])
	main.get_node("%StatusLabel").text = "Pair " + ("OK" if success else "FAILED: " + str(_msg))
	main.get_node("%PairButton").text = "Pair & Start Stream"
	main.get_node("%PairButton").disabled = false
	if success:
		main.get_node("%StatusLabel").text = "Pairing successful, starting stream..."
		main.config_mgr.load_config()
		var ip = main.get_node("%IPInput").text
		for h in main.config_mgr.get_hosts():
			if h.localaddress == ip:
				main.current_host_id = h.id
				await start_stream(h.id, 881448767)
				break

func setup_audio():
	var audio_stream = main.moon.get_audio_stream()
	if audio_stream:
		main.audio_player.stream = audio_stream
		main.audio_player.play()
		print("Audio Stream Started")

func bind_texture():
	var stream_tex = main.stream_viewport.get_texture()
	main.screen_mesh.material_override.set_shader_parameter("main_texture", stream_tex)
	main.detection_target.texture = stream_tex
	if main.depth_estimator:
		main.depth_estimator.bind_stream_texture()
	var ui_tex = main.ui_viewport.get_texture()
	main.ui_panel_3d.material_override.albedo_texture = ui_tex

func update_stats():
	if not main.is_streaming or not main.moon.has_method("get_decoder_name"):
		return
	var decoder = main.moon.get_decoder_name()
	var vw = main.moon.get_video_width()
	var vh = main.moon.get_video_height()
	var hw = "HW" if main.moon.is_hw_decode() else "SW"
	var queue = main.moon.get_decode_queue_size()
	var decoded = main.moon.get_frames_decoded()
	var dropped = main.moon.get_frames_dropped()
	main.get_node("%StatusLabel").text = "%dx%d %s %.0ffps/%dHz %dMbps\n%s q:%d dec:%d drop:%d net:%d" % [vw, vh, hw, main.stats_fps, main.stream_fps, bitrate / 1000, decoder, queue, decoded, dropped, main.stats_network_events]
