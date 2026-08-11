class_name CompositionLayerManager
extends RefCounted

var main
var available: bool = false
var in_use: bool = false
var _last_bind_rids: Array = []
var _last_bind_mode: Array = [0, 1, 0]

func invalidate_yuv_cache():
	_last_bind_rids = []
	_last_bind_mode = [0, 1, 0]

# set_shader_parameter("tex_y", ...) is fed either a Texture wrapper (the
# direct multi-plane YUV/AHB import path) or a raw RID (StreamConnection's
# compute-dispatch path sets it via texture_rd_create(), which returns an RID
# directly, not a Texture) - calling .get_rid() unconditionally only crashes
# once this branch is actually reachable (is_display_ready() correctly
# gating it, see the comment above bind_yuv_textures()'s real/fallback
# split) - a raw RID has no get_rid() method, only Texture-derived objects
# do. Handle both shapes instead of assuming one.
func _as_rid(v) -> RID:
	if v is RID:
		return v
	if v and v.has_method("get_rid"):
		return v.get_rid()
	return RID()

func _init(p_main):
	main = p_main
	available = ClassDB.class_exists("OpenXRCompositionLayerCylinder")

func get_screen_mesh_original_mat() -> Material:
	return main.primary_screen._original_mat

func get_cyl_params() -> Dictionary:
	var s = main.primary_screen
	return {"center": s._comp_cyl_center, "radius": s._comp_cyl_radius, "central_angle": s._comp_cyl_central_angle}

func get_shader_mats(s: VRScreen = null) -> Array:
	if s == null:
		s = main.primary_screen
	return [s.comp_shader_mat, s.comp_shader_mat_left, s.comp_shader_mat_right]

func get_stream_cursor_pair(index: int, s: VRScreen = null) -> Array:
	if s == null:
		s = main.primary_screen
	match index:
		0: return [s.comp_stream_cursor, s.comp_stream_cursor_circle]
		1: return [s.comp_stream_cursor_left, s.comp_stream_cursor_circle_left]
		_: return [s.comp_stream_cursor_right, s.comp_stream_cursor_circle_right]

