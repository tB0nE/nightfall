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

var equirect_available: bool = false

func _init(p_main):
	main = p_main
	available = ClassDB.class_exists("OpenXRCompositionLayerCylinder")
	# Checked separately (2026-08-24) - the equirect2 OpenXR extension is
	# less commonly implemented than cylinder, needed for a composition-
	# space environment-background replacement (see main.gd's
	# comp_bg_equirect comment). Just existing as a Godot class isn't
	# proof the RUNTIME actually supports it - is_natively_supported()
	# (checked once the layer is created) is the real signal.
	equirect_available = ClassDB.class_exists("OpenXRCompositionLayerEquirect")

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

	# Grab-bar visual (2026-08-24) - see VRScreen's comp_grab_bar comment.
	# Not billboarded (unlike the cursor/laser) - lies flat in the screen's
	# own plane, matching the real grab_bar MeshInstance3D's orientation,
	# so main.gd's _update_grab_bar_layers() just copies grab_bar's own
	# global position/rotation onto it directly every frame, no basis math
	# needed. Always visible once comp.in_use (like the real grab_bar in
	# normal projection mode) - never toggled off, so no risk of the
	# swapchain-teardown crash toggling caused for the cursor/laser.
	s.comp_grab_bar = OpenXRCompositionLayerQuad.new()
	s.comp_grab_bar.name = "CompGrabBarLayer_%s" % s.monitor_id
	s.comp_grab_bar.set_sort_order(998)
	s.comp_grab_bar.set_enable_hole_punch(false)
	s.comp_grab_bar.set_alpha_blend(true)
	s.comp_grab_bar.visible = false
	main.xr_origin.add_child(s.comp_grab_bar)

	s.comp_grab_bar_viewport = SubViewport.new()
	s.comp_grab_bar_viewport.name = "CompGrabBarViewport_%s" % s.monitor_id
	s.comp_grab_bar_viewport.disable_3d = true
	s.comp_grab_bar_viewport.transparent_bg = true
	# Aspect matches the quad_size set in main.gd's _update_grab_bar_layers()
	# (ms.x*0.134 x ms.x*0.009, ~14.9:1) - a mismatched viewport aspect would
	# stretch the panel non-uniformly onto the quad.
	s.comp_grab_bar_viewport.size = Vector2i(256, 18)
	s.comp_grab_bar_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(s.comp_grab_bar_viewport)

	# PanelContainer + StyleBoxFlat (2026-08-24, replacing an earlier
	# hand-rolled pixel-SDF pill texture) - reuses the exact same technique
	# the menu/keyboard's own "CompGrabBar" already uses (see
	# vr_panel_base.gd's _setup_grab_bar()), a small corner radius relative
	# to the bar's height for a rounded-rectangle "bar" look, not a full
	# stadium/pill. Also matters more now that the visual quad is much
	# thinner than the collision hitbox (see _update_grab_bar_layers()) -
	# a small fixed pixel radius reads correctly at that thinner aspect,
	# where the earlier radius-scales-with-height approach didn't.
	var grab_bar_panel = PanelContainer.new()
	grab_bar_panel.name = "GrabBarPanel"
	grab_bar_panel.anchors_preset = 15
	grab_bar_panel.anchor_right = 1.0
	grab_bar_panel.anchor_bottom = 1.0
	var grab_bar_style = StyleBoxFlat.new()
	# 0.05 idle alpha, matching the corner handles' same idle/hover/grabbed
	# dynamics (2026-08-24) - xr_interaction.gd's _set_grab_bar_color() now
	# mirrors the real dynamic alpha (0.01/0.05/0.15/0.3/0.4 depending on
	# state) onto this stylebox every time it changes; this is just the
	# initial value before the first such call.
	grab_bar_style.bg_color = Color(1, 1, 1, 0.05)
	grab_bar_style.set_corner_radius_all(6)
	grab_bar_panel.add_theme_stylebox_override("panel", grab_bar_style)
	s.comp_grab_bar_viewport.add_child(grab_bar_panel)

	s.comp_grab_bar.set_layer_viewport(s.comp_grab_bar_viewport)
	main._log("[COMP] Grab-bar composition layer created (%s)" % s.monitor_id)

	# Corner-handle visuals (2026-08-24) - see VRScreen's comp_corner_layers
	# comment. Reuses VRScreen._make_corner_texture() directly (the exact
	# same L-bracket generator the real corner_handles use) rather than
	# duplicating it - the base 0.08 opacity baked into that texture
	# already matches the real handles' idle state, and
	# xr_interaction.gd's _set_corner_color() mirrors hover/click alpha
	# onto comp_corner_rects[i].modulate.a the same way it already updates
	# the real handle's material_override.albedo_color.
	var corner_ids = ["top-left", "top-right", "bottom-left", "bottom-right"]
	s.comp_corner_layers.resize(4)
	s.comp_corner_rects.resize(4)
	for i in range(4):
		var corner_layer = OpenXRCompositionLayerQuad.new()
		corner_layer.name = "CompCorner%dLayer_%s" % [i, s.monitor_id]
		corner_layer.set_sort_order(998)
		corner_layer.set_enable_hole_punch(false)
		corner_layer.set_alpha_blend(true)
		corner_layer.visible = false
		main.xr_origin.add_child(corner_layer)

		var corner_viewport = SubViewport.new()
		corner_viewport.name = "CompCorner%dViewport_%s" % [i, s.monitor_id]
		corner_viewport.disable_3d = true
		corner_viewport.transparent_bg = true
		corner_viewport.size = Vector2i(128, 128)
		corner_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		main.add_child(corner_viewport)

		var corner_rect = TextureRect.new()
		corner_rect.name = "CornerBracket"
		corner_rect.anchors_preset = 15
		corner_rect.anchor_right = 1.0
		corner_rect.anchor_bottom = 1.0
		corner_rect.expand_mode = 1
		corner_rect.stretch_mode = TextureRect.STRETCH_SCALE
		# opacity=1.0 here, NOT the real corner_handles default of 0.08
		# (2026-08-24) - _set_corner_color() sets modulate.a to the dynamic
		# hover/click alpha (0.05 idle / 0.15 hover / 0.4 grabbed), which
		# MULTIPLIES against this texture's own baked alpha rather than
		# replacing it. With the real 0.08 baked in, that chain crushed
		# the actual rendered alpha down to ~0.03 at best (0.08 * 0.4) -
		# confirmed via a full-opacity test to be why nothing was visible
		# at all. Baking in full opacity here makes modulate.a the sole,
		# meaningful alpha control, matching what the dynamic values were
		# actually meant to look like.
		corner_rect.texture = VRScreen._make_corner_texture(corner_ids[i], 128, 20, 1.0)
		corner_viewport.add_child(corner_rect)

		corner_layer.set_layer_viewport(corner_viewport)
		s.comp_corner_layers[i] = corner_layer
		s.comp_corner_rects[i] = corner_rect
	main._log("[COMP] Corner-handle composition layers created (%s)" % s.monitor_id)

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
const DOT_BASE_FONT_SIZE := 96
const DOT_BASE_HEIGHT := 1080.0

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

