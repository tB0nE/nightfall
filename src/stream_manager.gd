class_name StreamManager
extends RefCounted

var main: Node3D
var bitrate: int = 20000
var _v2_yuv_rect: ColorRect = null
var local_capture_mode: bool = false
var current_stream_size := Vector2i(1920, 1080)

func _init(owner: Node3D):
	main = owner

func _b() -> StreamBackend:
	return main.stream_backend

func get_current_stream_size() -> Vector2i:
	return current_stream_size

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
	main.session_lifecycle.begin_connect()
	_current_host_id = host_id
	_current_app_id = app_id
	# Host-specific FPS is loaded after OpenXR's initial startup refresh-rate
	# setup. Apply it again at the actual connection boundary so a saved
	# 144/165/200/207 FPS selection is reflected both on the panel and in
	# client_refresh_rate_x100 before the Moonlight session is configured.
	# Awaited (2026-09-05, merge) - apply_display_refresh_rate() is now async
	# (verifies the requested rate actually took before returning). Select
	# the headset's refresh rate before the decoder and native OpenXR
	# swapchain allocate any GLES resources; changing it afterward can
	# recreate Quest's runtime surface underneath those resources - the
	# function's own target_already_active check avoids re-requesting a rate
	# that's already active, which is what protects that ordering here.
	await main.settings_controller.apply_display_refresh_rate()
	# forced_resolution set means this call IS the one-shot correction retry itself -
	# don't reset the guard there, or a host that never matches would loop forever.
	if forced_resolution == Vector2i.ZERO:
		_resolution_retry_done = false
	var ip = ""
	for h_host in _b().get_hosts():
		if h_host.get("id") == host_id:
			ip = h_host.get("localaddress", "")
			break

	# The experimental same-machine X11/PipeWire capture path is opt-in for
	# now. Its X11 implementation performs a full-frame CPU channel conversion
	# and GPU upload, which capped a 2560x1440/120 session near 80fps in real
	# testing. Prefer Sunshine's normal encode/decode path until local capture
	# has a genuinely zero-copy presentation path.
	var is_local := _is_local_host(ip)
	local_capture_mode = is_local \
		and OS.get_environment("NIGHTFALL_ENABLE_LOCAL_CAPTURE") != "" \
		and OS.get_environment("NIGHTFALL_DISABLE_LOCAL_CAPTURE") == ""
	if is_local and not local_capture_mode:
		main._log("[STREAM] Local capture disabled; using normal Sunshine decode path (set NIGHTFALL_ENABLE_LOCAL_CAPTURE=1 to test it)")
	if local_capture_mode:
		main._log("[STREAM] Localhost detected! Enabling local capture mode (%s)" % ("Wayland" if OS.get_environment("WAYLAND_DISPLAY") else "X11"))
		_b().set_local_capture_mode(true)
		if _b()._v2 and _b()._v2.has_method("set_restore_token"):
			_b()._v2.set_restore_token(main.settings.pipewire_restore_token)
	else:
		_b().set_local_capture_mode(false)

	var w = main.host_resolution.x
	var h = main.host_resolution.y
	if forced_resolution.x > 0 and forced_resolution.y > 0:
		w = forced_resolution.x
		h = forced_resolution.y
		main._log("[STREAM] Reconnecting with corrected resolution %dx%d (was %dx%d)" % [w, h, main.host_resolution.x, main.host_resolution.y])
	elif main.settings.host.double_h:
		w *= 2

	main._log("[STREAM] Starting stream host_id=%d app_id=%d res=%dx%d@%d local=%s" % [host_id, app_id, w, h, main.settings.host.stream_fps, str(local_capture_mode)])
	if main.settings.host.bitrate_idx >= 0:
		bitrate = main.bitrates[main.settings.host.bitrate_idx] * 1000
	else:
		# Auto bitrate picks its tier from the UNCAPPED resolution, not w/h
		# above - w/h can be reduced by the MiDaS-Fast resolution cap
		# (settings_controller.gd's AUTO_TABLE cap_px, applied in main.gd's
		# compute_requested_resolution()), which is meant to trade pixels
		# for FPS, not ALSO cut the bitrate. _auto_bitrate() keying off the
		# capped w/h used to do both at once (confirmed via logs: capping to
		# 3712x2088 or 2560x1440 both dropped bitrate from 80000 to 40000),
		# which starved the video of real detail and degraded MiDaS-Fast's
		# depth quality well beyond what the resolution cut alone
		# would explain (see compute_requested_resolution()'s apply_midas_cap
		# param). Same bitrate at fewer pixels means MORE bits per pixel.
		var bitrate_ref = main.compute_requested_resolution(false)
		bitrate = _auto_bitrate(bitrate_ref.x, bitrate_ref.y)
		if main.settings.codec_preference == 4:
			# PyroWave is intra-only (every frame is a full I-frame, no
			# inter-frame compression), so it needs substantially more
			# bitrate than HEVC for equivalent quality - confirmed starved
			# at HEVC's auto value (80Mbps at 1440p120): host-side testing
			# needed ~200Mbps (2.5x) to look right. 3x wasn't enough headroom
			# in practice - frames started dropping fast at higher
			# resolution/fps, so bumped to 4x. Bypasses the normal
			# auto-bitrate ceiling since that cap was tuned for
			# inter-frame codecs.
			bitrate = clampi(bitrate * 4, AUTO_BITRATE_MIN_KBPS, AUTO_BITRATE_MAX_KBPS * 4)
		main._log("[STREAM] Auto bitrate: %dx%d@%d -> %.0fMbps" % [
			bitrate_ref.x, bitrate_ref.y, main.settings.host.stream_fps, float(bitrate) / 1000.0])
	resize_stream_viewport(w, h)
	var options = {}
	if local_capture_mode:
		# Negotiated at the REAL resolution now, not a 320x240 dummy
		# (2026-08-21 fix attempt) - theory: Sunshine sizes its OWN capture
		# surface (and therefore what it scales incoming absolute mouse
		# events against, via LiSendMousePositionEvent's refWidth/refHeight)
		# off the NEGOTIATED stream dimensions, not off Nightfall's separate
		# local X11 capture. A 320x240 negotiation would mean Sunshine's own
		# internal mouse-scaling reference is 320x240 regardless of what
		# ref we send - explaining a scale-correct-at-center-wrong-at-edges
		# mismatch even though every client-side coordinate (uv, host_pt,
		# ref itself) has been independently verified correct this session.
		# Local capture never actually DISPLAYS this negotiated stream
		# (real pixels come from x11_capture.cpp's zero-copy grab instead),
		# so full resolution costs nothing but negotiation/decode overhead -
		# fps/bitrate stay minimal since the decoded frames are discarded.
		options["width"] = w
		options["height"] = h
		options["fps"] = 5
		options["bitrate"] = 500
	else:
		options["width"] = w
		options["height"] = h
		options["fps"] = main.settings.host.stream_fps
		options["bitrate"] = bitrate
	options["packet_size"] = 1024
	options["streaming_remotely"] = 2
	options["surroundAudioInfo"] = 0xCA0203
	if hdr_requested():
		options["hdr_mode"] = 1
	var capture_outputs = _compute_capture_outputs()
	main._log("[STREAM] capture_outputs computed: '%s' (layout.source=%s, enabled=%s)" % [
		capture_outputs, str(main.layout.source) if main.layout else "null",
		str(main.layout.enabled_monitors().map(func(m): return m.label)) if main.layout else "null"])
	if not capture_outputs.is_empty():
		options["capture_outputs"] = capture_outputs
	_meteor = {}
	if not local_capture_mode and not _meteor_bypass:
		_meteor = await _probe_meteor(host_id)
	_meteor_bypass = false
	if not _meteor.is_empty():
		options[MeteorClient.HTTPS_PORT_OPTION] = int(_meteor["ports"]["https"])
	main._ui_status_label.text = "Launching stream..."
	_b().establish_stream(host_id, app_id, options, _on_v2_launch_response)
	main._log("[STREAM] establish_stream called")

