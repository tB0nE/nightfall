extends SceneTree

class FakeBrowser extends RefCounted:
	var pages: Array = [{"id": 1, "title": "First"}, {"id": 2, "title": "Second"}]
	var selected_page := 1
	var active := true
	var closing := false
	var navigation: Dictionary = {"address": "https://example.com", "back": true, "forward": false}
	var actions: Array = []
	func tab_action(action: String, id: int = 0) -> void: actions.append([action, id])

class FakeComp extends RefCounted:
	var in_use := true

class FakeSources extends RefCounted:
	var offer_stream := true
	var open_browser_allowed := true
	var add_browser_allowed := true
	func can_open_browser(): return open_browser_allowed
	func can_add_browser_screen(): return add_browser_allowed
	func can_offer_stream_screen(): return offer_stream
	func can_add_stream_screen(): return offer_stream
	func can_make_primary(_screen): return false

class FakeMain extends Node3D:
	var browser_prototype := FakeBrowser.new()
	var primary_screen: VRScreen
	var is_streaming := false
	var comp := FakeComp.new()
	var screens: Array = []
	var screen_sources: RefCounted
	func _log(_message: String) -> void: pass

func _init():
	var pages := []
	for i in range(1, 9): pages.append({"id": i, "title": "Tab %d" % i})
	var visible := ScreenTabStrip.visible_pages(pages, 8)
	assert(visible.size() == 4)
	assert(visible[3].id == 8, "Selected overflow tab must stay visible")
	assert(pages[3].id == 4, "View selection must not reorder the source list")
	assert(ScreenTabStrip.visible_pages(pages.slice(0, 2), 1).size() == 2)
	assert(ScreenTabStrip.visible_pages([], 0).is_empty())
	var rects := ScreenTabStrip.page_rects(visible, 8)
	assert(is_equal_approx(rects[3].size.x, rects[0].size.x))
	assert(is_equal_approx(rects[0].position.x, -0.48))
	for i in range(rects.size() - 1):
		assert(rects[i].end.x < rects[i + 1].position.x)
	assert(is_equal_approx(rects[-1].end.x, 0.32), "Tabs should fill the row up to Add Browser")
	var overflow_rects := ScreenTabStrip.page_rects(visible, 8, true)
	assert(overflow_rects[-1].end.x < 0.26, "Overflow list button needs its own slot")
	# Hitboxes use explicit metadata and remain independent of painted expansion.
	var screen := VRScreen.new()
	var target := Area3D.new()
	target.set_meta(&"nf_role", &"screen_tab")
	target.set_meta(&"nf_action", &"page:2")
	screen.add_child(target)
	var resolved := PointerTarget.resolve(target)
	assert(resolved.screen == screen and resolved.role == &"screen_tab" and resolved.action == &"page:2")
	screen.free()
	var owner := FakeMain.new()
	owner.screen_sources = FakeSources.new()
	owner.primary_screen = VRScreen.new()
	owner.primary_screen._comp_cyl_radius = 3.0
	var viewport := SubViewport.new()
	var strip := ScreenTabStrip.new(owner)
	strip.attach(owner.primary_screen, viewport)
	var margin := owner.primary_screen.mesh_size.x * ScreenTabStrip.TOP_MARGIN_RATIO
	var surface := owner.primary_screen.mesh_size + Vector2(0.12, margin * 2.0)
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items.size() == 11)
	assert(strip._background.visible)
	assert(is_equal_approx(strip._background.size.x, owner.primary_screen.mesh_size.x * 1536.0 / surface.x),
		"Unified panel must match screen width exactly")
	assert(not strip._dropdown_background.visible)
	for item in strip._items:
		if String(item.action).begins_with("nav:"):
			assert(item.rect.end.y < 0.0, "Browser controls must stay above web content")
			assert(item.rect.position.y > strip._items[0].rect.end.y, "Browser controls need a separate row")
	assert(strip._items[-1].action == &"hover")
	assert(not strip._items[-1].panel.visible, "Hover backdrop must be invisible")
	assert(strip._items[0].label.text == "First", "Selected tab should use its title, not WEB")
	assert(strip._items[1].label.text == "Second", "Full-width tabs should show their titles")
	var retained_area: Area3D = strip._items[0].area
	owner.browser_prototype.pages[0].title = "Changed title"
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items[0].area == retained_area, "Title updates must retain the live physics target")
	var hit_geometry: PackedVector3Array = strip._items[1].area.get_child(0).shape.get_faces()
	strip.set_hover(&"page:2")
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items[1].area.get_child(0).shape.get_faces() == hit_geometry, "Artwork expansion must not grow hitboxes")
	assert(strip._items[1].panel.visible)
	for item in strip._items:
		if item.action == &"close:2":
			assert(item.panel.visible and item.area.collision_layer == 2, "Hovered tab must expose its close target")
		elif item.action == &"close:1":
			assert(not item.panel.visible and item.area.collision_layer == 0, "Idle close target must not intercept input")
	assert(strip._items[1].panel.size.is_equal_approx(strip._items[1].rect.size * owner.primary_screen.mesh_size.x * 1536.0 / surface.x),
		"Hover must not expand across neighbouring tab titles")
	strip.invoke(&"close:2")
	assert(owner.browser_prototype.actions[-1] == ["close", 2], "Close must target the hovered tab, not the selected one")
	strip.invoke(&"browser")
	assert(strip.popup == "sources", "Add Browser should offer tab versus screen")
	strip.update(owner.primary_screen, surface, margin, true)
	var source_actions := []
	for item in strip._items: source_actions.append(String(item.action))
	assert(source_actions.has("stream:new") and source_actions.has("screen:primary"))
	assert(strip._items[-1].rect.end.y > 0.15, "Hover backdrop must cover all four dropdown rows")
	owner.screen_sources.offer_stream = false
	strip._signature = ""
	strip.update(owner.primary_screen, surface, margin, true)
	source_actions.clear()
	for item in strip._items: source_actions.append(String(item.action))
	assert(not source_actions.has("stream:new") and source_actions.has("screen:primary"))
	strip.invoke(&"tab:new")
	assert(owner.browser_prototype.actions[-1] == ["new", 0], "Add tab must create on the current browser")
	strip.update(owner.primary_screen, surface, margin, false)
	assert(not strip._items[1].panel.visible)
	assert(not strip._background.visible)
	strip.popup = "settings"
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._dropdown_background.visible)
	var actions := []
	for item in strip._items: actions.append(String(item.action))
	for action in ["nav:privacy", "nav:blocking", "nav:bookmarks", "nav:home"]:
		assert(actions.has(action), "Hamburger menu is missing " + action)
	assert(not actions.has("nav:go"), "Browser toolbar submits addresses with Enter")
	var home_index := actions.find("nav:home")
	assert(home_index < actions.find("nav:privacy") and home_index < actions.find("nav:bookmarks"), "Home must be first in the menu")
	owner.browser_prototype.active = false
	strip.update(owner.primary_screen, surface, margin, true)
	assert(not strip._background.visible and not strip._dropdown_background.visible)
	assert(strip.popup == "")
	for item in strip._items:
		assert(not item.panel.visible and item.area.collision_layer == 0, "Welcome must have no browser menu or invisible targets")
	owner.browser_prototype.active = true
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._background.visible, "Opening Browser must restore its menu")
	assert(strip._items[0].area.collision_layer == 2)
	# A stream restart can build the bar while adding a browser is temporarily
	# unavailable. Becoming ready must refresh it even when screen count,
	# browser pages and is_streaming have not changed.
	owner.browser_prototype.active = false
	owner.is_streaming = true
	owner.screen_sources.open_browser_allowed = false
	owner.screen_sources.add_browser_allowed = false
	strip.popup = ""
	strip.update(owner.primary_screen, surface, margin, true)
	var browser_button: Dictionary
	for item in strip._items:
		if item.action == &"browser": browser_button = item
	assert(not browser_button.enabled)
	var browser_target: Area3D = browser_button.area
	owner.screen_sources.add_browser_allowed = true
	strip.update(owner.primary_screen, surface, margin, true)
	for item in strip._items:
		if item.action == &"browser": browser_button = item
	assert(browser_button.enabled, "Browser button must recover after the restart finishes")
	assert(browser_button.area == browser_target, "Availability changes must preserve the hit target")
	strip.invoke(&"browser")
	assert(strip.popup == "sources", "Recovered browser button must open its dropdown")
	var previous_screen := owner.primary_screen
	var previous_target: Area3D = strip._items[0].area
	owner.primary_screen = VRScreen.new()
	owner.primary_screen._comp_cyl_radius = 3.0
	var replacement_viewport := SubViewport.new()
	strip.attach(owner.primary_screen, replacement_viewport)
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._background.visible, "Toolbar must render after the host replaces primary")
	assert(strip._background.get_parent() == replacement_viewport)
	assert(previous_target.collision_layer == 0, "Retired toolbar targets must stop intercepting input")
	assert(strip._items[0].area.get_parent() == owner.primary_screen,
		"Toolbar hitboxes must follow the replacement screen")
	previous_screen.free()
	owner.primary_screen.free()
	replacement_viewport.free()
	viewport.free()
	owner.free()
	print("All screen tab strip tests passed")
	quit()
