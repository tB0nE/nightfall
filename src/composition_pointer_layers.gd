class_name CompositionPointerLayers
extends RefCounted

var cursor_layer: Node3D = null
var cursor_viewport: SubViewport = null
var secondary_cursor_layer: Node3D = null
var secondary_cursor_viewport: SubViewport = null
var _pointer_rect: TextureRect = null
var _circle_rect: ColorRect = null

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if cursor_layer:
		return
	cursor_layer = _make_layer("CompCursorLayer", Vector2(0.04, 0.04))
	xr_origin.add_child(cursor_layer)
	cursor_viewport = _make_viewport("CompCursorViewport", Vector2i(40, 64))
	scene_root.add_child(cursor_viewport)

	_pointer_rect = TextureRect.new()
	_pointer_rect.name = "PointerTexture"
	_pointer_rect.anchors_preset = Control.PRESET_FULL_RECT
	_pointer_rect.anchor_right = 1.0
	_pointer_rect.anchor_bottom = 1.0
	_pointer_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pointer_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_pointer_rect.texture = load("res://src/assets/mouse_pointer_01.png")
	cursor_viewport.add_child(_pointer_rect)
	_circle_rect = _make_circle("CircleTexture", false)
	cursor_viewport.add_child(_circle_rect)
	cursor_layer.set_layer_viewport(cursor_viewport)

	secondary_cursor_layer = _make_layer("LeftCompCursorLayer", Vector2(0.035, 0.035))
	xr_origin.add_child(secondary_cursor_layer)
	secondary_cursor_viewport = _make_viewport("LeftCompCursorViewport", Vector2i(256, 256))
	scene_root.add_child(secondary_cursor_viewport)
	secondary_cursor_viewport.add_child(_make_circle("CircleTexture", true))
	secondary_cursor_layer.set_layer_viewport(secondary_cursor_viewport)

func hide_primary() -> void:
	_set_hidden(cursor_layer)

func hide_secondary() -> void:
	_set_hidden(secondary_cursor_layer)

func has_primary() -> bool:
	return cursor_layer != null

func has_secondary() -> bool:
	return secondary_cursor_layer != null

func sync_viewports(primary_active: bool, secondary_active: bool) -> void:
	_set_viewport_active(cursor_viewport, primary_active)
	_set_viewport_active(secondary_cursor_viewport, secondary_active)

func deactivate() -> void:
	# Renderer switching is a rare transition, unlike per-frame pointer hiding,
	# so fully remove both layers from composition at this boundary.
	if cursor_layer:
		cursor_layer.visible = false
	if secondary_cursor_layer:
		secondary_cursor_layer.visible = false

func hide_all_embedded(screens: Array) -> void:
	for screen in screens:
		_hide_embedded_pair(screen.comp_stream_cursor, screen.comp_stream_cursor_circle)
		_hide_embedded_pair(screen.comp_stream_cursor_left, screen.comp_stream_cursor_circle_left)
		_hide_embedded_pair(screen.comp_stream_cursor_right, screen.comp_stream_cursor_circle_right)

func show_embedded(screen: VRScreen, screens: Array, hit_point: Vector3,
		bezel_enabled: bool, cursor_mode: int, stereo_mode: int,
		ai_cursor_position: int, depth_parallax: float,
		primary_screen: VRScreen) -> void:
	for other in screens:
		if other != screen:
			_hide_embedded_pair(other.comp_stream_cursor, other.comp_stream_cursor_circle)
			_hide_embedded_pair(other.comp_stream_cursor_left, other.comp_stream_cursor_circle_left)
			_hide_embedded_pair(other.comp_stream_cursor_right, other.comp_stream_cursor_circle_right)
	var uv := screen.hit_point_to_uv(hit_point)
	var bezel_px := 8 if bezel_enabled else 0
	var base_width := screen.comp_base_size.x
	var base_height := screen.comp_base_size.y
	var cursor_px := maxi(1, int(48.0 * base_height / 1080.0))
	var cx := bezel_px + uv.x * base_width
	var cy := bezel_px + uv.y * base_height
	if stereo_mode >= 3:
		cx += (ai_cursor_position + 1) * 12.0 * base_height / 1080.0
	_show_embedded_pair(screen.comp_stream_cursor, screen.comp_stream_cursor_circle,
		cx, cy, cursor_px, cursor_mode)
	if stereo_mode > 0 and screen == primary_screen:
		var left_cx := cx
		if stereo_mode in [5, 6, 10, 11]:
			left_cx += (0.015 / 0.042) * depth_parallax * base_width
		elif stereo_mode >= 3:
			left_cx += 0.015 * base_width
		_show_embedded_pair(screen.comp_stream_cursor_left,
			screen.comp_stream_cursor_circle_left, left_cx, cy, cursor_px, cursor_mode)
		_show_embedded_pair(screen.comp_stream_cursor_right,
			screen.comp_stream_cursor_circle_right, cx, cy, cursor_px, cursor_mode)
	else:
		_hide_embedded_pair(screen.comp_stream_cursor_left, screen.comp_stream_cursor_circle_left)
		_hide_embedded_pair(screen.comp_stream_cursor_right, screen.comp_stream_cursor_circle_right)

