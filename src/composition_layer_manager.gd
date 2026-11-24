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
const SCREEN_OVERLAY_SIZE := Vector2i(1100, 960)
const STATS_REGION := Rect2(0, 0, 768, 512)
const MESSAGE_REGION := Rect2(0, 516, 1100, 440)
const MESSAGE_PADDING := Vector2(4, 4)
const MESSAGE_SCREEN_WIDTH := 0.55
var screen_message_visible := false
var _screen_message_revision := 0
var _stats_background: Control
var _screen_message_panel: PanelContainer
var _screen_message_label: Label
var _sdr_shader: Shader = null
var _sdr_picture_shader: Shader = null
var _hdr_shader: Shader = null
var _hdr_lut: ImageTexture = null
var _current_color_transfer_type: int = 0

# Primary-screen ambient lighting is deliberately isolated in one small,
# alpha-blended compositor layer. It never changes the main screen layer's
# opaque blend mode or any of the YUV/HDR/AI-depth shaders.
const AMBIENT_LAYER_SCALE := 1.30
## Below every screen (their sort orders are 1-100, from viewing distance, and
## the native renderer recomputes the primary's every frame), above the
## passthrough fade (-50). Following the primary's distance instead let the
## glow draw over the screen when the viewer leaned back.
const AMBIENT_SORT_ORDER := 0
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
			if _independent_browser(s):
				continue
			if mat and mat.shader != shader:
				mat.shader = shader

func refresh_picture_shader_state():
	_apply_video_shader_state(_current_color_transfer_type)

var _last_bind_targets: Array = []

func _stream_binding_targets() -> Array:
	var targets := []
	for screen in main.screens:
		if _independent_browser(screen) or _browser_owns_surface(screen): continue
		var provider = main.screen_sources.browser_for_screen(screen) if main.screen_sources else null
		var materials := []
		for mat in get_shader_mats(screen): materials.append(mat.get_instance_id() if mat != null else 0)
		targets.append([screen.get_instance_id(), screen.content_tabs.selected_id,
			provider.get("generation") if provider != null else 0, materials])
	return targets

func invalidate_yuv_cache():
	_last_bind_targets = []
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

func _independent_browser(s: VRScreen) -> bool:
	var provider = main.screen_sources.browser_for_screen(s) if main.screen_sources != null else null
	return s != main.primary_screen and main.screen_sources != null \
		and ((provider != null and (provider.active or provider.closing or main.screen_sources.monitor_tab(s) == null)) or _independent_welcome(s))

func _independent_welcome(s: VRScreen) -> bool:
	return not main.is_streaming and main.screen_sources.has_method("stream_screen") \
		and main.screen_sources.stream_screen() == s

# Called each presentation frame: a browser texture can arrive after setup.
# Only the secondary owns this mono viewport; the primary stays native/AI-3D.
func refresh_browser_screen(s: VRScreen) -> void:
	if not _independent_browser(s):
		return
	var provider = main.screen_sources.browser_for_screen(s)
	var welcome := _independent_welcome(s)
	var ready: bool = welcome or (provider != null and not provider.closing and provider.active and provider.texture != null)
	for layer in [s.comp_cylinder_left, s.comp_cylinder_right]:
		if layer:
			layer.visible = false
	for viewport in [s.comp_viewport_left, s.comp_viewport_right]:
		if viewport:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not ready:
		if s.comp_cylinder:
			s.comp_cylinder.visible = false
		if s.comp_viewport:
			s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	for mat in get_shader_mats(s):
		if mat and mat.shader != _get_sdr_shader():
			mat.shader = _get_sdr_shader()
	s.bind_independent_browser_texture(main.welcome_viewport.get_texture() if welcome else provider.texture)
	_update_cylinder_params_for(s)
	var content_size: Vector2i = main.welcome_viewport.size if welcome else Vector2i(provider.render_size)
	if s.comp_base_size != content_size:
		s.comp_base_size = content_size
	_update_bezel_for(s)
	for label in [s.comp_loading_label, s.comp_loading_label_left, s.comp_loading_label_right]:
		if label:
			label.visible = false
	for cursor in [s.comp_stream_cursor, s.comp_stream_cursor_circle]:
		if cursor:
			cursor.visible = false
	if available and in_use and s.comp_cylinder:
		s.comp_layer = s.comp_cylinder
		SphereLayers.bind(s.comp_layer, s.comp_viewport)
		s.comp_layer.visible = true
		s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		if s._original_mat == null:
			s._original_mat = s.material_override
		if _transparent_mat:
			s.material_override = _transparent_mat

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

	main.composition_screen_controls.setup(main, main.xr_origin, main.screen_shortcuts, s)
	main._log("[COMP] Grab-bar/shortcut composition layer created (%s)" % s.monitor_id)
	main._log("[COMP] Combined corner-handle composition layer created (%s)" % s.monitor_id)

	if not with_stereo:
		return
	ensure_stereo_layers(s)

