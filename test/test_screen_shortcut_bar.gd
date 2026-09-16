extends SceneTree

func _init():
	_test_layout_order()
	_test_visible_actions()
	_test_contextual_reveal_state()
	_test_pointer_target_metadata()
	print("All screen_shortcut_bar tests passed")
	quit()

func _test_layout_order() -> void:
	var sbs_x = ScreenShortcutBar._action_x_ratio(ScreenShortcutBar.ACTION_SBS)
	var pad_x = ScreenShortcutBar._action_x_ratio(ScreenShortcutBar.ACTION_PAD)
	var menu_x = ScreenShortcutBar._action_x_ratio(ScreenShortcutBar.ACTION_MENU)
	var keyboard_x = ScreenShortcutBar._action_x_ratio(ScreenShortcutBar.ACTION_KEYBOARD)
	assert(pad_x < keyboard_x and keyboard_x < 0.0)
	assert(sbs_x > 0.0 and sbs_x < menu_x)
	assert(is_equal_approx(absf(keyboard_x), sbs_x))
	assert(is_equal_approx(absf(pad_x), menu_x))
	var half_hit = ScreenShortcutBar.HIT_SIZE_RATIO * 0.5
	var half_bar = ScreenShortcutBar.BAR_WIDTH_RATIO * 0.5
	assert(keyboard_x + half_hit < -half_bar)
	assert(sbs_x - half_hit > half_bar)
	assert(pad_x + half_hit < keyboard_x - half_hit)
	assert(sbs_x + half_hit < menu_x - half_hit)

func _test_visible_actions() -> void:
	assert(ScreenShortcutBar.VISIBLE_ACTIONS == [
		ScreenShortcutBar.ACTION_PAD,
		ScreenShortcutBar.ACTION_KEYBOARD,
		ScreenShortcutBar.ACTION_SBS,
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
