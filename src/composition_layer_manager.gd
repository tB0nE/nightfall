class_name CompositionLayerManager
extends RefCounted

var main
var available: bool = false
var in_use: bool = false
var _last_bind_rids: Array = []
var _last_bind_mode: Array = [0, 1, 0, 0]
var stats_viewport: SubViewport = null
var stats_label: Label = null
var stats_rects: Array = []
var stats_visible: bool = false
var _sdr_shader: Shader = null
var _sdr_picture_shader: Shader = null
var _hdr_shader: Shader = null
var _hdr_lut: ImageTexture = null
var _current_color_transfer_type: int = 0

# Primary-screen ambient lighting is deliberately isolated in one small,
# alpha-blended compositor layer. It never changes the main screen layer's
# opaque blend mode or any of the YUV/HDR/AI-depth shaders.
const AMBIENT_LAYER_SCALE := 1.30
const AMBIENT_SAMPLE_SIZE := 32
const AMBIENT_VIEWPORT_LONG_EDGE := 256
const AMBIENT_SLOW_INTERVAL_SEC := 0.10
# Live mode used to sample every script tick (up to 144-207Hz on the
# refresh-rate tiers this branch now supports) - ambient light doesn't
# need anywhere near that to look smooth, and it was the one ambient mode
# with no throttle at all. Capped the same way Slow already was.
const AMBIENT_LIVE_INTERVAL_SEC := 1.0 / 72.0
var _ambient_layer: Node3D = null
var _ambient_sample_viewport: SubViewport = null
var _ambient_sample_rect: TextureRect = null
var _ambient_viewport: SubViewport = null
var _ambient_rect: ColorRect = null
var _ambient_material: ShaderMaterial = null
var _ambient_source_viewport: SubViewport = null
var _ambient_source_texture: Texture2D = null
var _ambient_native_source_texture: ImageTexture = null
var _ambient_native_sample_revision := 0
var _ambient_native_applied_revision := -1
var _ambient_native_static_waiting := false
var _ambient_native_supported := false
var _ambient_support_logged := false
var _ambient_dirty := true
var _ambient_slow_elapsed := 0.0
var _ambient_live_elapsed := 0.0
var _ambient_sample_seeded := false
var _last_compositor_sharpen_mode := -1
var _last_compositor_sharpen_supported := false

func _get_sdr_shader() -> Shader:
	if not _sdr_shader:
		_sdr_shader = load("res://src/shaders/yuv_display.gdshader")
	return _sdr_shader

func _get_sdr_picture_shader() -> Shader:
	if not _sdr_picture_shader:
		_sdr_picture_shader = load("res://src/shaders/yuv_display_picture.gdshader")
	return _sdr_picture_shader

func _get_hdr_shader() -> Shader:
	if not _hdr_shader:
		_hdr_shader = load("res://src/shaders/yuv_display_hdr.gdshader")
	return _hdr_shader

# ST 2084 (PQ) inverse EOTF -> linear, normalized so 203 nits (the standard
# PQ SDR reference-white anchor, ITU-R BT.2408) = 1.0.
func _pq_decode(e: float) -> float:
	var m1 = 0.1593017578125
	var m2 = 78.84375
	var c1 = 0.8359375
	var c2 = 18.8515625
	var c3 = 18.6875
	var ep = pow(e, 1.0 / m2)
	var num = maxf(ep - c1, 0.0)
	var den = maxf(c2 - c3 * ep, 1e-6)
	var linear = pow(num / den, 1.0 / m1) # 0..1 represents 0..10000 nits
	return linear / 0.0203 # 203/10000

# ARIB STD-B67 (HLG) inverse OETF composed with its system-gamma OOTF (fixed
# 1.2, BT.2100's nominal value for a ~1000 nit reference display), normalized
# so 203 nits of HLG's ~1000 nit nominal peak = 1.0.
func _hlg_decode(e: float) -> float:
	var a = 0.17883277
	var b = 1.0 - 4.0 * a
	var c = 0.5 - a * log(4.0 * a)
	var scene = ((e * e) / 3.0) if (e < 0.5) else ((exp((e - c) / a) + b) / 12.0)
	var ootf = pow(maxf(scene, 0.0), 1.2)
	return ootf / 0.203 # 203/1000