func setup_screen(s: VRScreen, with_stereo: bool = true):
	if not available:
		return

	s.comp_cylinder = OpenXRCompositionLayerCylinder.new()
	s.comp_cylinder.name = "CompCylinderLayer_%s" % s.monitor_id
	s.comp_cylinder.set_sort_order(1)
	s.comp_cylinder.set_enable_hole_punch(false)
	s.comp_cylinder.set_alpha_blend(false)
	s.comp_cylinder.visible = false
	main.xr_origin.add_child(s.comp_cylinder)
	if s.comp_cylinder.is_natively_supported():
		main._log("[COMP] Cylinder layer natively supported (%s)" % s.monitor_id)
	else:
		main._log("[COMP] Cylinder layer NOT natively supported (%s)" % s.monitor_id)

	s.comp_viewport = SubViewport.new()
	s.comp_viewport.name = "CompViewport_%s" % s.monitor_id
	s.comp_viewport.disable_3d = true
	s.comp_viewport.transparent_bg = true
	s.comp_viewport.size = Vector2i(1920, 1080)
	s.comp_base_size = Vector2i(1920, 1080)
	s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(s.comp_viewport)

	s.comp_bezel_rect = _make_bezel_rect()
	s.comp_viewport.add_child(s.comp_bezel_rect)

	s.comp_yuv_rect = _make_yuv_rect()
	s.comp_shader_mat = ShaderMaterial.new()
	s.comp_shader_mat.shader = load("res://src/shaders/yuv_display.gdshader")
	s.comp_shader_mat.set_shader_parameter("main_texture", VRScreen.placeholder_texture())
	s.comp_yuv_rect.material = s.comp_shader_mat
	s.comp_bezel_rect.add_child(s.comp_yuv_rect)
	var dd = _make_loading_dots()
	s.comp_loading_label = dd["container"]
	s.comp_loading_dots = dd["dots"]
	s.comp_bezel_rect.add_child(s.comp_loading_label)

	s.comp_stream_cursor = _make_cursor_texture_rect()
	s.comp_bezel_rect.add_child(s.comp_stream_cursor)
	s.comp_stream_cursor_circle = _make_cursor_circle_rect()
	s.comp_bezel_rect.add_child(s.comp_stream_cursor_circle)

	s.comp_layer = s.comp_cylinder
	s.comp_layer.set_layer_viewport(s.comp_viewport)
	main._log("[COMP] Per-screen mono comp layer created (%s)" % s.monitor_id)

	if not with_stereo:
		return

	s.comp_cylinder_left = OpenXRCompositionLayerCylinder.new()
	s.comp_cylinder_left.name = "CompCylinderLeft_%s" % s.monitor_id
	s.comp_cylinder_left.set_sort_order(1)
	s.comp_cylinder_left.set_enable_hole_punch(false)
	s.comp_cylinder_left.set_alpha_blend(false)
	s.comp_cylinder_left.set_eye_visibility(OpenXRCompositionLayer.EYE_VISIBILITY_LEFT)
	s.comp_cylinder_left.visible = false
	main.xr_origin.add_child(s.comp_cylinder_left)

	s.comp_cylinder_right = OpenXRCompositionLayerCylinder.new()
	s.comp_cylinder_right.name = "CompCylinderRight_%s" % s.monitor_id
	s.comp_cylinder_right.set_sort_order(1)
	s.comp_cylinder_right.set_enable_hole_punch(false)
	s.comp_cylinder_right.set_alpha_blend(false)
	s.comp_cylinder_right.set_eye_visibility(OpenXRCompositionLayer.EYE_VISIBILITY_RIGHT)
	s.comp_cylinder_right.visible = false
	main.xr_origin.add_child(s.comp_cylinder_right)

	s.comp_viewport_left = SubViewport.new()
	s.comp_viewport_left.name = "CompViewportLeft_%s" % s.monitor_id
	s.comp_viewport_left.disable_3d = true
	s.comp_viewport_left.transparent_bg = true
	s.comp_viewport_left.size = Vector2i(1920, 1080)
	s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(s.comp_viewport_left)

	s.comp_bezel_rect_left = _make_bezel_rect()
	s.comp_viewport_left.add_child(s.comp_bezel_rect_left)
	s.comp_yuv_rect_left = _make_yuv_rect()
	s.comp_shader_mat_left = ShaderMaterial.new()
	s.comp_shader_mat_left.shader = load("res://src/shaders/yuv_display.gdshader")
	s.comp_shader_mat_left.set_shader_parameter("main_texture", VRScreen.placeholder_texture())
	s.comp_shader_mat_left.set_shader_parameter("eye_index", 1)
	s.comp_yuv_rect_left.material = s.comp_shader_mat_left
	s.comp_bezel_rect_left.add_child(s.comp_yuv_rect_left)
	var dd_left = _make_loading_dots()
	s.comp_loading_label_left = dd_left["container"]
	s.comp_loading_dots_left = dd_left["dots"]
	s.comp_bezel_rect_left.add_child(s.comp_loading_label_left)
	s.comp_stream_cursor_left = _make_cursor_texture_rect()
	s.comp_bezel_rect_left.add_child(s.comp_stream_cursor_left)
	s.comp_stream_cursor_circle_left = _make_cursor_circle_rect()
	s.comp_bezel_rect_left.add_child(s.comp_stream_cursor_circle_left)

	s.comp_viewport_right = SubViewport.new()
	s.comp_viewport_right.name = "CompViewportRight_%s" % s.monitor_id
	s.comp_viewport_right.disable_3d = true
	s.comp_viewport_right.transparent_bg = true
	s.comp_viewport_right.size = Vector2i(1920, 1080)
	s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(s.comp_viewport_right)

	s.comp_bezel_rect_right = _make_bezel_rect()
	s.comp_viewport_right.add_child(s.comp_bezel_rect_right)
	s.comp_yuv_rect_right = _make_yuv_rect()
	s.comp_shader_mat_right = ShaderMaterial.new()
	s.comp_shader_mat_right.shader = load("res://src/shaders/yuv_display.gdshader")
	s.comp_shader_mat_right.set_shader_parameter("main_texture", VRScreen.placeholder_texture())
	s.comp_shader_mat_right.set_shader_parameter("eye_index", 2)
	s.comp_yuv_rect_right.material = s.comp_shader_mat_right
	s.comp_bezel_rect_right.add_child(s.comp_yuv_rect_right)
	var dd_right = _make_loading_dots()
	s.comp_loading_label_right = dd_right["container"]
	s.comp_loading_dots_right = dd_right["dots"]
	s.comp_bezel_rect_right.add_child(s.comp_loading_label_right)
	s.comp_stream_cursor_right = _make_cursor_texture_rect()
	s.comp_bezel_rect_right.add_child(s.comp_stream_cursor_right)
	s.comp_stream_cursor_circle_right = _make_cursor_circle_rect()
	s.comp_bezel_rect_right.add_child(s.comp_stream_cursor_circle_right)

	s.comp_cylinder_left.set_layer_viewport(s.comp_viewport_left)
	s.comp_cylinder_right.set_layer_viewport(s.comp_viewport_right)
	main._log("[COMP] Per-screen stereo comp layers created (%s)" % s.monitor_id)

