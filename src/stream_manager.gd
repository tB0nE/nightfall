class_name StreamManager
extends RefCounted

var main: Node3D
var bitrate: int = 20000
var _v2_yuv_rect: ColorRect = null
var local_capture_mode: bool = false

func _init(owner: Node3D):
	main = owner

func _b() -> StreamBackend:
	return main.stream_backend

func _is_local_host(ip: String) -> bool:
	if ip == "127.0.0.1" or ip == "::1" or ip.to_lower() == "localhost":
		return true
	for addr in IP.get_local_addresses():
		if addr == ip:
			return true
	return false

# Set on the very first connect attempt of a session; cleared once a resolution-mismatch
# retry has happened, so we never retry more than once even if the manifest still doesn't
# match afterwards (e.g. a host that free-scales regardless of requested resolution).
var _resolution_retry_done: bool = false
var _current_host_id: int = -1
var _current_app_id: int = -1

func start_stream(host_id: int, app_id: int, forced_resolution: Vector2i = Vector2i.ZERO):
	_current_host_id = host_id
	_current_app_id = app_id
	# forced_resolution set means this call IS the one-shot correction retry itself -
	# don't reset the guard there, or a host that never matches would loop forever.
	if forced_resolution == Vector2i.ZERO:
		_resolution_retry_done = false
	var ip = ""
	for h_host in _b().get_hosts():
		if h_host.get("id") == host_id:
			ip = h_host.get("localaddress", "")
			break

	local_capture_mode = _is_local_host(ip)
	if local_capture_mode:
		main._log("[STREAM] Localhost detected! Enabling local capture mode (%s)" % ("Wayland" if OS.get_environment("WAYLAND_DISPLAY") else "X11"))
		_b().set_local_capture_mode(true)
		if _b()._v2 and _b()._v2.has_method("set_restore_token"):
			_b()._v2.set_restore_token(main.pipewire_restore_token)
	else:
		_b().set_local_capture_mode(false)

	var w = main.host_resolution.x
	var h = main.host_resolution.y
	if forced_resolution.x > 0 and forced_resolution.y > 0:
		w = forced_resolution.x
		h = forced_resolution.y
		main._log("[STREAM] Reconnecting with corrected resolution %dx%d (was %dx%d)" % [w, h, main.host_resolution.x, main.host_resolution.y])
	elif main.double_h:
		w *= 2

	main._log("[STREAM] Starting stream host_id=%d app_id=%d res=%dx%d@%d local=%s" % [host_id, app_id, w, h, main.stream_fps, str(local_capture_mode)])
	if main.bitrate_idx >= 0:
		bitrate = main.bitrates[main.bitrate_idx] * 1000
	else:
		bitrate = _auto_bitrate(w, h)
	resize_stream_viewport(w, h)
	var options = {}
	if local_capture_mode:
		options["width"] = 320
		options["height"] = 240
		options["fps"] = 10
		options["bitrate"] = 2000
	else:
		options["width"] = w
		options["height"] = h
		options["fps"] = main.stream_fps
		options["bitrate"] = bitrate
	options["packet_size"] = 1024
	options["streaming_remotely"] = 2
	options["surroundAudioInfo"] = 0xCA0203
	var capture_outputs = _compute_capture_outputs()
	main._log("[STREAM] capture_outputs computed: '%s' (layout.source=%s, enabled=%s)" % [
		capture_outputs, str(main.layout.source) if main.layout else "null",
		str(main.layout.enabled_monitors().map(func(m): return m.label)) if main.layout else "null"])
	if not capture_outputs.is_empty():
		options["capture_outputs"] = capture_outputs
	main._ui_status_label.text = "Launching stream..."
	_b().establish_stream(host_id, app_id, options, _on_v2_launch_response)
	main._log("[STREAM] establish_stream called")

