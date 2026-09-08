class_name CompositionControllerRays
extends RefCounted

var right_layer: Node3D = null
var right_viewport: SubViewport = null
var left_layer: Node3D = null
var left_viewport: SubViewport = null

func setup(scene_root: Node, xr_origin: Node3D, quad_size: Vector2) -> void:
	if right_layer or left_layer:
		return
	var texture := _make_texture(32, 256)
	for side in [&"right", &"left"]:
		var layer = OpenXRCompositionLayerQuad.new()
		layer.name = "CompLaser%sLayer" % String(side).capitalize()
		layer.set_sort_order(998)
		layer.set_enable_hole_punch(false)
		layer.set_alpha_blend(true)
		layer.set_quad_size(quad_size)
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
