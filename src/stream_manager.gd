class_name StreamManager
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func start_stream(host_id: int, app_id: int):
	main._log("[STREAM] Starting stream host_id=%d app_id=%d" % [host_id, app_id])
	var stream_cfg = MoonlightStreamConfigurationResource.new()
	stream_cfg.set_width(1920)
	stream_cfg.set_height(1080)
	stream_cfg.set_fps(60)
	stream_cfg.set_bitrate(20000)
	var stream_opts = MoonlightAdditionalStreamOptions.new()
	stream_opts.set_disable_hw_acceleration(false)
	stream_opts.set_disable_audio(false)
	stream_opts.set_disable_video(false)
	stream_opts.set_video_codec(0)
	main.moon.set_render_target(main.stream_target)
	main.moon.start_play_stream(host_id, app_id, stream_cfg, stream_opts)
	main._log("[STREAM] start_play_stream called")
	await main.get_tree().create_timer(0.1).timeout
	bind_texture()

func on_pair_pressed():
	var ip = main.get_node("%IPInput").text
	main.get_node("%Numpad").visible = false
	if ip.is_empty(): ip = "127.0.0.1"
	var save = ConfigFile.new()
	save.set_value("connection", "ip", ip)
	save.save("user://last_connection.cfg")
	main.config_mgr.load_config()
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
	main.get_node("%StatusLabel").text = "%dx%d %s %.0ffps\n%s q:%d dec:%d drop:%d net:%d" % [vw, vh, hw, main.stats_fps, decoder, queue, decoded, dropped, main.stats_network_events]
