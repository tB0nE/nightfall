extends "res://meteor_diagnostic_base.gd"
var input_tick := 0
## Observe/stop the upstream demo; do not create its scene or enable its viewport.
func _ready() -> void:
	output = OS.get_environment("METEOR_PROBE_OUTPUT")
	minimum_frames = int(OS.get_environment("METEOR_CONTINUOUS_FRAMES"))
	var xr := XRServer.find_interface("OpenXR")
	if not xr or not xr.is_initialized():
		push_error("ENGINE_XR_FAILED upstream OpenXR not initialized")
		get_tree().quit(2)
		return
	xr.session_stopping.connect(_session_stopping)
	RenderingServer.frame_post_draw.connect(_drawn)
	print("ENGINE_XR_UPSTREAM origin_centric_movement")
	print("ENGINE_XR_READY renderer=%s target=%s" % [RenderingServer.get_current_rendering_method(), xr.get_render_target_size()])

func _process(delta: float) -> void:
	if OS.get_environment("METEOR_XR_CONTROLLERS") == "1":
		input_tick += 1
		if input_tick % 6 == 0:
			var scene := get_tree().current_scene
			if scene:
				var origin := scene.get_node("XROrigin3D") as XROrigin3D
				var left := origin.get_node("LeftHand") as XRController3D
				var right := origin.get_node("RightHand") as XRController3D
				var movement := right.get_vector2(&"move")
				var ignored := left.get_vector2(&"move")
				print("UPSTREAM_INPUT left_active=%d right_active=%d left=%.4f,%.4f right=%.4f,%.4f origin=%.4f,%.4f,%.4f yaw=%.4f" % [
					int(left.get_is_active()), int(right.get_is_active()), ignored.x, ignored.y,
					movement.x, movement.y, origin.position.x, origin.position.y, origin.position.z, origin.rotation.y])
	super._process(delta)
