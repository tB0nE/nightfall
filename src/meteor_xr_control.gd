class_name MeteorXRControl
extends RefCounted
const PCVRVideoSettings = preload("res://src/pcvr_stream_settings.gd")
## DEV authenticated control only. Prepared never starts exclusive presentation.
signal changed
signal runtime_changed
signal library_reply(value: Dictionary)
signal library_open_requested
var _library_queue: Array[Dictionary] = []
var library_available := false
const MAX_FRAME := 4096
const CONFIG := "user://meteor_xr_control.cfg"
const IDENTITY := "user://meteor_xr_identity.key"
var owner: Node
var state := "idle"
var message := ""
var session := ""
var runtime_status: Dictionary = {}
var session_fps := 0
var session_eye_size := 0
var session_eye_height := 0
var bitrate_message := ""
var foveation_message := ""
var _last_foveation_status := ""
var _pending_foveation := -1
var _pending_bitrate := -1
var _bitrate_deadline := 0
var _generation := 0
var _peer: StreamPeerTCP
var _send
var _receive
var _tx := 0
var _rx := 0
var _busy := false
var _relay
var _owns_projection := false
var _owns_timing := false
var _long_run := false
var _standby_only := false
var _handover_on_ready := false
var _relay_config: Dictionary = {}

func _init(node: Node) -> void:
	owner = node

static func supported() -> bool:
	if not ClassDB.class_exists("MeteorChannelCipher"): return false
	return ClassDB.instantiate("MeteorChannelCipher").has_method("init_control")

static func config_path() -> String:
	if FileAccess.file_exists(CONFIG): return CONFIG
	if OS.has_feature("android") and ClassDB.class_exists("MeteorXrRelay"):
		var relay = ClassDB.instantiate("MeteorXrRelay")
		if relay.has_method("get_config_path"):
			var external: String = relay.get_config_path()
			if not external.is_empty() and FileAccess.file_exists(external): return external
	return CONFIG

func _status(value: String, text: String) -> void:
	state = value
	message = text
	owner._log("[XR-CONTROL] %s: %s" % [value, text])
	changed.emit()

func cancel(stop_projection: bool = true) -> void:
	_library_queue.clear()
	library_available = false
	_pending_foveation = -1
	foveation_message = ""
	_last_foveation_status = ""
	_pending_bitrate = -1
	bitrate_message = ""
	_generation += 1
	var owned := _owns_projection
	_owns_projection = false
	_long_run = false
	_standby_only = false
	_handover_on_ready = false
	if _relay: _relay.stop()
	_relay = null
	_relay_config.clear()
	if _peer: _peer.disconnect_from_host()
	_peer = null
	_send = null
	_receive = null
	session = ""
	session_fps = 0
	session_eye_size = 0
	session_eye_height = 0
	if not runtime_status.is_empty():
		runtime_status.clear()
		runtime_changed.emit()
	_busy = false
	_status("idle", "Control connection closed")
	if owned and stop_projection: owner.pcvr_test.request_stop()
	if _owns_timing:
		_owns_timing = false
		_release_timing_when_idle(_generation)

func _release_timing_when_idle(token: int) -> void:
	while token == _generation and (owner.pcvr_test.standby_active or owner.pcvr_test.is_exclusive()):
		await owner.get_tree().process_frame
	if token == _generation:
		owner.settings_controller.end_pcvr_timing()

func _fail(text: String) -> void:
	cancel()
	_status("failed", text)

