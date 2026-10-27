class_name CompositionScreenControls
extends RefCounted

const CORNER_IDS := ["top-left", "top-right", "bottom-left", "bottom-right"]
const CORNER_VIEWPORT_SIZE := Vector2i(128, 128)
const CORNER_LINE_WIDTH := 20
const CORNER_SIZE_RATIO := 0.027
const CORNER_ATLAS_WIDTH := 1536
var _scene_root: Node

func setup(scene_root: Node, xr_origin: Node3D, shortcuts: ScreenShortcutBar,
		screen: VRScreen) -> void:
	if screen.comp_corner_layer:
		return

	screen.comp_corner_layer = OpenXRCompositionLayerCylinder.new()
	screen.comp_corner_layer.name = "CompScreenControlsLayer_%s" % screen.monitor_id
	screen.comp_corner_layer.set_sort_order(998)
	screen.comp_corner_layer.set_enable_hole_punch(false)
	screen.comp_corner_layer.set_alpha_blend(true)
	screen.comp_corner_layer.visible = false
	xr_origin.add_child(screen.comp_corner_layer)
	screen.comp_corner_viewport = _make_viewport(
		"CompCornersViewport_%s" % screen.monitor_id, Vector2i(CORNER_ATLAS_WIDTH, 900))
	scene_root.add_child(screen.comp_corner_viewport)
	screen.comp_corner_layer.set_layer_viewport(screen.comp_corner_viewport)
	# Compatibility references intentionally point at the SAME node/viewport.
	# All 2D screen chrome occupies this one cylinder atlas, not a second quad.
	screen.comp_grab_bar = screen.comp_corner_layer
	screen.comp_grab_bar_viewport = screen.comp_corner_viewport
	shortcuts.populate_composition_viewport(screen, screen.comp_corner_viewport)
	var strip := screen.comp_corner_viewport.get_node("ShortcutStrip") as Control
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	strip.size = ScreenShortcutBar.COMP_VIEWPORT_SIZE
	screen.comp_corner_rects.resize(4)
	for i in range(4):
		var rect := _make_corner_rect(CORNER_IDS[i])
		screen.comp_corner_viewport.add_child(rect)
		screen.comp_corner_rects[i] = rect
	_scene_root = scene_root
	var menu = scene_root.screen_sources.menu_for_screen(screen)
	if menu:
		menu.attach(screen, screen.comp_corner_viewport)

func update(screens: Array, active: bool, grab_bars_enabled: bool,
		corners_enabled: bool, revealed_screen: VRScreen) -> void:
	for screen in screens:
		var provider = _scene_root.screen_sources.browser_for_screen(screen) if _scene_root else null
		# stop() owns the three-frame retirement window. Never submit its
		# hidden controls again while waiting for remove_browser_screen().
		if provider != null and provider.closing:
			_update_corners(screen, false, false)
			continue
		if _scene_root and _scene_root.comp:
			_scene_root.comp.refresh_browser_screen(screen)
		_update_corners(
			screen,
			active and (corners_enabled or grab_bars_enabled),
			screen == revealed_screen and corners_enabled,
			grab_bars_enabled)

func set_grab_bar_color(screen: VRScreen, color: Color) -> void:
	if not screen or not screen.comp_grab_bar_viewport:
		return
	var panel := screen.comp_grab_bar_viewport.find_child(
		"GrabBarPanel", true, false) as PanelContainer
	if not panel:
		return
	var style := panel.get_theme_stylebox("panel") as StyleBoxFlat
	if not style or style.bg_color == color:
		return
	style = style.duplicate()
	style.bg_color = color
	panel.add_theme_stylebox_override("panel", style)
	screen.comp_grab_bar_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func set_corner_alpha(screen: VRScreen, corner_index: int, alpha: float) -> void:
	if not screen or corner_index < 0 or corner_index >= screen.comp_corner_rects.size():
		return
	var rect = screen.comp_corner_rects[corner_index]
	if rect:
		rect.modulate.a = alpha

static func grab_strip_rect(mesh_size: Vector2, grab_y: float, surface_size: Vector2, margin: float) -> Rect2:
	var scale_px := CORNER_ATLAS_WIDTH / surface_size.x
	var strip_size := mesh_size.x * Vector2(ScreenShortcutBar.STRIP_WIDTH_RATIO, ScreenShortcutBar.STRIP_HEIGHT_RATIO)
	return Rect2(Vector2((surface_size.x - strip_size.x) * 0.5,
		margin + mesh_size.y * 0.5 - grab_y - strip_size.y * 0.5) * scale_px,
		strip_size * scale_px)

func _update_corners(screen: VRScreen, active: bool, artwork_visible: bool, grab_visible := false) -> void:
	var layer := screen.comp_corner_layer
	if not layer or not screen.comp_corner_viewport:
		return
	if not active:
		_set_layer_active(layer, false)
		return
	var corner_size := screen.mesh_size.x * CORNER_SIZE_RATIO
	var menu = _scene_root.screen_sources.menu_for_screen(screen) if _scene_root else null
	var grab_margin := -screen.grab_bar.position.y - screen.mesh_size.y * 0.5 \
		+ screen.mesh_size.x * ScreenShortcutBar.STRIP_HEIGHT_RATIO * 0.5
	var margin := maxf(corner_size, grab_margin)
	if menu: margin = maxf(margin, screen.mesh_size.x * ScreenTabStrip.TOP_MARGIN_RATIO)
	var surface_size := screen.mesh_size + Vector2(corner_size * 2.0, margin * 2.0)
	var radius := maxf(screen._comp_cyl_radius, 0.001) + 0.003
	layer.set_radius(radius)
	layer.set_central_angle(surface_size.x / radius)
	layer.set_aspect_ratio(surface_size.x / surface_size.y)
	layer.global_position = screen._comp_cyl_center
	layer.global_rotation = screen.global_rotation
	var viewport := screen.comp_corner_viewport
	var viewport_height := maxi(1, roundi(CORNER_ATLAS_WIDTH * surface_size.y / surface_size.x))
	var wanted_size := Vector2i(CORNER_ATLAS_WIDTH, viewport_height)
	if viewport.size != wanted_size:
		viewport.size = wanted_size
	var strip := viewport.get_node_or_null("ShortcutStrip") as Control
	if strip:
		var rect := grab_strip_rect(screen.mesh_size, screen.grab_bar.position.y, surface_size, margin)
		strip.position = rect.position
		strip.scale = rect.size / Vector2(ScreenShortcutBar.COMP_VIEWPORT_SIZE)
		strip.visible = grab_visible
	var pixel_size := maxi(1, roundi(CORNER_ATLAS_WIDTH * corner_size / surface_size.x))
	var vertical_inset := roundi((margin - corner_size) * CORNER_ATLAS_WIDTH / surface_size.x)
	for i in range(screen.comp_corner_rects.size()):
		var rect := screen.comp_corner_rects[i] as TextureRect
		if not rect:
			continue
		rect.size = Vector2(pixel_size, pixel_size)
		rect.position = Vector2(
			0 if i % 2 == 0 else CORNER_ATLAS_WIDTH - pixel_size,
			vertical_inset if i < 2 else viewport_height - pixel_size - vertical_inset)
		rect.visible = artwork_visible
	if menu:
		menu.update(screen, surface_size, margin, artwork_visible)
	_set_layer_active(layer, true)

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