func _srgb_encode(c: float) -> float:
	c = clampf(c, 0.0, 1.0)
	if c <= 0.0031308:
		return c * 12.92
	return 1.055 * pow(c, 1.0 / 2.4) - 0.055

# 256 wide (LUT input resolution) x 3 tall - row 0 = PQ decode, row 1 = HLG
# decode, row 2 = linear->sRGB encode (see yuv_display_hdr.gdshader's own
# comment on hdr_eotf_lut for why: trades per-pixel pow()/exp() calls for
# texture fetches). Built once, lazily, on first use - 768 total evaluations,
# not a per-frame cost.
func _get_hdr_lut() -> ImageTexture:
	if _hdr_lut:
		return _hdr_lut
	var img = Image.create(256, 3, false, Image.FORMAT_RF)
	for x in range(256):
		var e = float(x) / 255.0
		img.set_pixel(x, 0, Color(_pq_decode(e), 0.0, 0.0))
		img.set_pixel(x, 1, Color(_hlg_decode(e), 0.0, 0.0))
		img.set_pixel(x, 2, Color(_srgb_encode(e), 0.0, 0.0))
	_hdr_lut = ImageTexture.create_from_image(img)
	return _hdr_lut

# Select a compiled shader variant instead of making HDR and picture grading
# runtime branches in the always-hot SDR/AI-depth shader. Check each material
# rather than caching one global state: screen/layout rebuilds can introduce
# fresh materials without changing the stream's transfer type.
func _apply_video_shader_state(color_transfer_type: int):
	_current_color_transfer_type = color_transfer_type
	var picture_adjusted = main.settings.brightness_pct != 0 or main.settings.contrast_pct != 100 or main.settings.gamma_pct != 100
	var shader: Shader
	if color_transfer_type != 0:
		shader = _get_hdr_shader()
	elif picture_adjusted:
		shader = _get_sdr_picture_shader()
	else:
		shader = _get_sdr_shader()
	for s in main.screens:
		for mat in get_shader_mats(s):
			if mat and mat.shader != shader:
				mat.shader = shader

func refresh_picture_shader_state():
	_apply_video_shader_state(_current_color_transfer_type)

func invalidate_yuv_cache():
	_last_bind_rids = []
	_last_bind_mode = [0, 1, 0, 0]

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
	# The primary screen's four shortcut icons share this existing layer with
	# the grab bar. This is intentionally one wider transparent viewport, not
	# four more OpenXR layers. Secondary screens render only the centered bar.
	s.comp_grab_bar_viewport.size = ScreenShortcutBar.COMP_VIEWPORT_SIZE
	# Keep the render target resident while this composition layer is active.
	# UPDATE_ONCE repeatedly tears down/recreates it as hover state changes on
	# GLES, producing texture_free errors on Quest.
	s.comp_grab_bar_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(s.comp_grab_bar_viewport)
	main.screen_shortcuts.populate_composition_viewport(s, s.comp_grab_bar_viewport)

	s.comp_grab_bar.set_layer_viewport(s.comp_grab_bar_viewport)
	main._log("[COMP] Grab-bar/shortcut composition layer created (%s)" % s.monitor_id)

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
	setup_stats_overlay()