func _watch_lease(token: int, expected: String, milliseconds: int) -> void:
	var deadline := Time.get_ticks_msec() + milliseconds
	var next_status := Time.get_ticks_msec() + 500
	while token == _generation and state == expected:
		if not _peer:
			_fail("Control connection closed")
			return
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or (Time.get_ticks_msec() >= deadline and not (expected == "prepared" and not _relay_config.is_empty())):
			_fail("Control lease expired or host disconnected")
			return
		if expected == "prepared" and Time.get_ticks_msec() >= next_status:
			# Only this loop issues requests after acceptance; never overlap cipher
			# counters or reads. Active relay status renews the host's idle lease.
			var command := {"type": "status"}
			var updating := _pending_bitrate >= 0
			if updating:
				command = {"type":"set_bitrate", "session":session, "bitrate_mbps":_pending_bitrate}
				_pending_bitrate = -1
				_bitrate_deadline = Time.get_ticks_msec() + 5000
			var updating_foveation := _pending_foveation >= 0 and not updating
			if updating_foveation:
				command = {"type":"set_foveation", "session":session, "enabled":_pending_foveation == 1}
				_pending_foveation = -1
			if not updating and not updating_foveation and not _library_queue.is_empty(): command = _library_queue.pop_front()
			var reply := await _request(command, token)
			_handle_library_reply(reply)
			if token != _generation: return
			if reply.get("state", "") != "prepared" or reply.get("session", "") != session or not _update_runtime(reply):
				_fail("Invalid or expired XR runtime status")
				return
			if updating and reply.get("reason") != null:
				bitrate_message = "Bitrate unchanged: " + str(reply.reason)
			else:
				_update_bitrate_status(reply.get("bitrate"))
			if updating_foveation and reply.get("reason") != null:
				foveation_message = "Foveated encoding unchanged: " + str(reply.reason)
			else:
				var result = reply.get("foveation")
				if result is Dictionary:
					var signature := str(result)
					if signature != _last_foveation_status:
						_last_foveation_status = signature
						foveation_message = "Foveated encoding %s: %s" % ["On" if int(result.get("requested_enabled", 0)) == 1 else "Off", str(result.get("state", "pending"))]
						owner._log("[PCVR] " + foveation_message)
			next_status = Time.get_ticks_msec() + (50 if not _library_queue.is_empty() else 500)
		await owner.get_tree().process_frame

func request_library(action: String, key: String = "", offset: int = 0) -> bool:
	if not library_available or state not in ["watching", "prepared"] or action not in ["list", "art", "launch"]: return false
	if action in ["list", "launch"]: _library_queue.clear()
	if _library_queue.size() >= 12: return false
	_library_queue.append({"type":"library", "action":action, "key":key, "offset":offset})
	return true

func _handle_library_reply(reply: Dictionary) -> void:
	library_available = bool(reply.get("library_available", false))
	if reply.get("library") is Dictionary: library_reply.emit(reply.library)
	if reply.get("open_library", false): library_open_requested.emit()

func queue_foveation(enabled: bool) -> bool:
	if state != "prepared" or session.is_empty(): return false
	_pending_foveation = 1 if enabled else 0
	foveation_message = "Foveated encoding update queued"
	return true

func queue_bitrate(mbps: int) -> bool:
	if state != "prepared" or session.is_empty() or mbps not in PCVRVideoSettings.BITRATES: return false
	_pending_bitrate = mbps # Coalesce rapid cycling; only the control loop owns cipher I/O.
	bitrate_message = "Bitrate update queued"
	return true

func _update_bitrate_status(value: Variant) -> void:
	if not value is Dictionary: return
	if value.get("state") not in ["pending", "applied", "rejected"]: return
	if value.state == "applied":
		bitrate_message = "Bitrate %.1f Mbps applied" % (float(value.get("applied_bps", 0)) / 1000000.0)
	elif value.state == "rejected":
		bitrate_message = "Bitrate unchanged: " + str(value.get("error", "encoder rejected update"))
	elif Time.get_ticks_msec() >= _bitrate_deadline and _bitrate_deadline > 0:
		bitrate_message = "Bitrate update not yet confirmed"
	else:
		bitrate_message = "Bitrate update pending"

static func valid_runtime_status(value: Variant) -> bool:
	if not value is Dictionary: return false
	if not value.has_all(["phase", "generation", "event_sequence", "active_sessions"]): return false
	var phase = value.get("phase")
	if phase not in ["waiting_for_lanes", "starting", "ready_for_application", "session_created", "session_active", "session_ended", "stopping", "completed", "cancelled", "failed"]: return false
	var generation = value.get("generation")
	if generation != null:
		if not generation is String or generation.length() != 32: return false
		for digit in generation:
			if digit not in "0123456789abcdef": return false
	for field in ["event_sequence", "active_sessions"]:
		var number = value.get(field)
		if typeof(number) not in [TYPE_INT, TYPE_FLOAT]: return false
		if not is_finite(float(number)) or number < 0 or number > 9007199254740991 or number != int(number): return false
	var active := int(value.active_sessions)
	if active > 128 or (generation == null and int(value.event_sequence) != 0): return false
	if phase in ["session_created", "session_active", "session_ended"] and (generation == null or int(value.event_sequence) == 0): return false
	if phase == "session_active" and (active == 0 or generation == null or int(value.event_sequence) == 0): return false
	if active > 0 and (generation == null or int(value.event_sequence) == 0): return false
	if active > 0 and phase not in ["session_active", "stopping"]: return false
	return true

