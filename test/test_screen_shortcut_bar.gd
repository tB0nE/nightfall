extends SceneTree

func _init():
	_test_layout_order()
	_test_visible_actions()
	_test_contextual_reveal_state()
	_test_pointer_target_metadata()
	print("All screen_shortcut_bar tests passed")
	quit()

func _test_layout_order() -> void:
	var x := func(action: StringName) -> float: return ScreenShortcutBar._action_x_ratio(action)
	var order := ScreenShortcutBar.VISIBLE_ACTIONS
	for i in order.size() - 1:
		assert(x.call(order[i]) < x.call(order[i + 1]), "%s left of %s" % [order[i], order[i + 1]])
	# Three each side, mirrored.
	for i in 3:
		assert(x.call(order[i]) < 0.0 and x.call(order[5 - i]) > 0.0)
		assert(is_equal_approx(-x.call(order[i]), x.call(order[5 - i])))
	var half_hit = ScreenShortcutBar.HIT_SIZE_RATIO * 0.5
	var half_bar = ScreenShortcutBar.BAR_WIDTH_RATIO * 0.5
	assert(x.call(ScreenShortcutBar.ACTION_KEYBOARD) + half_hit < -half_bar)
	assert(x.call(ScreenShortcutBar.ACTION_SBS) - half_hit > half_bar)
	for i in order.size() - 1:
		assert(x.call(order[i]) + half_hit < x.call(order[i + 1]) - half_hit)
	# The strip (and its composition viewport) holds the outermost icons.
	assert(x.call(ScreenShortcutBar.ACTION_MENU) + half_hit <= ScreenShortcutBar.STRIP_WIDTH_RATIO * 0.5)
	var px_per_width := ScreenShortcutBar.COMP_VIEWPORT_SIZE.x / ScreenShortcutBar.STRIP_WIDTH_RATIO
	var px_per_height := ScreenShortcutBar.COMP_VIEWPORT_SIZE.y / ScreenShortcutBar.STRIP_HEIGHT_RATIO
	assert(absf(px_per_width - px_per_height) / px_per_height < 0.01, "the viewport keeps the strip's aspect")

func _test_visible_actions() -> void:
	assert(ScreenShortcutBar.VISIBLE_ACTIONS == [
		ScreenShortcutBar.ACTION_MIC,
		ScreenShortcutBar.ACTION_PAD,
		ScreenShortcutBar.ACTION_KEYBOARD,
		ScreenShortcutBar.ACTION_SBS,
		ScreenShortcutBar.ACTION_AI_3D,
		ScreenShortcutBar.ACTION_MENU,
	])

func _test_contextual_reveal_state() -> void:
	var shortcuts := ScreenShortcutBar.new(Node3D.new())
	var first := VRScreen.new()
	var second := VRScreen.new()
	assert(not shortcuts.controls_are_revealed(first))
	shortcuts.reveal_controls(first)
	assert(shortcuts.controls_are_revealed(first))
	assert(not shortcuts.controls_are_revealed(second))
	shortcuts.begin_pointer_frame(0.25)
	assert(shortcuts.controls_are_revealed(first))
	shortcuts.begin_pointer_frame(0.24)
	assert(shortcuts.controls_are_revealed(first))
	shortcuts.begin_pointer_frame(0.02)
	assert(not shortcuts.controls_are_revealed(first))
	shortcuts.main.free()
	first.free()
	second.free()

func _test_pointer_target_metadata() -> void:
	var screen := VRScreen.new()
	var icon := MeshInstance3D.new()
	icon.set_meta(&"nf_role", &"screen_shortcut")
	icon.set_meta(&"nf_action", ScreenShortcutBar.ACTION_KEYBOARD)
	var area := Area3D.new()
	icon.add_child(area)
	screen.add_child(icon)
	var target := PointerTarget.resolve(area)
	assert(target.role == &"screen_shortcut")
	assert(target.action == ScreenShortcutBar.ACTION_KEYBOARD)
	assert(target.screen == screen)
	var direct_area := Area3D.new()
	direct_area.set_meta(&"nf_role", &"screen_shortcut")
	direct_area.set_meta(&"nf_action", ScreenShortcutBar.ACTION_MENU)
	screen.add_child(direct_area)
	var direct_target := PointerTarget.resolve(direct_area)
	assert(direct_target.role == &"screen_shortcut")
	assert(direct_target.action == ScreenShortcutBar.ACTION_MENU)
	assert(direct_target.screen == screen)
	screen.free()