# Comma-separated real RandR output names (e.g. "DP-0,DP-2") for whichever
# monitors are currently enabled in main.layout, matching Polaris's new
# per-session outputs= launch/resume param. Sending this - even listing every
# currently-known output - activates multi-monitor capture on the host
# regardless of its static linux_multi_monitor_capture config, so the client
# always gets exactly what it asked for instead of depending on the host's
# own toggle. Returns "" when main.layout isn't real manifest-derived data yet
# (source stays at the class default "client_split" for every client-side
# placeholder - single()/split_h()/replicate(), including the aspect-mismatch
# reset in resize_stream_viewport()) - in that case the launch just omits the
# param and the host falls back to its static config, same as before this
# existed. Checking label.is_empty() alone isn't enough: single()'s placeholder
# monitor has a non-empty but FAKE label ("Display", not a real RandR name) -
# sending that as outputs= matches no real host output, and the host reports
# back zero enabled monitors and falls back to combined/undivided capture.
func _compute_capture_outputs() -> String:
	if not main.layout or main.layout.source != &"host_manifest":
		return ""
	var labels: Array = []
	for m in main.layout.enabled_monitors():
		if m.label.is_empty():
			return ""
		labels.append(m.label)
	return ",".join(labels)

func _on_v2_launch_response(response: Dictionary):
	if response.get("status", "") != "success":
		var msg = response.get("message", "unknown")
		main._log("[STREAM] Launch failed: %s" % msg)
		if msg.find("Session URL not found") != -1:
			main._log("[PAIR] Launch failed due to stale pairing, re-pairing...")
			var ip = ""
			for h in _b().get_hosts():
				if h.get("id") == main.current_host_id:
					ip = h.get("localaddress", "")
					break
			if not ip.is_empty():
				_b().get_config_manager().remove_host(main.current_host_id)
				main._ui_status_label.text = "Re-pairing with " + ip + "..."
				var pin = _b().start_pair(ip, 47989)
				if str(pin) != "" and str(pin) != "0":
					main._pair_pin = str(pin)
					main.welcome_screen.show_welcome_screen("pin")
					return
			main._ui_status_label.text = "Pairing needed. Please re-select server."
			main.welcome_screen.show_welcome_screen("server")
		else:
			main._ui_status_label.text = "Launch failed: " + str(msg)
			main.welcome_screen.show_welcome_screen("server")
		return

	var server_info = {}
	server_info["server_codec_mode_support"] = response.get("server_codec_mode_support", 0)
	var scm = response.get("server_codec_mode_support", 0)
	main._server_codec_support = {
		"h264": (scm & 0x01) != 0,
		"hevc": (scm & 0x0300) != 0,
		"av1": (scm & 0x030000) != 0,
		"raw": (scm & 0x01000000) != 0,
	}
	main._log("[CODEC] Server SCM=0x%x: h264=%s hevc=%s av1=%s raw=%s" % [
		scm,
		str(main._server_codec_support.get("h264", false)),
		str(main._server_codec_support.get("hevc", false)),
		str(main._server_codec_support.get("av1", false)),
		str(main._server_codec_support.get("raw", false))])
	if not main.settings_controller.is_codec_available(main.codec_preference):
		main.settings_controller.fallback_codec()
		main.ui_controller.update_codec_btn()
	server_info["rtsp_session_url"] = response.get("session_url", "")
	server_info["server_app_version"] = response.get("app_version", "")
	server_info["server_gfe_version"] = response.get("gfe_version", "")

	var w = response.get("width", 1920)
	var h = response.get("height", 1080)
	var fps = main.stream_fps
	var br = response.get("bitrate", 20000)

	var stream_config = {}
	if local_capture_mode:
		stream_config["width"] = 320
		stream_config["height"] = 240
		stream_config["fps"] = 10
		stream_config["bitrate"] = 2000
	else:
		stream_config["width"] = w
		stream_config["height"] = h
		stream_config["fps"] = fps
		stream_config["bitrate"] = br
	stream_config["packet_size"] = response.get("packet_size", 1024)
	stream_config["streaming_remotely"] = response.get("streaming_remotely", 2)
	stream_config["audio_configuration"] = response.get("audio_configuration", 0x0302CA)
	var codec_pref = main.codec_preference
	if codec_pref == 3:
		stream_config["supported_video_formats"] = 0x10000
	else:
		var family_map = [1, 2, 3]
		stream_config["supported_video_formats"] = _b().probe_video_format(family_map[codec_pref], false)
	stream_config["color_space"] = 1
	stream_config["color_range"] = 0
	stream_config["encryption_flags"] = 0xFFFFFFFF
	stream_config["client_refresh_rate_x100"] = int(main.display_refresh_rate * 100)

	var rikey_raw = response.get("rikey_raw", PackedByteArray())
	var rikeyid = response.get("rikeyid", 0)
	if rikey_raw.size() == 16:
		stream_config["remote_input_aes_key"] = rikey_raw
		var iv = PackedByteArray()
		iv.resize(16)
		iv.fill(0)
		iv[0] = (rikeyid >> 24) & 0xFF
		iv[1] = (rikeyid >> 16) & 0xFF
		iv[2] = (rikeyid >> 8) & 0xFF
		iv[3] = rikeyid & 0xFF
		stream_config["remote_input_aes_iv"] = iv

	var manifest = response.get("manifest", {})
	if manifest is Dictionary and not manifest.is_empty():
		var host_layout = ScreenLayout.from_dict(manifest)
		var layout_err = host_layout.validate(host_layout.frame_size)
		if layout_err == "":
			main._log("[LAYOUT] Host manifest received: %d monitor(s), frame=%dx%d" % [host_layout.monitors.size(), host_layout.frame_size.x, host_layout.frame_size.y])
			main.settings_controller.apply_screen_layout(host_layout)
		else:
			main._log("[LAYOUT] Host manifest invalid, ignoring: %s" % layout_err)

	main._host_cursor_toggle_supported = response.get("cursor_supported", false)
	main.host_cursor_visible = response.get("cursor_visible", false)
	main.ui_controller.update_host_cursor_btn_state()

	var ip = response.get("ip", "")
	_b().start_stream_v2(ip, server_info, stream_config, false)
	main._log("[STREAM] start_stream called (%dx%d@%d %dMbps)" % [w, h, fps, br])

