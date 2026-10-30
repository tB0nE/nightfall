extends SceneTree

class FakeBrowser extends RefCounted:
	var active := false
	var closing := false
	var browser_id := 0
	var screen: VRScreen

class FakeComp extends RefCounted:
	var available := false
	var in_use := false
	func get_shader_mats(_screen): return []

class FakePresentation extends RefCounted:
	func can_render_native(): return true

class FakeUi extends RefCounted:
	func update_monitor_tab(): pass

class Fixture extends Node3D:
	var video_presentation := FakePresentation.new()
	var settings := AppSettings.new()
	var stream_viewport := SubViewport.new()
	var stream_target := ColorRect.new()
	var primary_screen: VRScreen
	var screens: Array[VRScreen] = []
	var browser_prototype := FakeBrowser.new()
	var screen_sources: ScreenSources
	var session_lifecycle := SessionLifecycle.new()
	var is_streaming := true
	var layout := ScreenLayout.single(Vector2i(1920, 1080))
	var comp := FakeComp.new()
	var comp_layer = null
	var screen_manager: ScreenManager
	var ui_controller := FakeUi.new()
	func _log(_message): pass
	func get_blur_scale(_screen): return 1.0
	func add_screen(_id, _x, _primary):
		assert(false, "A full browser workspace must reuse its primary surface for the stream")
	func remove_screen(_id):
		assert(false, "The host manifest must not remove browser screens")

func _init(): _run.call_deferred()

func _run():
	var owner := Fixture.new()
	root.add_child(owner)
	owner.add_child(owner.stream_viewport)
	owner.add_child(owner.stream_target)
	owner.primary_screen = load("res://src/vr_screen.tscn").instantiate()
	owner.add_child(owner.primary_screen)
	owner.primary_screen.setup(owner, &"welcome")
	owner.primary_screen.create_corner_handles()
	owner.screens.append(owner.primary_screen)
	owner.screen_sources = ScreenSources.new(owner, "Android")
	owner.screen_manager = ScreenManager.new(owner)
	for id in [1, 2, 3]:
		var screen = load("res://src/vr_screen.tscn").instantiate()
		owner.add_child(screen)
		screen.monitor_id = StringName("browser-screen:%d" % id)
		var provider := FakeBrowser.new()
		provider.active = true
		provider.browser_id = id
		owner.screen_sources.register_browser(screen, provider)
		owner.screens.append(screen)
	var before := owner.screens.duplicate()
	var browser_size := owner.screens[1].mesh_size
	SettingsController.new(owner).apply_screen_layout(ScreenLayout.single(Vector2i(2560, 1600)))
	assert(owner.screens == before and owner.screens.size() == 4)
	assert(owner.primary_screen.monitor_id == owner.layout.enabled_monitors()[0].id)
	assert(owner.screens[1].mesh_size == browser_size, "Stream resize must not resize independent browsers")
	owner.layout.source = &"host_manifest"
	var aspect_before := owner.primary_screen.mesh_size.x / owner.primary_screen.mesh_size.y
	owner.screen_manager.resize_screen_to_aspect(4480, 1440)
	assert(is_equal_approx(owner.primary_screen.mesh_size.x / owner.primary_screen.mesh_size.y, aspect_before),
		"A correction reconnect must preserve the monitor's aspect while the encoded size changes")
	owner.layout.source = &"client_split"
	var welcome_geometry := owner.primary_screen.mesh_size
	var stream := StreamManager.new(owner)
	stream.resize_stream_viewport(4480, 1440, false)
	assert(stream.get_current_stream_size() == Vector2i(4480, 1440))
	assert(owner.primary_screen.mesh_size == welcome_geometry,
		"Preparing cached decoder dimensions must not reshape the welcome screen")
	stream.resize_stream_viewport(4480, 1440)
	assert(owner.primary_screen.mesh_size != welcome_geometry,
		"Confirmed decoded dimensions must still update non-manifest screen geometry")
	for screen in owner.screens.slice(1):
		assert(owner.screen_sources.is_browser_screen(screen))
	# The dropdown is ordinary viewport UI, not a native popup/layer.
	var welcome := Control.new()
	owner.add_child(welcome)
	WelcomeScreen.new(owner).build_browser_picker(welcome)
	var picker = welcome.get_node("BrowserPicker")
	var options = picker.get_node("BrowserOptions")
	assert(not options.visible and options.get_child_count() == 2)
	assert(options.get_child(0).text == "Open browser here")
	assert(options.get_child(1).text == "New browser screen")
	var toggle = picker.get_node("BrowserToggle")
	assert(picker.position == Vector2(24, 24) and toggle.get_index() == 0, "Top-left, with the options below")
	toggle.pressed.emit()
	assert(options.visible and options.get_child(0).disabled and options.get_child(1).disabled)
	assert(picker.position == Vector2(24, 24) and toggle.get_index() == 0, "Opening the options must not move the toggle")
	options.hide()
	assert(picker.position == Vector2(24, 24))
	owner.free()
	print("All stream_browser_workspace tests passed")
	quit()
