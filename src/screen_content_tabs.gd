class_name ScreenContentTabs
extends RefCounted

signal selection_changed(previous: ScreenContentTab, current: ScreenContentTab)
signal tabs_changed

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
	tabs_changed.emit()
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
	tabs_changed.emit()
	return true

## Browser metadata is a partial update to a mixed source list. Keep existing
## tab objects (including their settings), and never steal a monitor selection.
func sync_browser_pages(pages: Array, selected_page: int) -> void:
	if pages.is_empty(): return # Opening/error snapshots are not a close event.
	var previous := selected()
	var keep := {}
	for page in pages:
		if not page is Dictionary or int(page.get("id", 0)) <= 0: continue
		var id := StringName("browser:page:%d" % int(page.id))
		keep[id] = true
		var tab := find_tab(id)
		if tab == null:
			tab = ScreenContentTab.new()
			tab.id = id
			tab.kind = ScreenContentTab.BROWSER
			tab.locator = {"url": "about:blank"}
			add(tab, false)
		tab.title = str(page.get("title", "Browser"))
	if keep.is_empty(): return
	for tab in tabs.duplicate():
		if tab.kind == ScreenContentTab.BROWSER and not keep.has(tab.id): remove(tab.id)
	if previous == null or previous.kind == ScreenContentTab.BROWSER:
		select(StringName("browser:page:%d" % selected_page))
	tabs_changed.emit()

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
	tabs_changed.emit()
	selection_changed.emit(previous, selected())
	return true
