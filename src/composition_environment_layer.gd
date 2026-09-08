class_name CompositionEnvironmentLayer
extends RefCounted

var layer: Node3D = null
var capture_viewport: SubViewport = null
var capture_camera: Camera3D = null

func setup(scene_root: Node, xr_origin: Node3D, horizontal_angle_deg: float, capture_fov_deg: float) -> bool:
	if layer:
		return true
	layer = OpenXRCompositionLayerEquirect.new()
	layer.name = "CompBgEquirect"
	layer.set_sort_order(-100)
	layer.set_radius(40.0)
	layer.set_central_horizontal_angle(deg_to_rad(horizontal_angle_deg))
	layer.set_upper_vertical_angle(deg_to_rad(horizontal_angle_deg * 0.5))
	layer.set_lower_vertical_angle(deg_to_rad(horizontal_angle_deg * 0.5))
	layer.visible = false
	xr_origin.add_child(layer)
	if not layer.is_natively_supported():
		layer.queue_free()
		layer = null
		return false

	capture_viewport = SubViewport.new()
	capture_viewport.name = "CompBgCaptureViewport"
	capture_viewport.disable_3d = false
	capture_viewport.own_world_3d = true
	capture_viewport.transparent_bg = false
	capture_viewport.size = Vector2i(1024, 1024)
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	scene_root.add_child(capture_viewport)

	var world_environment := WorldEnvironment.new()
	world_environment.name = "CaptureEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 1)
	world_environment.environment = environment
	capture_viewport.add_child(world_environment)

	capture_camera = Camera3D.new()
	capture_camera.name = "CaptureCamera"
	capture_camera.fov = capture_fov_deg
	capture_camera.current = true
	capture_viewport.add_child(capture_camera)

	layer.set_layer_viewport(capture_viewport)
	return true