func setup_stats_overlay():
	# Match Moonlight Android XR's 768x512 diagnostic panel. Render it once and
	# sample that texture inside each existing screen viewport, rather than
	# allocating another OpenXR composition layer/swapchain. This pins the panel
	# to the screen's top-left in mono and stereo modes and keeps projection off.
	stats_viewport = SubViewport.new()
	stats_viewport.name = "PerformanceStatsViewport"
	stats_viewport.disable_3d = true
	stats_viewport.transparent_bg = true
	stats_viewport.size = Vector2i(768, 512)
	stats_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(stats_viewport)

	var background = ColorRect.new()
	background.name = "Background"
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0, 0, 0, 0.69)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_viewport.add_child(background)

	stats_label = Label.new()
	stats_label.name = "StatsText"
	stats_label.position = Vector2(10, 8)
	stats_label.size = Vector2(748, 496)
	stats_label.add_theme_font_size_override("font_size", 22)
	stats_label.add_theme_color_override("font_color", Color.WHITE)
	stats_label.add_theme_constant_override("line_spacing", 2)
	var mono = SystemFont.new()
	mono.font_names = PackedStringArray(["monospace"])
	stats_label.add_theme_font_override("font", mono)
	stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.add_child(stats_label)

	var screen = main.primary_screen
	var targets = [
		{"bezel": screen.comp_bezel_rect, "viewport": screen.comp_viewport},
		{"bezel": screen.comp_bezel_rect_left, "viewport": screen.comp_viewport_left},
		{"bezel": screen.comp_bezel_rect_right, "viewport": screen.comp_viewport_right},
	]
	for target in targets:
		if not target.bezel or not target.viewport:
			continue
		var rect = TextureRect.new()
		rect.name = "PerformanceStatsOverlay"
		rect.texture = stats_viewport.get_texture()
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.z_index = 100
		rect.visible = false
		target.bezel.add_child(rect)
		stats_rects.append({"rect": rect, "viewport": target.viewport})
	_layout_stats_rects()
	main._log("[COMP] In-screen performance statistics overlay created")

func set_stats_visible(enabled: bool):
	if not stats_viewport:
		return
	if stats_visible == enabled:
		return
	stats_visible = enabled
	stats_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if enabled else SubViewport.UPDATE_DISABLED
	for target in stats_rects:
		target.rect.visible = enabled
	if enabled:
		_layout_stats_rects()

func update_stats_text(value: String):
	if stats_label:
		stats_label.text = value
		if stats_visible:
			stats_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func update_stats_transform():
	_layout_stats_rects()

func _layout_stats_rects():
	for target in stats_rects:
		var rect: TextureRect = target.rect
		var viewport: SubViewport = target.viewport
		if not rect or not viewport:
			continue
		var margin = float(viewport.size.x) * 0.02
		var overlay_width = float(viewport.size.x) * 0.30
		var overlay_height = overlay_width * (512.0 / 768.0)
		rect.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		rect.position = Vector2(margin, margin)
		rect.size = Vector2(overlay_width, overlay_height)