func _auto_bitrate(w: int, h: int) -> int:
	var pixels = w * h
	if pixels >= 3840 * 2160:
		return 80000
	elif pixels >= 2560 * 1440:
		return 40000
	elif pixels >= 3440 * 1440:
		return 50000
	elif pixels >= 1920 * 1080:
		return 20000
	elif pixels >= 1600 * 1200:
		return 20000
	else:
		return 10000

func resize_stream_viewport(w: int, h: int):
	main.stream_viewport.size = Vector2i(w, h)
	main.stream_target.custom_minimum_size = Vector2(w, h)
	if _v2_yuv_rect:
		_v2_yuv_rect.custom_minimum_size = Vector2(w, h)
	# comp_viewport/_left/_right/comp_base_size alias to the PRIMARY screen only;
	# every screen's own composite viewport must track the actual decoded
	# resolution too, or secondary screens stay stuck at their setup_screen()
	# default (1920x1080) and look soft once the stream exceeds that.
	for s in main.screens:
		if s.comp_viewport:
			s.comp_viewport.size = Vector2i(w, h)
		if s.comp_viewport_left:
			s.comp_viewport_left.size = Vector2i(w, h)
		if s.comp_viewport_right:
			s.comp_viewport_right.size = Vector2i(w, h)
		s.comp_base_size = Vector2i(w, h)
	main.comp.update_bezel()
	if main.comp_layer and main.comp_layer is OpenXRCompositionLayerQuad:
		main.comp_layer.set_quad_size(main._mesh_size)
	var new_frame = Vector2i(w, h)
	var layout_changed := false
	# This runs immediately on start_stream(), before the host's real per-session
	# manifest has arrived - main.layout at this point is still whatever the
	# welcome screen last set it to (a 16:9 single-screen placeholder), not the
	# real multi-monitor layout, so its aspect essentially never matches a wide
	# multi-monitor request. Eagerly "fixing" that here used to squish
	# everything onto one screen for the brief window until the manifest
	# response arrives moments later and correctly re-splits it - a visible
	# squish-then-split glitch on every connect. local_capture_mode never gets
	# a manifest at all, so it still needs this eager guess; every other host
	# is about to send one via the launch response's _on_v2_launch_response()
	# handler regardless, making this guess pure churn - skip straight to
	# waiting for the real data instead of rendering a wrong intermediate one.
	if local_capture_mode and main.layout.frame_size != new_frame:
		layout_changed = true
		var old_aspect = float(main.layout.frame_size.x) / float(main.layout.frame_size.y) if main.layout.frame_size.y > 0 else 1.0
		var new_aspect = float(w) / float(h) if h > 0 else 1.0
		if absf(old_aspect - new_aspect) < 0.01:
			var rescaled = main.layout.rescale_to(new_frame)
			if rescaled.validate(new_frame) == "":
				main.settings_controller.apply_screen_layout(rescaled)
			else:
				main._log("[LAYOUT] Rescale produced an invalid layout, resetting to single()")
				main.settings_controller.apply_screen_layout(ScreenLayout.single(new_frame))
		else:
			main._log("[LAYOUT] Stream aspect changed (%.3f -> %.3f), resetting display layout to single()" % [old_aspect, new_aspect])
			main.settings_controller.apply_screen_layout(ScreenLayout.single(new_frame))
			main._ui_status_label.text = "Display layout reset: stream resolution changed"
	if not layout_changed:
		main.screen_manager.resize_screen_to_aspect(w, h)
	for s in main.screens:
		if s.material_override is ShaderMaterial:
			s.material_override.set_shader_parameter("blur_scale", main.get_blur_scale(s))
		for cm in main.comp.get_shader_mats(s):
			if cm:
				cm.set_shader_parameter("blur_scale", main.get_blur_scale(s))
	main._log("[STREAM] Viewport resized to %dx%d (blur_scale=%.2f)" % [w, h, main.get_blur_scale(main.primary_screen)])