# HDR needs a 10-bit codec (HEVC or AV1) and, for now, Android: Quest's
# MediaCodec -> SurfaceTexture path samples 10-bit frames natively, while the
# desktop FFmpeg upload only handles 8-bit NV12/YUV420P.
func hdr_requested() -> bool:
	return main.settings.hdr_enabled and OS.get_name() == "Android" \
		and (main.settings.codec_preference == 1 or main.settings.codec_preference == 2)

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
		# Client-side-only virtual monitor placeholders (Monitors tab "Virtual"
		# staging, see SettingsController._build_staged_layout()) have no real
		# RandR output behind them - skip them here rather than letting their
		# empty label trip the "malformed manifest" bailout below and disable
		# outputs= for the real monitors too.
		if m.hint.get("virtual", false):
			continue
		if m.label.is_empty():
			return ""
		labels.append(m.label)
	return ",".join(labels)

# Nightfall Meteor's port map when the current launch goes through it (see
# MeteorClient), else {}.
var _meteor: Dictionary = {}
# Set after a launch through Meteor fails, so the retry goes straight to Sunshine.
var _meteor_bypass := false
# The address Meteor answered on, for its depth port.
var _meteor_address := ""

## Meteor's host depth offer for the current stream (see
## MeteorClient.depth_info()), or {} when there's none.
func meteor_depth_info() -> Dictionary:
	return MeteorClient.depth_info(_meteor)

func meteor_address() -> String:
	return _meteor_address

