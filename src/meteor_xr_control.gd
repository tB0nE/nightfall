class_name MeteorXRControl
extends RefCounted
## DEV authenticated control only. Prepared never starts exclusive presentation.
signal changed
const MAX_FRAME := 4096
const CONFIG := "user://meteor_xr_control.cfg"
const IDENTITY := "user://meteor_xr_identity.key"
var owner: Node
var state := "idle"
var message := ""
var session := ""
var _generation := 0
var _peer: StreamPeerTCP
var _send
var _receive
var _tx := 0
var _rx := 0
var _busy := false
var _relay
var _owns_projection := false
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
	_generation += 1
	var owned := _owns_projection
	_owns_projection = false
	if _relay: _relay.stop()
	_relay = null
	_relay_config.clear()
	if _peer: _peer.disconnect_from_host()
	_peer = null
	_send = null
	_receive = null
	session = ""
	_busy = false
	_status("idle", "Control connection closed")
	if owned and stop_projection: owner.pcvr_test.request_stop()

func _fail(text: String) -> void:
	cancel()
	_status("failed", text)

func _watch_lease(token: int, expected: String, milliseconds: int) -> void:
	var deadline := Time.get_ticks_msec() + milliseconds
	while token == _generation and state == expected:
		if not _peer:
			_fail("Control connection closed")
			return
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() >= deadline:
			_fail("Control lease expired or host disconnected")
			return
		await owner.get_tree().process_frame

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

func connect_offer() -> void:
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
	if token != _generation: return
	if authenticated.get("state", "") != "idle":
		_fail("Control authentication rejected or host busy")
		return
	var hz := int(config.get_value("host", "hz", 20))
	if hz not in [20, 60]:
		_fail("Unsupported developer XR rate")
		return
	var offer := await _request({"type": "offer", "width": 512, "height": 512, "hz": hz}, token)
	if token != _generation: return
	_busy = false
	if offer.get("state", "") != "awaiting_acceptance" or not offer.get("session") is String:
		_fail("XR offer rejected")
		return
	session = offer.session
	_status("offered", "Accept exclusive Meteor XR session?" if not _relay_config.is_empty() else "Accept control-only XR preparation?")
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
	_status("prepared", "Preparing authenticated XR transport" if not _relay_config.is_empty() else "Control-only XR preparation accepted")
	_watch_lease(token, "prepared", 60000)
	if not _relay_config.is_empty() and reply.get("relay") is Dictionary:
		_start_relay(reply.relay, token)

func _start_relay(ports: Dictionary, token: int) -> void:
	if not ClassDB.class_exists("MeteorXrRelay") or int(ports.get("framing", 0)) != 1:
		_fail("Native relay worker unavailable")
		return
	if session.length() != 32 or session.hex_decode().size() != 16:
		_fail("Invalid relay session ID")
		return
	var reason: String = owner.pcvr_test.busy_reason()
	if not reason.is_empty():
		_fail(reason)
		return
	_relay_config["video"] = int(ports.get("video", 0))
	_relay_config["tracking"] = int(ports.get("tracking", 0))
	_relay_config["session"] = session.hex_decode()
	_relay = ClassDB.instantiate("MeteorXrRelay")
	_owns_projection = true
	owner.pcvr_test.start(false, true)
	if not owner.pcvr_test.is_exclusive():
		_fail("Exclusive XR entry rejected")
		return
	var deadline := Time.get_ticks_msec() + 5000
	while token == _generation:
		var native: Dictionary = owner.pcvr_test.backend.get_test_status()
		if bool(native.get("meteor_endpoints_ready", false)): break
		# Native idle is expected until the asynchronous render-layer preparation
		# drains. Do not tear down the accepted lease before start_meteor_test runs.
		if Time.get_ticks_msec() >= deadline or relay_preparation_failed(str(native.get("state", "failed")), owner.pcvr_test.is_exclusive()):
			_fail("Local XR endpoints did not become ready")
			return
		await owner.get_tree().process_frame
	if token != _generation: return
	if not _relay.start(_relay_config):
		_fail("Native relay startup failed")
		return
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