func _setup_ambient_layer() -> bool:
	if _ambient_layer and _ambient_material:
		return true
	if not available or not main.primary_screen:
		return false
	# All ambient cylinders use the same OpenXR layer type as the primary
	# screen, so its already-created layer is a zero-allocation support probe.
	# Do not create an ambient node or swapchain while the feature is Off.
	if not main.primary_screen.comp_cylinder or not main.primary_screen.comp_cylinder.is_natively_supported():
		if not _ambient_support_logged:
			main._log("[AMBIENT] Native cylinder layers unavailable - ambient lighting disabled")
			_ambient_support_logged = true
		return false

	_ambient_layer = OpenXRCompositionLayerCylinder.new()
	_ambient_layer.name = "CompAmbientLayer"
	_ambient_layer.set_sort_order(0)
	_ambient_layer.set_enable_hole_punch(false)
	_ambient_layer.set_alpha_blend(true)
	_ambient_layer.visible = false
	main.xr_origin.add_child(_ambient_layer)
	_ambient_native_supported = _ambient_layer.is_natively_supported()
	if not _ambient_native_supported:
		main._log("[AMBIENT] Ambient cylinder not natively supported - ambient lighting disabled")
		_ambient_support_logged = true
		_ambient_layer.queue_free()
		_ambient_layer = null
		return false

	# Reduce the already-rendered screen to a deliberately coarse colour map
	# before producing the halo. Besides making the glow read as light rather
	# than a duplicate picture, this keeps every later blur/filter lookup inside
	# a tiny, cache-friendly texture instead of repeatedly sampling a 4K frame.
	_ambient_sample_viewport = SubViewport.new()
	_ambient_sample_viewport.name = "AmbientColorSampleViewport"
	_ambient_sample_viewport.disable_3d = true
	_ambient_sample_viewport.transparent_bg = false
	_ambient_sample_viewport.size = Vector2i(AMBIENT_SAMPLE_SIZE, AMBIENT_SAMPLE_SIZE)
	_ambient_sample_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_ambient_sample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(_ambient_sample_viewport)

	_ambient_sample_rect = TextureRect.new()
	_ambient_sample_rect.name = "AmbientColorSample"
	_ambient_sample_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ambient_sample_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_ambient_sample_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_ambient_sample_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_ambient_sample_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ambient_sample_viewport.add_child(_ambient_sample_rect)

	_ambient_viewport = SubViewport.new()
	_ambient_viewport.name = "CompAmbientViewport"
	_ambient_viewport.disable_3d = true
	_ambient_viewport.transparent_bg = true
	_ambient_viewport.size = Vector2i(AMBIENT_VIEWPORT_LONG_EDGE, 180)
	_ambient_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(_ambient_viewport)

	_ambient_rect = ColorRect.new()
	_ambient_rect.name = "AmbientHalo"
	_ambient_rect.anchors_preset = 15
	_ambient_rect.anchor_right = 1.0
	_ambient_rect.anchor_bottom = 1.0
	_ambient_rect.grow_horizontal = 2
	_ambient_rect.grow_vertical = 2
	_ambient_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ambient_material = ShaderMaterial.new()
	_ambient_material.shader = load("res://src/shaders/ambient_halo.gdshader")
	_ambient_material.set_shader_parameter("source_texture", _ambient_sample_viewport.get_texture())
	_ambient_rect.material = _ambient_material
	_ambient_viewport.add_child(_ambient_rect)

	_ambient_layer.set_layer_viewport(_ambient_viewport)
	_update_ambient_geometry()
	main._log("[AMBIENT] 32x32 colour sample and low-resolution composition layer created on demand")
	return true

func ambient_supported() -> bool:
	if _ambient_layer:
		return _ambient_native_supported
	return available and main.primary_screen != null and main.primary_screen.comp_cylinder != null and main.primary_screen.comp_cylinder.is_natively_supported()

func apply_compositor_sharpen(mode: int) -> bool:
	var requested = mode >= main.SHARPEN_RUNTIME_NORMAL
	# Values exposed by the patched OpenXRCompositionLayer engine class:
	# 0=None, 3=normal sharpening, 4=quality sharpening.
	var compositor_filter = 0
	if mode == main.SHARPEN_RUNTIME_NORMAL:
		compositor_filter = 3
	elif mode == main.SHARPEN_RUNTIME_QUALITY:
		compositor_filter = 4
	var supported = false
	for s in main.screens:
		for layer in [s.comp_cylinder, s.comp_cylinder_left, s.comp_cylinder_right]:
			if not layer or not layer.has_method("set_compositor_filter"):
				continue
			if layer.has_method("is_compositor_filter_supported") and layer.is_compositor_filter_supported():
				supported = true
			layer.set_compositor_filter(compositor_filter)
	var first_probe = _last_compositor_sharpen_mode < 0
	if mode != _last_compositor_sharpen_mode or supported != _last_compositor_sharpen_supported:
		if requested:
			main._log("[SHARPEN] Runtime compositor sharpening %s (%s)" % ["Quality" if mode == main.SHARPEN_RUNTIME_QUALITY else "Normal", "active" if supported else "unsupported; using shader fallback"])
		elif first_probe:
			main._log("[SHARPEN] Runtime compositor sharpening is %s" % ("available" if supported else "unavailable"))
	_last_compositor_sharpen_mode = mode
	_last_compositor_sharpen_supported = supported
	return requested and supported and in_use