func ensure_stereo_layers(s: VRScreen) -> void:
	if not available or s.comp_cylinder_left != null: return

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
	# A screen promoted to primary already has its place in the frame; the new
	# eye layers must show that region, not the whole multi-screen frame.
	s.comp_shader_mat_left.set_shader_parameter("uv_region", s.uv_region)
	s.comp_shader_mat_right.set_shader_parameter("uv_region", s.uv_region)
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

func setup():
	if not available:
		main._log("[COMP] OpenXRCompositionLayerCylinder not available")
		return

	setup_background_equirect()

	setup_screen(main.primary_screen, true)
	setup_stats_overlay()

func setup_stats_overlay():
	# Keep the 768x512 diagnostic panel, with a notification strip below it. Render once and
	# sample that texture inside each existing screen viewport, rather than
	# allocating another OpenXR composition layer/swapchain. This pins the panel
	# to the screen's top-left in mono and stereo modes and keeps projection off.
	stats_viewport = SubViewport.new()
	stats_viewport.name = "PerformanceStatsViewport"
	stats_viewport.disable_3d = true
	stats_viewport.transparent_bg = true
	stats_viewport.size = SCREEN_OVERLAY_SIZE
	stats_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(stats_viewport)

	var background = ColorRect.new()
	background.name = "Background"
	background.size = Vector2(768, 512)
	background.visible = false
	_stats_background = background
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

	_screen_message_panel = PanelContainer.new()
	_screen_message_panel.name = "ScreenNotification"
	_screen_message_panel.size = _message_panel_size()
	_screen_message_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_message_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.09, 0.92)
	style.set_corner_radius_all(28)
	style.border_color = Color(0.49, 0.45, 1.0, 0.9)
	style.set_border_width_all(3)
	style.set_content_margin_all(12)
	_screen_message_panel.add_theme_stylebox_override("panel", style)
	stats_viewport.add_child(_screen_message_panel)
	_screen_message_label = Label.new()
	_screen_message_label.add_theme_font_size_override("font_size", 40)
	_screen_message_label.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	_screen_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_screen_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_screen_message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_screen_message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_message_panel.add_child(_screen_message_label)

	var screen = main.primary_screen
	var targets = [
		{"bezel": screen.comp_bezel_rect, "viewport": screen.comp_viewport},
		{"bezel": screen.comp_bezel_rect_left, "viewport": screen.comp_viewport_left},
		{"bezel": screen.comp_bezel_rect_right, "viewport": screen.comp_viewport_right},
	]
	for target in targets:
		if not target.bezel or not target.viewport:
			continue
		var rect = _make_overlay_rect("PerformanceStatsOverlay", STATS_REGION, target.bezel)
		var message_rect = _make_overlay_rect("ScreenNotificationOverlay", MESSAGE_REGION, target.bezel)
		stats_rects.append({"rect": rect, "message_rect": message_rect, "viewport": target.viewport})
	_layout_stats_rects()
	main._log("[COMP] In-screen performance statistics overlay created")

func set_stats_visible(enabled: bool):
	if not stats_viewport: return
	stats_visible = enabled
	_sync_screen_overlay()

func set_screen_message(text: String) -> void:
	if not stats_viewport: return
	screen_message_visible = not text.is_empty()
	_screen_message_label.text = text
	_screen_message_revision += 1
	_sync_screen_overlay()
	if screen_message_visible:
		_refresh_message_after_layout(_screen_message_revision)
	elif main.video_presentation:
		main.video_presentation.request_stats_overlay_update()