func _make_triangle_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompHandTriangle"
	r.visible = true
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat = ShaderMaterial.new()
	mat.shader = preload("res://src/shaders/inverted_triangle.gdshader")
	r.material = mat
	return r

func setup():
	if not available:
		main._log("[COMP] OpenXRCompositionLayerCylinder not available")
		return

	setup_background_equirect()

	setup_screen(main.primary_screen, true)

func setup_background_equirect():
	if not equirect_available:
		main._log("[COMP] OpenXRCompositionLayerEquirect not available - environment backgrounds won't show in projectionless mode")
		return

	main.comp_bg_equirect = OpenXRCompositionLayerEquirect.new()
	main.comp_bg_equirect.name = "CompBgEquirect"
	main.comp_bg_equirect.set_sort_order(-100)
	main.comp_bg_equirect.set_radius(40.0)
	main.comp_bg_equirect.set_central_horizontal_angle(deg_to_rad(main.BG_EQUIRECT_ANGLE_DEG))
	main.comp_bg_equirect.set_upper_vertical_angle(deg_to_rad(main.BG_EQUIRECT_ANGLE_DEG * 0.5))
	main.comp_bg_equirect.set_lower_vertical_angle(deg_to_rad(main.BG_EQUIRECT_ANGLE_DEG * 0.5))
	main.comp_bg_equirect.visible = false
	main.xr_origin.add_child(main.comp_bg_equirect)
	if not main.comp_bg_equirect.is_natively_supported():
		main._log("[COMP] OpenXRCompositionLayerEquirect not natively supported on this runtime - environment backgrounds won't show in projectionless mode")
		main.comp_bg_equirect.queue_free()
		main.comp_bg_equirect = null
		return

	main.comp_bg_capture_viewport = SubViewport.new()
	main.comp_bg_capture_viewport.name = "CompBgCaptureViewport"
	main.comp_bg_capture_viewport.disable_3d = false
	main.comp_bg_capture_viewport.own_world_3d = true
	main.comp_bg_capture_viewport.transparent_bg = false
	main.comp_bg_capture_viewport.size = Vector2i(1024, 1024)
	main.comp_bg_capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(main.comp_bg_capture_viewport)

	var bg_env = WorldEnvironment.new()
	bg_env.name = "CaptureEnvironment"
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 1)
	bg_env.environment = env
	main.comp_bg_capture_viewport.add_child(bg_env)

	main.comp_bg_capture_camera = Camera3D.new()
	main.comp_bg_capture_camera.name = "CaptureCamera"
	main.comp_bg_capture_camera.fov = main.BG_CAPTURE_FOV_DEG
	main.comp_bg_capture_camera.current = true
	main.comp_bg_capture_viewport.add_child(main.comp_bg_capture_camera)

	main.comp_bg_equirect.set_layer_viewport(main.comp_bg_capture_viewport)
	main._log("[COMP] Environment-background equirect composition layer created")

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
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
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

	# Cursor layers (2026-08-24) - previously created only for the non-GLES
	# path (an early return here skipped them entirely under GLES), even
	# though the cursor-update logic in main.gd's _update_cursor_layer()
	# already had GLES-specific quad-sizing branches for them (see its
	# RenderingServer.get_current_rendering_method() == "gl_compatibility"
	# checks) - that code was dead/unreachable since comp_cursor was always
	# null under GLES. Nothing in this creation code is Vulkan-specific
	# (plain SubViewport + TextureRect/ColorRect + shader), so there was no
	# actual technical reason to skip it - just an oversight from GLES's
	# first pass. Moved above the gl_compatibility/else split so both paths
	# reach it, instead of duplicating it into the GLES branch above.
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

	# Controller ray indicators - see main.gd's comp_laser_right/left comment
	# for why these exist. Uses main._make_comp_laser_texture() - a wider
	# texture than the real 3D laser's shared gradient, with room to render
	# rounded capsule-style end caps (matching the real Laser mesh's own
	# CapsuleMesh shape) rather than a hard rectangular cutoff.
	var laser_tex = main._make_comp_laser_texture(32, 256)
	for side in ["right", "left"]:
		var layer = OpenXRCompositionLayerQuad.new()
		layer.name = "CompLaser%sLayer" % side.capitalize()
		layer.set_sort_order(998)
		layer.set_enable_hole_punch(false)
		layer.set_alpha_blend(true)
		layer.set_quad_size(Vector2(main.LASER_QUAD_WIDTH, main.LASER_QUAD_LENGTH))
		layer.visible = false
		main.xr_origin.add_child(layer)

		var viewport = SubViewport.new()
		viewport.name = "CompLaser%sViewport" % side.capitalize()
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.size = Vector2i(32, 256)
		# UPDATE_ALWAYS, not UPDATE_ONCE (2026-08-24) - matching comp_cursor_
		# viewport's working pattern. UPDATE_ONCE was an unproven attempt to
		# save a little render cost for what's genuinely static content (the
		# gradient texture never changes), but it's suspected as part of why
		# the laser never actually appeared - the one-time render could
		# plausibly land before the viewport/TextureRect were fully ready,
		# leaving it blank forever with nothing to mark it dirty again.
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		main.add_child(viewport)

		var laser_tex_rect = TextureRect.new()
		laser_tex_rect.name = "LaserGradient"
		laser_tex_rect.anchors_preset = 15
		laser_tex_rect.anchor_right = 1.0
		laser_tex_rect.anchor_bottom = 1.0
		laser_tex_rect.expand_mode = 1
		laser_tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
		# _make_comp_laser_texture() is opaque at one end, fading to
		# transparent at the other (same convention as _make_laser_gradient(),
		# which this was split off from) - flip_v confirmed correct on-device
		# (opaque near the hand, fading toward the far end) for that
		# convention, kept when switching to the new capsule-shaped texture.
		laser_tex_rect.flip_v = true
		laser_tex_rect.texture = laser_tex
		viewport.add_child(laser_tex_rect)

		layer.set_layer_viewport(viewport)
		if side == "right":
			main.comp_laser_right = layer
			main.comp_laser_right_viewport = viewport
		else:
			main.comp_laser_left = layer
			main.comp_laser_left_viewport = viewport
	main._log("[COMP] Controller ray composition layers created")

	# Persistent controller position markers (2026-08-25) - the ray above only
	# shows while the raycast is in an active pointing posture (raycast.enabled),
	# so a resting/idle controller has no projectionless indicator at all. This
	# is a small always-on dot shown at the tracked controller position whenever
	# XRController3D.get_is_active() is true, independent of pointing posture -
	# see main.gd's _update_marker_layers().
	for side in ["right", "left"]:
		var marker_layer = OpenXRCompositionLayerQuad.new()
		marker_layer.name = "CompMarker%sLayer" % side.capitalize()
		marker_layer.set_sort_order(998)
		marker_layer.set_enable_hole_punch(false)
		marker_layer.set_alpha_blend(true)
		marker_layer.set_quad_size(Vector2(0.03, 0.03))
		marker_layer.visible = false
		main.xr_origin.add_child(marker_layer)

		var marker_viewport = SubViewport.new()
		marker_viewport.name = "CompMarker%sViewport" % side.capitalize()
		marker_viewport.disable_3d = true
		marker_viewport.transparent_bg = true
		marker_viewport.size = Vector2i(64, 64)
		marker_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		main.add_child(marker_viewport)

		var marker_circle = _make_cursor_circle_rect()
		marker_circle.name = "MarkerCircle"
		marker_circle.anchors_preset = 15
		marker_circle.anchor_right = 1.0
		marker_circle.anchor_bottom = 1.0
		marker_circle.visible = true
		marker_viewport.add_child(marker_circle)

		marker_layer.set_layer_viewport(marker_viewport)
		if side == "right":
			main.comp_marker_right = marker_layer
			main.comp_marker_right_circle = marker_circle
		else:
			main.comp_marker_left = marker_layer
			main.comp_marker_left_circle = marker_circle
	main._log("[COMP] Controller position marker composition layers created")

	# Composite-only hand indicators (2026-08-27) - see main.gd's
	# comp_hand_right/left comment for why this replaced an earlier full
	# 3D-scene-in-a-viewport hand skeleton (too expensive even throttled to
	# 14fps). Same disable_3d=true/no-offscreen-3D-scene shape as the
	# controller markers just above, but the triangle's three vertices are
	# live shader uniforms (inverted_triangle.gdshader's point_a/b/c) driven
	# every frame from the wrist + two knuckle joints' real projected
	# positions (main._update_one_hand_indicator()), not a fixed icon - the
	# quad itself is also oriented to the hand's own plane, not billboarded
	# to the camera, so the triangle's shape/orientation genuinely tracks
	# hand pose in real time.
	for side in ["right", "left"]:
		var hand_layer = OpenXRCompositionLayerQuad.new()
		hand_layer.name = "CompHand%sLayer" % side.capitalize()
		hand_layer.set_sort_order(998)
		hand_layer.set_enable_hole_punch(false)
		hand_layer.set_alpha_blend(true)
		hand_layer.set_quad_size(Vector2(main.HAND_INDICATOR_SIZE, main.HAND_INDICATOR_SIZE))
		hand_layer.visible = false
		main.xr_origin.add_child(hand_layer)

		var hand_viewport = SubViewport.new()
		hand_viewport.name = "CompHand%sViewport" % side.capitalize()
		hand_viewport.disable_3d = true
		hand_viewport.transparent_bg = true
		# 256x256, not 64x64 (2026-08-27 fix) - the shader's own smoothstep
		# antialiasing (inverted_triangle.gdshader's edge_soft) needs enough
		# pixels to actually blend across, and at 64px on a 0.32m quad each
		# pixel is ~5mm - reported as "very pixelated and blocky".
		hand_viewport.size = Vector2i(256, 256)
		hand_viewport.msaa_2d = Viewport.MSAA_4X
		hand_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		main.add_child(hand_viewport)

		var hand_triangle = _make_triangle_rect()
		hand_triangle.anchors_preset = 15
		hand_triangle.anchor_right = 1.0
		hand_triangle.anchor_bottom = 1.0
		hand_viewport.add_child(hand_triangle)

		hand_layer.set_layer_viewport(hand_viewport)
		if side == "right":
			main.comp_hand_right = hand_layer
			main.comp_hand_right_triangle = hand_triangle
		else:
			main.comp_hand_left = hand_layer
			main.comp_hand_left_triangle = hand_triangle
	main._log("[COMP] Hand indicator composition layers created")

	# GLES already created its own comp_kb above (different sort order/log,
	# same overall shape) - only create the non-GLES variant here to avoid
	# double-creating (and leaking the first one's viewport/quad) now that
	# cursor creation above runs unconditionally for both paths.
	if RenderingServer.get_current_rendering_method() != "gl_compatibility":
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
			var bezel_size = Vector2i(base_w + px * 2, base_h + px * 2)
			if t.vp.size != bezel_size:
				t.vp.size = bezel_size
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
			var content_size = Vector2i(base_w, base_h)
			if t.vp.size != content_size:
				t.vp.size = content_size
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
	# stereo_mode 5's upsample pass decodes YUV itself now (depth_upsample.gdshader)
	# rather than depending on comp_viewport's rendered output - see main.gd's
	# depth_estimator.setup() call site for why that dependency direction was a
	# problem. AI-3D is primary-only, so this always mirrors whatever the loop
	# above just bound, regardless of which screen(s) it iterated.
	if main.depth_estimator and main.depth_estimator.upsample_mat:
		var um = main.depth_estimator.upsample_mat
		um.set_shader_parameter("tex_y", tex_y)
		um.set_shader_parameter("tex_u", tex_u)
		um.set_shader_parameter("tex_v", tex_v)
		um.set_shader_parameter("yuv_mode", yuv_mode)
		um.set_shader_parameter("color_matrix_type", cmt)
		um.set_shader_parameter("color_range", cr)
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
