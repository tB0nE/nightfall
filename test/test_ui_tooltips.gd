extends SceneTree

class FakeMain extends Node3D:
	var ui_visible := true
	var _ui_viewport_size := Vector2i(1200, 580)
	var ui_viewport: SubViewport

func _init():
	call_deferred("_run")

func _run():
	var main := FakeMain.new()
	root.add_child(main)
	main.ui_viewport = SubViewport.new()
	main.ui_viewport.size = Vector2i(1200, 682)
	main.add_child(main.ui_viewport)
	var controller := UIController.new(main)
	controller._build_tooltip_surface()
	assert(controller._tooltip_panel.get_parent() == main.ui_viewport)
	assert(controller._tooltip_panel.position == Vector2(100, 0))
	assert(controller._tooltip_panel.size == Vector2(1000, 64))

	var first := Button.new()
	first.set_meta(UIController.TOOLTIP_META, "First tooltip")
	main.add_child(first)
	var second := Button.new()
	second.set_meta(UIController.TOOLTIP_META, "Second tooltip")
	main.add_child(second)

	controller.set_hovered_tooltip(first)
	assert(not controller._tooltip_panel.visible, "Initial tooltip should be delayed")
	await create_timer(UIController.TOOLTIP_DELAY_SEC + 0.05).timeout
	assert(controller._tooltip_panel.visible)
	assert(controller._tooltip_label.text == "First tooltip")

	controller.set_hovered_tooltip(second)
	assert(controller._tooltip_panel.visible, "Replacement should remain visible")
	assert(controller._tooltip_label.text == "Second tooltip", "Replacement should be immediate")

	controller.set_hovered_tooltip(null)
	assert(not controller._tooltip_panel.visible, "Tooltip should disappear immediately")
	assert(not controller._tooltip_panel.visible,
		"Hiding a tooltip must clear its pixels without changing the menu render target")

	controller.set_hovered_tooltip(first)
	await create_timer(UIController.TOOLTIP_DELAY_SEC * 0.55).timeout
	controller.set_hovered_tooltip(second)
	await create_timer(UIController.TOOLTIP_DELAY_SEC * 0.55).timeout
	assert(not controller._tooltip_panel.visible, "A stale timer must not show an old tooltip")
	await create_timer(UIController.TOOLTIP_DELAY_SEC * 0.55).timeout
	assert(controller._tooltip_panel.visible)
	assert(controller._tooltip_label.text == "Second tooltip")

	controller.clear_tooltip()
	assert(not controller._tooltip_panel.visible)
	print("All ui_tooltips tests passed")
	quit()