func _make_bezel_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompBezelRect"
	r.color = Color(0, 0, 0, 1)
	r.anchors_preset = 15
	r.anchor_right = 1.0
	r.anchor_bottom = 1.0
	r.grow_horizontal = 2
	r.grow_vertical = 2
	return r

func _make_yuv_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompYuvRect"
	r.anchors_preset = 15
	r.anchor_right = 1.0
	r.anchor_bottom = 1.0
	r.grow_horizontal = 2
	r.grow_vertical = 2
	return r

const DOT_COLOR := Color(0.25, 0.25, 0.25)
const DOT_HIDDEN_COLOR := Color(0.45, 0.45, 0.45)  # matches the placeholder/background grey, so a "hidden" dot just blends in
const DOT_BASE_FONT_SIZE := 96
const DOT_BASE_HEIGHT := 1080.0

const DOT_ANIM_INTERVAL := 0.6

var _dot_anim_time := 0.0
var _dot_anim_phase := 1  # start on the center dot
# A single "restart episode" (settings change -> teardown -> reconnect ->
# possibly one more mismatch-retry reconnect, see main.gd's
# _on_stream_started()) calls clear_yuv_textures() more than once before the
# dots are ever hidden again. Only re-derive the dot size the FIRST time they
# go from hidden to shown; every clear_yuv_textures() after that in the same
# episode is a no-op for sizing, so the dots hold one stable size for their
# whole visible lifetime instead of snapping to whatever intermediate/tentative
# resolution the viewport happens to be mid-resize to at that instant.
var _dots_active := false

# Returns {"container": Control, "dots": Array[Label]} - a small centered
# ". . ." indicator, one Label per dot so each can be independently faded
# to the background colour to animate a simple loading cycle.
func _make_loading_dots() -> Dictionary:
	var container = CenterContainer.new()
	container.name = "CompLoadingDots"
	container.anchors_preset = 15
	container.anchor_right = 1.0
	container.anchor_bottom = 1.0
	container.grow_horizontal = 2
	container.grow_vertical = 2
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.visible = false
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 24)
	container.add_child(hbox)
	var dots: Array[Label] = []
	for i in range(3):
		var d = Label.new()
		d.name = "Dot%d" % i
		d.text = "."
		d.add_theme_color_override("font_color", DOT_COLOR)
		d.add_theme_font_size_override("font_size", DOT_BASE_FONT_SIZE)
		hbox.add_child(d)
		dots.append(d)
	return {"container": container, "dots": dots}

func _apply_dot_phase(dots: Array):
	for i in range(dots.size()):
		if dots[i]:
			dots[i].add_theme_color_override("font_color", DOT_HIDDEN_COLOR if i == _dot_anim_phase else DOT_COLOR)

# Called every frame from main._process(); cheap no-op unless a loading
# indicator is actually visible somewhere.
func process_loading_dots(delta: float):
	var any_visible = false
	for s in main.screens:
		if (s.comp_loading_label and s.comp_loading_label.visible) \
		or (s.comp_loading_label_left and s.comp_loading_label_left.visible) \
		or (s.comp_loading_label_right and s.comp_loading_label_right.visible):
			any_visible = true
			break
	if not any_visible:
		return
	_dot_anim_time += delta
	if _dot_anim_time < DOT_ANIM_INTERVAL:
		return
	_dot_anim_time -= DOT_ANIM_INTERVAL
	_dot_anim_phase = (_dot_anim_phase + 1) % 3
	for s in main.screens:
		_apply_dot_phase(s.comp_loading_dots)
		_apply_dot_phase(s.comp_loading_dots_left)
		_apply_dot_phase(s.comp_loading_dots_right)

# The dots' font_size is in the comp SubViewport's own pixel space, which is
# resized to the real stream resolution (resize_stream_viewport()) - without
# rescaling, the same nominal font_size would render visually bigger or
# smaller depending on the connected resolution. Scale relative to 1080p.
func _update_loading_dot_size(s: VRScreen):
	var h = float(s.comp_viewport.size.y) if s.comp_viewport else DOT_BASE_HEIGHT
	var size = maxi(1, int(DOT_BASE_FONT_SIZE * h / DOT_BASE_HEIGHT))
	for dots in [s.comp_loading_dots, s.comp_loading_dots_left, s.comp_loading_dots_right]:
		for d in dots:
			if d:
				d.add_theme_font_size_override("font_size", size)

func update_loading_dot_sizes():
	for s in main.screens:
		_update_loading_dot_size(s)

