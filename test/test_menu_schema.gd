extends SceneTree

func _init():
	assert(MenuSchema.validate().is_empty(), "Menu schema must be internally valid")
	assert(_tab_button_labels() == ["Display", "Stream", "Control", "AI 3D", "Picture", "Screens", "Settings"])
	assert(_tab_ids() == [&"display", &"stream", &"control", &"picture", &"settings"])
	assert(_option_count(&"display") == 8)
	assert(_option_count(&"stream") == 8)
	assert(_option_count(&"control") == 8)
	assert(_option_count(&"picture") == 8)
	# Desktop: Logs, Stats, hidden 3D Debug, Cursor Position, hidden Android
	# Depth Sync, Language, Auto-Reconnect, Idle, Quick Start, Forget Meteor
	# Keys, Microphone, hidden Android Audio Output, Licences.
	assert(_option_count(&"settings") == 18)
	assert(MenuSchema.get_tab(&"settings").get("scrollable", false))
	for row in MenuSchema.get_tab(&"settings")["rows"]:
		assert(not String(row.get("title", "")).is_empty(), "Settings rows need section titles")
	for tab_button in MenuSchema.get_tab_buttons():
		assert(not String(tab_button["tooltip"]).is_empty())
	assert(_contains(&"stream", &"_ui_crop_btn"))
	assert(_contains(&"settings", &"_ui_host_cursor_btn"))
	for field in [&"_ui_key_btn", &"_ui_key_tolerance_btn", &"_ui_host_background_btn"]:
		assert(_contains(&"picture", field))
	for tab in MenuSchema.get_tabs():
		for row in tab["rows"]:
			assert(row["options"].size() <= 4)
			for option in row["options"]:
				assert(not String(option["tooltip"]).is_empty())
	var debug_option: Dictionary = MenuSchema.get_tab(&"settings")["rows"][0]["options"][2]
	assert(debug_option["field"] == &"_ui_3d_debug_btn")
	assert(not debug_option["visible"])
	assert(debug_option["disabled"])
	print("All menu_schema tests passed")
	quit()

func _tab_button_labels() -> Array[String]:
	var labels: Array[String] = []
	for button in MenuSchema.get_tab_buttons():
		labels.append(button["label"])
	return labels

func _tab_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	assert(_contains(&"stream", &"_ui_crop_btn"))
	assert(_contains(&"settings", &"_ui_host_cursor_btn"))
	for field in [&"_ui_key_btn", &"_ui_key_tolerance_btn", &"_ui_host_background_btn"]:
		assert(_contains(&"picture", field))
	for tab in MenuSchema.get_tabs():
		ids.append(tab["id"])
	return ids

func _option_count(tab_id: StringName) -> int:
	var count := 0
	for row in MenuSchema.get_tab(tab_id)["rows"]:
		count += row["options"].size()
	return count

func _contains(tab_id: StringName, field: StringName) -> bool:
	for row in MenuSchema.get_tab(tab_id)["rows"]:
		for option in row["options"]:
			if option["field"] == field: return true
	return false
