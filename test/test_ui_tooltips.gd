extends SceneTree

class FakeMain extends Node3D:
	var ui_visible := true

func _init():
	call_deferred("_run")

func _run():
	var main := FakeMain.new()
	root.add_child(main)
	var controller := UIController.new(main)
	controller._tooltip_panel = PanelContainer.new()
	controller._tooltip_label = Label.new()
	controller._tooltip_panel.add_child(controller._tooltip_label)
	main.add_child(controller._tooltip_panel)
	controller._tooltip_panel.visible = false
	controller._tooltip_viewport = SubViewport.new()
	controller._tooltip_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(controller._tooltip_viewport)

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
	assert(controller._tooltip_viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"Hiding a tooltip must not tear down its OpenXR render target")

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