func _probe_meteor(host_id: int) -> Dictionary:
	var cm = _b().get_computer_manager()
	for host in _b().get_hosts():
		if host.get("id") != host_id:
			continue
		var address: String = cm.get_host_address(host) if cm else host.get("localaddress", "")
		var info := await MeteorClient.probe(main, address, int(host.get("https_port", 47984)))
		if not info.is_empty():
			_meteor_address = address
			var ports: Dictionary = info["ports"]
			main._log("[METEOR] Found Nightfall Meteor %s on %s; streaming through it (https %d, rtsp %d, video %d)" % [
				info.get("version", "?"), address, int(ports.get("https", 0)), int(ports.get("rtsp", 0)), int(ports.get("video", 0))])
			var depth := MeteorClient.depth_info(info)
			if not depth.is_empty():
				main._log("[METEOR] Host depth offered: %s %dx%d on port %d" % [
					depth.get("model", "?"), int(depth["width"]), int(depth["height"]), int(depth["port"])])
		return info
	return {}

# Address the current stream was launched against (USB Link or network).
var stream_host_address: String = ""

# "USB Link", "Wi-Fi", "Ethernet", or "Network" when the platform can't tell.
func connection_label() -> String:
	if stream_host_address.to_lower().begins_with("fe80:"):
		return "USB Link"
	var bridge = main.settings_controller._usb_link_bridge()
	var transport: String = bridge.get_active_transport() if bridge and bridge.has_method("get_active_transport") else ""
	return transport if not transport.is_empty() else "Network"

# Native auto-reconnect asks for a full relaunch rather than replaying the old
# RTSP session (see NightfallStream::set_reconnect_via_launch).
func relaunch_for_reconnect():
	if not main.session_lifecycle.is_reconnecting():
		return
	await start_stream(_current_host_id, _current_app_id)

