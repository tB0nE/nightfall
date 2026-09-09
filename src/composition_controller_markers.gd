class_name CompositionControllerMarkers
extends RefCounted

var right_layer: Node3D = null
var right_viewport: SubViewport = null
var right_circle: ColorRect = null
var left_layer: Node3D = null
var left_viewport: SubViewport = null
var left_circle: ColorRect = null

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if right_layer or left_layer:
		return
	for side in [&"right", &"left"]:
		var layer := _make_layer("CompMarker%sLayer" % String(side).capitalize())
		xr_origin.add_child(layer)

		var viewport := _make_viewport("CompMarker%sViewport" % String(side).capitalize())
		scene_root.add_child(viewport)

		var circle := _make_circle()
		viewport.add_child(circle)
		layer.set_layer_viewport(viewport)

		if side == &"right":
			right_layer = layer
			right_viewport = viewport
			right_circle = circle
		else:
			left_layer = layer
			left_viewport = viewport
			left_circle = circle

func _make_layer(layer_name: String) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(998)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(Vector2(0.03, 0.03))
	layer.visible = false
	return layer

func _make_viewport(viewport_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = Vector2i(64, 64)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport

func _make_circle() -> ColorRect:
	var circle := ColorRect.new()
	circle.name = "MarkerCircle"
	circle.anchors_preset = Control.PRESET_FULL_RECT
	circle.anchor_right = 1.0
	circle.anchor_bottom = 1.0
	circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = preload("res://src/shaders/circle_cursor.gdshader")
	circle.material = material
	circle.visible = true
	return circle
