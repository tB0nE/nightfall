extends SceneTree

func _init():
	assert(MenuSchema.validate().is_empty(), "Menu schema must be internally valid")
	assert(_tab_button_labels() == ["Display", "Stream", "Control", "AI 3D", "Picture", "Monitors", "Advanced"])
	assert(_tab_ids() == [&"display", &"stream", &"control", &"picture", &"advanced"])
	assert(_option_count(&"display") == 8)
	assert(_option_count(&"stream") == 6)
	assert(_option_count(&"control") == 8)
	assert(_option_count(&"picture") == 4)
	assert(_option_count(&"advanced") == 3)
	var debug_option: Dictionary = MenuSchema.get_tab(&"advanced")["rows"][1]["options"][0]
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