func hide_loading_dots():
	_dots_active = false
	for s in main.screens:
		for lbl in [s.comp_loading_label, s.comp_loading_label_left, s.comp_loading_label_right]:
			if lbl:
				lbl.visible = false

func _make_cursor_texture_rect() -> TextureRect:
	var r = TextureRect.new()
	r.name = "CompStreamCursor"
	r.texture = load("res://src/assets/mouse_pointer_01.png")
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.visible = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _make_cursor_circle_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompStreamCursorCircle"
	r.visible = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat = ShaderMaterial.new()
	mat.shader = preload("res://src/shaders/circle_cursor.gdshader")
	r.material = mat
	return r

func setup():
	if not available:
		main._log("[COMP] OpenXRCompositionLayerCylinder not available")
		return

	setup_screen(main.primary_screen, true)

	main.comp_ui = OpenXRCompositionLayerQuad.new()
	main.comp_ui.name = "CompUILayer"
	main.comp_ui.set_sort_order(1000)
	main.comp_ui.set_enable_hole_punch(false)
	main.comp_ui.set_alpha_blend(true)
	main.comp_ui.set_quad_size(main._ui_mesh_size)
	main.comp_ui.visible = false
	main.xr_origin.add_child(main.comp_ui)
	main.comp_ui.set_layer_viewport(main.ui_viewport)
	main._log("[COMP] UI composition layer created")

	main.comp_cursor = OpenXRCompositionLayerQuad.new()
	main.comp_cursor.name = "CompCursorLayer"
	main.comp_cursor.set_sort_order(999)
	main.comp_cursor.set_enable_hole_punch(false)
	main.comp_cursor.set_alpha_blend(true)
	main.comp_cursor.set_quad_size(Vector2(0.04, 0.04))
	main.comp_cursor.visible = false
	main.xr_origin.add_child(main.comp_cursor)

	main.comp_cursor_viewport = SubViewport.new()
	main.comp_cursor_viewport.name = "CompCursorViewport"
	main.comp_cursor_viewport.disable_3d = true
	main.comp_cursor_viewport.transparent_bg = true
	main.comp_cursor_viewport.size = Vector2i(40, 64)
	main.comp_cursor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(main.comp_cursor_viewport)

	var pointer_tex = TextureRect.new()
	pointer_tex.name = "PointerTexture"
	pointer_tex.anchors_preset = 15
	pointer_tex.anchor_right = 1.0
	pointer_tex.anchor_bottom = 1.0
	pointer_tex.expand_mode = 1
	pointer_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pointer_tex.texture = load("res://src/assets/mouse_pointer_01.png")
	main.comp_cursor_viewport.add_child(pointer_tex)

	var circle = ColorRect.new()
	circle.name = "CircleTexture"
	circle.anchors_preset = 15
	circle.anchor_right = 1.0
	circle.anchor_bottom = 1.0
	var circle_mat = ShaderMaterial.new()
	circle_mat.shader = preload("res://src/shaders/circle_cursor.gdshader")
	circle.material = circle_mat
	circle.visible = false
	main.comp_cursor_viewport.add_child(circle)

	main.comp_cursor.set_layer_viewport(main.comp_cursor_viewport)
	main._log("[COMP] Cursor composition layer created")

	main.left_comp_cursor_layer = OpenXRCompositionLayerQuad.new()
	main.left_comp_cursor_layer.name = "LeftCompCursorLayer"
	main.left_comp_cursor_layer.set_sort_order(999)
	main.left_comp_cursor_layer.set_enable_hole_punch(false)
	main.left_comp_cursor_layer.set_alpha_blend(true)
	main.left_comp_cursor_layer.set_quad_size(Vector2(0.035, 0.035))
	main.left_comp_cursor_layer.visible = false
	main.xr_origin.add_child(main.left_comp_cursor_layer)

	main.left_comp_cursor_viewport = SubViewport.new()
	main.left_comp_cursor_viewport.name = "LeftCompCursorViewport"
	main.left_comp_cursor_viewport.disable_3d = true
	main.left_comp_cursor_viewport.transparent_bg = true
	main.left_comp_cursor_viewport.size = Vector2i(256, 256)
	main.left_comp_cursor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(main.left_comp_cursor_viewport)

	var left_circle = ColorRect.new()
	left_circle.name = "CircleTexture"
	left_circle.anchors_preset = 15
	left_circle.anchor_right = 1.0
	left_circle.anchor_bottom = 1.0
	var left_circle_mat = ShaderMaterial.new()
	left_circle_mat.shader = preload("res://src/shaders/circle_cursor.gdshader")
	left_circle.material = left_circle_mat
	main.left_comp_cursor_viewport.add_child(left_circle)

	main.left_comp_cursor_layer.set_layer_viewport(main.left_comp_cursor_viewport)
	main._log("[COMP] Left cursor composition layer created")

	main.comp_kb = OpenXRCompositionLayerQuad.new()
	main.comp_kb.name = "CompKBLayer"
	main.comp_kb.set_sort_order(999)
	main.comp_kb.set_enable_hole_punch(false)
	main.comp_kb.set_alpha_blend(true)
	main.comp_kb.set_quad_size(main.virtual_keyboard.mesh_size)
	main.comp_kb.visible = false
	main.xr_origin.add_child(main.comp_kb)
	main.comp_kb.set_layer_viewport(main.virtual_keyboard.viewport)
	main._log("[COMP] Keyboard composition layer created")

	available = true
	if main.primary_screen.comp_cylinder.is_natively_supported():
		main._log("[COMP] Composition layer cylinder natively supported")
	else:
		main._log("[COMP] Composition layer cylinder NOT natively supported (using fallback mesh)")

