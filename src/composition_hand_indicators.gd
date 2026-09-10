class_name CompositionHandIndicators
extends RefCounted

const QUAD_SIZE := 0.32
const VIEWPORT_SIZE := Vector2i(256, 256)

var right_layer: Node3D = null
var right_triangle: ColorRect = null
var left_layer: Node3D = null
var left_triangle: ColorRect = null

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if right_layer or left_layer:
		return
	for side in [&"right", &"left"]:
		var layer := _make_layer("CompHand%sLayer" % String(side).capitalize())
		xr_origin.add_child(layer)

		var viewport := _make_viewport("CompHand%sViewport" % String(side).capitalize())
		scene_root.add_child(viewport)

		var triangle := _make_triangle()
		viewport.add_child(triangle)
		layer.set_layer_viewport(viewport)

		if side == &"right":
			right_layer = layer
			right_triangle = triangle
		else:
			left_layer = layer
			left_triangle = triangle

func _make_layer(layer_name: String) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(998)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(Vector2(QUAD_SIZE, QUAD_SIZE))
	layer.visible = false
	return layer

func _make_viewport(viewport_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	# The triangle shader's smoothstep antialiasing needs enough pixels to
	# blend cleanly on a 0.32 m quad; 64x64 appeared visibly blocky on-device.
	viewport.size = VIEWPORT_SIZE
	viewport.msaa_2d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport

func _make_triangle() -> ColorRect:
	var triangle := ColorRect.new()
	triangle.name = "CompHandTriangle"
	triangle.anchors_preset = Control.PRESET_FULL_RECT
	triangle.anchor_right = 1.0
	triangle.anchor_bottom = 1.0
	triangle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = preload("res://src/shaders/inverted_triangle.gdshader")
	triangle.material = material
	triangle.visible = true
	return triangle
