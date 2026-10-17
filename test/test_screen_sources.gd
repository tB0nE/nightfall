extends SceneTree

class FakeBrowser extends RefCounted:
	var owner: Node3D
	var active := false
	var closing := false
	var starts := 0
	var screen: VRScreen
	var browser_id := 0
	var releases := 0
	func cancel_pointer(): releases += 1
	func clear_gamepad(): pass
	func release_keys(): pass
	func _gamepad_bridge(): return null
	func start():
		if active: return
		active = true
		starts += 1
		owner.screen_sources.browser_opened()
	func stop():
		if not active: return
		active = false
		owner.screen_sources.browser_closed()

class FakeMain extends Node3D:
	var is_streaming := false
	var screens: Array[VRScreen] = []
	var primary_screen: VRScreen
	var session_lifecycle := SessionLifecycle.new()
	var browser_prototype: FakeBrowser
	var screen_sources: ScreenSources
	# Any accidental host input/session access would fail this test.
	var stream_backend = null

func _init():
	var owner := FakeMain.new()
	owner.primary_screen = VRScreen.new()
	owner.screens.assign([owner.primary_screen])
	owner.browser_prototype = FakeBrowser.new()
	owner.browser_prototype.owner = owner
	owner.screen_sources = ScreenSources.new(owner, "Android")
	var sources := owner.screen_sources
	assert(sources.can_open_browser())
	assert(sources.can_add_browser_screen(), "Welcome can open a separate browser without replacing Connect")
	owner.browser_prototype.closing = true
	assert(not sources.can_open_browser(), "Do not reopen while native layers are draining")
	owner.browser_prototype.closing = false
	assert(not sources.choose_source(ScreenContentTab.LOCAL_MEDIA))
	assert(sources.choose_source(ScreenContentTab.BROWSER))
	assert(owner.primary_screen.content_tabs.tabs.size() == 2)
	assert(owner.primary_screen.content_tabs.selected().kind == ScreenContentTab.BROWSER)
	sources.sync_browser_pages([{"id": 10, "title": "First"}, {"id": 11, "title": "Second"}], 11)
	assert(owner.primary_screen.content_tabs.tabs.size() == 3)
	assert(owner.primary_screen.content_tabs.selected_id == &"browser:page:11")
	assert(owner.primary_screen.content_tabs.selected().title == "Second")
	sources.sync_browser_pages([{"id": 10, "title": "First"}], 10)
	assert(owner.primary_screen.content_tabs.tabs.size() == 2)
	assert(sources.choose_source(ScreenContentTab.BROWSER))
	assert(owner.browser_prototype.starts == 1)
	assert(owner.primary_screen.content_tabs.tabs.size() == 2)
	assert(sources.choose_source(ScreenContentTab.STREAM))
	assert(not owner.browser_prototype.active)
	assert(owner.primary_screen.content_tabs.tabs.size() == 1)
	assert(owner.primary_screen.content_tabs.selected().kind == ScreenContentTab.STREAM)
	assert(owner.session_lifecycle.phase == SessionLifecycle.Phase.BOOT)
	assert(sources.choose_source(ScreenContentTab.STREAM))
	owner.session_lifecycle.begin_connect()
	assert(not sources.choose_source(ScreenContentTab.BROWSER))
	owner.session_lifecycle.stream_started()
	owner.is_streaming = true
	assert(not sources.can_open_browser())
	assert(sources.can_add_browser_screen(), "One stream can coexist with independent browser screens")
	owner.is_streaming = false
	owner.session_lifecycle.reconnect_scheduled()
	assert(not sources.can_open_browser())
	owner.session_lifecycle.show_server_selection()
	var secondary := VRScreen.new()
	owner.screens.append(secondary)
	assert(sources.can_open_browser(), "Other screens must not block opening a browser on welcome")
	owner.screens.erase(secondary)
	secondary.free()
	assert(sources.can_open_browser())
	owner.browser_prototype.active = true
	sources.register_browser(owner.primary_screen, owner.browser_prototype)
	assert(sources.can_add_browser_screen())
	var second_screen := VRScreen.new()
	var second_provider := FakeBrowser.new()
	second_provider.browser_id = 1
	second_provider.active = true
	sources.register_browser(second_screen, second_provider)
	owner.screens.append(second_screen)
	assert(sources.can_add_browser_screen(), "Adding a second browser must leave capacity for two more")
	assert(sources._free_browser_slot() == 2)
	var extra_screens: Array[VRScreen] = []
	for id in [2, 3]:
		var extra := VRScreen.new()
		var provider := FakeBrowser.new()
		provider.browser_id = id
		provider.active = true
		sources.register_browser(extra, provider)
		owner.screens.append(extra)
		extra_screens.append(extra)
	assert(not sources.can_add_browser_screen(), "Physical browser screens must stop at four")
	assert(sources._free_browser_slot() == -1)
	sources._browsers.erase(extra_screens[0].get_instance_id())
	owner.screens.erase(extra_screens[0])
	assert(sources.can_add_browser_screen() and sources._free_browser_slot() == 2, "Closing a screen frees only its own slot")
	assert(sources.browser_for_screen(second_screen) == second_provider)
	assert(ScreenSources.browser_grid_offset(1) != ScreenSources.browser_grid_offset(2))
	assert(ScreenSources.browser_grid_offset(2) != ScreenSources.browser_grid_offset(3))
	for extra in extra_screens:
		sources._browsers.erase(extra.get_instance_id())
		owner.screens.erase(extra)
		extra.free()
	sources.focus_browser(owner.browser_prototype)
	sources.focus_browser(second_provider)
	assert(owner.browser_prototype.releases == 1, "Focus transfer releases old browser input")
	assert(sources.focused_browser() == second_provider)
	sources.sync_browser_pages([{"id": 10, "title": "Independent page"}], 10, second_screen)
	assert(second_screen.content_tabs.selected().title == "Independent page")
	assert(owner.primary_screen.content_tabs.selected().title != "Independent page", "Independent pages must not replace primary tabs")
	assert(sources.browser_for_screen(second_screen) == second_provider)
	assert(sources.browser_for_screen(owner.primary_screen) == owner.browser_prototype)
	owner.screens.erase(second_screen)
	second_screen.free()
	owner.browser_prototype.active = false
	sources.browser_supported = false
	assert(not sources.choose_source(ScreenContentTab.BROWSER))
	owner.primary_screen.free()
	owner.free()
	print("All screen_sources tests passed")
	quit()
