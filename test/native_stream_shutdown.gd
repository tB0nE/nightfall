extends RefCounted

static func _connected_stream(host: Node) -> Node:
	var stream: Node = ClassDB.instantiate("NightfallStream")
	host.add_child(stream)
	# Exercise the real native state/signal path without opening a network stream.
	stream.get_stream_connection().emit_signal("stream_started")
	return stream

static func run(host: Node) -> Dictionary:
	var normal := {"states": 0, "terminated": 0}
	var stream := _connected_stream(host)
	stream.state_changed.connect(func(_state): normal.states += 1)
	stream.stream_terminated.connect(func(_code, _message): normal.terminated += 1)
	stream.stop_stream()
	assert(normal.states == 2 and normal.terminated == 1, "Explicit disconnect must still notify the UI")
	stream.free()
	var shutdown := {"states": 0, "terminated": 0}
	stream = _connected_stream(host)
	stream.state_changed.connect(func(_state): shutdown.states += 1)
	stream.stream_terminated.connect(func(_code, _message): shutdown.terminated += 1)
	stream.free()
	assert(shutdown.states == 0 and shutdown.terminated == 0,
		"Destroying a connected native node must not call back into the retiring scene")
	return {"explicit_disconnect_notifies": true, "destruction_is_silent": true}
