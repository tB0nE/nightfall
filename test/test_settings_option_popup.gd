extends SceneTree

func _init():
	call_deferred("run")

func run():
	var settings := AppSettings.new()
	settings.ambient_gain = 1.75
	var config := ConfigFile.new()
	SettingsPersistence.write_app(config, settings)
	var loaded := AppSettings.new()
	SettingsPersistence.read_app(config, loaded, false, [0])
	assert(is_equal_approx(loaded.ambient_gain, 1.75))
	loaded.reset_display()
	assert(loaded.ambient_gain == 1.0)
	var host := HostSettings.new()
	host.bitrate_mbps = 400
	SettingsPersistence.write_host(config, "host", host)
	var restored := HostSettings.new()
	SettingsPersistence.read_host(config, "host", restored, [60], [100], 10, 20)
	assert(restored.bitrate_mbps == 400)
	config.erase_section_key("host", "bitrate_mbps")
	config.set_value("host", "bitrate_idx", 4)
	SettingsPersistence.read_host(config, "host", restored, [60], [100], 10, 20)
	assert(restored.bitrate_mbps == 0 and restored.bitrate_idx == 4)
	var popup := SettingsOptionPopup.new()
	root.add_child(popup)
	var observed := {"preview": 0, "commit": 0, "cancel": 0}
	popup.open_slider("Test", 40, 5, 120, 1, " Mbps",
		func(_v): observed.preview += 1,
		func(_v): observed.commit += 1,
		func(): observed.cancel += 1, "Auto", Callable())
	var labels := func():
		var found := []
		for button in popup.find_children("*", "Button", true, false): found.append(button.text)
		return found
	assert(labels.call().has("Done") and not labels.call().has("Apply"), "A live slider's button is Done")
	popup._slider.value = 55
	popup._slider.value = 60
	assert(observed.preview == 2)
	assert(observed.commit == 0)
	popup.close()
	assert(observed.cancel == 1)
	popup.close()
	assert(observed.cancel == 1)
	var choices: Array = []
	for id in 24: choices.append({"id": id, "label": "Choice %d" % id})
	popup.open_choices("Test", choices, 3, func(_id): observed.commit += 1)
	await process_frame
	await process_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.global_position = Vector2(200, 200)
	popup._choice_drag_input(press)
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.global_position = Vector2(200, 140)
	popup._choice_drag_input(motion)
	assert(popup._choice_scroll.scroll_vertical > 0)
	assert(observed.commit == 0, "Dragging a choice list must not commit")
	popup.close()
	var owner := Node3D.new()
	var ui := UIController.new(owner)
	ui._settings_popup = popup
	popup.open_slider("Test", 100, 0, 200, 5, "%", Callable(), Callable(),
		func(): observed.cancel += 1, "Reset", Callable())
	var deferred_labels := []
	for button in popup.find_children("*", "Button", true, false): deferred_labels.append(button.text)
	assert(deferred_labels.has("Apply"), "A slider applied only on commit keeps Apply")
	assert(ui.settings_popup_open())
	ui.close_settings_popup()
	assert(not ui.settings_popup_open())
	assert(observed.cancel == 2, "Closing the menu must roll back an uncommitted preview")
	# Use the real menu height: content-sized popups must retain usable rows,
	# while long lists must fit and scroll rather than clipping the panel.
	root.size = Vector2i(1200, 580)
	for count in [3, 7, 24]:
		var entries: Array = []
		for id in count: entries.append({"id": id, "label": "Option %d" % id})
		popup.open_choices("Layout", entries, 0, Callable())
		for frame in 3: await process_frame
		var panel := popup.get_child(0) as PanelContainer
		var scroll := popup._choice_scroll
		var grid := scroll.get_child(0) as GridContainer
		assert(not scroll.clip_contents, "Choice lists must avoid the broken GLES SubViewport clip path")
		popup._cull_choices()
		assert(grid.get_child(0).modulate.a == 1.0, "The first complete row must remain visible")
		assert(scroll.size.y >= 96, "At least one complete choice row must remain visible")
		assert(panel.position.y >= 16 and panel.position.y + panel.size.y <= popup.size.y - 15)
		assert(grid.get_child(0).size.y >= 96, "Choice buttons need a usable XR target height")
		if count <= 7: assert(scroll.size.y >= grid.size.y, "Short lists should show every option")
		if count == 24:
			scroll.scroll_vertical = 10000
			for frame in 3: await process_frame
			popup._cull_choices()
			assert(grid.get_child(0).modulate.a == 0.0, "Scrolled-out rows must not draw over popup chrome")
			assert(grid.get_child(0).mouse_filter == Control.MOUSE_FILTER_IGNORE)
			assert(grid.get_child(grid.get_child_count() - 1).modulate.a == 1.0, "The last row must be reachable")
	popup.close()
	owner.free()
	popup.queue_free()
	print("All settings popup tests passed")
	quit()
