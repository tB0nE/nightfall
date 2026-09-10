class_name CompositionControllerRays
extends RefCounted

const QUAD_LENGTH := 0.4
const QUAD_WIDTH := 0.003
const START_OFFSET := 0.06
const QUAD_SIZE := Vector2(QUAD_WIDTH, QUAD_LENGTH)

var right_layer: Node3D = null
var right_viewport: SubViewport = null
var left_layer: Node3D = null
var left_viewport: SubViewport = null

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if right_layer or left_layer:
		return
	var texture := _make_texture(32, 256)
	for side in [&"right", &"left"]:
		var layer = OpenXRCompositionLayerQuad.new()
		layer.name = "CompLaser%sLayer" % String(side).capitalize()
		layer.set_sort_order(998)
		layer.set_enable_hole_punch(false)
		layer.set_alpha_blend(true)
		layer.set_quad_size(QUAD_SIZE)
		layer.visible = false
		xr_origin.add_child(layer)

		var viewport := SubViewport.new()
		viewport.name = "CompLaser%sViewport" % String(side).capitalize()
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.size = Vector2i(32, 256)
		# Keep rendering continuously. UPDATE_ONCE could run before the
		# viewport and texture are fully ready, leaving the ray blank forever.
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		scene_root.add_child(viewport)

		var gradient := TextureRect.new()
		gradient.name = "LaserGradient"
		gradient.anchors_preset = Control.PRESET_FULL_RECT
		gradient.anchor_right = 1.0
		gradient.anchor_bottom = 1.0
		gradient.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gradient.stretch_mode = TextureRect.STRETCH_SCALE
		gradient.flip_v = true
		gradient.texture = texture
		viewport.add_child(gradient)
		layer.set_layer_viewport(viewport)

		if side == &"right":
			right_layer = layer
			right_viewport = viewport
		else:
			left_layer = layer
			left_viewport = viewport

# Updates the fixed-length controller beams used by projectionless rendering.
# `enabled` is the diagnostic feature gate; `active` is the current XR and
# composition-layer state. Keeping those separate preserves the existing
# behavior where temporarily leaving composition mode hides the beams without
# needlessly stopping and restarting their backing viewports.
func update(enabled: bool, active: bool, camera_position: Vector3,
		right_raycast: RayCast3D, left_raycast: RayCast3D) -> void:
	if not right_layer and not left_layer:
		return
	if not enabled:
		_set_viewport_active(right_viewport, false)
		_set_viewport_active(left_viewport, false)
		_set_hidden(right_layer)
		_set_hidden(left_layer)
		return
	if not active:
		_set_hidden(right_layer)
		_set_hidden(left_layer)
		return
	_update_one(right_layer, right_raycast, camera_position)
	_update_one(left_layer, left_raycast, camera_position)

func _update_one(layer: Node3D, raycast: RayCast3D,
		camera_position: Vector3) -> void:
	if not layer:
		return
	# raycast.enabled is the application's active-pointing signal for both
	# physical controllers and tracked hands. XRController3D.get_is_active()
	# only describes the controller pose and is false during hand tracking.
	if not raycast or not raycast.enabled:
		_set_hidden(layer)
		return
	var ray_origin := raycast.global_position
	var ray_dir := -raycast.global_transform.basis.z.normalized()
	var to_camera := (camera_position - ray_origin).normalized()
	# Keep local Y on the ray direction (the texture fade axis) while rotating
	# the quad around that axis to face the camera.
	var z_axis := to_camera - to_camera.project(ray_dir)
	if z_axis.length() < 0.001:
		z_axis = layer.global_transform.basis.z
	z_axis = z_axis.normalized()
	var x_axis := ray_dir.cross(z_axis).normalized()
	z_axis = x_axis.cross(ray_dir).normalized()
	layer.global_transform.basis = Basis(x_axis, ray_dir, z_axis)
	layer.global_position = ray_origin + ray_dir * (START_OFFSET + QUAD_LENGTH * 0.5)
	layer.set_quad_size(QUAD_SIZE)
	layer.visible = true

func _set_hidden(layer: Node3D) -> void:
	if layer:
		# Preserve the OpenXR swapchain by changing only the world-space size.
		layer.set_quad_size(Vector2(0.0001, 0.0001))

func _set_viewport_active(viewport: SubViewport, active: bool) -> void:
	if not viewport:
		return
	var wanted := SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if viewport.render_target_update_mode != wanted:
		viewport.render_target_update_mode = wanted

# Capsule/stadium alpha mask combined with a length-fade gradient. This has
# enough pixel width for rounded ends, unlike the one-pixel texture used by
# the normal 3D controller ray.
func _make_texture(width: int, height: int) -> ImageTexture:
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var cap_radius := float(width) * 0.5
	var half_width := float(width) * 0.5
	var body_top := cap_radius
	var body_bottom := float(height - 1) - cap_radius
	for y in range(height):
		var fade := 1.0 - float(y) / float(height - 1)
		var fy := float(y)
		for x in range(width):
			var nx := float(x) - (float(width) - 1.0) * 0.5
			var shape_alpha := 0.0
			if fy < body_top:
				var distance := sqrt(nx * nx + (body_top - fy) * (body_top - fy))
				shape_alpha = clampf(cap_radius - distance + 0.5, 0.0, 1.0)
			elif fy > body_bottom:
				var distance := sqrt(nx * nx + (fy - body_bottom) * (fy - body_bottom))
				shape_alpha = clampf(cap_radius - distance + 0.5, 0.0, 1.0)
			else:
				shape_alpha = clampf(half_width - absf(nx) + 0.5, 0.0, 1.0)
			image.set_pixel(x, y, Color(1, 1, 1, fade * shape_alpha))
	return ImageTexture.create_from_image(image)
