class_name ScreenImageOptions
extends RefCounted

const CROP_LABELS := ["Off", "21:9", "4:3", "16:9", "16:10", "32:9", "Auto"]
const ASPECTS := [0.0, 21.0 / 9.0, 4.0 / 3.0, 16.0 / 9.0, 16.0 / 10.0, 32.0 / 9.0]
const KEY_LABELS := ["Off", "Green", "Blue", "Magenta"]
const KEY_COLORS := [Color.BLACK, Color(0, 1, 0), Color(0, 0, 1), Color(1, 0, 1)]
const TOLERANCES := [0.08, 0.16, 0.26]
const TOLERANCE_LABELS := ["Low", "Medium", "High"]

static func crop_region(size: Vector2i, mode: int) -> Vector4:
	var result := Vector4(0, 0, 1, 1)
	if size.x <= 0 or size.y <= 0 or mode <= 0 or mode >= ASPECTS.size():
		return result
	var source := float(size.x) / size.y
	var target: float = ASPECTS[mode]
	if source > target:
		result.z = target / source
		result.x = (1.0 - result.z) * 0.5
	else:
		result.w = source / target
		result.y = (1.0 - result.w) * 0.5
	return result

static func content_uv(uv: Vector2, crop: Vector4) -> Vector2:
	return Vector2(crop.x, crop.y) + uv * Vector2(crop.z, crop.w)

const AUTO_MODE := 6
var _auto := AutoScreenCrop.new()
var _auto_source := []
var _sample_requested := false
var _next_sample_ms := 0
var _sample_viewport: SubViewport
var _sample_rect: ColorRect

var main: Node3D
var _applied := {}
var _material_options := {}
var _key_shader := preload("res://src/shaders/stereo_screen_key.gdshader")
var _picture_key_shader := preload("res://src/shaders/stereo_screen_picture_key.gdshader")
var _plain_shader := preload("res://src/shaders/stereo_screen.gdshader")
var _picture_shader := preload("res://src/shaders/stereo_screen_picture.gdshader")

func _init(owner: Node3D):
	main = owner

func crop_for(screen: VRScreen) -> Vector4:
	if screen != main.primary_screen: return Vector4(0, 0, 1, 1)
	if main.settings.screen_crop_mode == AUTO_MODE: return _auto.region
	return crop_region(source_size(screen), main.settings.screen_crop_mode)

func source_size(screen: VRScreen) -> Vector2i:
	var size := Vector2i.ZERO
	if main.screen_sources.is_browser_screen(screen):
		var browser = main.screen_sources.browser_for_screen(screen)
		if browser: size = browser.render_size
	elif main.is_streaming:
		if main.layout and main.layout.source == &"host_manifest" and screen.monitor:
			size = screen.monitor.frame_rect.size
		else:
			var media: Vector2i = main.primary_media_size()
			size = Vector2i(roundi(media.x * screen.uv_region.z), roundi(media.y * screen.uv_region.w))
	if screen == main.primary_screen:
		if main.settings.host.sbs_mode == 1: size.x /= 2
		elif main.settings.host.sbs_mode == 2: size /= 2
	return size

func key_color() -> Color:
	var mode: int = clampi(main.settings.screen_key_mode, 0, KEY_COLORS.size() - 1)
	var color: Color = KEY_COLORS[mode]
	color.a = TOLERANCES[main.settings.screen_key_tolerance] if mode > 0 else 0.0
	return color

func process() -> void:
	_process_auto()
	for screen in main.screens:
		var crop := crop_for(screen)
		var media: bool = main.is_streaming or main.screen_sources.is_browser_screen(screen)
		var key := key_color() if media else Color(0, 0, 0, 0)
		screen.display_crop = crop
		for layer in [screen.comp_layer, screen.comp_cylinder, screen.comp_cylinder_left, screen.comp_cylinder_right]:
			if layer and layer.has_method("set_alpha_blend") and layer.get_alpha_blend() != (key.a > 0.0):
				layer.set_alpha_blend(key.a > 0.0)
		var materials: Array = [screen.material_override, screen.comp_shader_mat, screen.comp_shader_mat_left, screen.comp_shader_mat_right, screen._original_mat]
		for material in materials:
			if material is ShaderMaterial:
				var path: String = material.shader.resource_path if material.shader else ""
				if path.contains("stereo_screen"):
					var picture := path.contains("picture")
					var shader: Shader = (_picture_key_shader if picture else _key_shader) if key.a > 0 else (_picture_shader if picture else _plain_shader)
					if material.shader != shader: material.shader = shader
				var signature: Array = [crop, key, material.shader]
				var material_id: int = material.get_instance_id()
				if _material_options.get(material_id) != signature:
					material.set_shader_parameter("screen_crop", crop)
					material.set_shader_parameter("screen_key", key)
					_material_options[material_id] = signature

		var id: int = screen.get_instance_id()
		var old: Vector4 = _applied.get(id, Vector4(0, 0, 1, 1))
		if old != crop:
			# Retain content's physical scale: remove the bars from the mesh too.
			screen.mesh_size *= Vector2(crop.z / old.z, crop.w / old.w)
			screen.apply_curvature()
			screen.update_corner_positions()
			screen.update_bezel_size()
			_applied[id] = crop
			if main.comp.in_use: main.comp.update_cylinder_params()

func redraw_native() -> void:
	if main.native_xr_renderer:
		main.native_xr_renderer._force_redraw = true