func _prepare_ambient_sample_update() -> bool:
	if main.video_presentation and main.video_presentation.is_native_active():
		main.video_presentation.request_ambient_sample()
		# Do not redraw from the now-disabled legacy viewport while the first
		# asynchronous native sample is still in flight.
		if not _ambient_native_source_texture:
			_ambient_native_static_waiting = main.settings.ambient_mode == 1
			return false
		# Static mode must wait for a newly requested sample after a settings
		# change, rather than immediately redrawing the previous frozen sample.
		if main.settings.ambient_mode == 1:
			if _ambient_native_sample_revision == _ambient_native_applied_revision:
				_ambient_native_static_waiting = true
				return false
			_ambient_native_applied_revision = _ambient_native_sample_revision
			_ambient_native_static_waiting = false
	if not _ambient_sample_rect or not _ambient_sample_viewport:
		return false
	if not _ambient_sample_seeded:
		# First frame replaces the cleared target so startup is never dark.
		_ambient_sample_rect.modulate = Color.WHITE
		_ambient_sample_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		_ambient_sample_seeded = true
	else:
		# Preserve the previous 32x32 target and alpha-blend the new frame over
		# it. Live converges in roughly ten frames; Slow uses a stronger blend
		# because it only receives ten samples per second.
		var blend = 0.35 if main.settings.ambient_mode == 2 else 0.12
		_ambient_sample_rect.modulate = Color(1.0, 1.0, 1.0, blend)
	return true

func update_native_ambient_sample(pixels: PackedByteArray, width: int, height: int):
	if pixels.size() != width * height * 4 or width <= 0 or height <= 0:
		return
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
	# GLES readback uses a bottom-left origin; Godot textures use top-left.
	image.flip_y()
	var first_sample := _ambient_native_source_texture == null
	if first_sample:
		_ambient_native_source_texture = ImageTexture.create_from_image(image)
	else:
		_ambient_native_source_texture.update(image)
	_ambient_native_sample_revision += 1
	if first_sample or _ambient_source_texture != _ambient_native_source_texture:
		_refresh_ambient_source(true)
	if first_sample or _ambient_native_static_waiting:
		_ambient_dirty = true

func clear_native_ambient_sample():
	var had_native_source := _ambient_native_source_texture != null
	_ambient_native_source_texture = null
	_ambient_native_sample_revision = 0
	_ambient_native_applied_revision = -1
	_ambient_native_static_waiting = false
	if had_native_source:
		_refresh_ambient_source(true)

func _ambient_static_color() -> Color:
	var colors := [
		Color(1.0, 1.0, 1.0),
		Color(1.0, 0.72, 0.45),
		Color(1.0, 0.12, 0.08),
		Color(0.20, 1.0, 0.25),
		Color(0.15, 0.45, 1.0),
		Color(0.72, 0.20, 1.0),
	]
	return colors[clampi(main.settings.ambient_color, 0, colors.size() - 1)]

func _ambient_intensity() -> float:
	# Static remains Medium; screen-reactive Slow/Live need the stronger High
	# preset so their changing colours remain clearly visible around the panel.
	return 0.35 if main.settings.ambient_mode >= 2 else 0.20

func _refresh_ambient_source(force: bool = false):
	if not _ambient_material or not main.primary_screen:
		return
	var source: SubViewport = null
	var source_texture: Texture2D = null
	if main.video_presentation and main.video_presentation.is_native_active() and _ambient_native_source_texture:
		source_texture = _ambient_native_source_texture
	else:
		source = main.primary_screen.comp_viewport
		var stereo = main.settings_controller.get_stereo_mode() if main.settings_controller else 0
		if stereo > 0 and main.primary_screen.comp_viewport_left:
			# A single both-eye halo is intentional. The left-eye composited output
			# is a stable representative source and avoids a second ambient layer.
			source = main.primary_screen.comp_viewport_left
		source_texture = source.get_texture()
	if force or source != _ambient_source_viewport or source_texture != _ambient_source_texture:
		_ambient_source_viewport = source
		_ambient_source_texture = source_texture
		if _ambient_sample_rect:
			_ambient_sample_rect.texture = source_texture
			_ambient_sample_rect.modulate = Color.WHITE
		if _ambient_sample_viewport:
			_ambient_sample_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		_ambient_sample_seeded = false
		_ambient_dirty = true