func _on_v2_launch_response(response: Dictionary):
	if response.get("status", "") != "success":
		var msg = response.get("message", "unknown")
		main._log("[STREAM] Launch failed: %s" % msg)
		# Meteor is experimental: never let it cost a working connection (or
		# trigger the stale-pairing re-pair below). Retry once without it.
		if not _meteor.is_empty():
			main._log("[METEOR] Launch through Meteor failed; retrying straight to Sunshine")
			_meteor = {}
			_meteor_bypass = true
			start_stream(_current_host_id, _current_app_id)
			return
		# Mid-reconnect (e.g. cable still unplugged): hand the failure back to
		# the native retry schedule instead of tearing the session down.
		if main.session_lifecycle.is_reconnecting() and _b()._v2:
			main._log("[RECONNECT] Relaunch failed, scheduling next attempt")
			_b()._v2.retry_reconnect()
			return
		# establish_stream() failed before a decoder session existed, so there
		# will be no stream_terminated callback to restore the welcome viewport.
		# Undo start_stream()'s eager resolution change here; otherwise the
		# welcome UI is 1920x1080 while its composition cursor still maps against
		# the attempted stream resolution.
		main.restore_after_failed_connect("Launch failed: " + str(msg))
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
				# Stored host records only keep the plain HTTPS port
				# (localaddress/https_port), not whatever custom HTTP pairing
				# port the user originally typed into %IPInput (see
				# main.parse_ip_port()) - falls back to the default here,
				# same as before this port-suffix support existed.
				var pin = _b().start_pair(ip, main.DEFAULT_PAIR_PORT)
				if str(pin) != "" and str(pin) != "0":
					main._pair_pin = str(pin)
					main.welcome_screen.show_welcome_screen("pin")
					return
			main._ui_status_label.text = "Pairing needed. Please re-select server."
			main.welcome_screen.show_welcome_screen("server")
		else:
			main._ui_status_label.text = "Launch failed: " + str(msg)
		return

	var server_info = {}
	server_info["server_codec_mode_support"] = response.get("server_codec_mode_support", 0)
	var scm = response.get("server_codec_mode_support", 0)
	main._server_codec_support = {
		"h264": (scm & 0x01) != 0,
		"hevc": (scm & 0x0300) != 0,
		"av1": (scm & 0x030000) != 0,
		"raw": (scm & 0x01000000) != 0,
		# SCM_PYROWAVE (docs/plans/active/pyrowave-codec.md) - see this
		# project's moonlight-common-c overlay patch, 0003-add-pyrowave-codec.patch.
		"pyrowave": (scm & 0x00800000) != 0,
	}
	main._log("[CODEC] Server SCM=0x%x: h264=%s hevc=%s av1=%s raw=%s pyrowave=%s" % [
		scm,
		str(main._server_codec_support.get("h264", false)),
		str(main._server_codec_support.get("hevc", false)),
		str(main._server_codec_support.get("av1", false)),
		str(main._server_codec_support.get("raw", false)),
		str(main._server_codec_support.get("pyrowave", false))])
	if not main.settings_controller.is_codec_available(main.settings.codec_preference):
		main.settings_controller.fallback_codec()
		main.ui_controller.update_codec_btn()
	server_info["rtsp_session_url"] = response.get("session_url", "")
	if not _meteor.is_empty():
		var session_url: String = server_info["rtsp_session_url"]
		server_info["rtsp_session_url"] = MeteorClient.route_rtsp_url(session_url, _meteor)
		main._log("[METEOR] RTSP %s -> %s" % [session_url, server_info["rtsp_session_url"]])
		if session_url.begins_with("rtspenc"):
			# Meteor can't rewrite the UDP ports inside encrypted RTSP, so
			# video and audio would go straight to Sunshine.
			main._log("[METEOR] Sunshine is using encrypted RTSP; stream ports won't go through Meteor")
	server_info["server_app_version"] = response.get("app_version", "")
	server_info["server_gfe_version"] = response.get("gfe_version", "")

	var w = response.get("width", 1920)
	var h = response.get("height", 1080)
	var fps = main.settings.host.stream_fps
	var br = response.get("bitrate", 20000)

	var stream_config = {}
	if local_capture_mode:
		# Real resolution, not a 320x240 dummy - see the matching comment in
		# start_stream()'s options block for the full reasoning.
		stream_config["width"] = w
		stream_config["height"] = h
		stream_config["fps"] = 5
		stream_config["bitrate"] = 500
	else:
		stream_config["width"] = w
		stream_config["height"] = h
		stream_config["fps"] = fps
		stream_config["bitrate"] = br
	stream_config["packet_size"] = response.get("packet_size", 1024)
	stream_config["streaming_remotely"] = response.get("streaming_remotely", 2)
	stream_config["audio_configuration"] = response.get("audio_configuration", 0x0302CA)
	var codec_pref = main.settings.codec_preference
	if codec_pref == 3:
		stream_config["supported_video_formats"] = 0x10000
	elif codec_pref == 4:
		# PyroWave (docs/plans/active/pyrowave-codec.md) - VIDEO_FORMAT_PYROWAVE.
		# Not a FfmpegDecoder-probed family like H264/HEVC/AV1 above (PyroWave's
		# decode path on Android is MediaCodec-free, see stream_connection.cpp's
		# _cb_decoder_setup()), so there's nothing to probe - request it directly.
		stream_config["supported_video_formats"] = 0x01000000
	else:
		var family_map = [1, 2, 3]
		var formats: int = _b().probe_video_format(family_map[codec_pref], false)
		if hdr_requested():
			# The 10-bit profile alongside each 8-bit one the decoder passed
			# (VIDEO_FORMAT_H265 -> H265_MAIN10, AV1_MAIN8 -> AV1_MAIN10). The
			# host only picks it when its display is actually in HDR.
			if formats & 0x0100:
				formats |= 0x0200
			if formats & 0x1000:
				formats |= 0x2000
		stream_config["supported_video_formats"] = formats
		main._log("[STREAM] Video formats 0x%x (HDR %s)" % [formats, "requested" if hdr_requested() else "off"])
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
		# The host's "primary" flag tracks its real OS-level primary display,
		# independent of which output(s) we actually asked it to capture. If
		# the client is only streaming a non-OS-primary monitor (e.g. after
		# swapping VR-primary to a secondary and disabling the original),
		# the manifest for that captured set legitimately has zero enabled
		# monitors flagged primary - validate() used to reject the whole
		# manifest for that, leaving the client on its previous (differently
		# shaped) layout while the actual stream played at the new single
		# monitor's real aspect, producing a stale-mesh-vs-real-video
		# letterbox mismatch. Promote the sole/first enabled monitor instead.
		var enabled_in_manifest := host_layout.enabled_monitors()
		if not enabled_in_manifest.is_empty():
			var has_primary := false
			for m in enabled_in_manifest:
				if m.is_primary:
					has_primary = true
					break
			if not has_primary:
				enabled_in_manifest[0].is_primary = true
		var layout_err = host_layout.validate(host_layout.frame_size)
		if layout_err == "":
			main._log("[LAYOUT] Host manifest received: %d monitor(s), frame=%dx%d, desktop_bounds=%s" % [host_layout.monitors.size(), host_layout.frame_size.x, host_layout.frame_size.y, str(host_layout.desktop_bounds)])
			for m in host_layout.enabled_monitors():
				main._log("[LAYOUT]   monitor %s frame_rect=%s desktop_rect=%s primary=%s" % [String(m.id), str(m.frame_rect), str(m.desktop_rect), str(m.is_primary)])
			main.settings_controller.apply_screen_layout(host_layout)
			# A Monitors-tab Apply that changed the real capture selection
			# deferred adding virtual placeholders/positioning screens until now
			# (see SettingsController.apply_staged_monitor_config()) - this
			# manifest is the first one with real geometry for the newly
			# requested set, so finish that work now that it's safe to.
			if main._pending_monitor_apply:
				main._pending_monitor_apply = false
				main.settings_controller.finish_pending_monitor_apply()
		else:
			main._log("[LAYOUT] Host manifest invalid, ignoring: %s" % layout_err)

	main._host_cursor_toggle_supported = response.get("cursor_supported", false)
	main.host_cursor_visible = response.get("cursor_visible", false)
	main.ui_controller.update_host_cursor_btn_state()

	var ip = response.get("ip", "")
	if ip.is_empty():
		main._log("[STREAM] Launch response had no reconnectable host address")
		main.restore_after_failed_connect("Host address missing from launch response")
		return
	stream_host_address = ip
	_b().start_stream_v2(ip, server_info, stream_config, false)
	main._log("[STREAM] start_stream called (%dx%d@%d %.1fMbps)" % [w, h, fps, float(br) / 1000.0])

