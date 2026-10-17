extends SceneTree

class Browser extends RefCounted:
	var active := true
	var closing := false
	var browser_id := 0
	var screen: VRScreen
	var uploader: RefCounted
	var texture: Texture2D
	var binds := 0
	func bind_texture(): binds += 1
	func _gamepad_bridge(): return null
	func cancel_pointer(): pass
	func clear_gamepad(): pass
	func release_keys(): pass

class Depth extends RefCounted:
	var enabled := true
	func set_enabled(value): enabled = value

class Presentation extends RefCounted:
	var stopped := false
	func deactivate_native(_restore): stopped = true

class Interaction extends RefCounted:
	func cancel_transient_interactions(_reason): pass

class Comp extends RefCounted:
	var stereo_owner: VRScreen
	func ensure_stereo_layers(screen): stereo_owner = screen
	func invalidate_yuv_cache(): pass

class Settings extends RefCounted:
	var applies := 0
	func apply_stereo(): applies += 1

class Welcome extends RefCounted:
	var shown := 0
	func show_welcome_screen(_name): shown += 1

class Sources extends ScreenSources:
	# Headless tests have no XR draw loop. Keep the asynchronous ownership
	# boundary, without pretending to test the compositor's GPU fence here.
	func _wait_for_primary_drain(): await main.get_tree().process_frame

class Fixture extends Node3D:
	var primary_screen: VRScreen
	var screens: Array[VRScreen] = []
	var browser_prototype: RefCounted
	var screen_tab_strip: ScreenTabStrip
	var is_streaming := false
	var session_lifecycle := SessionLifecycle.new()
	var depth_estimator := Depth.new()
	var video_presentation := Presentation.new()
	var xr_interaction := Interaction.new()
	var comp := Comp.new()
	var settings_controller := Settings.new()
	var screen_sources: ScreenSources
	var welcome_screen := Welcome.new()
	var screen_mesh: MeshInstance3D
	var comp_shader_mat = null
	var comp_shader_mat_left = null
	var comp_shader_mat_right = null
	func set_primary_screen(screen): primary_screen = screen
	func get_welcome_content_texture(): return VRScreen.placeholder_texture()
	func add_screen(id, _position, _stereo):
		var screen := VRScreen.new()
		screen.monitor_id = id
		screens.append(screen)
		return screen

func _init(): _run.call_deferred()

func _run():
	var owner := Fixture.new()
	root.add_child(owner)
	for id in [0, 1]:
		var screen := VRScreen.new()
		owner.screens.append(screen)
	owner.primary_screen = owner.screens[0]
	owner.screen_mesh = owner.primary_screen
	owner.browser_prototype = Browser.new()
	owner.browser_prototype.texture = VRScreen.placeholder_texture()
	owner.screen_tab_strip = ScreenTabStrip.new(owner, owner.primary_screen, owner.browser_prototype)
	owner.screen_sources = Sources.new(owner, "Android")
	var sources := owner.screen_sources
	sources.register_browser(owner.primary_screen, owner.browser_prototype)
	var second := Browser.new()
	second.browser_id = 1
	second.texture = VRScreen.placeholder_texture()
	sources.register_browser(owner.screens[1], second)
	assert(sources.stream_screen() == null and sources.can_add_stream_screen())
	assert(sources.can_make_primary(owner.screens[1]))
	var original := owner.browser_prototype
	assert(await sources.make_primary(owner.screens[1]))
	assert(owner.primary_screen == owner.screens[1] and owner.browser_prototype == second)
	assert(owner.video_presentation.stopped and not owner.depth_estimator.enabled)
	assert(owner.comp.stereo_owner == owner.screens[1] and second.binds == 1)
	assert(sources.browser_for_screen(owner.screens[0]) == original)
	assert(sources.menu_for_screen(owner.screens[0]).browser == original)
	assert(owner.screen_tab_strip.browser == second)
	assert(sources.focused_browser() == second and not sources.switching_primary)
	assert(not sources.can_make_primary(owner.primary_screen))
	owner.is_streaming = true
	assert(not sources.can_add_stream_screen() and not sources.can_make_primary(owner.screens[0]))
	owner.is_streaming = false
	owner.session_lifecycle.begin_connect()
	assert(not sources.can_add_stream_screen() and not sources.can_make_primary(owner.screens[0]))
	owner.session_lifecycle.show_server_selection()
	# An inactive browser is the welcome surface: it suppresses New stream.
	original.active = false
	assert(sources.stream_screen() == owner.screens[0] and not sources.can_add_stream_screen())
	assert(await sources.make_primary(owner.screens[0]))
	assert(owner.browser_prototype == original and original.binds == 1)
	assert(sources.browser_for_screen(owner.screens[1]) == second and second.active)
	assert(owner.screen_tab_strip.browser == original)
	# New stream creates exactly one welcome surface, preserves browser
	# sessions and becomes primary. Repeated invocation cannot duplicate it.
	original.active = true
	assert(sources.can_add_stream_screen())
	await sources.add_stream_screen()
	var welcome := owner.primary_screen
	assert(owner.screens.size() == 3 and sources.stream_screen() == welcome)
	assert(owner.welcome_screen.shown == 1 and not sources.can_add_stream_screen())
	assert(original.active and second.active)
	assert(sources.allocate_primary_browser_slot(owner.browser_prototype))
	assert(owner.browser_prototype.browser_id == 2, "Do not reuse either live browser's Android slot")
	await sources.add_stream_screen()
	assert(owner.screens.size() == 3)
	assert(await sources.make_primary(owner.screens[1]))
	owner.session_lifecycle.begin_connect()
	assert(await sources.make_primary(welcome, true), "Connect restores welcome ownership even after its timeout has armed")
	assert(owner.primary_screen == welcome and second.active)
	for screen in owner.screens: screen.free()
	owner.free()
	print("All screen_primary_selection tests passed")
	quit()
