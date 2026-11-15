extends SceneTree

class Provider extends RefCounted:
	var active := false
	var closing := false
	var generation := 0
class Sources extends RefCounted:
	var providers := {}
	func browser_for_screen(screen): return providers.get(screen)
	func monitor_tab(screen):
		for tab in screen.content_tabs.tabs:
			if tab.kind == ScreenContentTab.STREAM: return tab
		return null
class Backend extends RefCounted:
	var material: ShaderMaterial
	func get_shader_material(): return material
	func is_display_ready(): return true
class Owner extends Node3D:
	var primary_screen: VRScreen
	var screens: Array[VRScreen] = []
	var screen_sources := Sources.new()
	var stream_backend := Backend.new()
	var stream_viewport := SubViewport.new()
	var depth_estimator = null
	var layout := ScreenLayout.new()
	var is_streaming := true
	var settings := {"brightness_pct":0,"contrast_pct":100,"gamma_pct":100}
	func primary_media_size(): return layout.frame_size
	func _log(_message): pass
class Renderer extends RefCounted:
	var secondary: Array = []
	func set_secondary_screens(value): secondary = value
class Native extends NativeXrRendererManager:
	func _layer_geometry(screen: VRScreen) -> Dictionary: return {"id":screen.monitor_id}

func screen(owner: Owner, id: StringName, y: int) -> VRScreen:
	var result := VRScreen.new()
	result.main = owner
	result.monitor_id = id
	result.comp_shader_mat = ShaderMaterial.new()
	result.comp_shader_mat.shader = load("res://src/shaders/yuv_display.gdshader")
	var monitor := ScreenLayout.MonitorSpec.new()
	monitor.id = id
	monitor.frame_rect = Rect2i(0,y,2560,1440)
	result.apply_monitor(monitor,owner.layout.frame_size)
	owner.screens.append(result)
	return result

func _init():
	var owner := Owner.new()
	owner.layout.frame_size = Vector2i(2560,4320)
	var primary := screen(owner,&"m0",0)
	var secondary := screen(owner,&"v1",1440)
	owner.primary_screen = primary
	var provider := Provider.new()
	owner.screen_sources.providers[secondary] = provider
	var native := Native.new(owner)
	native.renderer = Renderer.new()
	assert(not native._browser_output(secondary), "An idle provider must not exclude a virtual monitor")
	native._sync_secondary_screens()
	assert(native.renderer.secondary.size() == 1)
	assert(native.renderer.secondary[0].pixels == Vector2i(2560,1440))
	assert(is_equal_approx(native.renderer.secondary[0].crop[1], 1.0/3.0+0.5/4320.0))
	provider.active = true
	native._sync_secondary_screens()
	assert(native.renderer.secondary.is_empty(), "An active browser must retain its independent layer")
	provider.active = false
	provider.closing = true
	assert(native._browser_output(secondary), "Closing browser surfaces must stay isolated")
	provider.closing = false
	native._sync_secondary_screens()
	assert(native.renderer.secondary.size() == 1)
	secondary.comp_cylinder = Node3D.new()
	secondary.comp_viewport = SubViewport.new()
	secondary.comp_cylinder.visible = true
	native._disable_legacy_video()
	assert(not secondary.comp_cylinder.visible and secondary.comp_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED)

	var texture := ImageTexture.create_from_image(Image.create(2,2,false,Image.FORMAT_RGBA8))
	owner.stream_backend.material = ShaderMaterial.new()
	owner.stream_backend.material.shader = load("res://src/shaders/yuv_display.gdshader")
	for key in ["tex_y","tex_u","tex_v"]: owner.stream_backend.material.set_shader_parameter(key,texture)
	var comp := CompositionLayerManager.new(owner)
	comp.in_use = true
	comp.bind_yuv_textures()
	assert(secondary.comp_shader_mat.get_shader_parameter("yuv_mode") == 3)
	var browser_texture := ImageTexture.create_from_image(Image.create(3,3,false,Image.FORMAT_RGBA8))
	secondary.bind_independent_browser_texture(browser_texture)
	provider.generation += 1
	# No new decoder frame, texture ID, or intermediate bind occurs here.
	comp.bind_yuv_textures()
	assert(secondary.comp_shader_mat.get_shader_parameter("yuv_mode") == 3)
	assert(secondary.comp_shader_mat.get_shader_parameter("tex_y") == texture)
	assert(is_equal_approx(secondary.comp_shader_mat.get_shader_parameter("uv_region").y,1.0/3.0))
	var fresh := screen(owner,&"v2",2880)
	comp.bind_yuv_textures()
	assert(fresh.comp_shader_mat.get_shader_parameter("tex_y") == texture, "New secondary materials need a binding even on a static desktop")
	provider.active = true
	secondary.bind_independent_browser_texture(browser_texture)
	comp.bind_yuv_textures()
	assert(secondary.comp_shader_mat.get_shader_parameter("yuv_mode") == 0, "Stream refresh must not overwrite an active browser")
	secondary.comp_cylinder.free()
	secondary.comp_viewport.free()
	for item in owner.screens: item.free()
	owner.stream_viewport.free()
	owner.free()
	print("All secondary monitor ownership, crop and static-frame binding tests passed")
	quit()