# Moonlight's baseline bitrate table at 30 FPS. Values between anchors are
# linearly interpolated by pixel count, avoiding quality cliffs for scaled and
# ultrawide resolutions. Values beyond the table clamp to its endpoints, as in
# Moonlight Android/Qt; a multi-monitor canvas should not make Auto request an
# unbounded bitrate.
const AUTO_BITRATE_RESOLUTION_TABLE := [
	{"pixels": 640 * 360, "mbps_30": 1.0},
	{"pixels": 854 * 480, "mbps_30": 2.0},
	{"pixels": 1280 * 720, "mbps_30": 5.0},
	{"pixels": 1920 * 1080, "mbps_30": 10.0},
	{"pixels": 2560 * 1440, "mbps_30": 20.0},
	{"pixels": 3840 * 2160, "mbps_30": 40.0},
]

# Explicit entries for every selectable stream FPS. Preserve roughly the same
# bits per frame above 60 FPS: Moonlight's generic sqrt rule produced only
# 15 Mbps at 720p144 and visibly broke down in motion on Quest. The final
# bitrate is capped at the highest value exposed by Nightfall's manual bitrate
# control so high-resolution/high-rate combinations remain realistic for Wi-Fi.
const AUTO_BITRATE_FPS_FACTORS := {
	30: 1.000000,
	60: 2.000000,
	72: 2.400000,
	90: 3.000000,
	120: 4.000000,
	144: 4.800000,
	165: 5.500000,
	200: 6.666667,
	207: 6.900000,
}
const AUTO_BITRATE_MIN_KBPS := 1000
const AUTO_BITRATE_MAX_KBPS := 120000

func _auto_bitrate(w: int, h: int) -> int:
	var pixels = w * h
	var resolution_mbps: float = AUTO_BITRATE_RESOLUTION_TABLE[0]["mbps_30"]
	if pixels >= AUTO_BITRATE_RESOLUTION_TABLE[-1]["pixels"]:
		resolution_mbps = AUTO_BITRATE_RESOLUTION_TABLE[-1]["mbps_30"]
	else:
		for i in range(1, AUTO_BITRATE_RESOLUTION_TABLE.size()):
			var upper: Dictionary = AUTO_BITRATE_RESOLUTION_TABLE[i]
			if pixels > upper["pixels"]:
				continue
			var lower: Dictionary = AUTO_BITRATE_RESOLUTION_TABLE[i - 1]
			var span_pixels: float = float(upper["pixels"] - lower["pixels"])
			var weight: float = float(pixels - lower["pixels"]) / span_pixels
			resolution_mbps = lerpf(lower["mbps_30"], upper["mbps_30"], clampf(weight, 0.0, 1.0))
			break
	var fps_factor: float = AUTO_BITRATE_FPS_FACTORS.get(main.settings.host.stream_fps, 2.0)
	# Match Moonlight's whole-Mbps rounding so the result remains readable and
	# stable across tiny custom-resolution changes.
	var kbps := int(round(resolution_mbps * fps_factor)) * 1000
	return clampi(kbps, AUTO_BITRATE_MIN_KBPS, AUTO_BITRATE_MAX_KBPS)