func _update_runtime(reply: Dictionary) -> bool:
	if not reply.has("runtime"):
		# An older host never supplied runtime status. Once supplied for this
		# lease it must not disappear and erase our generation/replay checks.
		return runtime_status.is_empty()
	var value = reply.runtime
	if not valid_runtime_status(value): return false
	if not runtime_status.is_empty():
		var previous = runtime_status.get("generation")
		if previous != null and value.generation != previous: return false
		if int(value.event_sequence) < int(runtime_status.event_sequence): return false
	if runtime_status != value:
		runtime_status = value.duplicate(true)
		if value.phase == "ready_for_application":
			message = "XR armed: start the application on the PC (30s window)"
		elif value.phase == "session_active":
			message = "XR application active"
		owner._log("[XR-CONTROL] runtime=%s events=%s active_sessions=%s" % [value.phase, value.event_sequence, value.active_sessions])
		runtime_changed.emit()
		changed.emit()
	return true

static func valid_pin(pin: String) -> bool:
	if pin.length() != 64 or pin.to_lower() == "0".repeat(64): return false
	for digit in pin.to_lower():
		if digit not in "0123456789abcdef": return false
	return true

func _identity() -> PackedByteArray:
	if FileAccess.file_exists(IDENTITY):
		return FileAccess.get_file_as_bytes(IDENTITY)
	var identity := Crypto.new().generate_random_bytes(32)
	var file := FileAccess.open(IDENTITY, FileAccess.WRITE)
	if not file: return PackedByteArray()
	if OS.has_feature("linux") or OS.has_feature("android"):
		if FileAccess.set_unix_permissions(IDENTITY, 384) != OK:
			file.close()
			return PackedByteArray()
	file.store_buffer(identity)
	file.close()
	return identity

func public_identity() -> String:
	if not supported(): return ""
	var identity := _identity()
	if identity.size() != 32: return ""
	return ClassDB.instantiate("MeteorChannelCipher").identity_public(identity).hex_encode()

func _read(peer: StreamPeerTCP, count: int, token: int) -> PackedByteArray:
	var out := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 5000
	while out.size() < count and token == _generation:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() >= deadline: return PackedByteArray()
		var available := mini(peer.get_available_bytes(), count - out.size())
		if available > 0:
			var result := peer.get_partial_data(available)
			if result[0] != OK: return PackedByteArray()
			out.append_array(result[1])
		else:
			await owner.get_tree().process_frame
	return out if token == _generation else PackedByteArray()

func _write(peer: StreamPeerTCP, bytes: PackedByteArray, token: int) -> bool:
	var offset := 0
	var deadline := Time.get_ticks_msec() + 5000
	while offset < bytes.size() and token == _generation:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() >= deadline: return false
		var result := peer.put_partial_data(bytes.slice(offset))
		if result[0] != OK: return false
		offset += int(result[1])
		if offset < bytes.size(): await owner.get_tree().process_frame
	return token == _generation