func _refresh_message_after_layout(revision: int) -> void:
	# Container layout/text shaping settle after the first draw. Capturing only
	# that draw produced a styled background with no text on first use.
	for frame in 2:
		if not is_instance_valid(main) or not main.is_inside_tree(): return
		await main.get_tree().process_frame
	if not is_instance_valid(main) or revision != _screen_message_revision or not is_instance_valid(stats_viewport): return
	# The first zero-width wrap can grow a PanelContainer's minimum height;
	# it does not shrink itself again when the real text width is known.
	_screen_message_panel.size = _message_panel_size()
	_screen_message_panel.position = MESSAGE_REGION.position + (MESSAGE_REGION.size - _message_panel_size()) * 0.5
	await main.get_tree().process_frame
	if not is_instance_valid(main) or revision != _screen_message_revision or not is_instance_valid(stats_viewport): return
	stats_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if main.video_presentation: main.video_presentation.request_stats_overlay_update()

func _message_panel_size() -> Vector2:
	var height := 432.0 if _screen_message_label != null and _screen_message_label.text.count("\n") > 1 else 176.0
	return Vector2(MESSAGE_REGION.size.x - MESSAGE_PADDING.x * 2, height)

func _sync_screen_overlay() -> void:
	_screen_message_label.add_theme_font_size_override("font_size", 34 if _screen_message_label.text.count("\n") > 1 else 40)
	var stats_enabled: bool = main.settings.performance_overlay_enabled and main.is_streaming
	_stats_background.visible = stats_enabled
	_screen_message_panel.visible = screen_message_visible
	_screen_message_panel.position = MESSAGE_REGION.position + (MESSAGE_REGION.size - _message_panel_size()) * 0.5
	stats_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if stats_enabled or screen_message_visible else SubViewport.UPDATE_DISABLED
	for target in stats_rects:
		if is_instance_valid(target.rect): target.rect.visible = stats_visible
		if is_instance_valid(target.get("message_rect")): target.message_rect.visible = screen_message_visible
	_layout_stats_rects()

func update_stats_text(value: String):
	if stats_label:
		stats_label.text = value
		if stats_visible or screen_message_visible or main.settings.performance_overlay_enabled:
			stats_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func update_stats_transform():
	_layout_stats_rects()

func _make_overlay_rect(rect_name: String, region: Rect2, parent: Control) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = rect_name
	var atlas := AtlasTexture.new()
	atlas.atlas = stats_viewport.get_texture()
	atlas.region = region
	atlas.filter_clip = true
	rect.texture = atlas
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.z_index = 100
	rect.visible = false
	parent.add_child(rect)
	return rect

static func screen_message_bounds(size: Vector2) -> Rect2:
	var width := size.x * MESSAGE_SCREEN_WIDTH
	var height := width * MESSAGE_REGION.size.y / MESSAGE_REGION.size.x
	return Rect2((size - Vector2(width, height)) * 0.5, Vector2(width, height))

