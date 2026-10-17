extends SceneTree

class FakeBrowser extends RefCounted:
	var owner: Node3D
	var active := false
	var closing := false
	var starts := 0
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
	owner.is_streaming = false
	owner.session_lifecycle.reconnect_scheduled()
	assert(not sources.can_open_browser())
	owner.session_lifecycle.show_server_selection()
	var secondary := VRScreen.new()
	owner.screens.append(secondary)
	assert(not sources.can_open_browser())
	owner.screens.erase(secondary)
	secondary.free()
	assert(sources.can_open_browser())
	sources.browser_supported = false
	assert(not sources.choose_source(ScreenContentTab.BROWSER))
	owner.primary_screen.free()
	owner.free()
	print("All screen_sources tests passed")
	quit()
