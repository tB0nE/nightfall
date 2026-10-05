extends SceneTree

func _init():
	assert(MenuSchema.validate().is_empty(), "Menu schema must be internally valid")
	assert(_tab_button_labels() == ["Display", "Stream", "Control", "AI 3D", "Picture", "Monitors", "Settings"])
	assert(_tab_ids() == [&"display", &"stream", &"control", &"picture", &"settings"])
	assert(_option_count(&"display") == 8)
	assert(_option_count(&"stream") == 8)
	assert(_option_count(&"control") == 8)
	assert(_option_count(&"picture") == 4)
	# Desktop: Logs, Stats, hidden 3D Debug, Language, Auto-Reconnect, Idle.
	assert(_option_count(&"settings") == 6)
	assert(MenuSchema.get_tab(&"settings").get("scrollable", false))
	for row in MenuSchema.get_tab(&"settings")["rows"]:
		assert(not String(row.get("title", "")).is_empty(), "Settings rows need section titles")
	for tab_button in MenuSchema.get_tab_buttons():
		assert(not String(tab_button["tooltip"]).is_empty())
	for tab in MenuSchema.get_tabs():
		for row in tab["rows"]:
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
	for tab in MenuSchema.get_tabs():
		ids.append(tab["id"])
	return ids

func _option_count(tab_id: StringName) -> int:
	var count := 0
	for row in MenuSchema.get_tab(tab_id)["rows"]:
		count += row["options"].size()
	return count