func _layout_stats_rects():
	if not main.primary_screen: return
	var screen = main.primary_screen
	var bezels = [screen.comp_bezel_rect, screen.comp_bezel_rect_left, screen.comp_bezel_rect_right]
	var viewports = [screen.comp_viewport, screen.comp_viewport_left, screen.comp_viewport_right]
	for i in bezels.size():
		if not is_instance_valid(bezels[i]) or not is_instance_valid(viewports[i]): continue
		while stats_rects.size() <= i: stats_rects.append({"rect": null, "message_rect": null, "viewport": null})
		var target: Dictionary = stats_rects[i]
		for entry in [["rect", "PerformanceStatsOverlay", STATS_REGION], ["message_rect", "ScreenNotificationOverlay", MESSAGE_REGION]]:
			if not is_instance_valid(target.get(entry[0])):
				target[entry[0]] = _make_overlay_rect(entry[1], entry[2], bezels[i])
			elif target[entry[0]].get_parent() != bezels[i]:
				target[entry[0]].reparent(bezels[i], false)
		target.viewport = viewports[i]
		var size := Vector2(viewports[i].size)
		var margin := size.x * 0.02
		var width := size.x * 0.30
		target.rect.position = Vector2(margin, margin)
		target.rect.size = Vector2(width, width * STATS_REGION.size.y / STATS_REGION.size.x)
		target.rect.visible = stats_visible
		var bounds := screen_message_bounds(size)
		target.message_rect.position = bounds.position
		target.message_rect.size = bounds.size
		target.message_rect.visible = screen_message_visible

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
	_ambient_layer.set_sort_order(AMBIENT_SORT_ORDER)
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
	return (0.35 if main.settings.ambient_mode >= 2 else 0.20) * main.settings.ambient_gain

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
	# The welcome UI is already rendered through the same primary composition
	# viewport as the stream. Keep the halo available before connecting (and
	# after disconnecting) so Static can be previewed and Slow/Live can sample
	# the welcome image without starting the native video sampling path.
	var should_show = available and in_use and main.settings.ambient_mode > 0
	if not should_show:
		_disable_ambient()
		return
	if not _ambient_layer.visible:
		_update_ambient_geometry()
		# A SubViewport attached to an OpenXR composition layer must keep a
		# stable render target while the layer is submitted. UPDATE_ONCE falls
		# back to UPDATE_DISABLED after each draw; on Quest that made Godot
		# destroy and recreate this layer's swapchain on every ambient tick
		# (10 Hz in Slow mode), eventually leaving teardown to crash in the GL
		# thread. The output is only 256 pixels on its long edge, so keep this
		# inexpensive halo pass alive and throttle the 32x32 source sampling
		# below instead.
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
	_ambient_layer.set_sort_order(AMBIENT_SORT_ORDER)
	_ambient_layer.set_radius(radius)
	_ambient_layer.set_central_angle(expanded_size.x / radius)
	_ambient_layer.set_aspect_ratio(aspect)
	_ambient_layer.global_position = s._comp_cyl_center
	_ambient_layer.global_rotation = s.global_rotation
	# On a sphere grid the primary is a sphere band: its glow is a larger band
	# of the same sphere, so it curves with the screen in both directions.
	var on_sphere: bool = s.on_sphere()
	var frame := Transform3D.IDENTITY
	var horizontal := 0.0
	var upper := 0.0
	var lower := 0.0
	if on_sphere:
		frame = ScreenPlacementGrid.sphere_frame(s.global_transform, s.surface_lat, s.sphere_r())
		horizontal = expanded_size.x / maxf(s.placement_radius, 0.001)
		var half: float = s.band_half() * AMBIENT_LAYER_SCALE
		upper = minf(s.band_mid() + half, PI * 0.5)
		lower = maxf(s.band_mid() - half, -PI * 0.5)
	SphereLayers.sync(_ambient_layer, on_sphere, frame, s.sphere_r(), horizontal, upper, lower, AMBIENT_SORT_ORDER)

func setup_background_equirect():
	# Only the environment background needs equirect layers. The UI, cursor,
	# ray and marker layers below must be created either way: SteamVR (Steam
	# Frame) has no XR_KHR_composition_layer_equirect2, and returning early
	# here left the pointer drawn in the projection layer, behind every panel.
	if not equirect_available:
		main._log("[COMP] OpenXRCompositionLayerEquirect not available - environment backgrounds won't show in projectionless mode")
	elif not main.composition_environment.setup(main, main.xr_origin, main.BG_EQUIRECT_ANGLE_DEG, main.BG_CAPTURE_FOV_DEG):
		main._log("[COMP] OpenXRCompositionLayerEquirect not natively supported on this runtime - environment backgrounds won't show in projectionless mode")
	else:
		main._log("[COMP] Environment-background equirect composition layer created")

	main.composition_panels.setup_ui(main.xr_origin, main.ui_viewport,
		main._ui_mesh_size + Vector2(0, main.UI_TOOLTIP_STRIP_METERS))
	main._log("[COMP] UI composition layer created")
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		main.composition_panels.setup_keyboard(main.xr_origin, main.virtual_keyboard.viewport, main.virtual_keyboard.mesh_size)
		main._log("[COMP] Keyboard composition layer created")

	# Cursor layers (2026-08-24) - previously created only for the non-GLES
	# path (an early return here skipped them entirely under GLES), even
	# though the cursor-update logic in main.gd's _update_cursor_layer()
	# already had GLES-specific quad-sizing branches for them (see its
	# RenderingServer.get_current_rendering_method() == "gl_compatibility"
	# checks) - that code was dead/unreachable since the pointer layer was always
	# null under GLES. Nothing in this creation code is Vulkan-specific
	# (plain SubViewport + TextureRect/ColorRect + shader), so there was no
	# actual technical reason to skip it - just an oversight from GLES's
	# first pass. Moved above the gl_compatibility/else split so both paths
	# reach it, instead of duplicating it into the GLES branch above.
	main.composition_pointers.setup(main, main.xr_origin)
	main._log("[COMP] Cursor composition layer created")
	main._log("[COMP] Left cursor composition layer created")

	main.composition_controller_rays.setup(main, main.xr_origin)
	main.composition_toast.setup(main, main.xr_origin)
	main._log("[COMP] Controller ray composition layers created")

	# Persistent controller position markers (2026-08-25) complement the ray
	# layers: they remain visible while a controller is resting and the active
	# pointing ray is hidden. Pose and visibility stay in main.gd for now.
	main.composition_controller_markers.setup(main, main.xr_origin)
	main._log("[COMP] Controller position marker composition layers created")

	# Cheap, shader-driven hand triangles replace the earlier full hand-skeleton
	# viewport capture. Pose updates remain in main's XR interaction loop.
	main.composition_hand_indicators.setup(main, main.xr_origin)
	main._log("[COMP] Hand indicator composition layers created")

	# GLES already created its keyboard layer above (different sort order/log,
	# same overall shape) - only create the non-GLES variant here to avoid
	# double-creating (and leaking the first one's viewport/quad) now that
	# cursor creation above runs unconditionally for both paths.
	if RenderingServer.get_current_rendering_method() != "gl_compatibility":
		main.composition_panels.setup_keyboard(main.xr_origin, main.virtual_keyboard.viewport, main.virtual_keyboard.mesh_size)
		main._log("[COMP] Keyboard composition layer created")

	available = true
	var cylinder = main.primary_screen.comp_cylinder
	if cylinder and cylinder.is_natively_supported():
		main._log("[COMP] Composition layer cylinder natively supported")
	else:
		main._log("[COMP] Composition layer cylinder NOT natively supported (using fallback mesh)")