func connect_welcome_texture():
	if not available:
		return
	for mat in get_shader_mats():
		if mat:
			mat.set_shader_parameter("main_texture", main.welcome_viewport.get_texture())
			mat.set_shader_parameter("yuv_mode", 0)
	main.primary_screen.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func _update_bezel_for(s: VRScreen):
	var base_w = s.comp_base_size.x
	var base_h = s.comp_base_size.y
	var triplet = [
		{"bezel": s.comp_bezel_rect, "yuv": s.comp_yuv_rect, "vp": s.comp_viewport, "cyl": s.comp_cylinder},
		{"bezel": s.comp_bezel_rect_left, "yuv": s.comp_yuv_rect_left, "vp": s.comp_viewport_left, "cyl": s.comp_cylinder_left},
		{"bezel": s.comp_bezel_rect_right, "yuv": s.comp_yuv_rect_right, "vp": s.comp_viewport_right, "cyl": s.comp_cylinder_right},
	]
	if main.bezel_enabled and in_use:
		var px = 8
		var bezel_x = s.mesh_size.x * (1.0 + float(px * 2) / float(base_w))
		var bezel_y = s.mesh_size.y * (1.0 + float(px * 2) / float(base_h))
		for t in triplet:
			if not t.bezel:
				continue
			t.bezel.color = Color(0, 0, 0, 1)
			t.bezel.anchors_preset = 15
			t.bezel.offset_left = 0
			t.bezel.offset_top = 0
			t.bezel.offset_right = 0
			t.bezel.offset_bottom = 0
			t.yuv.offset_left = px
			t.yuv.offset_top = px
			t.yuv.offset_right = -px
			t.yuv.offset_bottom = -px
			t.yuv.anchor_left = 0.0
			t.yuv.anchor_top = 0.0
			t.yuv.anchor_right = 1.0
			t.yuv.anchor_bottom = 1.0
			t.yuv.anchors_preset = 0
			t.vp.size = Vector2i(base_w + px * 2, base_h + px * 2)
			if t.cyl and t.cyl.visible:
				t.cyl.set_aspect_ratio(bezel_x / bezel_y)
	else:
		for t in triplet:
			if not t.bezel:
				continue
			t.bezel.color = Color(0, 0, 0, 0)
			t.bezel.anchors_preset = 15
			t.bezel.offset_left = 0
			t.bezel.offset_top = 0
			t.bezel.offset_right = 0
			t.bezel.offset_bottom = 0
			t.yuv.offset_left = 0
			t.yuv.offset_top = 0
			t.yuv.offset_right = 0
			t.yuv.offset_bottom = 0
			t.yuv.anchors_preset = 15
			t.vp.size = Vector2i(base_w, base_h)
			if t.cyl and t.cyl.visible:
				t.cyl.set_aspect_ratio(s.mesh_size.x / s.mesh_size.y)

func update_bezel():
	if not main.primary_screen or not main.primary_screen.comp_yuv_rect:
		return
	for s in main.screens:
		_update_bezel_for(s)