func _request(request: Dictionary, token: int) -> Dictionary:
	var peer := _peer
	var plain := JSON.stringify(request).to_utf8_buffer()
	if plain.size() > MAX_FRAME - 16 or _tx == 0x7fffffffffffffff: return {}
	var header := PackedByteArray()
	header.resize(4)
	header.encode_u32(0, plain.size() + 16)
	var body: PackedByteArray = _send.seal(_tx, header, plain)
	if body.is_empty(): return {}
	_tx += 1
	header.append_array(body)
	if not await _write(peer, header, token): return {}
	var length := await _read(peer, 4, token)
	if length.size() != 4: return {}
	var size := length.decode_u32(0)
	if size < 16 or size > MAX_FRAME or _rx == 0x7fffffffffffffff: return {}
	var encrypted := await _read(peer, size, token)
	if encrypted.size() != size or token != _generation: return {}
	var decoded: PackedByteArray = _receive.open(_rx, length, encrypted)
	_rx += 1
	var json := JSON.new()
	if decoded.is_empty() or json.parse(decoded.get_string_from_utf8()) != OK or not json.data is Dictionary: return {}
	return json.data

func connect_offer(watch_only: bool = false) -> void:
	if _busy or state not in ["idle", "failed"]: return
	cancel()
	if not supported():
		_fail("Updated native control cipher is required")
		return
	var config := ConfigFile.new()
	if config.load(config_path()) != OK:
		_fail("Developer host configuration missing")
		return
	var host := str(config.get_value("host", "address", ""))
	var port := int(config.get_value("host", "port", 0))
	var pin := str(config.get_value("host", "key", "")).to_lower()
	if not host.is_valid_ip_address() or port < 1 or port > 65535 or not valid_pin(pin):
		_fail("Invalid developer address, port or pinned host key")
		return
	var identity := _identity()
	if identity.size() != 32:
		_fail("Invalid private device identity; not replacing existing key")
		return
	_busy = true
	var token := _generation
	_peer = StreamPeerTCP.new()
	var peer := _peer
	_status("connecting", "Authenticating Meteor control")
	if peer.connect_to_host(host, port) != OK:
		_fail("Control connection failed")
		return
	var deadline := Time.get_ticks_msec() + 5000
	while token == _generation:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTING: break
		if Time.get_ticks_msec() >= deadline: break
		await owner.get_tree().process_frame
	if token != _generation: return
	var hello := await _read(peer, 72, token)
	if token != _generation: return
	if hello.size() != 72 or hello.slice(0, 8) != PackedByteArray([78, 70, 88, 67, 1, 0, 0, 0]) or hello.slice(8, 40).hex_encode() != pin:
		_fail("Host version/key mismatch or handshake timeout")
		return
	var nonce := Crypto.new().generate_random_bytes(32)
	if bool(config.get_value("host", "relay", false)):
		_relay_config = {"address": host, "host": pin.hex_decode(), "identity": identity,
			"server_nonce": hello.slice(40), "client_nonce": nonce}
	_send = ClassDB.instantiate("MeteorChannelCipher")
	_receive = ClassDB.instantiate("MeteorChannelCipher")
	if not _send.init_control(pin, hello.slice(40), nonce, identity, true).is_empty() or not _receive.init_control(pin, hello.slice(40), nonce, identity, false).is_empty():
		_fail("Control key agreement failed")
		return
	var response: PackedByteArray = _send.get_public_key()
	response.append_array(nonce)
	_tx = 0
	_rx = 0
	if not await _write(peer, response, token):
		if token == _generation: _fail("Handshake send failed")
		return
	var authenticated := await _request({"type": "authenticate"}, token)
	_handle_library_reply(authenticated)
	if token != _generation: return
	if authenticated.get("state", "") != "idle":
		_fail("Control authentication rejected or host busy")
		return
	if watch_only:
		_busy = false
		_status("watching", "Automatic XR ready; waiting for a host launch")
		await _watch_launch_intent(config, token)
		return
	await _offer_authenticated(config, token)

static func valid_launch_notice(value: Variant) -> bool:
	if not value is Dictionary: return false
	var generation = value.get("generation")
	var app_id = value.get("app_id")
	return generation is String and generation.length() == 32 and generation.is_valid_hex_number(false) and app_id is String and app_id.is_valid_int() and int(app_id) > 0 and int(app_id) < 4294967296

