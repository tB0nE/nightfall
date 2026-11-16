extends SceneTree

func _init():
	_test_mixed_sources()
	_test_restore()
	_test_lifecycle()
	_test_tab_display_settings()
	_test_browser_metadata_preserves_stream_selection()
	print("All content_tabs tests passed")
	quit()

func _browser() -> ScreenContentTab:
	var tab := ScreenContentTab.new()
	tab.id = &"browser:1"
	tab.kind = ScreenContentTab.BROWSER
	tab.locator = {"url": "https://example.com"}
	return tab

func _test_mixed_sources():
	var model := ScreenContentTabs.new()
	assert(model.selected() == null)
	var stream := ScreenContentTab.for_monitor(&"m0")
	var browser := _browser()
	var media := ScreenContentTab.new()
	media.id = &"media:1"
	media.kind = ScreenContentTab.LOCAL_MEDIA
	media.locator = {"source": "file", "item": "content://media/video/1"}
	assert(model.add(stream))
	assert(model.add(browser))
	assert(model.add(media, false))
	assert(model.selected() == browser)
	assert(not model.add(browser))
	assert(not model.select(&"missing"))
	assert(model.remove(browser.id))
	assert(model.selected() == media)
	assert(model.remove(media.id))
	assert(model.selected() == stream)
	assert(model.remove(stream.id))
	assert(model.selected() == null)
	browser.locator.url = "javascript:alert(1)"
	assert(not model.add(browser))

func _test_restore():
	var model := ScreenContentTabs.new()
	var browser := _browser()
	browser.keep_audio_playing = true
	browser.locator["password"] = "must-not-persist"
	assert(model.add(browser))
	var saved := model.to_dict()
	assert(not saved.tabs[0].locator.has("password"))
	var copy := ScreenContentTabs.new()
	assert(copy.restore(saved))
	assert(copy.selected().keep_audio_playing)
	assert(copy.selected().locator.url == "https://example.com")
	saved.tabs.append(saved.tabs[0])
	assert(not copy.restore(saved))
	assert(copy.tabs.size() == 1)
	assert(not copy.restore({"schema_version": 99, "tabs": []}))
	assert(copy.restore({"schema_version": 1, "tabs": [], "selected_id": ""}))
	assert(copy.selected() == null)

func _test_lifecycle():
	var tab := _browser()
	assert(ContentProvider.activity_for(tab, false) == ContentProvider.Activity.SUSPENDED)
	tab.keep_audio_playing = true
	assert(ContentProvider.activity_for(tab, false) == ContentProvider.Activity.BACKGROUND_AUDIO)
	tab.muted = true
	assert(ContentProvider.activity_for(tab, false) == ContentProvider.Activity.SUSPENDED)
	var provider := ContentProvider.new()
	provider.set_activity(ContentProvider.Activity.VISIBLE)
	assert(provider.can_infer_depth())
	provider.set_activity(ContentProvider.Activity.BACKGROUND_AUDIO)
	assert(not provider.can_infer_depth())
	assert(provider.accepts_frame(0))
	provider.close()
	assert(not provider.accepts_frame(0))
	provider.set_activity(ContentProvider.Activity.VISIBLE)
	assert(not provider.can_infer_depth())

func _test_tab_display_settings():
	var monitor := ScreenContentTab.for_monitor(&"m0")
	var browser := _browser()
	assert(monitor.effective_resolution(Vector2i(1920,1080)) == Vector2i(1920,1080))
	assert(monitor.effective_crop(3) == 3)
	monitor.resolution = Vector2i(2560,1440)
	monitor.crop_mode = 1
	browser.resolution = Vector2i(1920,1080)
	browser.crop_mode = 2
	var model := ScreenContentTabs.new()
	model.add(monitor)
	model.add(browser)
	model.select(monitor.id)
	assert(model.selected().resolution == Vector2i(2560,1440) and model.selected().crop_mode == 1)
	model.select(browser.id)
	assert(model.selected().resolution == Vector2i(1920,1080) and model.selected().crop_mode == 2)
	var restored := ScreenContentTabs.new()
	assert(restored.restore(JSON.parse_string(JSON.stringify(model.to_dict()))))
	assert(restored.selected().resolution == browser.resolution and restored.selected().crop_mode == 2)
	var corrupt := model.to_dict()
	corrupt.tabs[0].resolution = [1920, 0]
	assert(not restored.restore(corrupt))
	assert(restored.selected().id == browser.id, "A malformed layout must not partially replace current tabs")
	monitor.keep_audio_playing = true
	assert(ContentProvider.activity_for(monitor, false) == ContentProvider.Activity.SUSPENDED)

func _test_browser_metadata_preserves_stream_selection():
	var model := ScreenContentTabs.new()
	var monitor := ScreenContentTab.for_monitor(&"m0")
	model.add(monitor)
	model.sync_browser_pages([{"id":1,"title":"First"},{"id":2,"title":"Second"}], 1)
	assert(model.selected() == monitor, "Browser metadata must not select over a monitor")
	var first := model.find_tab(&"browser:page:1")
	first.resolution = Vector2i(2560,1440)
	first.crop_mode = 4
	model.select(first.id)
	model.sync_browser_pages([{"id":1,"title":"Renamed"}],1)
	assert(model.selected() == first and first.title == "Renamed")
	assert(first.resolution == Vector2i(2560,1440) and first.crop_mode == 4)
	assert(model.find_tab(&"browser:page:2") == null and model.find_tab(monitor.id) == monitor)
	model.sync_browser_pages([],0)
	assert(model.selected() == first, "An opening/error snapshot is not a browser close")