func apply_ambient_settings():
	main.settings.ambient_mode = clampi(main.settings.ambient_mode, 0, main.ambient_mode_labels.size() - 1)
	main.settings.ambient_color = clampi(main.settings.ambient_color, 0, main.ambient_color_labels.size() - 1)
	if main.settings.ambient_mode == 0:
		_disable_ambient()
		return
	if not _ambient_material and not _setup_ambient_layer():
		return
	_ambient_material.set_shader_parameter("reactive", main.settings.ambient_mode >= 2)
	_ambient_material.set_shader_parameter("static_color", _ambient_static_color())
	_ambient_material.set_shader_parameter("intensity", _ambient_intensity())
	_ambient_slow_elapsed = 0.0
	_ambient_dirty = true
	# The source viewport can resize/reallocate its render target when a stream
	# starts. Rebind explicitly on every mode/settings change instead of relying
	# on the SubViewport object identity remaining sufficient.
	_refresh_ambient_source(true)
	var intensity_label = "High" if main.settings.ambient_mode >= 2 else "Medium"
	main._log("[AMBIENT] Mode=%s intensity=%s (Glow)" % [main.ambient_mode_labels[main.settings.ambient_mode], intensity_label])

func _disable_ambient():
	# Avoid needlessly touching composition-layer visibility every frame while
	# Off/disconnected; layer visibility transitions can rebuild swapchains.
	if _ambient_layer and _ambient_layer.visible:
		_ambient_layer.visible = false
	if _ambient_viewport and _ambient_viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		_ambient_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _ambient_sample_viewport and _ambient_sample_viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		_ambient_sample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _ambient_sample_viewport:
		_ambient_sample_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_ambient_sample_seeded = false

func process_ambient(delta: float):
	if main.settings.ambient_mode == 0:
		_disable_ambient()
		return
	if not _ambient_viewport and not _setup_ambient_layer():
		return
	if not ambient_supported() or not _ambient_viewport:
		return
	var should_show = available and in_use and main.is_streaming and main.settings.ambient_mode > 0
	if not should_show:
		_disable_ambient()
		return
	if not _ambient_layer.visible:
		_update_ambient_geometry()
		# Keep the composition layer's render target resident while it is
		# submitted. UPDATE_ONCE drops back to UPDATE_DISABLED after every draw;
		# on Quest that destroyed and recreated this 256px swapchain on every
		# ambient tick and eventually corrupted GLES teardown state.
		_ambient_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_ambient_layer.visible = true
		_ambient_dirty = true
	elif _ambient_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		_ambient_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Also detects a primary-screen or stereo-mode change while the layer is
	# already visible; the uniform is only touched when the source changes.
	_refresh_ambient_source()

	match main.settings.ambient_mode:
		1: # Static colour; the tiny layer target stays resident while visible.
			_ambient_dirty = false
		2: # Slow: sample the screen at 10 Hz.
			_ambient_slow_elapsed += delta
			if _ambient_dirty or _ambient_slow_elapsed >= AMBIENT_SLOW_INTERVAL_SEC:
				_ambient_slow_elapsed = fmod(_ambient_slow_elapsed, AMBIENT_SLOW_INTERVAL_SEC)
				if not _prepare_ambient_sample_update():
					return
				_ambient_sample_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				_ambient_dirty = false
		3: # Live: sample at 72 Hz - plenty for ambient light, and no longer
			# ties the native readback (glBlitFramebuffer + glReadPixels + PBO
			# fence, see NightfallXrRenderer::issue_ambient_sample()) to every
			# single script tick at whatever refresh rate is selected.
			_ambient_live_elapsed += delta
			if _ambient_dirty or _ambient_live_elapsed >= AMBIENT_LIVE_INTERVAL_SEC:
				_ambient_live_elapsed = fmod(_ambient_live_elapsed, AMBIENT_LIVE_INTERVAL_SEC)
				if not _prepare_ambient_sample_update():
					return
				if _ambient_sample_viewport.render_target_update_mode != SubViewport.UPDATE_ONCE:
					_ambient_sample_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				_ambient_dirty = false

