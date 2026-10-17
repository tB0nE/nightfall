extends SceneTree

# GPU smoke test: run with an actual display/renderer, not --headless.
const Fixture = preload("res://test/test_screen_tab_strip.gd")

func _init(): _run.call_deferred()

func _run():
	var owner := Fixture.FakeMain.new()
	owner.primary_screen = VRScreen.new()
	owner.primary_screen._comp_cyl_radius = 3.0
	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var margin := owner.primary_screen.mesh_size.x * ScreenTabStrip.TOP_MARGIN_RATIO
	var surface := owner.primary_screen.mesh_size + Vector2(owner.primary_screen.mesh_size.x * 0.054, margin * 2.0)
	viewport.size = Vector2i(1536, roundi(1536 * surface.y / surface.x))
	root.add_child(viewport)
	var strip := ScreenTabStrip.new(owner)
	strip.attach(owner.primary_screen, viewport)
	strip.update(owner.primary_screen, surface, margin, true)
	for i in range(4): await process_frame
	await RenderingServer.frame_post_draw
	for item in strip._items:
		print("TAB VISUAL ", item.action, " label=", item.label.text, " size=", item.label.size,
			" panel=", item.panel.size, " colour=", item.label.get_theme_color("font_color"))
	var image := viewport.get_texture().get_image()
	for item in strip._items:
		if not item.enabled or not item.panel.visible: continue
		var rect: Rect2i = Rect2i(item.panel.get_rect())
		var bright := 0
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var color := image.get_pixel(x, y)
				if color.a > 0.4 and maxf(color.r, maxf(color.g, color.b)) > 0.5: bright += 1
		assert(bright > 8, "Tab has no visible caption/icon pixels")
	var result := image.save_png("/tmp/nightfall-tab-strip-render.png")
	assert(result == OK)
	owner.primary_screen.free()
	viewport.free()
	owner.free()
	quit()