func _update_cylinder_params_for(s: VRScreen):
	if not s.comp_cylinder and not s.comp_cylinder_left:
		return
	var cam_to_screen = s.global_position - main.xr_camera.global_position
	var view_dist = max(cam_to_screen.length(), 0.5)
	var radius = view_dist * 100.0
	if s.curvature == 1:
		radius = view_dist * 3.0
	elif s.curvature == 2:
		radius = view_dist * 2.0
	var screen_forward = -s.global_transform.basis.z
	var central_angle = s.mesh_size.x / radius
	var aspect = s.mesh_size.x / s.mesh_size.y
	s._comp_cyl_radius = radius
	s._comp_cyl_central_angle = central_angle
	s._comp_cyl_center = s.global_position - screen_forward * radius
	var sort_order = clampi(int((10.0 - view_dist) * 10), 1, 100)
	for cyl in [s.comp_cylinder, s.comp_cylinder_left, s.comp_cylinder_right]:
		if cyl:
			cyl.set_sort_order(sort_order)
			cyl.set_radius(radius)
			cyl.set_central_angle(central_angle)
			cyl.set_aspect_ratio(aspect)
			cyl.global_position = s.global_position - screen_forward * radius
			cyl.global_rotation = s.global_rotation

func update_cylinder_params():
	for s in main.screens:
		_update_cylinder_params_for(s)

var _transparent_mat: StandardMaterial3D = null

func make_screen_transparent():
	if _transparent_mat == null:
		_transparent_mat = StandardMaterial3D.new()
		_transparent_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_transparent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_transparent_mat.albedo_color = Color(0, 0, 0, 0)
	for s in main.screens:
		if s._original_mat == null:
			s._original_mat = s.material_override
		s.material_override = _transparent_mat

func make_ui_transparent():
	main.ui_panel_3d.visible = false

func make_kb_transparent():
	if not main.virtual_keyboard:
		return
	main.virtual_keyboard.mesh_instance.visible = false

func restore_screen_material():
	for s in main.screens:
		if s._original_mat != null:
			s.material_override = s._original_mat
			s._original_mat = null
		s.grab_bar.visible = true

func restore_ui_material():
	main.ui_panel_3d.visible = main.ui_visible

func restore_kb_material():
	if main.virtual_keyboard:
		main.virtual_keyboard.mesh_instance.visible = main.virtual_keyboard.visible

func bind_yuv_textures():
	var mat = main.stream_backend.get_shader_material()
	if not mat:
		main._log("[YUV] No shader material from stream backend, using SubViewport path")
		var stream_tex = main.stream_viewport.get_texture()
		if not in_use:
			for s in main.screens:
				if s.material_override is ShaderMaterial:
					s.material_override.set_shader_parameter("main_texture", stream_tex)
					s.material_override.set_shader_parameter("yuv_mode", 0)
		bind_fallback_texture(stream_tex)
		return
	var tex_y = mat.get_shader_parameter("tex_y")
	var tex_u = mat.get_shader_parameter("tex_u")
	var tex_v = mat.get_shader_parameter("tex_v")
	var is_nv12_rd = mat.get_shader_parameter("is_nv12_rd")
	var is_semi_planar = mat.get_shader_parameter("is_semi_planar")
	var cmt = mat.get_shader_parameter("color_matrix_type")
	var cr = mat.get_shader_parameter("color_range")
	# tex_y can be a non-null Texture object whose underlying RID no longer
	# points to valid GPU memory - e.g. right after a stream restart, before
	# the new decoder session has produced its first frame, the shader
	# material (reused across the restart, not recreated) still holds a
	# reference to the just-freed previous session's texture. Binding that to
	# the composition layer shader doesn't just look wrong, it makes Godot's
	# renderer error repeatedly ("uniform_set_create ... not a valid
	# texture") and render black.
	#
	# tex_y.get_rid().is_valid() does NOT detect this: for the AHardwareBuffer
	# path, tex_y is a reused Texture2DRD wrapper object whose own Godot-side
	# RID is valid from the moment it's instantiated, regardless of whether
	# the RD-level texture it currently wraps is live or freed - so that check
	# is a no-op that's always true once any session has ever bound a texture.
	# The native side tracks the real signal (has THIS session's first frame
	# actually been wired into tex_y yet) via is_display_ready(); ask it
	# directly instead of trying to infer freshness from the RID.
	if tex_y and main.stream_backend.is_display_ready():
		var yuv_mode_val = 0
		if is_nv12_rd:
			yuv_mode_val = 1
		elif is_semi_planar:
			yuv_mode_val = 2
		else:
			yuv_mode_val = 3
		var rids = [_as_rid(tex_y), _as_rid(tex_u), _as_rid(tex_v)]
		var mode_tuple = [yuv_mode_val, cmt, cr]
		var unchanged = (rids == _last_bind_rids and mode_tuple == _last_bind_mode)
		if not in_use:
			for s in main.screens:
				if s.material_override is ShaderMaterial:
					s.material_override.set_shader_parameter("tex_y", tex_y)
					s.material_override.set_shader_parameter("tex_u", tex_u)
					s.material_override.set_shader_parameter("tex_v", tex_v)
					s.material_override.set_shader_parameter("color_matrix_type", cmt)
					s.material_override.set_shader_parameter("color_range", cr)
					s.material_override.set_shader_parameter("yuv_mode", yuv_mode_val)
		if not unchanged:
			main._log("[YUV] Direct YUV binding: mode=%d nv12_rd=%s semi_planar=%s" % [yuv_mode_val, str(is_nv12_rd), str(is_semi_planar)])
			bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode_val, cmt, cr)
			_last_bind_rids = rids
			_last_bind_mode = mode_tuple
	else:
		var stream_tex = main.stream_viewport.get_texture()
		if not in_use:
			for s in main.screens:
				if s.material_override is ShaderMaterial:
					s.material_override.set_shader_parameter("main_texture", stream_tex)
					s.material_override.set_shader_parameter("yuv_mode", 0)
		bind_fallback_texture(stream_tex)

func bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode: int, cmt, cr):
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("tex_y", tex_y)
			mat.set_shader_parameter("tex_u", tex_u)
			mat.set_shader_parameter("tex_v", tex_v)
			mat.set_shader_parameter("yuv_mode", yuv_mode)
			mat.set_shader_parameter("color_matrix_type", cmt)
			mat.set_shader_parameter("color_range", cr)
		for lbl in [s.comp_loading_label, s.comp_loading_label_left, s.comp_loading_label_right]:
			if lbl:
				lbl.visible = false
	_dots_active = false
	main._log("[COMP] YUV textures bound to composition layer shader (mode=%d)" % yuv_mode)

func bind_fallback_texture(stream_tex):
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("main_texture", stream_tex)
			mat.set_shader_parameter("yuv_mode", 0)

func switch_to_comp_layer():
	if not available:
		in_use = false
		main._log("[COMP] Not available, using mesh rendering")
		return
	var stereo = main.settings_controller.get_stereo_mode() if main.settings_controller else 0
	if stereo > 0:
		switch_to_stereo_comp_layer()
		return
	in_use = true
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var s = main.primary_screen
	if s.comp_cylinder_left: s.comp_cylinder_left.visible = false
	if s.comp_cylinder_right: s.comp_cylinder_right.visible = false
	if s.comp_viewport_left: s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if s.comp_viewport_right: s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for scr in main.screens:
		if scr.comp_cylinder:
			scr.comp_layer = scr.comp_cylinder
			scr.comp_layer.set_layer_viewport(scr.comp_viewport)
			scr.comp_layer.visible = true
		scr.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		scr.comp_shader_mat.set_shader_parameter("stereo_mode", 0)
	main.settings_controller.apply_filter()
	make_screen_transparent()
	for scr in main.screens:
		if scr.bezel_mesh:
			scr.bezel_mesh.visible = false
	update_cylinder_params()
	update_bezel()

func switch_to_stereo_comp_layer():
	if not available:
		in_use = false
		main._log("[COMP] Not available, cannot use stereo comp layer")
		return
	var s = main.primary_screen
	# Screens are normally only given stereo (left/right) comp layers when
	# they're created as primary (see add_screen()'s with_stereo param) -
	# guard against a screen that somehow became primary without them rather
	# than half-hiding the working mono layer and crashing on a null
	# dereference below.
	if not (s.comp_cylinder_left and s.comp_cylinder_right and s.comp_shader_mat_left and s.comp_shader_mat_right):
		main._log("[COMP] Primary screen has no stereo comp layers - staying on mono composition layer")
		return
	in_use = true
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if s.comp_cylinder: s.comp_cylinder.visible = false
	s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var stereo = main.settings_controller.get_stereo_mode()
	s.comp_cylinder_left.visible = true
	s.comp_cylinder_right.visible = true
	s.comp_cylinder_left.set_layer_viewport(s.comp_viewport_left)
	s.comp_cylinder_right.set_layer_viewport(s.comp_viewport_right)
	s.comp_shader_mat_left.set_shader_parameter("stereo_mode", stereo)
	s.comp_shader_mat_left.set_shader_parameter("eye_index", 1)
	s.comp_shader_mat_right.set_shader_parameter("stereo_mode", stereo)
	s.comp_shader_mat_right.set_shader_parameter("eye_index", 2)
	s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for scr in main.screens:
		if scr == s:
			continue
		if scr.comp_cylinder:
			scr.comp_layer = scr.comp_cylinder
			scr.comp_layer.set_layer_viewport(scr.comp_viewport)
			scr.comp_layer.visible = true
		scr.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	make_screen_transparent()
	for scr in main.screens:
		if scr.bezel_mesh:
			scr.bezel_mesh.visible = false
	update_cylinder_params()
	update_bezel()
	if main.is_streaming:
		bind_yuv_textures()
	main._log("[COMP] Switched to stereo composition layer (mode=%d)" % stereo)

