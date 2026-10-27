extends SceneTree

const Controls = preload("res://src/composition_screen_controls.gd")

class NativeFixture extends Node3D:
	const SHARPEN_RUNTIME_NORMAL = 5
	const SHARPEN_RUNTIME_QUALITY = 6
	var primary_screen: VRScreen
	var screens: Array = []
	var screen_sources = Sources.new()
	var settings = {"codec_preference": 0, "sharpen_mode": 0}
	var settings_controller = null
	var auto_detect_enabled = false

class Sources extends RefCounted:
	var secondary: VRScreen
	var closing = false
	var active = false
	var texture = null
	func is_browser_screen(screen): return screen == secondary
	func browser_for_screen(screen): return self if screen == secondary else null

class Fixture extends RefCounted:
	var is_streaming := false
	var primary_screen: VRScreen
	var screen_sources = Sources.new()
	var screens: Array = []
	var depth_estimator = null
	var settings = {"brightness_pct": 0, "contrast_pct": 100, "gamma_pct": 100}
	func _log(_message): pass

func _initialize():
	var fixture = Fixture.new()
	var primary = VRScreen.new()
	var secondary = VRScreen.new()
	fixture.primary_screen = primary
	fixture.screen_sources.secondary = secondary
	fixture.screens = [primary, secondary]
	var manager = CompositionLayerManager.new(fixture)
	var shader = load("res://src/shaders/yuv_display.gdshader")
	primary.comp_shader_mat = ShaderMaterial.new()
	primary.comp_shader_mat.shader = shader
	secondary.comp_shader_mat = ShaderMaterial.new()
	secondary.comp_shader_mat.shader = shader
	var image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var browser_texture = ImageTexture.create_from_image(image)
	var stream_texture = ImageTexture.create_from_image(image)
	secondary.comp_shader_mat.set_shader_parameter("stereo_mode", 5)
	secondary.bind_independent_browser_texture(browser_texture)
	assert(secondary.comp_shader_mat.get_shader_parameter("main_texture") == browser_texture)
	assert(secondary.comp_shader_mat.get_shader_parameter("stereo_mode") == 0)
	assert(secondary.comp_shader_mat.get_shader_parameter("uv_region") == Vector4(0, 0, 1, 1))
	assert(not manager._independent_browser(primary))
	assert(manager._independent_browser(secondary))
	# Closing still owns the screen, even with active=false. Neither legacy
	# video refresh nor controls may resurrect it during deferred removal.
	fixture.screen_sources.closing = true
	secondary.comp_cylinder = Node3D.new()
	secondary.comp_cylinder.visible = true
	secondary.comp_viewport = SubViewport.new()
	manager.refresh_browser_screen(secondary)
	assert(not secondary.comp_cylinder.visible)
	assert(secondary.comp_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED)
	var controls = Controls.new()
	controls._scene_root = native_controls_fixture(fixture.screen_sources)
	controls.update([secondary], true, true, true, secondary)
	controls._scene_root.free()
	secondary.comp_cylinder.free()
	secondary.comp_cylinder = null
	secondary.comp_viewport.free()
	secondary.comp_viewport = null
	# Global disconnect/reset and stream YUV binding must leave this owner intact.
	manager.clear_yuv_textures()
	manager.bind_comp_yuv_textures(stream_texture, stream_texture, stream_texture, 3, 0, 0)
	assert(secondary.comp_shader_mat.get_shader_parameter("main_texture") == browser_texture)
	assert(secondary.comp_shader_mat.get_shader_parameter("yuv_mode") == 0)
	var native_fixture = NativeFixture.new()
	primary.curvature = 0
	native_fixture.primary_screen = primary
	native_fixture.screens = [primary, secondary]
	native_fixture.screen_sources.secondary = secondary
	var native_manager = NativeXrRendererManager.new(native_fixture)
	native_manager.provider_registered = true
	assert(native_manager.can_render_current_config())
	native_fixture.screen_sources.secondary = null
	assert(not native_manager.can_render_current_config())
	native_fixture.free()
	primary.free()
	secondary.free()
	print("Browser presentation isolation tests passed")
	quit()

class ControlsFixture extends Node:
	var screen_sources

func native_controls_fixture(sources) -> Node:
	var fixture = ControlsFixture.new()
	fixture.screen_sources = sources
	return fixture