func show_primary(hit_point: Vector3, surface_normal: Vector3,
		camera_position: Vector3, screen_position: Vector3, on_screen: bool,
		cursor_mode: int, world_offset: Vector3 = Vector3.ZERO) -> void:
	if not cursor_layer:
		return
	var to_camera := (camera_position - hit_point).normalized()
	var distance_scale := 1.0
	if on_screen:
		var screen_distance := camera_position.distance_to(screen_position)
		if screen_distance > 0.0001:
			distance_scale = camera_position.distance_to(hit_point) / screen_distance
	if cursor_mode == 0:
		_set_cursor_art(false)
		_set_cursor_viewport_size(Vector2i(256, 256))
		cursor_layer.set_quad_size(Vector2(0.035 * distance_scale, 0.035 * distance_scale))
		_place_primary(hit_point + world_offset + surface_normal * 0.002, to_camera)
	elif on_screen:
		_set_cursor_art(true)
		_set_cursor_viewport_size(Vector2i(40, 64))
		cursor_layer.set_quad_size(Vector2(0.04 * distance_scale, 0.064 * distance_scale))
		_place_primary(hit_point + world_offset + surface_normal * 0.002, to_camera)
		var right := cursor_layer.global_transform.basis.x
		var up := cursor_layer.global_transform.basis.y
		cursor_layer.global_position += right * 0.02 - up * 0.032
	else:
		_set_cursor_art(false)
		_set_cursor_viewport_size(Vector2i(256, 256))
		cursor_layer.set_quad_size(Vector2(0.035, 0.035))
		_place_primary(hit_point + surface_normal * 0.002, to_camera)
	cursor_layer.visible = true

func show_secondary(hit_point: Vector3, camera_position: Vector3) -> void:
	if not secondary_cursor_layer:
		return
	var to_camera := (camera_position - hit_point).normalized()
	secondary_cursor_layer.global_position = hit_point + to_camera * 0.002
	secondary_cursor_layer.look_at(
		secondary_cursor_layer.global_position + to_camera, Vector3.UP)
	secondary_cursor_layer.rotate_object_local(Vector3.UP, PI)
	secondary_cursor_layer.set_quad_size(Vector2(0.035, 0.035))
	secondary_cursor_layer.visible = true

func _set_cursor_art(show_pointer: bool) -> void:
	if _pointer_rect:
		_pointer_rect.visible = show_pointer
	if _circle_rect:
		_circle_rect.visible = not show_pointer

func _set_cursor_viewport_size(wanted: Vector2i) -> void:
	# GLES keeps the original 40x64 target resident; resizing it while active
	# can rebuild the OpenXR layer's backing swapchain.
	if cursor_viewport and RenderingServer.get_current_rendering_method() != "gl_compatibility":
		cursor_viewport.size = wanted

func _place_primary(position: Vector3, to_camera: Vector3) -> void:
	cursor_layer.global_position = position
	cursor_layer.look_at(cursor_layer.global_position + to_camera, Vector3.UP)
	cursor_layer.rotate_object_local(Vector3.UP, PI)

func _show_embedded_pair(cursor: TextureRect, circle: ColorRect, cx: float,
		cy: float, cursor_px: int, cursor_mode: int) -> void:
	if cursor_mode == 0:
		if cursor:
			cursor.visible = false
		if circle:
			circle.visible = true
			circle.position = Vector2(cx - cursor_px * 0.5, cy - cursor_px * 0.5)
			circle.size = Vector2(cursor_px, cursor_px)
	else:
		if circle:
			circle.visible = false
		if cursor:
			cursor.visible = true
			cursor.position = Vector2(cx, cy)
			cursor.size = Vector2(cursor_px, cursor_px * 1.6)

func _hide_embedded_pair(cursor: TextureRect, circle: ColorRect) -> void:
	if cursor:
		cursor.visible = false
	if circle:
		circle.visible = false

func _set_hidden(layer: Node3D) -> void:
	if layer:
		# Do not toggle visibility during normal pointer movement: that destroys
		# and recreates the OpenXR swapchain repeatedly under GLES.
		layer.set_quad_size(Vector2(0.0001, 0.0001))

func _set_viewport_active(viewport: SubViewport, active: bool) -> void:
	if not viewport:
		return
	var wanted := SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if viewport.render_target_update_mode != wanted:
		viewport.render_target_update_mode = wanted

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
