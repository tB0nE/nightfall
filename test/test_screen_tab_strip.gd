extends SceneTree

class FakeBrowser extends RefCounted:
	const RESOLUTIONS := [Vector2i(1920,1080),Vector2i(2560,1440)]
	var pages: Array = [{"id": 1, "title": "First"}, {"id": 2, "title": "Second"}]
	var selected_page := 1
	var active := true
	var suspended := false
	var closing := false
	var navigation: Dictionary = {"address": "https://example.com", "back": true, "forward": false}
	var actions: Array = []
	func tab_action(action: String, id: int = 0) -> void: actions.append([action, id])

class FakeComp extends RefCounted:
	var in_use := true

class FakeSources extends RefCounted:
	var edit_browser_resolution := false
	var offer_stream := true
	var browser_ready := true
	var open_browser_allowed := true
	var add_browser_allowed := true
	var close_monitor_allowed := false
	var closed_monitors: Array = []
	var physical_available := false
	var monitor_requests: Array = []
	var placements: Array = []
	func add_monitor_tab(_screen, virtual := false, size := Vector2i.ZERO, id := &""): monitor_requests.append(["tab",virtual,size] if id == &"" else ["tab",virtual,size,id])
	func add_monitor_screen(virtual := false, size := Vector2i.ZERO, _id := &""): monitor_requests.append(["screen",virtual,size])
	func begin_screen_placement(request: Dictionary): placements.append(request)
	func host_monitor_size(): return Vector2i(2560, 1440)
	func physical_choices(screen = null): return [{"id": &"DP-1", "label": "Left monitor", "enabled": true}] if physical_available or screen == null else []
	func can_add_monitor_tab(_screen, virtual := false): return virtual or physical_available
	func can_close_monitor_screen(_screen): return close_monitor_allowed
	func close_monitor_screen(screen): closed_monitors.append(screen)
	func can_open_browser(): return browser_ready and open_browser_allowed
	func can_add_browser_screen(): return browser_ready and add_browser_allowed
	func can_offer_stream_screen(): return offer_stream
	func can_add_stream_screen(): return offer_stream
	func can_make_primary(_screen): return false
	func monitor_tab(_screen): return null
	func can_switch_content_tab(_screen): return can_open_browser()
	func can_edit_browser_tab_resolution(_screen): return edit_browser_resolution
	var add_monitor_allowed := false
	func can_add_monitor_screen(_virtual := false): return add_monitor_allowed