func connect_welcome_texture():
	if not available:
		return
	for mat in get_shader_mats():
		if mat:
			mat.set_shader_parameter("main_texture", main.get_welcome_content_texture())
			mat.set_shader_parameter("yuv_mode", 0)
	main.primary_screen.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

## Padding (px per side) every composition viewport carries for the bezel.
const BEZEL_PX := 8

func _update_bezel_for(s: VRScreen):
	var render_size := s.comp_render_size()
	var base_w = render_size.x
	var base_h = render_size.y
	var triplet = [
		{"bezel": s.comp_bezel_rect, "yuv": s.comp_yuv_rect, "vp": s.comp_viewport, "cyl": s.comp_cylinder},
		{"bezel": s.comp_bezel_rect_left, "yuv": s.comp_yuv_rect_left, "vp": s.comp_viewport_left, "cyl": s.comp_cylinder_left},
		{"bezel": s.comp_bezel_rect_right, "yuv": s.comp_yuv_rect_right, "vp": s.comp_viewport_right, "cyl": s.comp_cylinder_right},
	]
	# Always allocate the bezel-padded viewport size/aspect and only toggle
	# the border's alpha, rather than flipping t.vp.size between content_size
	# and bezel_size on/off (2026-09-05) - toggling bezel while streaming
	# reliably crashed with the exact same signature (SIGSEGV, fault addr
	# 0xe0, null pointer) as the pointer layer's documented swapchain race:
	# resizing a SubViewport that backs an OpenXRCompositionLayer
	# forces Godot to tear down and recreate that layer's swapchain, which
	# can race in-flight render commands. Keeping the size (and therefore the
	# swapchain) constant across a bezel toggle avoids that resize entirely;
	# a genuine resolution change (comp_base_size changing) still resizes
	# normally via the guard below; only the padding is now unconditional.
	# The legacy OpenXR layer ignores viewport alpha, so a transparent margin
	# still looks black. With the bezel off, fill the fixed padding with the
	# image instead; only the ColorRect/inset changes, never the swapchain.
	var px = BEZEL_PX
	var bezel_x = s.mesh_size.x * (1.0 + float(px * 2) / float(base_w))
	var bezel_y = s.mesh_size.y * (1.0 + float(px * 2) / float(base_h))
	var bezel_size = Vector2i(base_w + px * 2, base_h + px * 2)
	var show_border = main.settings.bezel_enabled and in_use
	var inset = px if show_border else 0
	for t in triplet:
		if not t.bezel:
			continue
		t.bezel.color = Color(0, 0, 0, 1 if show_border else 0)
		t.bezel.anchors_preset = 15
		t.bezel.offset_left = 0
		t.bezel.offset_top = 0
		t.bezel.offset_right = 0
		t.bezel.offset_bottom = 0
		# Keep the video rectangle anchored to all four sides of the bezel.
		# PRESET_TOP_LEFT after setting the inset discarded the full-width
		# anchors, so welcome content could cover the border on resize.
		t.yuv.set_anchors_preset(Control.PRESET_FULL_RECT)
		t.yuv.offset_left = inset
		t.yuv.offset_top = inset
		t.yuv.offset_right = -inset
		t.yuv.offset_bottom = -inset
		if t.vp.size != bezel_size:
			t.vp.size = bezel_size
		if t.cyl and t.cyl.visible:
			t.cyl.set_aspect_ratio(bezel_x / bezel_y)
			t.cyl.set_central_angle(s._comp_cyl_central_angle * (bezel_x / s.mesh_size.x) if s._comp_cyl_central_angle > 0.0 else t.cyl.get_central_angle())

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
	# On a grid surface, a Curved screen takes the surface's radius and a
	# Slight Curve panel its own (VRScreen.get_cylinder_radius()); Flat stays flat.
	if s.placement_radius > 0.0 and s.curvature > 0:
		radius = s.get_cylinder_radius()
	var screen_forward = -s.global_transform.basis.z
	var central_angle = s.mesh_size.x / radius
	var aspect = s.mesh_size.x / s.mesh_size.y
	# The layer shows the whole composition viewport, which always carries
	# BEZEL_PX of padding on each side (see _update_bezel_for()). Size the
	# layer for that padded image so the padding (the black bezel) sits around
	# the picture: sized for the picture alone, the bezel was squeezed inside
	# and drew a thin, aliased black line over the picture's edge. The pointer
	# keeps the picture's own angle (_comp_cyl_central_angle) for hit tests.
	var layer_angle = central_angle
	var layer_aspect = aspect
	var render_size := s.comp_render_size()
	if render_size.x > 0 and render_size.y > 0:
		var pad_x = 1.0 + float(BEZEL_PX * 2) / float(render_size.x)
		var pad_y = 1.0 + float(BEZEL_PX * 2) / float(render_size.y)
		layer_angle = central_angle * pad_x
		layer_aspect = (s.mesh_size.x * pad_x) / (s.mesh_size.y * pad_y)
	# The pointer hits the screen's own curved mesh. A screen moved since that
	# mesh was built (e.g. a new primary taking the old one's place) would show
	# its picture on this cylinder while the laser hits the old curve.
	if not s.is_flat() and absf(s.built_radius - radius) > radius * 0.01:
		s.apply_curvature()
	s._comp_cyl_radius = radius
	s._comp_cyl_central_angle = central_angle
	s._comp_cyl_center = s.global_position - screen_forward * radius
	var sort_order = clampi(int((10.0 - view_dist) * 10), 1, 100)
	for cyl in [s.comp_cylinder, s.comp_cylinder_left, s.comp_cylinder_right]:
		if cyl:
			cyl.set_sort_order(sort_order)
			cyl.set_radius(radius)
			cyl.set_central_angle(layer_angle)
			cyl.set_aspect_ratio(layer_aspect)
			cyl.global_position = s.global_position - screen_forward * radius
			cyl.global_rotation = s.global_rotation
	_sync_sphere_bands(s, sort_order)
	if s == main.primary_screen:
		_update_ambient_geometry()

