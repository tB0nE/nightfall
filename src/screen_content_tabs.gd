class_name ScreenContentTabs
extends RefCounted

signal selection_changed(previous: ScreenContentTab, current: ScreenContentTab)

var tabs: Array[ScreenContentTab] = []
var selected_id: StringName = &""

func selected() -> ScreenContentTab:
	return find_tab(selected_id)

func find_tab(id: StringName) -> ScreenContentTab:
	for tab in tabs:
		if tab.id == id:
			return tab
	return null

func add(tab: ScreenContentTab, select_new: bool = true) -> bool:
	if tab == null or not tab.validate().is_empty() or find_tab(tab.id) != null:
		return false
	tabs.append(tab)
	if select_new or selected() == null:
		select(tab.id)
	return true

func select(id: StringName) -> bool:
	var next := find_tab(id)
	if next == null:
		return false
	if selected_id != id:
		var previous := selected()
		selected_id = id
		selection_changed.emit(previous, next)
	return true

func remove(id: StringName) -> bool:
	var tab := find_tab(id)
	if tab == null:
		return false
	var index := tabs.find(tab)
	var was_selected := selected_id == id
	tabs.remove_at(index)
	if was_selected:
		selected_id = tabs[mini(index, tabs.size() - 1)].id if not tabs.is_empty() else &""
		selection_changed.emit(tab, selected())
	return true

func to_dict() -> Dictionary:
	var saved := []
	for tab in tabs:
		saved.append(tab.to_dict())
	return {"schema_version": 1, "tabs": saved, "selected_id": String(selected_id)}

# Transactional restore: malformed workspaces cannot partially replace a screen.
func restore(data: Dictionary) -> bool:
	if data.get("schema_version", 0) != 1 or not data.get("tabs", null) is Array:
		return false
	var restored: Array[ScreenContentTab] = []
	var ids := {}
	for entry in data.tabs:
		if not entry is Dictionary:
			return false
		var tab := ScreenContentTab.from_dict(entry)
		if not tab.validate().is_empty() or ids.has(tab.id):
			return false
		ids[tab.id] = true
		restored.append(tab)
	var restored_selection := StringName(str(data.get("selected_id", "")))
	if not restored.is_empty() and not ids.has(restored_selection):
		return false
	if restored.is_empty() and restored_selection != &"":
		return false
	var previous := selected()
	tabs = restored
	selected_id = restored_selection
	selection_changed.emit(previous, selected())
	return true