func switch_to_mesh_rendering():
	in_use = false
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if main.is_streaming else SubViewport.UPDATE_DISABLED
	for scr in main.screens:
		if scr.comp_cylinder: scr.comp_cylinder.visible = false
		if scr.comp_cylinder_left: scr.comp_cylinder_left.visible = false
		if scr.comp_cylinder_right: scr.comp_cylinder_right.visible = false
		if scr.comp_viewport:
			scr.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		if scr.bezel_mesh:
			scr.bezel_mesh.visible = main.bezel_enabled
	if main.comp_ui: main.comp_ui.visible = false
	if main.comp_kb: main.comp_kb.visible = false
	if main.comp_cursor: main.comp_cursor.visible = false
	if main.left_comp_cursor_layer: main.left_comp_cursor_layer.visible = false
	restore_screen_material()
	restore_ui_material()
	restore_kb_material()
	update_bezel()
	if main.is_streaming:
		main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var mode = main.settings_controller.get_stereo_mode()
		for scr in main.screens:
			var mat = scr.material_override
			if mat:
				mat.set_shader_parameter("main_texture", main.stream_viewport.get_texture())
				mat.set_shader_parameter("yuv_mode", 0)
				# Stereo/AI-3D applies to primary only (matches apply_stereo()
				# and switch_to_stereo_comp_layer() elsewhere in this file) - a
				# secondary already samples just its own cropped uv_region of
				# the composite frame, and the shader halves UV for stereo
				# BEFORE that crop is applied (yuv_display.gdshader), so
				# setting this on a secondary would show a quartered slice of
				# the wrong content instead of that screen's own picture.
				mat.set_shader_parameter("stereo_mode", mode if scr == main.primary_screen else 0)
				mat.set_shader_parameter("filter_mode", main.smooth_mode)
				mat.set_shader_parameter("sharpen", float(main.sharpen_mode) * 0.016)
		bind_yuv_textures()

func update_layer_size():
	update_cylinder_params()

func clear_yuv_textures():
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("tex_y", null)
			mat.set_shader_parameter("tex_u", null)
			mat.set_shader_parameter("tex_v", null)
			mat.set_shader_parameter("yuv_mode", 0)
			# main_texture must stay non-null: an unset sampler2D uniform (no
			# hint_default_black) samples as solid white in Godot, which is
			# what produced the flash-of-white-screen every restart. Reset to
			# the same dark placeholder used before the very first frame ever
			# arrives instead of leaving it null.
			mat.set_shader_parameter("main_texture", VRScreen.placeholder_texture())
			mat.set_shader_parameter("stereo_mode", 0)
			mat.set_shader_parameter("depth_texture", null)
		for lbl in [s.comp_loading_label, s.comp_loading_label_left, s.comp_loading_label_right]:
			if lbl:
				lbl.visible = true
	if _dots_active:
		return
	_dots_active = true
	# Deliberately sized here (using whatever comp_viewport.size still is right
	# now, i.e. the OLD/current resolution) rather than after resize_stream_viewport()
	# resizes it to the newly-requested one - that resize happens immediately at
	# start_stream(), well before the new session is actually ready, so sizing off
	# it made the dots visibly snap to the wrong size the instant a restart began.
	# Leaving the size alone here keeps it stable for the dots' whole visible
	# lifetime; it'll be correct again once the next real connection re-derives it.
	# Guarded by _dots_active so a multi-step restart episode (teardown +
	# reconnect, then possibly one more mismatch-retry reconnect - see
	# _on_stream_started()) only does this once instead of re-sizing/resetting
	# on every intermediate clear_yuv_textures() call in between.
	update_loading_dot_sizes()
	_dot_anim_time = 0.0
	_dot_anim_phase = 1
	for s in main.screens:
		_apply_dot_phase(s.comp_loading_dots)
		_apply_dot_phase(s.comp_loading_dots_left)
		_apply_dot_phase(s.comp_loading_dots_right)

static func set_grab_bar_color(viewport: SubViewport, color: Color):
	if not viewport:
		return
	var bar = viewport.find_child("CompGrabBar", true, false) as PanelContainer
	if not bar:
		return
	var style = bar.get_theme_stylebox("panel") as StyleBoxFlat
	if not style or is_equal_approx(style.bg_color.a, color.a):
		return
	style = style.duplicate()
	style.bg_color = Color(1, 1, 1, color.a)
	bar.add_theme_stylebox_override("panel", style)