## Sphere grid screens: show each of the screen's layers as a band of the sphere.
func _sync_sphere_bands(s: VRScreen, sort_order: int) -> void:
	var on := s.on_sphere()
	var frame := Transform3D.IDENTITY
	var r := s.sphere_r()
	var horizontal := 0.0
	var upper := 0.0
	var lower := 0.0
	if on:
		frame = ScreenPlacementGrid.sphere_frame(s.global_transform, s.surface_lat, r)
		var pad := Vector2.ONE
		if s.comp_base_size.x > 0 and s.comp_base_size.y > 0:
			pad = Vector2(1.0 + float(BEZEL_PX * 2) / float(s.comp_base_size.x), 1.0 + float(BEZEL_PX * 2) / float(s.comp_base_size.y))
		horizontal = s.mesh_size.x * pad.x / maxf(s.placement_radius, 0.001)
		var half := s.band_half() * pad.y
		upper = s.band_mid() + half
		lower = s.band_mid() - half
	for cyl in [s.comp_cylinder, s.comp_cylinder_left, s.comp_cylinder_right]:
		if cyl:
			SphereLayers.sync(cyl, on, frame, r, horizontal, upper, lower, sort_order)

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

func _browser_owns_surface(screen: VRScreen) -> bool:
	var provider = main.screen_sources.browser_for_screen(screen) if main.screen_sources else null
	return provider != null and (provider.active or provider.closing)