class FakeMain extends Node3D:
	var browser_prototype := FakeBrowser.new()
	var primary_screen: VRScreen
	var is_streaming := false
	var comp := FakeComp.new()
	var layout := ScreenLayout.new()
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
	assert(is_equal_approx(rects[0].position.x, ScreenTabStrip.TAB_LEFT))
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
	assert(strip._items.size() == 10)
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
	var shared_close: Dictionary
	var close_count := 0
	for item in strip._items:
		assert(not String(item.action).begins_with("close:"), "Tabs must not retain individual close targets")
		if item.action == &"close":
			shared_close = item
			close_count += 1
	assert(close_count == 1 and shared_close.panel.visible and shared_close.area.collision_layer == 2)
	assert(shared_close.rect.size.x == shared_close.rect.size.y, "Close button must be circular, not pill shaped")
	assert(shared_close.rect.end.x < strip._items[0].rect.position.x, "Close button needs its own space at top left")
	assert(shared_close.styles[0].bg_color.r > shared_close.styles[0].bg_color.g)
	var close_area: Area3D = shared_close.area
	strip.invoke(&"close")
	assert(owner.browser_prototype.actions[-1] == ["close", 1], "Close targets the active tab even when another tab is hovered")
	owner.browser_prototype.selected_page = 2
	strip.update(owner.primary_screen, surface, margin, true)
	strip.invoke(&"close")
	assert(owner.browser_prototype.actions[-1] == ["close", 2])
	for item in strip._items:
		if item.action == &"close": assert(item.area == close_area, "Changing tabs must preserve the shared close target")
	owner.browser_prototype.selected_page = 1
	strip.hide_controls()
	var before_hidden_click := owner.browser_prototype.actions.size()
	strip.invoke(&"close")
	assert(owner.browser_prototype.actions.size() == before_hidden_click, "Hidden top controls cannot be activated during the reveal delay")
	for item in strip._items:
		assert(item.area.collision_layer == (2 if item.action == &"hover" else 0))
	strip.update(owner.primary_screen, surface, margin, true)
	strip.invoke(&"browser")
	assert(strip.popup == "sources", "Add Browser should offer tab versus screen")
	strip.update(owner.primary_screen, surface, margin, true)
	var source_actions := []
	for item in strip._items: source_actions.append(String(item.action))
	assert(source_actions.find("screen:new") >= 0 and source_actions.find("screen:new") < source_actions.find("tab:new"), "Add Screen, then Add Tab")
	assert(not source_actions.has("screen:primary"), "No Make Primary on the primary")
	assert(not source_actions.has("stream:new"), "Connection creation belongs in the screen-type menu")
	strip.invoke(&"screen:new")
	strip.update(owner.primary_screen, surface, margin, true)
	var screen_types := []
	for item in strip._items: screen_types.append(String(item.action))
	assert(screen_types.has("screen:browser") and screen_types.has("screen:physical") and screen_types.has("screen:virtual") and screen_types.has("stream:new"))
	# A new screen is placed by clicking where its outline shows.
	strip.invoke(&"screen:browser")
	assert(owner.screen_sources.placements[-1].kind == &"browser" and strip.popup == "")
	owner.screen_sources.add_monitor_allowed = true
	strip.invoke(&"browser")
	strip.invoke(&"screen:new")
	strip.update(owner.primary_screen, surface, margin, true)
	strip.invoke(&"screen:physical")
	assert(strip.popup == "physical_list")
	strip.update(owner.primary_screen, surface, margin, true)
	var physical_actions := []
	for item in strip._items: physical_actions.append(String(item.action))
	assert(physical_actions.has("physical:DP-1"))
	strip.invoke(&"physical:DP-1")
	assert(owner.screen_sources.placements[-1] == {"kind": &"physical", "id": &"DP-1", "title": "Left monitor"})
	owner.screen_sources.add_monitor_allowed = false
	strip.invoke(&"browser")
	strip.invoke(&"screen:new")
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items[-1].rect.end.y > 0.15, "Hover backdrop must cover the full type menu")
	owner.screen_sources.offer_stream = false
	strip._signature = ""
	strip.update(owner.primary_screen, surface, margin, true)
	source_actions.clear()
	for item in strip._items: source_actions.append(String(item.action))
	assert(not source_actions.has("stream:new") and source_actions.has("screen:browser"))
	# Eligibility can change after a restart without any tab/screen-count change.
	owner.browser_prototype.active = false
	owner.is_streaming = true
	strip.popup = ""
	owner.screen_sources.browser_ready = false
	strip.update(owner.primary_screen, surface, margin, true)
	var browser_index := -1
	for i in strip._items.size():
		if strip._items[i].action == &"browser": browser_index = i
	assert(browser_index >= 0 and not strip._items[browser_index].enabled)
	owner.screen_sources.browser_ready = true
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items[browser_index].enabled, "Browser must enable without adding another screen")
	owner.browser_prototype.active = true
	owner.is_streaming = false
	strip.invoke(&"tab:new")
	assert(strip.popup == "tab_types")
	strip.update(owner.primary_screen, surface, margin, true)
	var tab_actions := []
	for item in strip._items: tab_actions.append(String(item.action))
	assert(tab_actions.has("tab:browser") and tab_actions.has("tab:start_stream"))
	assert(not tab_actions.has("tab:physical") and not tab_actions.has("tab:virtual"))
	owner.is_streaming = true
	strip.update(owner.primary_screen, surface, margin, true)
	var physical_enabled := true
	var virtual_enabled := false
	for item in strip._items:
		if item.action == &"tab:physical": physical_enabled = item.enabled
		if item.action == &"tab:virtual": virtual_enabled = item.enabled
	assert(not physical_enabled and virtual_enabled, "Reserved physical outputs must not prevent adding virtual tabs")
	owner.screen_sources.physical_available = true
	strip.update(owner.primary_screen, surface, margin, true)
	for item in strip._items:
		if item.action == &"tab:physical": assert(item.enabled)
	owner.is_streaming = false
	strip.invoke(&"tab:browser")
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
	owner.screen_sources.edit_browser_resolution = true
	owner.browser_prototype.active = true
	strip.popup = "tab_resolution"
	strip._signature = ""
	strip.update(owner.primary_screen, surface, margin, true)
	var sizes := []
	for item in strip._items:
		if String(item.action).begins_with("tab:res:"): sizes.append(item.title)
	assert(sizes == ["Default","1920 × 1080","2560 × 1440"], "Browser picker must offer only supported render surfaces")
	owner.browser_prototype.pages = []
	owner.browser_prototype.active = false
	owner.is_streaming = true
	owner.screen_sources.close_monitor_allowed = true
	strip.popup = ""
	strip.set_hover(&"current")
	strip.update(owner.primary_screen, surface, margin, true)
	var close_monitor: Dictionary
	for item in strip._items:
		if item.action == &"close": close_monitor = item
	assert(not close_monitor.is_empty() and close_monitor.panel.visible)
	assert(close_monitor.area.collision_layer == 2, "Hovering the monitor title must reveal a clickable close button")
	strip.invoke(&"close")
	assert(owner.screen_sources.closed_monitors == [owner.primary_screen])
	# Monitor IDs are strings; browser IDs are integers. Both must paint while
	# a browser is selected, including retained controls from a prior rebuild.
	owner.browser_prototype.active = true
	owner.is_streaming = false
	owner.browser_prototype.pages = [{"id":1,"title":"Browser one"},{"id":2,"title":"Browser two"}]
	owner.browser_prototype.selected_page = 2
	owner.primary_screen.content_tabs.add(ScreenContentTab.for_monitor(&"m0"))
	owner.primary_screen.content_tabs.add(ScreenContentTab.for_monitor(&"v1"))
	owner.primary_screen.content_tabs.sync_browser_pages(owner.browser_prototype.pages,2)
	owner.primary_screen.content_tabs.select(&"browser:page:2")
	strip.update(owner.primary_screen,surface,margin,true)
	var mixed_actions := []
	for item in strip._items:
		if String(item.action).begins_with("monitor:") or String(item.action).begins_with("page:"):
			assert(item.panel.visible and not item.panel.text.is_empty())
			mixed_actions.append(String(item.action))
	assert(mixed_actions == ["monitor:m0","monitor:v1","page:1","page:2"])
	strip.popup = "tabs"
	strip.update(owner.primary_screen,surface,margin,true)
	var mixed_pages := [{"id":"monitor:m0"},{"id":"monitor:v1"},{"id":1},{"id":2},{"id":3}]
	assert(ScreenTabStrip.visible_pages(mixed_pages,3)[3].id == 3)
	owner.layout.virtual_modes_supported = true
	strip.invoke(&"tab:virtual")
	assert(strip.popup == "virtual_resolution")
	strip.update(owner.primary_screen,surface,margin,true)
	var ratio_actions := []
	for item in strip._items: ratio_actions.append(String(item.action))
	var default_titles := []
	for item in strip._items:
		if item.action == &"virtual:default": default_titles.append(item.title)
	assert(default_titles == ["Default (2560 × 1440)"], "Default says what it creates")
	assert(ratio_actions.has("virtual:default") and ratio_actions.has("virtual:ratio:0") and ratio_actions.has("virtual:ratio:2") and ratio_actions.has("virtual:custom"))
	strip.invoke(&"virtual:ratio:1")
	assert(strip.popup == "virtual_ratio")
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:size:1")
	assert(owner.screen_sources.monitor_requests[-1] == ["tab",true,Vector2i(3440,1440)])
	strip.invoke(&"tab:virtual")
	strip.invoke(&"virtual:ratio:0")
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:size:1")
	assert(owner.screen_sources.monitor_requests[-1] == ["tab",true,Vector2i(2560,1440)])
	strip._virtual_kind = "screen"
	strip.popup = "virtual_ratio"
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:size:0")
	assert(owner.screen_sources.placements[-1] == {"kind": &"virtual", "size": Vector2i(1920,1080), "title": "Virtual 1920 × 1080"})
	# Vertical Orientation turns every size on its side, Default included.
	strip.popup = "virtual_resolution"
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:vertical")
	strip.update(owner.primary_screen,surface,margin,true)
	var vertical_titles := {}
	for item in strip._items: vertical_titles[String(item.action)] = item.title
	assert(vertical_titles["virtual:default"] == "Default (1440 × 2560)" and vertical_titles["virtual:ratio:1"] == "9:21  ›")
	assert(vertical_titles["virtual:vertical"] == "Vertical Orientation: On" and vertical_titles.has("virtual:custom"))
	strip.invoke(&"virtual:ratio:2")
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:size:1")
	assert(owner.screen_sources.placements[-1].size == Vector2i(1200,1600), "A vertical 4:3 size is 1200 × 1600")
	strip.popup = "virtual_resolution"
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:default")
	assert(owner.screen_sources.placements[-1].size == Vector2i(1440,2560), "A vertical Default names its size")
	strip._virtual_vertical = false
	strip.invoke(&"tab:virtual")
	strip.invoke(&"virtual:custom")
	for key in ["1","2","8","0"]: strip.invoke(StringName("virtual:key:"+key))
	strip.invoke(&"virtual:field:1")
	for key in ["1","0","2","4"]: strip.invoke(StringName("virtual:key:"+key))
	strip.update(owner.primary_screen,surface,margin,true)
	strip.invoke(&"virtual:create")
	assert(owner.screen_sources.monitor_requests[-1] == ["tab",true,Vector2i(1280,1024)])
	previous_screen.free()
	owner.primary_screen.free()
	replacement_viewport.free()
	viewport.free()
	owner.free()
	print("All screen tab strip tests passed")
	quit()