func cycle_crop() -> void:
	main.settings.screen_crop_mode = (main.settings.screen_crop_mode + 1) % CROP_LABELS.size()
	main.ui_controller.update_option_btn(main._ui_crop_btn, CROP_LABELS[main.settings.screen_crop_mode])
	process()
	redraw_native()
	main.state_manager.save_state()

func cycle_key() -> void:
	main.settings.screen_key_mode = (main.settings.screen_key_mode + 1) % KEY_LABELS.size()
	if main.settings.screen_key_mode > 0 and main.passthrough_supported:
		main.settings.passthrough_enabled = true
		main.settings_controller.apply_passthrough(true)
		main.ui_controller.update_option_btn(main._ui_pt_btn, "On")
	main.ui_controller.update_option_btn(main._ui_key_btn, KEY_LABELS[main.settings.screen_key_mode])
	process()
	redraw_native()
	main.state_manager.save_state()

func cycle_key_tolerance() -> void:
	main.settings.screen_key_tolerance = (main.settings.screen_key_tolerance + 1) % TOLERANCES.size()
	main.ui_controller.update_option_btn(main._ui_key_tolerance_btn, TOLERANCE_LABELS[main.settings.screen_key_tolerance])
	process()
	redraw_native()
	main.state_manager.save_state()

func _process_auto() -> void:
	var enabled: bool = main.settings.screen_crop_mode == AUTO_MODE and main.primary_media_active()
	var native = main.native_xr_renderer
	var renderer = native.renderer if native and native.active else null
	var signature: Array = [main.primary_screen, main.primary_capture_source(), source_size(main.primary_screen), main.settings.host.sbs_mode] if enabled else []
	if signature != _auto_source:
		_auto_source = signature
		_auto.reset()
		_sample_requested = false
		_next_sample_ms = Time.get_ticks_msec() + AutoScreenCrop.INTERVAL_MS
		# Discard results from the previous screen/source.
		if renderer and renderer.has_method("consume_crop_sample"): renderer.consume_crop_sample()
	if not enabled: return
	if not renderer or not renderer.has_method("request_crop_sample"):
		_process_fallback_sample()
		return
	# A renderer restart may discard an outstanding request.
	if _sample_requested and Time.get_ticks_msec() > _next_sample_ms + 1500:
		_sample_requested = false
	var pixels: PackedByteArray = renderer.consume_crop_sample()
	if not pixels.is_empty() and _sample_requested:
		_sample_requested = false
		if pixels.size() == AutoScreenCrop.SAMPLE_SIZE.x * AutoScreenCrop.SAMPLE_SIZE.y * 4:
			var image := Image.create_from_data(128, 72, false, Image.FORMAT_RGBA8, pixels)
			# GLES readback starts with the bottom row; crop UVs start at the top.
			image.flip_y()
			if _auto.observe(image, source_size(main.primary_screen)): redraw_native()
	if Time.get_ticks_msec() >= _next_sample_ms and not _sample_requested:
		renderer.request_crop_sample()
		_sample_requested = true
		_next_sample_ms = Time.get_ticks_msec() + AutoScreenCrop.INTERVAL_MS

# Legacy/Linux: draw only the tiny uncropped colour sample, not a full screen.
# The readback occurs after that draw, never get_image() on a video texture.
func _process_fallback_sample() -> void:
	if _sample_requested or Time.get_ticks_msec() < _next_sample_ms: return
	var material: ShaderMaterial
	if main.screen_sources.is_browser_screen(main.primary_screen):
		var browser = main.screen_sources.browser_for_screen(main.primary_screen)
		if not browser or not browser.texture: return
		material = ShaderMaterial.new()
		material.shader = preload("res://src/shaders/crop_sample.gdshader")
		material.set_shader_parameter("main_texture", browser.texture)
	else:
		var original = main.stream_backend.get_shader_material()
		if not original: return
		material = original.duplicate()
		material.set_shader_parameter("uv_region", main.primary_screen.uv_region)
	for entry in [["screen_crop", Vector4(0,0,1,1)], ["screen_key", Vector4.ZERO],
		["stereo_mode", main.settings.host.sbs_mode], ["eye_index", 0],
		["brightness", 0.0], ["contrast", 1.0], ["gamma", 1.0], ["sharpen", 0.0]]:
		material.set_shader_parameter(entry[0], entry[1])
	if not is_instance_valid(_sample_viewport):
		_sample_viewport = SubViewport.new()
		_sample_viewport.name = "AutoCropSample"
		_sample_viewport.disable_3d = true
		_sample_viewport.size = AutoScreenCrop.SAMPLE_SIZE
		_sample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		main.add_child(_sample_viewport)
		_sample_rect = ColorRect.new()
		_sample_rect.size = Vector2(AutoScreenCrop.SAMPLE_SIZE)
		_sample_viewport.add_child(_sample_rect)
	_sample_rect.material = material
	_sample_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_sample_requested = true
	_next_sample_ms = Time.get_ticks_msec() + AutoScreenCrop.INTERVAL_MS
	RenderingServer.frame_post_draw.connect(_consume_fallback_sample.bind(_auto_source.duplicate()), CONNECT_ONE_SHOT)

func _consume_fallback_sample(signature: Array) -> void:
	_sample_requested = false
	if signature != _auto_source or main.settings.screen_crop_mode != AUTO_MODE: return
	if not is_instance_valid(_sample_viewport): return
	var image := _sample_viewport.get_texture().get_image()
	if _auto.observe(image, source_size(main.primary_screen)): redraw_native()
