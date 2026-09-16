class_name CompositionPanelLayers
extends RefCounted

enum KeyboardMaterialAction {
	NONE,
	MAKE_TRANSPARENT,
	RESTORE,
}

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

func has_ui() -> bool:
	return ui_layer != null

func show_ui(source: Node3D) -> void:
	if not ui_layer:
		return
	if source:
		ui_layer.global_position = source.global_position
		ui_layer.global_rotation = source.global_rotation
	ui_layer.visible = true

func hide_ui() -> void:
	if ui_layer:
		ui_layer.visible = false

func deactivate() -> void:
	# Mesh/composition switching is a rare renderer transition, so fully hiding
	# these layers here is intentional. Rapid tooltip visibility remains encoded
	# in transparent viewport content and never toggles its stable layer.
	if ui_layer:
		ui_layer.visible = false
	if keyboard_layer:
		keyboard_layer.visible = false

func sync_transforms(ui_source: Node3D, keyboard) -> KeyboardMaterialAction:
	if ui_layer and ui_layer.visible and ui_source:
		ui_layer.global_position = ui_source.global_position
		ui_layer.global_rotation = ui_source.global_rotation
	if keyboard_layer and keyboard and keyboard.visible:
		keyboard_layer.global_position = keyboard.global_position
		keyboard_layer.global_rotation = keyboard.global_rotation
		keyboard_layer.visible = true
		if keyboard.mesh_instance.visible:
			return KeyboardMaterialAction.MAKE_TRANSPARENT
	else:
		if keyboard_layer:
			keyboard_layer.visible = false
		if keyboard and not keyboard.mesh_instance.visible:
			return KeyboardMaterialAction.RESTORE
	return KeyboardMaterialAction.NONE

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
