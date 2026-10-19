extends Node3D
## An ordinary engine-rendered scene, not a replacement OpenXR frame loop.
var elapsed := 0.0
var rendered := 0
var cubes: Array[MeshInstance3D] = []
var output := ""
var minimum_frames := 32
var exit_requested := false
var monitor_elapsed := 0.0
var ledger_position := 0
var ledger_lines := 0
var monitor_polls := 0
var monitor_bytes := 0
var monitor_total_us := 0
var monitor_max_us := 0
var first_draw_us := 0
var last_draw_us := 0
var max_draw_gap_us := 0
var legacy_monitor := OS.get_environment("METEOR_XR_MONITOR_LEGACY") == "1"

func _ready() -> void:
	output = OS.get_environment("METEOR_PROBE_OUTPUT")
	minimum_frames = int(OS.get_environment("METEOR_CONTINUOUS_FRAMES"))
	var xr := XRServer.find_interface("OpenXR")
	if not xr or not xr.is_initialized():
		push_error("ENGINE_XR_FAILED OpenXR not initialized")
		get_tree().quit(2)
		return
	get_viewport().use_xr = true
	xr.session_stopping.connect(_session_stopping)
	var origin := XROrigin3D.new()
	add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	for row in range(3):
		for column in range(5):
			var cube := MeshInstance3D.new()
			cube.mesh = BoxMesh.new()
			cube.scale = Vector3.ONE * 0.22
			cube.position = Vector3((column - 2) * 0.5, (row - 1) * 0.45, -2.4 - row * 0.2)
			var material := StandardMaterial3D.new()
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.albedo_color = Color.from_hsv(float(column) / 5.0, 0.8, 0.4 + row * 0.25)
			cube.material_override = material
			add_child(cube)
			cubes.append(cube)
	RenderingServer.frame_post_draw.connect(_drawn)
	print("ENGINE_XR_READY renderer=%s target=%s" % [RenderingServer.get_current_rendering_method(), xr.get_render_target_size()])

func _drawn() -> void:
	rendered += 1
	var now := Time.get_ticks_usec()
	if last_draw_us: max_draw_gap_us = maxi(max_draw_gap_us, now - last_draw_us)
	else: first_draw_us = now
	last_draw_us = now

func _request_exit() -> void:
	if exit_requested: return
	exit_requested = true
	var request := FileAccess.open(output.path_join("engine-request-exit"), FileAccess.WRITE)
	request.store_line("engine fixture exit")
	request.close()

func _session_stopping() -> void:
	print("ENGINE_MONITOR_TIMING mode=%s polls=%d bytes=%d total_us=%d max_us=%d draws=%d draw_span_us=%d draw_max_us=%d" % [
		"legacy" if legacy_monitor else "incremental", monitor_polls, monitor_bytes,
		monitor_total_us, monitor_max_us, rendered, last_draw_us - first_draw_us, max_draw_gap_us])
	print("ENGINE_XR_STOPPING")
	get_tree().quit.call_deferred()

func _count_encoded_lines(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file: return -1
	var length := file.get_length()
	if legacy_monitor:
		monitor_bytes += length
		return file.get_as_text().strip_edges().split("\n").size()
	if length < ledger_position: return -1 # Unexpected truncation within a session.
	file.seek(ledger_position)
	var chunk := file.get_buffer(mini(length - ledger_position, 131072))
	ledger_position += chunk.size()
	monitor_bytes += chunk.size()
	# Count only completed records; a partially written line is counted when its
	# newline arrives in a later chunk. Never re-read the growing JSONL history.
	for byte in chunk:
		if byte == 10: ledger_lines += 1
	return ledger_lines

func _process(delta: float) -> void:
	elapsed += delta
	for index in range(cubes.size()):
		cubes[index].rotation = Vector3(elapsed * 0.4, elapsed * 0.7 + index * 0.15, 0)
	if FileAccess.file_exists(output.path_join("client-disconnected")):
		print("ENGINE_XR_INTERRUPTED tracking disconnected")
		_request_exit()
		return
	if elapsed > 35.0:
		push_error("ENGINE_XR_FAILED no encoded frames before deadline")
		get_tree().quit(3)
		return
	monitor_elapsed += delta
	if not legacy_monitor and monitor_elapsed < 0.1: return
	monitor_elapsed = 0.0
	var ledger := output.path_join("monado-stereo.jsonl")
	if FileAccess.file_exists(ledger):
		var start := Time.get_ticks_usec()
		var encoded := _count_encoded_lines(ledger)
		var cost := Time.get_ticks_usec() - start
		monitor_polls += 1
		monitor_total_us += cost
		monitor_max_us = maxi(monitor_max_us, cost)
		if encoded < 0:
			push_error("ENGINE_XR_FAILED diagnostic ledger unreadable/truncated")
			get_tree().quit(3)
			return
		if encoded >= minimum_frames and not exit_requested:
			var marker := FileAccess.open(output.path_join("engine-completion.tmp"), FileAccess.WRITE)
			marker.store_string(JSON.stringify({"state": "completion_requested", "target": minimum_frames,
				"encoded_at_request": encoded, "run_id": OS.get_environment("METEOR_ENGINE_RUN_ID")}))
			marker.close()
			DirAccess.rename_absolute(output.path_join("engine-completion.tmp"), output.path_join("engine-completion.json"))
			print("ENGINE_XR_COMPLETE encoded_at_least=%d draws=%d" % [encoded, rendered])
			_request_exit()