func bind_yuv_textures():
	var mat = main.stream_backend.get_shader_material()
	if not mat:
		main._log("[YUV] No shader material from stream backend, using SubViewport path")
		var stream_tex = main.stream_viewport.get_texture()
		if not in_use:
			for s in main.screens:
				if _independent_browser(s) or _browser_owns_surface(s):
					continue
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
		var targets := _stream_binding_targets()
		var unchanged = (rids == _last_bind_rids and mode_tuple == _last_bind_mode and targets == _last_bind_targets)
		if not in_use:
			for s in main.screens:
				if _independent_browser(s) or _browser_owns_surface(s):
					continue
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
			_last_bind_targets = targets
	else:
		var stream_tex = main.stream_viewport.get_texture()
		if not in_use:
			for s in main.screens:
				if _independent_browser(s) or _browser_owns_surface(s):
					continue
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
		if _independent_browser(s) or _browser_owns_surface(s):
			continue
		var provider = main.screen_sources.browser_for_screen(s) if main.screen_sources else null
		if provider != null and (provider.active or provider.closing): continue
		if provider == null or (not provider.active and not provider.closing):
			s.restore_monitor_region()
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
		if _independent_browser(s) or _browser_owns_surface(s):
			continue
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
	# The saved SBS/AI-3D preference is allowed to remain selected on the
	# welcome screen, but the welcome screen itself is always mono.  A delayed
	# AI-3D commit can arrive after disconnect; using get_stereo_mode() here
	# would reactivate the old stereo OpenXR layers while no stream exists.
	# That stale layer transition was observed immediately before the Quest GL
	# thread null-dereference crash.
	var stereo = main.settings_controller.get_stereo_mode() if main.settings_controller else 0
	if main.primary_media_active() and stereo > 0:
		switch_to_stereo_comp_layer()
		return
	in_use = true
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for scr in main.screens:
		# Every screen, not just the current primary: an earlier primary keeps
		# its eye layers.
		if scr.comp_cylinder_left: scr.comp_cylinder_left.visible = false
		if scr.comp_cylinder_right: scr.comp_cylinder_right.visible = false
		if scr.comp_viewport_left: scr.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if scr.comp_viewport_right: scr.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for scr in main.screens:
		if _independent_browser(scr):
			refresh_browser_screen(scr)
			continue
		if scr.comp_cylinder:
			scr.comp_layer = scr.comp_cylinder
			SphereLayers.bind(scr.comp_layer, scr.comp_viewport)
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
	SphereLayers.bind(s.comp_cylinder_left, s.comp_viewport_left)
	SphereLayers.bind(s.comp_cylinder_right, s.comp_viewport_right)
	s.comp_shader_mat_left.set_shader_parameter("stereo_mode", stereo)
	s.comp_shader_mat_left.set_shader_parameter("eye_index", 1)
	s.comp_shader_mat_right.set_shader_parameter("stereo_mode", stereo)
	s.comp_shader_mat_right.set_shader_parameter("eye_index", 2)
	s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for scr in main.screens:
		if scr == s:
			continue
		if _independent_browser(scr):
			refresh_browser_screen(scr)
			continue
		if scr.comp_cylinder:
			scr.comp_layer = scr.comp_cylinder
			SphereLayers.bind(scr.comp_layer, scr.comp_viewport)
			scr.comp_layer.visible = true
		# Only the primary draws in 3D. A screen that was primary before keeps
		# its eye layers, which would otherwise stay drawn over its flat one.
		if scr.comp_cylinder_left: scr.comp_cylinder_left.visible = false
		if scr.comp_cylinder_right: scr.comp_cylinder_right.visible = false
		if scr.comp_viewport_left: scr.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if scr.comp_viewport_right: scr.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
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
	main.composition_panels.deactivate()
	main.composition_pointers.deactivate()
	restore_screen_material()
	restore_ui_material()
	restore_kb_material()
	update_bezel()
	if main.is_streaming:
		main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var mode = main.settings_controller.get_stereo_mode()
		var runtime_sharpen_active = apply_compositor_sharpen(main.settings.sharpen_mode)
		for scr in main.screens:
			if _independent_browser(scr):
				refresh_browser_screen(scr)
				continue
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
		if _independent_browser(s):
			continue
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
