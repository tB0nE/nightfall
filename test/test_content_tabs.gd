extends SceneTree

func _init():
	_test_mixed_sources()
	_test_restore()
	_test_lifecycle()
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