func _update_ambient_geometry():
	if not _ambient_layer or not _ambient_viewport or not main.primary_screen:
		return
	var s = main.primary_screen
	var expanded_size: Vector2 = s.mesh_size * AMBIENT_LAYER_SCALE
	var aspect = expanded_size.x / maxf(expanded_size.y, 0.001)
	var viewport_size: Vector2i
	if aspect >= 1.0:
		viewport_size = Vector2i(AMBIENT_VIEWPORT_LONG_EDGE, maxi(64, roundi(AMBIENT_VIEWPORT_LONG_EDGE / aspect)))
	else:
		viewport_size = Vector2i(maxi(64, roundi(AMBIENT_VIEWPORT_LONG_EDGE * aspect)), AMBIENT_VIEWPORT_LONG_EDGE)
	if _ambient_viewport.size != viewport_size:
		_ambient_viewport.size = viewport_size
		_ambient_dirty = true

	var radius = maxf(s._comp_cyl_radius, 0.001)
	var view_dist = maxf((s.global_position - main.xr_camera.global_position).length(), 0.5)
	var screen_sort = clampi(int((10.0 - view_dist) * 10), 1, 100)
	_ambient_layer.set_sort_order(maxi(0, screen_sort - 1))
	_ambient_layer.set_radius(radius)
	_ambient_layer.set_central_angle(expanded_size.x / radius)
	_ambient_layer.set_aspect_ratio(aspect)
	_ambient_layer.global_position = s._comp_cyl_center
	_ambient_layer.global_rotation = s.global_rotation

func setup_background_equirect():
	if not equirect_available:
		main._log("[COMP] OpenXRCompositionLayerEquirect not available - environment backgrounds won't show in projectionless mode")
		return

	if not main.composition_environment.setup(main, main.xr_origin, main.BG_EQUIRECT_ANGLE_DEG, main.BG_CAPTURE_FOV_DEG):
		main._log("[COMP] OpenXRCompositionLayerEquirect not natively supported on this runtime - environment backgrounds won't show in projectionless mode")
		return
	main._log("[COMP] Environment-background equirect composition layer created")

	main.composition_panels.setup_ui(main.xr_origin, main.ui_viewport, main._ui_mesh_size)
	main._log("[COMP] UI composition layer created")
	main.composition_panels.setup_tooltip(
		main.xr_origin,
		main.ui_controller.get_tooltip_viewport(),
		UIController.TOOLTIP_QUAD_SIZE)
	main._log("[COMP] Tooltip composition layer created")
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		main.composition_panels.setup_keyboard(main.xr_origin, main.virtual_keyboard.viewport, main.virtual_keyboard.mesh_size)
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
		main.composition_panels.setup_keyboard(main.xr_origin, main.virtual_keyboard.viewport, main.virtual_keyboard.mesh_size)
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
	# Always allocate the bezel-padded viewport size/aspect and only toggle
	# the border's alpha, rather than flipping t.vp.size between content_size
	# and bezel_size on/off (2026-09-05) - toggling bezel while streaming
	# reliably crashed with the exact same signature (SIGSEGV, fault addr
	# 0xe0, null pointer) as _set_comp_quad_hidden()'s documented swapchain
	# race above: resizing a SubViewport that backs an OpenXRCompositionLayer
	# forces Godot to tear down and recreate that layer's swapchain, which
	# can race in-flight render commands. Keeping the size (and therefore the
	# swapchain) constant across a bezel toggle avoids that resize entirely;
	# a genuine resolution change (comp_base_size changing) still resizes
	# normally via the guard below; only the padding is now unconditional.
	# Visual cost: an ~8px transparent margin around the video when the
	# bezel is off, instead of the video filling the quad edge-to-edge.
	var px = 8
	var bezel_x = s.mesh_size.x * (1.0 + float(px * 2) / float(base_w))
	var bezel_y = s.mesh_size.y * (1.0 + float(px * 2) / float(base_h))
	var bezel_size = Vector2i(base_w + px * 2, base_h + px * 2)
	var show_border = main.settings.bezel_enabled and in_use
	for t in triplet:
		if not t.bezel:
			continue
		t.bezel.color = Color(0, 0, 0, 1 if show_border else 0)
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
		if t.vp.size != bezel_size:
			t.vp.size = bezel_size
		if t.cyl and t.cyl.visible:
			t.cyl.set_aspect_ratio(bezel_x / bezel_y)