func resize_stream_viewport(w: int, h: int):
	var stream_size = Vector2i(w, h)
	# A SubViewport assigned to an OpenXRCompositionLayer owns a compositor
	# swapchain. Resizing it while the OpenXR session is running can race an
	# in-flight layer submission; on Quest this is a repeatable GLThread
	# SIGSEGV at address 0xe0. The native renderer does not sample these legacy
	# composition buffers, so preserve their existing allocation across a
	# native-path restart. Keeping comp_base_size unchanged also prevents the
	# stream-started apply_stereo() -> update_bezel() call from resizing them a
	# second time. Legacy-only configurations still use the normal path below.
	var native_path: bool = main.video_presentation != null \
		and main.video_presentation.can_render_native()
	var preserve_source_render_target: bool = \
		main.session_lifecycle.is_restarting() and native_path
	# Initial native connects arrive from the visible 1920x1080 welcome layer.
	# Preserve that legacy allocation too: the native path never samples it,
	# and resizing an attached OpenXR SubViewport is the 0xe0 GLThread crash.
	var preserve_legacy_composition: bool = native_path
	current_stream_size = stream_size
	if not preserve_source_render_target and main.stream_viewport.size != stream_size:
		main._log("[STREAM] Resizing source viewport %s -> %s" % [str(main.stream_viewport.size), str(stream_size)])
		main.stream_viewport.size = stream_size
	elif preserve_source_render_target and main.stream_viewport.size != stream_size:
		main._log("[STREAM] Preserving source render target during native restart (logical size %s)" % str(stream_size))
	main.stream_target.custom_minimum_size = Vector2(w, h)
	if _v2_yuv_rect:
		_v2_yuv_rect.custom_minimum_size = Vector2(w, h)
	# comp_viewport/_left/_right/comp_base_size alias to the PRIMARY screen only;
	# every screen's own composite viewport must track the actual decoded
	# resolution too, or secondary screens stay stuck at their setup_screen()
	# default (1920x1080) and look soft once the stream exceeds that. Used to
	# be skipped entirely under GLES (2026-08-23's "gl_compatibility" gate,
	# no comment explaining why) - re-enabled (2026-08-24) since it was
	# silently downscale-then-upscale blurring every GLES stream above
	# 1920x1080, and none of the swapchain-teardown crashes fixed earlier
	# this session were about resizing SubViewports (they were about
	# repeatedly toggling a composition layer's `.visible`), so there's no
	# known reason left to keep this GLES-specific.
	if preserve_legacy_composition:
		main._log("[STREAM] Preserving dormant legacy composition buffers for native path (requested %s)" % str(stream_size))
	else:
		for s in main.screens:
			s.comp_base_size = stream_size
			var comp_size = stream_size
			if main.settings.bezel_enabled and main.comp.in_use:
				comp_size += Vector2i(16, 16)
			if s.comp_viewport and s.comp_viewport.size != comp_size:
				s.comp_viewport.size = comp_size
			if s.comp_viewport_left and s.comp_viewport_left.size != comp_size:
				s.comp_viewport_left.size = comp_size
			if s.comp_viewport_right and s.comp_viewport_right.size != comp_size:
				s.comp_viewport_right.size = comp_size
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
	var raw_text = main.get_node("%IPInput").text
	main.get_node("%Numpad").visible = false
	if raw_text.is_empty(): raw_text = "127.0.0.1"
	var save = ConfigFile.new()
	save.set_value("connection", "ip", raw_text)
	save.save("user://last_connection.cfg")
	if _b().get_config_manager():
		_b().get_config_manager().load_config()
	# Optional "ip:port" suffix (see main.parse_ip_port()) - host records only
	# ever store the plain ip (pairing saves host_data["localaddress"] from
	# the ALREADY-parsed ip, not the raw field text), so matching against
	# h.localaddress needs the parsed ip too, not raw_text verbatim.
	var parsed = main.parse_ip_port(raw_text)
	var ip: String = parsed[0]
	var pair_port: int = parsed[1]
	var paired_host_id = -1
	for h in _b().get_hosts():
		if main.host_matches_address(h, ip):
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
		main._log("[PAIR] Starting pair with %s:%d..." % [ip, pair_port])
		var pin = _b().start_pair(ip, pair_port)
		main._log("[PAIR] start_pair completed (result type=%s)" % str(typeof(pin)))
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
		# Sunshine listens on IPv4 only by default, and USB Link is IPv6-only,
		# so an instant refusal over the cable almost always means this.
		var pair_ip: String = main.parse_ip_port(main.get_node("%IPInput").text)[0]
		if pair_ip.to_lower().begins_with("fe80:") and str(_msg).contains("Could not connect"):
			main._ui_status_label.text = "Server refused the USB connection.\nSet address_family = both in its Sunshine config and restart it."
			main._log("[PAIR] USB Link host refused connection - Sunshine likely listening on IPv4 only")
		main.welcome_screen.show_welcome_screen("server")
		return
	main._ui_status_label.text = "Pairing successful, starting stream..."
	# Settle delay (2026-08-26) - the mutual-TLS HTTPS endpoint (port 57984)
	# that pairing's own stage 5 (phrase=pairchallenge) just used successfully
	# was seen failing to connect ("Could not connect to server") when
	# establish_stream()'s first HTTPS call landed only ~15ms after pairing
	# completed - the host's TLS server needs a brief moment to actually
	# start accepting the just-registered client certificate for mutual TLS.
	# Confirmed via on-device logcat: an identical cert, same host/port,
	# succeeded during pairing and failed moments later with no other
	# change. Only on this fresh-pairing path - normal reconnects (an
	# already-paired host) don't hit this race and aren't delayed.
	await main.get_tree().create_timer(1.5).timeout
	if _b().get_config_manager():
		_b().get_config_manager().load_config()
	var ip = main.parse_ip_port(main.get_node("%IPInput").text)[0]
	# Match by server_unique_id, not bare IP (2026-08-26) - a host reached via
	# NAT port-forwarding (e.g. a VM's game-streaming port forwarded through
	# its host machine's IP) can share the exact same localaddress as a
	# completely different, already-paired host on another port. Bare-IP
	# matching would then pick whichever host record happens to be FIRST in
	# get_hosts(), not the one just paired. server_unique_id is the value
	# each server reports in its own serverinfo XML and is what pairing
	# itself already dedupes existing host records by (computer_manager.cpp),
	# so it's the only reliable way to find the host record that was just
	# created/updated. Fall back to bare-IP matching only if unique_id is
	# unavailable (e.g. an older cached build without get_last_paired_unique_id).
	var unique_id = _b().get_last_paired_unique_id() if _b().has_method("get_last_paired_unique_id") else ""
	# Reached an already-paired machine by a new path (e.g. over USB Link):
	# continue under its saved identity so per-host settings stay shared.
	if not unique_id.is_empty():
		for h in _b().get_hosts():
			if h.get("server_unique_id", "") == unique_id:
				var saved_ip: String = h.get("localaddress", "")
				if not saved_ip.is_empty() and saved_ip != main.get_node("%IPInput").text:
					main.get_node("%IPInput").text = saved_ip
					main.state_manager.load_host_state(saved_ip)
				break
	main.welcome_screen.save_last_ip(main.get_node("%IPInput").text, unique_id)
	var found = false
	for h in _b().get_hosts():
		if not unique_id.is_empty() and h.get("server_unique_id", "") == unique_id:
			main.current_host_id = h.id
			found = true
			await start_stream(h.id, main._selected_app_id)
			break
	if not found and unique_id.is_empty():
		for h in _b().get_hosts():
			if main.host_matches_address(h, ip):
				main.current_host_id = h.id
				found = true
				await start_stream(h.id, main._selected_app_id)
				break
	if not found:
		main._log("[PAIR] Host not found after pairing, retrying config load")
		_b().get_config_manager().load_config()
		for h in _b().get_hosts():
			if not unique_id.is_empty() and h.get("server_unique_id", "") == unique_id:
				main.current_host_id = h.id
				found = true
				await start_stream(h.id, main._selected_app_id)
				break
			elif unique_id.is_empty() and main.host_matches_address(h, ip):
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
	# USB Link carries only link-local IPv6, invisible to the IPv4 browse, so
	# scan the link too (in parallel) whenever it's actually up.
	var usb_iface := _usb_link_iface()
	var threads: Array[Thread] = []
	var lan_hosts: Array = []
	var usb_hosts: Array = []
	var lan_thread = Thread.new()
	lan_thread.start(func(): lan_hosts.append_array(_b().browse_mdns(3.0)))
	threads.append(lan_thread)
	if not usb_iface.is_empty():
		var usb_thread = Thread.new()
		usb_thread.start(func(): usb_hosts.append_array(_b().browse_mdns_usb(usb_iface, 3.0)))
		threads.append(usb_thread)
	for t in threads:
		while t.is_alive():
			await main.get_tree().create_timer(0.1).timeout
		t.wait_to_finish()
	_mdns_result = _merge_mdns_hosts(usb_hosts, lan_hosts)
	main._log("[mDNS] Found %d hosts" % _mdns_result.size())
	return _mdns_result

