extends Node3D
## An ordinary engine-rendered scene, not a replacement OpenXR frame loop.
var elapsed := 0.0
var rendered := 0
var cubes: Array[MeshInstance3D] = []
var output := ""
var minimum_frames := 32
var exit_requested := false

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

func _request_exit() -> void:
	if exit_requested: return
	exit_requested = true
	var request := FileAccess.open(output.path_join("engine-request-exit"), FileAccess.WRITE)
	request.store_line("engine fixture exit")
	request.close()

func _session_stopping() -> void:
	print("ENGINE_XR_STOPPING")
	get_tree().quit.call_deferred()

func _process(delta: float) -> void:
	elapsed += delta
	for index in range(cubes.size()):
		cubes[index].rotation = Vector3(elapsed * 0.4, elapsed * 0.7 + index * 0.15, 0)
	if FileAccess.file_exists(output.path_join("client-disconnected")):
		print("ENGINE_XR_INTERRUPTED tracking disconnected")
		_request_exit()
		return
	var ledger := output.path_join("monado-stereo.jsonl")
	if FileAccess.file_exists(ledger):
		var encoded := FileAccess.get_file_as_string(ledger).strip_edges().split("\n").size()
		if encoded >= minimum_frames and not exit_requested:
			var marker := FileAccess.open(output.path_join("engine-completion.tmp"), FileAccess.WRITE)
			marker.store_string(JSON.stringify({"state": "completion_requested", "target": minimum_frames,
				"encoded_at_request": encoded, "run_id": OS.get_environment("METEOR_ENGINE_RUN_ID")}))
			marker.close()
			DirAccess.rename_absolute(output.path_join("engine-completion.tmp"), output.path_join("engine-completion.json"))
			print("ENGINE_XR_COMPLETE encoded_at_least=%d draws=%d" % [encoded, rendered])
			_request_exit()
	if elapsed > 35.0:
		push_error("ENGINE_XR_FAILED no encoded frames before deadline")
		get_tree().quit(3)
