class_name MeteorMicrophone
extends RefCounted

## Sends the headset's microphone to Nightfall Meteor, which plays it into a
## "Nightfall Microphone" input device on the PC
## (docs/plans/active/meteor-microphone.md). Capture is native AAudio
## (addons/nightfall-stream/src/audio/meteor_mic.cpp); this decides when it
## runs: the Microphone setting is on, a stream goes through a Meteor that
## offers a microphone, the app has RECORD_AUDIO, and it isn't paused.

const PERMISSION := "android.permission.RECORD_AUDIO"
const RETRY_SEC := 5.0
const LOG_EVERY_SEC := 10.0

var main
var _paused := false
var _running := false
var _host := ""
var _port := 0
var _retry_at := 0.0
var _last_error := ""
var _log_at := 0.0
var _logged_packets := 0
var _peak := 0.0

func _init(owner) -> void:
	main = owner

static func is_supported() -> bool:
	return OS.get_name() == "Android"

static func has_permission() -> bool:
	return not is_supported() or OS.get_granted_permissions().has(PERMISSION)

## Asks for RECORD_AUDIO when it's missing. Calls done(granted) once the
## user has answered (straight away when it's already granted).
func request_permission(done: Callable) -> void:
	if has_permission():
		done.call(true)
		return
	var tree: SceneTree = main.get_tree()
	var on_result := func(permission: String, granted: bool) -> void:
		if permission == PERMISSION:
			done.call(granted)
	tree.on_request_permissions_result.connect(on_result, CONNECT_ONE_SHOT)
	if OS.request_permission(PERMISSION):
		# Granted without a dialog: no result signal follows.
		if tree.on_request_permissions_result.is_connected(on_result):
			tree.on_request_permissions_result.disconnect(on_result)
		done.call(true)

func is_live() -> bool:
	return _running

## Stops capture while the app is paused (headset asleep, app in the
## background); process() starts it again after resume.
func set_paused(paused: bool) -> void:
	_paused = paused
	if paused and _running:
		_stop("app paused")

func process() -> void:
	if not is_supported():
		return
	var native = _native()
	var offer: Dictionary = main.stream_manager.meteor_mic_info() if main.stream_manager else {}
	var wanted: bool = native != null and main.settings.microphone_enabled and main.is_streaming \
		and not offer.is_empty() and not _paused and has_permission()
	if not wanted:
		if _running:
			_stop("stream ended" if not main.is_streaming else "microphone turned off")
		_last_error = ""
		return
	var host: String = main.stream_manager.meteor_address()
	var port := int(offer["port"])
	if _running and (host != _host or port != _port):
		_stop("Meteor moved")
	var now := Time.get_ticks_msec() / 1000.0
	if not _running:
		if now < _retry_at:
			return
		var err: String = native.start_meteor_mic(host, port)
		if err.is_empty():
			_running = true
			_host = host
			_port = port
			_log_at = now
			_logged_packets = 0
			_peak = 0.0
			_last_error = ""
			main._log("[METEOR-MIC] Sending the microphone to %s:%d" % [host, port])
			main.ui_controller.show_temporary_status("Microphone on", 2.0)
		else:
			_retry_at = now + RETRY_SEC
			if err != _last_error:
				_last_error = err
				main._log("[METEOR-MIC] Can't start: %s" % err)
				main.ui_controller.show_temporary_status("Microphone unavailable", 2.0)
		return
	var status: Dictionary = native.get_meteor_mic_status()
	if not status.get("running", false):
		main._log("[METEOR-MIC] Capture stopped: %s" % status.get("error", "unknown"))
		_running = false
		_retry_at = now + RETRY_SEC
		return
	_peak = maxf(_peak, float(status.get("level", 0.0)))
	if now - _log_at >= LOG_EVERY_SEC:
		var packets := int(status.get("packets", 0))
		main._log("[METEOR-MIC] %.0f packets/s, peak %.0f dBFS" % [
			(packets - _logged_packets) / (now - _log_at), linear_to_db(maxf(_peak, 0.00001))])
		_log_at = now
		_logged_packets = packets
		_peak = 0.0

func _stop(reason: String) -> void:
	var native = _native()
	if native:
		native.stop_meteor_mic()
	_running = false
	main._log("[METEOR-MIC] Stopped (%s)" % reason)

func _native():
	var backend = main.stream_backend
	if backend and backend._v2 and backend._v2.has_method("start_meteor_mic"):
		return backend._v2
	return null