# One entry per machine: a PC reachable both ways advertises the same SRV
# target on each network, and the cable is the path worth taking.
func _merge_mdns_hosts(usb_hosts: Array, lan_hosts: Array) -> Array:
	var merged: Array = []
	var seen := {}
	for host in usb_hosts + lan_hosts:
		var key = str(host.get("hostname", host.get("ip", ""))).to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		merged.append(host)
	return merged

func _usb_link_iface() -> String:
	if not main.settings_controller.usb_link_supported():
		return ""
	var bridge = main.settings_controller._usb_link_bridge()
	if bridge == null or not bridge.is_up():
		return ""
	return bridge.get_interface_name()

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
	# This blanket "Android always means color_matrix_type=3 (already-RGB
	# OES bridge)" assumption predates PyroWave, the first Android codec
	# that genuinely decodes to real multi-plane YUV (color_matrix_type=1)
	# instead of an OES-converted RGB surface - it was stomping PyroWave's
	# correctly-computed cmt back to 3 on this exact shared
	# TextureUploader material, which made tex_u/tex_v never get sampled at
	# all (color_matrix_type==3 short-circuits straight to tex_y.rgb) -
	# the actual root cause of PyroWave's greyscale video.
	if local_capture_mode or (OS.get_name() == "Android" and main.settings.codec_preference != 4):
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
	# Leave short user-facing confirmations readable. Important lifecycle
	# messages are written through their own paths and can still replace them.
	if main.ui_controller and main.ui_controller.is_temporary_status_active():
		return
	if not _v2_yuv_rect:
		_setup_v2_yuv_rect()
	_update_yuv_shader_params()
	main.comp.bind_yuv_textures()  # Re-bind after compute pipeline may have updated tex_y
	var vw = _b().get_video_width()
	var vh = _b().get_video_height()
	# Local-capture mode (2026-08-21 fix) - the negotiated RTSP video stream
	# in this mode is a throwaway 320x240 dummy (see start_stream()'s
	# options block below); get_video_width()/height() read the DECODER's
	# dims, which reflect that dummy stream, not the real X11-captured
	# monitor. Relying on vw/vh here (as the normal network path correctly
	# does) meant layout.frame_size/host_ref() never matched what was
	# actually captured/shown, sending clicks scaled against the wrong
	# frame size (confirmed live: [CAPTURE-GT] showed layout.frame_size
	# stuck at host_resolution/native_resolution defaults while the real
	# X11 capture was a different resolution entirely). Poll the real
	# capture region instead and reconcile against THAT.
	if local_capture_mode:
		var region = _b().get_local_capture_region()
		var rw = int(region.get("width", 0))
		var rh = int(region.get("height", 0))
		if rw > 0 and rh > 0:
			var cur_local = current_stream_size
			if cur_local.x != rw or cur_local.y != rh:
				resize_stream_viewport(rw, rh)
	else:
		if vw == 0 or vh == 0:
			return
		var cur_size = current_stream_size
		if cur_size.x != vw or cur_size.y != vh:
			resize_stream_viewport(vw, vh)
	var hw = _b().get_decode_mode()
	var ip = main.get_node("%IPInput").text
	var ip_display = ip if not ip.is_empty() else "?"
	var dropped = _b().get_frames_dropped()
	var network_latency_ms = _b().get_network_latency_ms()
	var bitrate_mbps = bitrate / 1000.0
	var refresh_hz = main.display_refresh_rate
	var codec_name = main.codec_labels[main.settings.codec_preference] if main.settings.codec_preference < main.codec_labels.size() else "?"
	var txt = ip_display + " \u2022 " + str(vw) + "x" + str(vh) + " " + str(main.settings.host.stream_fps) + "fps " + str(int(bitrate_mbps)) + "Mbps " + codec_name + " " + hw
	txt += " \u2022 Net:" + (str(network_latency_ms) + "ms" if network_latency_ms >= 0 else "?")
	txt += " \u2022 " + str(int(refresh_hz)) + "Hz \u2022 App:" + str(int(round(main.telemetry.app_fps))) + "fps"
	if dropped > 0:
		txt += " \u2022 drop:" + str(dropped)
	# Live depth-inference readout (2026-08-25, extended to CPU 2026-10-02) -
	# added for the 1080p-vs-1440p+ MiDaS-256-GPU throughput investigation, so
	# testing resolution/quality-tier combos doesn't require pulling logcat
	# each time. Shown whenever depth is actually running, GPU or CPU -
	# DepthEstimator.java's recordTelemetry() accumulates a real window for
	# CPU inference too, it's not just reset every call.
	if main.depth_estimator and main.depth_estimator.enabled and main.stream_backend \
			and main.stream_backend.has_method("get_effective_depth_backend") \
			and main.stream_backend.get_effective_depth_backend() != 0 \
			and main.stream_backend.has_method("get_depth_last_inference_ms"):
		var inf_ms = main.stream_backend.get_depth_last_inference_ms()
		var inf_hz = main.stream_backend.get_depth_last_inference_hz()
		if inf_ms > 0.0:
			txt += " \u2022 AI3D:" + str(snapped(inf_ms, 0.1)) + "ms/" + str(snapped(inf_hz, 0.1)) + "Hz"
	if main.controller_mapper and main.controller_mapper.is_active():
		txt += " \u2022 " + main.controller_mapper.get_mode_label()
		if main.controller_mapper.is_gamepad_mode() and main.controller_mapper.get_close_to_head():
			txt += " D-PAD"
	main._ui_status_label.text = txt