func _watch_launch_intent(config: ConfigFile, token: int) -> void:
	while token == _generation and state == "watching" and owner.is_streaming:
		var command: Dictionary = _library_queue.pop_front() if not _library_queue.is_empty() else {"type":"pending_launch"}
		var reply := await _request(command,token)
		_handle_library_reply(reply)
		if token != _generation: return
		if reply.get("state", "") != "idle" or reply.get("reason") != null:
			_fail("Automatic XR watch unavailable on host")
			return
		if reply.get("pending_launch") != null:
			if not valid_launch_notice(reply.pending_launch):
				_fail("Invalid automatic XR launch notice")
				return
			var reason: String = owner.pcvr_test.standby_busy_reason()
			if not reason.is_empty():
				await owner.get_tree().create_timer(1.0).timeout
				continue
			var claimed := await _request({"type":"claim_launch","generation":reply.pending_launch.generation},token)
			if token != _generation: return
			if claimed.get("reason") != null or claimed.get("state", "") != "idle":
				_fail("Automatic XR launch request expired")
				return
			owner._log("[XR-AUTO] Host requested Steam application " + reply.pending_launch.app_id)
			await _offer_authenticated(config,token)
			if token == _generation and state == "offered": accept_offer()
			return
		await owner.get_tree().create_timer(0.05 if not _library_queue.is_empty() else 1.0).timeout
	if token == _generation and state == "watching": cancel()

func _offer_authenticated(config: ConfigFile, token: int) -> void:
	_busy = true
	var quest3: bool = owner.get("device_is_quest3") == true
	var hz := int(config.get_value("host", "hz", PCVRVideoSettings.QUEST3_STREAM_FPS if quest3 else 20))
	var eye_size := int(config.get_value("host", "eye_size", 512))
	var video_settings := PCVRVideoSettings.new(quest3)
	video_settings.load_from()
	var recommended := PCVRVideoSettings.reference_eye_dimensions(owner.pcvr_test.backend, owner.get("stream_backend"))
	if video_settings.resolution_percent > 0 and (recommended.x <= 0 or recommended.y <= 0):
		_fail("Headset OpenXR resolution is not ready")
		return
	var dimensions := video_settings.effective_eye_dimensions(eye_size, recommended)
	eye_size = dimensions.x
	var eye_height := dimensions.y
	if quest3: hz = PCVRVideoSettings.QUEST3_STREAM_FPS
	_long_run = bool(config.get_value("host", "long_run", false))
	_handover_on_ready = bool(config.get_value("host", "handover_on_ready", false))
	_standby_only = bool(config.get_value("host", "standby_only", false)) or _handover_on_ready
	if hz not in [20, 60, 72] or not PCVRVideoSettings.valid_eye_size(eye_size) or not PCVRVideoSettings.valid_eye_size(eye_height) or (_long_run and hz not in [60, 72]):
		_fail("Unsupported developer XR rate or eye size")
		return
	var configured := await _request({"type": "configure_video", "bitrate_mbps": video_settings.bitrate_mbps, "codec": "h265" if quest3 else "h264", "foveated_encoding":video_settings.foveated_encoding}, token)
	if token != _generation: return
	if configured.get("state", "") != "idle" or configured.get("reason") != null:
		_fail("Host rejected PCVR video configuration; update Meteor")
		return
	owner._log("[PCVR] Offer %dx%d per eye, %d%%, centre-priority encoding=%s" % [eye_size, eye_height, video_settings.resolution_percent, video_settings.foveated_encoding])
	var offer := await _request({"type": "offer_long" if _long_run else "offer", "width": eye_size, "height": eye_height, "hz": hz}, token)
	if token != _generation: return
	_busy = false
	if offer.get("state", "") != "awaiting_acceptance" or not offer.get("session") is String:
		_fail("XR offer rejected")
		return
	session = offer.session
	session_fps = hz
	session_eye_size = eye_size
	session_eye_height = eye_height
	var offer_text := "Accept control-only XR preparation?"
	if not _relay_config.is_empty():
		offer_text = "Accept XR standby? Desktop stays visible" if _standby_only else "Accept exclusive Meteor XR session?"
		if _handover_on_ready: offer_text = "Accept XR handover? Desktop returns on exit"
	_status("offered", offer_text)
	_watch_lease(token, "offered", 15000)