func on_pair_pressed():
	var ip = main.get_node("%IPInput").text
	main.get_node("%Numpad").visible = false
	if ip.is_empty(): ip = "127.0.0.1"
	var save = ConfigFile.new()
	save.set_value("connection", "ip", ip)
	save.save("user://last_connection.cfg")
	if _b().get_config_manager():
		_b().get_config_manager().load_config()
	var paired_host_id = -1
	for h in _b().get_hosts():
		if h.has("localaddress") and h.localaddress == ip:
			paired_host_id = h.id
			break
	if paired_host_id != -1:
		main.current_host_id = paired_host_id
		main._ui_status_label.text = "Connecting..."
		# Used to await host_discovery.query_host_resolution() here, which blindly
		# sleeps 5s every connect regardless of whether its (single-monitor-only,
		# not multi-monitor-aware) HTTP probe already answered. Superseded by
		# native_resolution/resolution_scale_pct - the host's real desktop size
		# comes from its display manifest (or the negotiated launch resolution)
		# once actually connecting, and gets cached per-host for next time.
		await start_stream(paired_host_id, main._selected_app_id)
	else:
		main._ui_status_label.text = "Pairing with " + ip + "..."
		main._log("[PAIR] Starting pair with %s:47989..." % ip)
		var pin = _b().start_pair(ip, 47989)
		main._log("[PAIR] start_pair returned: %s (type=%s)" % [str(pin), str(typeof(pin))])
		if str(pin) == "" or str(pin) == "0":
			main._ui_status_label.text = "Failed to connect to " + ip
			main._log("[PAIR] FAILED - no pin returned")
			main.welcome_screen.show_welcome_screen("server")
			return
		main._pair_pin = str(pin)
		main.welcome_screen.show_welcome_screen("pin")

func on_pair_completed(success: bool, _msg: String):
	main._log("[PAIR] pair_completed: success=%s msg=%s" % [str(success), str(_msg)])
	if not success:
		main._ui_status_label.text = "Pair FAILED: " + str(_msg)
		main.welcome_screen.show_welcome_screen("server")
		return
	main._ui_status_label.text = "Pairing successful, starting stream..."
	if _b().get_config_manager():
		_b().get_config_manager().load_config()
	var ip = main.get_node("%IPInput").text
	var found = false
	for h in _b().get_hosts():
		if h.has("localaddress") and h.localaddress == ip:
			main.current_host_id = h.id
			found = true
			await start_stream(h.id, main._selected_app_id)
			break
	if not found:
		main._log("[PAIR] Host not found after pairing, retrying config load")
		_b().get_config_manager().load_config()
		for h in _b().get_hosts():
			if h.has("localaddress") and h.localaddress == ip:
				main.current_host_id = h.id
				found = true
				await start_stream(h.id, main._selected_app_id)
				break
	if not found:
		main._ui_status_label.text = "Pair OK but host not found"
		main.welcome_screen.show_welcome_screen("server")

var _mdns_result: Array = []

func browse_mdns() -> Array:
	main._log("[mDNS] Starting browse...")
	_mdns_result = []
	var thread = Thread.new()
	thread.start(func():
		_mdns_result = _b().browse_mdns(3.0)
	)
	while thread.is_alive():
		await main.get_tree().create_timer(0.1).timeout
	thread.wait_to_finish()
	main._log("[mDNS] Found %d hosts" % _mdns_result.size())
	return _mdns_result

