class_name SessionLifecycle
extends RefCounted

enum Phase {
	BOOT,
	SERVER_SELECTION,
	CONNECTING,
	STREAMING,
	RESTARTING,
	RECONNECTING,
	DISCONNECTING,
	FAILED,
}

signal phase_changed(previous: int, current: int)

var phase: Phase = Phase.BOOT
var media_active: bool = false
var connect_timeout_pending: bool = false

func phase_name() -> String:
	return Phase.keys()[phase].to_lower()

func is_restarting() -> bool:
	return phase == Phase.RESTARTING

func is_reconnecting() -> bool:
	return phase == Phase.RECONNECTING

func _set_phase(next_phase: Phase) -> void:
	if phase == next_phase:
		return
	var previous := phase
	phase = next_phase
	phase_changed.emit(previous, phase)

func show_server_selection() -> void:
	media_active = false
	connect_timeout_pending = false
	_set_phase(Phase.SERVER_SELECTION)

func begin_connect() -> void:
	# A restarted or native auto-reconnected connection keeps its intent until
	# stream_started arrives; that intent controls UI preservation and resource
	# teardown behavior.
	if phase != Phase.RESTARTING and phase != Phase.RECONNECTING:
		_set_phase(Phase.CONNECTING)

func arm_connect_timeout() -> void:
	connect_timeout_pending = true
	begin_connect()

func cancel_connect_timeout() -> void:
	connect_timeout_pending = false

func stream_started() -> bool:
	var was_restarting := phase == Phase.RESTARTING
	media_active = true
	connect_timeout_pending = false
	_set_phase(Phase.STREAMING)
	return was_restarting

func request_restart() -> void:
	_set_phase(Phase.RESTARTING)

func request_disconnect() -> void:
	_set_phase(Phase.DISCONNECTING)

func reconnect_scheduled() -> void:
	media_active = false
	_set_phase(Phase.RECONNECTING)

func stream_terminated(auto_reconnect: bool, error_code: int) -> void:
	media_active = false
	if phase == Phase.RESTARTING:
		return
	if auto_reconnect and error_code != 0:
		_set_phase(Phase.RECONNECTING)
	elif phase != Phase.FAILED:
		_set_phase(Phase.SERVER_SELECTION)

func fail() -> void:
	media_active = false
	connect_timeout_pending = false
	_set_phase(Phase.FAILED)

func finish_cleanup() -> void:
	media_active = false
	connect_timeout_pending = false
	if phase != Phase.FAILED:
		_set_phase(Phase.SERVER_SELECTION)
