extends SceneTree

class FakeBrowser extends RefCounted:
	var pages: Array = [{"id": 1, "title": "First"}, {"id": 2, "title": "Second"}]
	var selected_page := 1
	var active := true
	var closing := false

class FakeComp extends RefCounted:
	var in_use := true

class FakeMain extends Node3D:
	var browser_prototype := FakeBrowser.new()
	var primary_screen: VRScreen
	var is_streaming := false
	var comp := FakeComp.new()

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
	assert(rects[3].size.x > rects[0].size.x)
	for i in range(rects.size() - 1):
		assert(rects[i].end.x < rects[i + 1].position.x)
	assert(rects[-1].end.x < 0.26, "Page hitboxes must not overlap the close button")
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
	owner.primary_screen = VRScreen.new()
	owner.primary_screen._comp_cyl_radius = 3.0
	var viewport := SubViewport.new()
	var strip := ScreenTabStrip.new(owner)
	strip.attach(owner.primary_screen, viewport)
	var margin := owner.primary_screen.mesh_size.x * ScreenTabStrip.TOP_MARGIN_RATIO
	var surface := owner.primary_screen.mesh_size + Vector2(0.12, margin * 2.0)
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items.size() == 6)
	assert(strip._items[-1].action == &"hover")
	assert(not strip._items[-1].panel.visible, "Hover backdrop must be invisible")
	assert(strip._items[0].label.text == "First", "Selected tab should use its title, not WEB")
	assert(strip._items[1].label.text == "", "Inactive browser tabs should show only their globe")
	var retained_area: Area3D = strip._items[0].area
	owner.browser_prototype.pages[0].title = "Changed title"
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items[0].area == retained_area, "Title updates must retain the live physics target")
	var hit_geometry: PackedVector3Array = strip._items[1].area.get_child(0).shape.get_faces()
	strip.set_hover(&"page:2")
	strip.update(owner.primary_screen, surface, margin, true)
	assert(strip._items[1].area.get_child(0).shape.get_faces() == hit_geometry, "Artwork expansion must not grow hitboxes")
	assert(strip._items[1].panel.visible)
	strip.update(owner.primary_screen, surface, margin, false)
	assert(not strip._items[1].panel.visible)
	owner.primary_screen.free()
	viewport.free()
	owner.free()
	print("All screen tab strip tests passed")
	quit()
