class_name CompositionPanelLayers
extends RefCounted

var ui_layer: Node3D = null
var keyboard_layer: Node3D = null
var tooltip_layer: Node3D = null

func setup_ui(xr_origin: Node3D, viewport: SubViewport, quad_size: Vector2) -> void:
	if ui_layer:
		return
	ui_layer = _make_panel_layer("CompUILayer", 1000, quad_size, viewport)
	xr_origin.add_child(ui_layer)

func setup_keyboard(xr_origin: Node3D, viewport: SubViewport, quad_size: Vector2) -> void:
	if keyboard_layer:
		return
	keyboard_layer = _make_panel_layer("CompKBLayer", 999, quad_size, viewport)
	xr_origin.add_child(keyboard_layer)

func setup_tooltip(xr_origin: Node3D, viewport: SubViewport, quad_size: Vector2) -> void:
	if tooltip_layer or viewport == null:
		return
	tooltip_layer = _make_panel_layer("CompTooltipLayer", 1001, quad_size, viewport)
	xr_origin.add_child(tooltip_layer)
	# Unlike the other panels, tooltips appear and disappear rapidly. Keep one
	# stable OpenXR swapchain and hide the bar using transparent viewport content
	# instead of changing layer visibility on every pointer transition.
	tooltip_layer.visible = true

func _make_panel_layer(layer_name: String, sort_order: int, quad_size: Vector2, viewport: SubViewport) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(sort_order)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(quad_size)
	layer.visible = false
	layer.set_layer_viewport(viewport)
	return layer
