class_name ScreenImageOptions
extends RefCounted

const CROP_LABELS := ["Off", "21:9", "4:3", "16:9", "16:10", "32:9"]
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
	return crop_region(size, main.settings.screen_crop_mode)

func key_color() -> Color:
	var mode: int = clampi(main.settings.screen_key_mode, 0, KEY_COLORS.size() - 1)
	var color: Color = KEY_COLORS[mode]
	color.a = TOLERANCES[main.settings.screen_key_tolerance] if mode > 0 else 0.0
	return color

func process() -> void:
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