func update_bezel():
	if not main.primary_screen or not main.primary_screen.comp_yuv_rect:
		return
	for s in main.screens:
		_update_bezel_for(s)
	_layout_stats_rects()

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
	if s == main.primary_screen:
		_update_ambient_geometry()

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
	# 0 = SDR, 1 = PQ, 2 = HLG - see TextureUploader::_render_thread_setup()/
	# update_colorspace() (native) for where this actually gets set.
	var ctt = mat.get_shader_parameter("color_transfer_type")
	if ctt == null:
		ctt = 0
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
		var mode_tuple = [yuv_mode_val, cmt, cr, ctt]
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
			main._log("[YUV] Direct YUV binding: mode=%d nv12_rd=%s semi_planar=%s transfer=%d" % [yuv_mode_val, str(is_nv12_rd), str(is_semi_planar), ctt])
			bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode_val, cmt, cr, ctt)
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

func bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode: int, cmt, cr, ctt: int = 0):
	# Swap the composition materials' shader resource BEFORE pushing
	# parameters below - see yuv_display_hdr.gdshader's own comment for why
	# this is a separate compiled shader rather than a branch in the plain
	# one (keeps the always-hot SDR/depth-warp path free of PQ/HLG code
	# entirely, instead of paying for it on every stream regardless of
	# whether it's ever used).
	_apply_video_shader_state(ctt)
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
			if ctt != 0:
				mat.set_shader_parameter("color_transfer_type", ctt)
				mat.set_shader_parameter("hdr_eotf_lut", _get_hdr_lut())
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
	if main.depth_estimator:
		main.depth_estimator.bind_decoder_textures(tex_y, tex_u, tex_v, yuv_mode, cmt, cr)
	_dots_active = false
	main._log("[COMP] YUV textures bound to composition layer shader (mode=%d)" % yuv_mode)

func bind_fallback_texture(stream_tex):
	# This path is also used while a new decoder session has not produced a
	# bindable direct-YUV texture yet. The HDR shader only tonemaps its direct
	# YUV/RGB input path (yuv_mode > 0), not main_texture, so retaining it here
	# cannot correctly process an HDR fallback and only leaks the previous
	# session's shader state. GLES HDR fallback needs its own explicit plumbing.
	_apply_video_shader_state(0)
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("main_texture", stream_tex)
			mat.set_shader_parameter("yuv_mode", 0)
	if main.depth_estimator:
		main.depth_estimator.bind_stream_texture()

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
	_refresh_ambient_source()
	_ambient_dirty = true

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
	_refresh_ambient_source()
	_ambient_dirty = true
	main._log("[COMP] Switched to stereo composition layer (mode=%d)" % stereo)

func switch_to_mesh_rendering():
	in_use = false
	_disable_ambient()
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if main.is_streaming else SubViewport.UPDATE_DISABLED
	for scr in main.screens:
		if scr.comp_cylinder: scr.comp_cylinder.visible = false
		if scr.comp_cylinder_left: scr.comp_cylinder_left.visible = false
		if scr.comp_cylinder_right: scr.comp_cylinder_right.visible = false
		if scr.comp_viewport:
			scr.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		if scr.bezel_mesh:
			scr.bezel_mesh.visible = main.settings.bezel_enabled
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
		var runtime_sharpen_active = apply_compositor_sharpen(main.settings.sharpen_mode)
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
				mat.set_shader_parameter("filter_mode", 0)
				var shader_sharpen = float(main.settings.sharpen_mode) * 0.016
				if main.settings.sharpen_mode >= main.SHARPEN_RUNTIME_NORMAL:
					shader_sharpen = 0.0 if runtime_sharpen_active else (0.5 if main.settings.sharpen_mode == main.SHARPEN_RUNTIME_NORMAL else 1.0)
				mat.set_shader_parameter("sharpen", shader_sharpen)
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
