class_name CompositionPointerLayers
extends RefCounted

var cursor_layer: Node3D = null
var cursor_viewport: SubViewport = null
var secondary_cursor_layer: Node3D = null
var secondary_cursor_viewport: SubViewport = null

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if cursor_layer:
		return
	cursor_layer = _make_layer("CompCursorLayer", Vector2(0.04, 0.04))
	xr_origin.add_child(cursor_layer)
	cursor_viewport = _make_viewport("CompCursorViewport", Vector2i(40, 64))
	scene_root.add_child(cursor_viewport)

	var pointer := TextureRect.new()
	pointer.name = "PointerTexture"
	pointer.anchors_preset = Control.PRESET_FULL_RECT
	pointer.anchor_right = 1.0
	pointer.anchor_bottom = 1.0
	pointer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pointer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pointer.texture = load("res://src/assets/mouse_pointer_01.png")
	cursor_viewport.add_child(pointer)
	cursor_viewport.add_child(_make_circle("CircleTexture", false))
	cursor_layer.set_layer_viewport(cursor_viewport)

	secondary_cursor_layer = _make_layer("LeftCompCursorLayer", Vector2(0.035, 0.035))
	xr_origin.add_child(secondary_cursor_layer)
	secondary_cursor_viewport = _make_viewport("LeftCompCursorViewport", Vector2i(256, 256))
	scene_root.add_child(secondary_cursor_viewport)
	secondary_cursor_viewport.add_child(_make_circle("CircleTexture", true))
	secondary_cursor_layer.set_layer_viewport(secondary_cursor_viewport)

func _make_layer(layer_name: String, quad_size: Vector2) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(999)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(quad_size)
	layer.visible = false
	return layer

func _make_viewport(viewport_name: String, viewport_size: Vector2i) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = viewport_size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport

func _make_circle(control_name: String, visible: bool) -> ColorRect:
	var circle := ColorRect.new()
	circle.name = control_name
	circle.anchors_preset = Control.PRESET_FULL_RECT
	circle.anchor_right = 1.0
	circle.anchor_bottom = 1.0
	var material := ShaderMaterial.new()
	material.shader = preload("res://src/shaders/circle_cursor.gdshader")
	circle.material = material
	circle.visible = visible
	return circle