func accept_offer() -> void:
	if state != "offered" or _busy: return
	_busy = true
	var token := _generation
	var reply := await _request({"type": "accept", "session": session}, token)
	if token != _generation: return
	_busy = false
	if reply.get("state", "") != "prepared" or reply.get("session", "") != session or reply.get("lan_video_available", true) != false:
		_fail("XR acceptance failed or unsupported transport")
		return
	if not _update_runtime(reply):
		_fail("Invalid initial XR runtime status")
		return
	_status("prepared", "Preparing authenticated XR transport" if not _relay_config.is_empty() else "Control-only XR preparation accepted")
	_watch_lease(token, "prepared", 360000 if _long_run else 60000)
	if not _relay_config.is_empty() and reply.get("relay") is Dictionary:
		_start_relay(reply.relay, token)

func _start_relay(ports: Dictionary, token: int) -> void:
	if not ClassDB.class_exists("MeteorXrRelay") or int(ports.get("framing", 0)) != 1:
		_fail("Native relay worker unavailable")
		return
	if session.length() != 32 or session.hex_decode().size() != 16:
		_fail("Invalid relay session ID")
		return
	var reason: String = owner.pcvr_test.standby_busy_reason() if _standby_only else owner.pcvr_test.busy_reason()
	if not reason.is_empty():
		_fail(reason)
		return
	_relay_config["video"] = int(ports.get("video", 0))
	_relay_config["tracking"] = int(ports.get("tracking", 0))
	_relay_config["session"] = session.hex_decode()
	if _handover_on_ready:
		_owns_timing = true
		var prepared: bool = await owner.settings_controller.prepare_pcvr_timing(session_fps)
		if token != _generation: return
		if not prepared:
			_fail("Cannot prepare matched PCVR display and desktop timing")
			return
	if not owner.pcvr_test.backend.has_method("set_meteor_eye_dimensions") or not owner.pcvr_test.backend.set_meteor_eye_dimensions(session_eye_size, session_eye_height):
		_fail("Cannot configure matching PCVR projection resolution")
		return
	if owner.pcvr_test.backend.has_method("set_pcvr_post_processing"):
		var post := PCVRVideoSettings.new(owner.get("device_is_quest3") == true)
		post.load_from()
		owner.pcvr_test.backend.set_pcvr_post_processing(post.sharpen, post.sampling)
	_relay = ClassDB.instantiate("MeteorXrRelay")
	_owns_projection = true
	if _standby_only:
		if not owner.pcvr_test.start_meteor_standby(300.0 if _long_run else 45.0):
			_fail("XR standby entry rejected")
			return
	else:
		owner.pcvr_test.start(false, true, 300.0 if _long_run else 45.0)
		if not owner.pcvr_test.is_exclusive():
			_fail("Exclusive XR entry rejected")
			return
	var deadline := Time.get_ticks_msec() + 5000
	while token == _generation:
		var native: Dictionary = owner.pcvr_test.backend.get_test_status()
		if bool(native.get("meteor_endpoints_ready", false)): break
		# Native idle is expected until the asynchronous render-layer preparation
		# drains. Do not tear down the accepted lease before start_meteor_test runs.
		var owns_backend: bool = owner.pcvr_test.standby_active if _standby_only else owner.pcvr_test.is_exclusive()
		if Time.get_ticks_msec() >= deadline or relay_preparation_failed(str(native.get("state", "failed")), owns_backend):
			_fail("Local XR endpoints did not become ready")
			return
		await owner.get_tree().process_frame
	if token != _generation: return
	if not _relay.start(_relay_config):
		_fail("Native relay startup failed")
		return
	if _handover_on_ready and not owner.pcvr_handover.arm(self):
		_fail("XR handover requires a single desktop/welcome screen and updated native provider")
		return
	if _handover_on_ready: _owns_timing = false # Handover now owns drain-before-restore.
	_watch_relay(token)

static func relay_preparation_failed(native_state: String, exclusive: bool) -> bool:
	return not exclusive or native_state in ["failed", "stopping"]

func _watch_relay(token: int) -> void:
	while token == _generation and _owns_projection and _relay:
		var status: Dictionary = _relay.get_status()
		if bool(status.get("failed", false)):
			_fail("Authenticated XR relay disconnected")
			return
		if bool(status.get("idle", false)):
			cancel()
			return
		await owner.get_tree().process_frame
