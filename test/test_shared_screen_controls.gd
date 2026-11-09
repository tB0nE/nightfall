extends SceneTree

class Sources extends RefCounted:
	func menu_for_screen(_screen): return null
	func browser_for_screen(_screen): return null

class Owner extends Node3D:
	var primary_screen: VRScreen
	var screen_sources := Sources.new()
	var settings := AppSettings.new()
	var controller_mapper = null
	var ui_visible := false
	var virtual_keyboard = null
	var meteor_microphone = null
	var comp = null

func _init(): _run.call_deferred()

func _run():
	var owner := Owner.new()
	root.add_child(owner)
	var origin := Node3D.new()
	owner.add_child(origin)
	var controls := CompositionScreenControls.new()
	var shortcuts := ScreenShortcutBar.new(owner)
	var screens: Array[VRScreen] = []
	for i in range(4):
		var screen: VRScreen = preload("res://src/vr_screen.tscn").instantiate()
		owner.add_child(screen)
		screen.monitor_id = StringName("test:%d" % i)
		screen.mesh_size = Vector2(2.24, 1.26)
		screen._comp_cyl_radius = 3.0
		screen.grab_bar.position.y = -screen.mesh_size.y * 0.5595
		if i == 0: owner.primary_screen = screen
		controls.setup(owner, origin, shortcuts, screen)
		assert(screen.comp_grab_bar == screen.comp_corner_layer, "Screen controls must share ONE XR layer")
		assert(screen.comp_grab_bar_viewport == screen.comp_corner_viewport, "Screen controls must share ONE viewport")
		screens.append(screen)
	assert(origin.get_child_count() == 4, "Four screens must allocate four controls layers, not eight")
	# Nothing pointed at: no controls layer is submitted at all. Four always-on controls layers
	# took the headset past its 16 composition layers and screens flashed out.
	controls.update(screens, true, true, true, null, null)
	for screen in screens:
		assert(not screen.comp_corner_layer.visible, "Controls layers stay hidden until a screen is pointed at")
	for screen in screens:
		controls.update(screens, true, true, true, null, screen)
		var shown := 0
		for other in screens:
			shown += 1 if other.comp_corner_layer.visible else 0
		assert(shown == 1 and screen.comp_corner_layer.visible, "Only the screen pointed at submits its controls")
		var viewport := screen.comp_corner_viewport
		var strip := viewport.get_node("ShortcutStrip") as Control
		assert(strip.visible, "Pointing at a screen shows its grab bar")
		for corner in screen.comp_corner_rects: assert(not corner.visible, "Corners wait for the controls themselves")
		var center := strip.position + Vector2(ScreenShortcutBar.COMP_VIEWPORT_SIZE) * strip.scale * 0.5
		var scale_px := CompositionScreenControls.CORNER_ATLAS_WIDTH / (screen.mesh_size.x * 1.054)
		assert(is_equal_approx(center.x, viewport.size.x * 0.5))
		var bottom_margin := -screen.grab_bar.position.y - screen.mesh_size.y * 0.5 \
			+ screen.mesh_size.x * ScreenShortcutBar.STRIP_HEIGHT_RATIO * 0.5
		var expected_y := (bottom_margin + screen.mesh_size.y * 0.5 - screen.grab_bar.position.y) * scale_px
		assert(is_equal_approx(center.y, expected_y), "Grab bar artwork must stay aligned with its existing hitbox")
		assert(center.y + screen.mesh_size.x * ScreenShortcutBar.STRIP_HEIGHT_RATIO * scale_px * 0.5 <= viewport.size.y + 1.0,
			"Shared atlas must not crop the grab bar")
	controls.update(screens, true, true, true, screens[1], screens[1])
	assert(screens[1].comp_corner_rects[0].visible)
	assert(screens[1].comp_corner_layer.visible)
	assert(not screens[0].comp_corner_layer.visible)
	controls.update(screens, false, true, true, null)
	for screen in screens:
		assert(not screen.comp_corner_layer.visible)
		screen.free()
	owner.free()
	print("Shared screen controls tests passed")
	quit()
