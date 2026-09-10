class_name CompositionScreenControls
extends RefCounted

const CORNER_IDS := ["top-left", "top-right", "bottom-left", "bottom-right"]
const CORNER_VIEWPORT_SIZE := Vector2i(128, 128)
const CORNER_LINE_WIDTH := 20
const CORNER_SIZE_RATIO := 0.027

func setup(scene_root: Node, xr_origin: Node3D, shortcuts: ScreenShortcutBar,
		screen: VRScreen) -> void:
	if screen.comp_grab_bar:
		return

	screen.comp_grab_bar = _make_layer("CompGrabBarLayer_%s" % screen.monitor_id)
	xr_origin.add_child(screen.comp_grab_bar)
	screen.comp_grab_bar_viewport = _make_viewport(
		"CompGrabBarViewport_%s" % screen.monitor_id,
		ScreenShortcutBar.COMP_VIEWPORT_SIZE)
	scene_root.add_child(screen.comp_grab_bar_viewport)
	shortcuts.populate_composition_viewport(screen, screen.comp_grab_bar_viewport)
	screen.comp_grab_bar.set_layer_viewport(screen.comp_grab_bar_viewport)

	screen.comp_corner_layers.resize(4)
	screen.comp_corner_rects.resize(4)
	for i in range(4):
		var layer := _make_layer("CompCorner%dLayer_%s" % [i, screen.monitor_id])
		xr_origin.add_child(layer)
		var viewport := _make_viewport(
			"CompCorner%dViewport_%s" % [i, screen.monitor_id],
			CORNER_VIEWPORT_SIZE)
		scene_root.add_child(viewport)
		var rect := _make_corner_rect(CORNER_IDS[i])
		viewport.add_child(rect)
		layer.set_layer_viewport(viewport)
		screen.comp_corner_layers[i] = layer
		screen.comp_corner_rects[i] = rect

func update(screens: Array, active: bool, grab_bars_enabled: bool,
		corners_enabled: bool) -> void:
	for screen in screens:
		_update_corners(screen, active and corners_enabled)
		_update_grab_bar(screen, active and grab_bars_enabled)

func _update_grab_bar(screen: VRScreen, active: bool) -> void:
	var layer := screen.comp_grab_bar
	if not layer:
		return
	if not active:
		_set_layer_active(layer, false)
		return
	var mesh_size := screen.mesh_size
	layer.set_quad_size(Vector2(
		mesh_size.x * ScreenShortcutBar.STRIP_WIDTH_RATIO,
		mesh_size.x * ScreenShortcutBar.STRIP_HEIGHT_RATIO))
	# The source CylinderMesh is rotated for its local geometry. The textured
	# quad uses the screen basis directly so asymmetric shortcut icons remain
	# upright and their visual order matches the physics targets.
	layer.global_rotation = screen.global_rotation
	layer.global_position = screen.grab_bar.global_position
	_set_layer_active(layer, true)

func _update_corners(screen: VRScreen, active: bool) -> void:
	if screen.comp_corner_layers.is_empty():
		return
	if not active:
		for layer in screen.comp_corner_layers:
			_set_layer_active(layer, false)
		return
	var corner_size := screen.mesh_size.x * CORNER_SIZE_RATIO
	for i in range(screen.comp_corner_layers.size()):
		var layer = screen.comp_corner_layers[i]
		if not layer or i >= screen.corner_handles.size():
			continue
		var handle = screen.corner_handles[i]
		layer.set_quad_size(Vector2(corner_size, corner_size))
		layer.global_position = handle.global_position
		layer.global_rotation = handle.global_rotation
		_set_layer_active(layer, true)

func _make_layer(layer_name: String) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(998)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.visible = false
	return layer

func _make_viewport(viewport_name: String, viewport_size: Vector2i) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = viewport_size
	# Keep the render target resident while active. UPDATE_ONCE churns the
	# backing GLES texture as hover state changes on Quest.
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport

func _make_corner_rect(corner_id: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = "CornerBracket"
	rect.anchors_preset = Control.PRESET_FULL_RECT
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	# Dynamic hover/grab alpha is applied through modulate, so the generated
	# texture itself must retain full opacity.
	rect.texture = VRScreen._make_corner_texture(
		corner_id, CORNER_VIEWPORT_SIZE.x, CORNER_LINE_WIDTH, 1.0)
	return rect

func _set_layer_active(layer: Node3D, active: bool) -> void:
	if not layer:
		return
	if layer.visible != active:
		layer.visible = active
	var viewport = layer.get_layer_viewport()
	if viewport:
		var wanted := SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
		if viewport.render_target_update_mode != wanted:
			viewport.render_target_update_mode = wanted