func bind_texture():
	var stream_tex
	if main.comp.in_use and main.comp_viewport:
		stream_tex = main.comp_viewport.get_texture()
	else:
		stream_tex = main.stream_viewport.get_texture()
	main.detection_target.texture = stream_tex
	if main.depth_estimator:
		main.depth_estimator.bind_stream_texture()
	_setup_v2_yuv_rect()
	var ui_tex = main.ui_viewport.get_texture()
	main.ui_panel_3d.material_override.albedo_texture = ui_tex

func _setup_v2_yuv_rect():
	if _v2_yuv_rect:
		return
	var mat = _b().get_shader_material()
	if not mat:
		main._log("[STREAM] No shader material from TextureUploader yet - will retry")
		return
	_v2_yuv_rect = ColorRect.new()
	_v2_yuv_rect.name = "V2YuvRect"
	_v2_yuv_rect.material = mat
	_v2_yuv_rect.anchors_preset = Control.PRESET_FULL_RECT
	_v2_yuv_rect.custom_minimum_size = Vector2(main.stream_viewport.size)
	main.stream_target.visible = false
	main.stream_viewport.add_child(_v2_yuv_rect)
	main._log("[STREAM] YUV ColorRect added to StreamViewport")
	
	# Force shader params immediately (Godot may duplicate the material on assignment)
	_update_yuv_shader_params()

func _update_yuv_shader_params():
	if not _v2_yuv_rect or not _v2_yuv_rect.material:
		return
	var mat = _v2_yuv_rect.material
	if not mat is ShaderMaterial:
		return
	if local_capture_mode or OS.get_name() == "Android":
		mat.set_shader_parameter("color_matrix_type", 3)
		mat.set_shader_parameter("color_range", 1)
		mat.set_shader_parameter("is_semi_planar", false)
		mat.set_shader_parameter("is_nv12_rd", false)

func teardown_v2_yuv_rect():
	if _v2_yuv_rect:
		_v2_yuv_rect.queue_free()
		_v2_yuv_rect = null
	main.stream_target.visible = true

func update_stats():
	if not main.is_streaming:
		return
	if not main._ui_status_label:
		return
	if not _v2_yuv_rect:
		_setup_v2_yuv_rect()
	_update_yuv_shader_params()
	main.comp.bind_yuv_textures()  # Re-bind after compute pipeline may have updated tex_y
	var new_frame = _b().consume_new_frame()
	var vw = _b().get_video_width()
	var vh = _b().get_video_height()
	if vw == 0 or vh == 0:
		return
	var cur_size = main.stream_viewport.size
	if cur_size.x != vw or cur_size.y != vh:
		resize_stream_viewport(vw, vh)
	var hw = "HW" if _b().is_hw_decode() else "SW"
	var ip = main.get_node("%IPInput").text
	var ip_display = ip if not ip.is_empty() else "?"
	var dropped = _b().get_frames_dropped()
	var decoded = _b().get_frames_decoded()
	var latency_ms = _b().get_last_frame_latency() / 1000.0
	var bitrate_mbps = bitrate / 1000.0
	var refresh_hz = main.display_refresh_rate
	var codec_name = main.codec_labels[main.codec_preference] if main.codec_preference < main.codec_labels.size() else "?"
	if decoded > 0 and not new_frame:
		main._log("[STREAM] Frames decoded=%d but no new frame consumed!" % decoded)
	var txt = ip_display + " \u2022 " + str(vw) + "x" + str(vh) + " " + str(main.stream_fps) + "fps " + str(int(bitrate_mbps)) + "Mbps " + codec_name + " " + hw
	txt += " \u2022 " + str(int(latency_ms)) + "ms"
	txt += " \u2022 " + str(int(refresh_hz)) + "Hz \u2022 " + str(int(main.stats_fps)) + "fps"
	if dropped > 0:
		txt += " \u2022 drop:" + str(dropped)
	if main.controller_mapper and main.controller_mapper.is_active():
		txt += " \u2022 " + main.controller_mapper.get_mode_label()
		if main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD and main.controller_mapper.get_close_to_head():
			txt += " D-PAD"
	main._ui_status_label.text = txt
