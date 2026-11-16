extends SceneTree

class FakeSources extends RefCounted:
	func is_browser_screen(screen): return String(screen.monitor_id).begins_with("browser:")

class LayoutOwner extends Node3D:
	const MAX_SCREENS := 4
	var screens: Array[VRScreen] = []
	var screen_sources := FakeSources.new()
	var layout := ScreenLayout.single(Vector2i(2560, 1440))
	var _staged_physical_count := 2
	var _staged_virtual_count := 0
	var _staged_preset_id: StringName = &""
	func _log(_message): pass

func _init():
	_test_default_presets_shape()
	_test_default_ids_unique()
	_test_json_round_trip()
	_test_custom_preset_file_round_trip()
	_test_browser_layout_budget()
	_test_add_keeps_existing_outputs()
	print("All monitor_presets tests passed")
	quit()

func _test_add_keeps_existing_outputs():
	var owner := LayoutOwner.new()
	owner.layout = ScreenLayout.new()
	owner.layout.frame_size = Vector2i(5760,1080)
	owner.layout.desktop_bounds = Rect2i(0,0,5760,1080)
	for i in 3:
		var monitor := ScreenLayout.MonitorSpec.new()
		monitor.id = StringName("m%d" % i)
		monitor.frame_rect = Rect2i(i * 1920,0,1920,1080)
		monitor.desktop_rect = monitor.frame_rect
		monitor.enabled = i == 2
		monitor.is_primary = i == 2
		owner.layout.monitors.append(monitor)
	var controller := SettingsController.new(owner)
	var target := controller._build_staged_layout(true)
	assert(target.enabled_monitors().size() == 2)
	assert(target.get_primary().id == &"m2", "Adding an output must retain the current primary")
	var enabled := []
	for monitor in target.enabled_monitors(): enabled.append(monitor.id)
	assert(enabled.has(&"m2") and enabled.has(&"m0"), "Add must retain the active rightmost output and pick one spare")
	var legacy := controller._build_staged_layout()
	assert(legacy.get_primary().id == &"m0", "Existing Screens count selection keeps its original ordering")
	owner._staged_physical_count = 1
	owner._staged_virtual_count = 1
	target = controller._build_staged_layout(true)
	assert(target.get_primary().id == &"m2", "Adding a virtual screen must not replace the physical source")
	controller._monitor_selection_override = [&"m1"]
	target = controller._build_staged_layout(true)
	assert(target.enabled_monitors()[0].id == &"m1", "Close must preserve the requested surviving output, not choose the leftmost")
	owner.free()

func _test_browser_layout_budget():
	var owner := LayoutOwner.new()
	for id in ["m0", "m1", "browser:1"]:
		var screen := VRScreen.new()
		screen.monitor_id = StringName(id)
		owner.screens.append(screen)
	var second := ScreenLayout.MonitorSpec.new()
	second.id = &"m1"
	second.capturable = true
	second.frame_rect = Rect2i(2560, 0, 1920, 1080)
	second.desktop_rect = second.frame_rect
	owner.layout.monitors.append(second)
	var controller := SettingsController.new(owner)
	assert(controller.browser_screen_count() == 1)
	assert(controller.staged_total() == 3, "Two monitors and a browser need three-screen presets")
	controller.stage_virtual_count(3)
	assert(owner._staged_virtual_count == 1, "Browser must reserve its screen slot")
	assert(controller.staged_total() == 4)
	var browser := VRScreen.new()
	browser.monitor_id = &"browser:2"
	owner.screens.append(browser)
	controller.stage_monitor_count(2)
	assert(owner._staged_virtual_count == 0)
	assert(controller.staged_total() == 4, "Two monitors and two browsers fill the shared budget")
	var target := controller._build_staged_layout()
	assert(target.enabled_monitors().size() == 2, "Browsers must not become host capture outputs")
	owner.screens.pop_back().free()
	assert(controller.staged_total() == 3, "Closing a browser must restore the three-screen preset count")
	for screen in owner.screens: screen.free()
	owner.free()

func _test_default_presets_shape():
	var presets = MonitorPresets.default_presets()
	assert(presets.size() == 8)
	for p in presets:
		assert(p.get("built_in") == true)
		var screens: Array = p.get("screens", [])
		assert(screens.size() == p.get("screen_count"))
		var primary_count = 0
		for s in screens:
			if s.get("is_primary"):
				primary_count += 1
			assert(s.get("grid_mode") == true)
			var gp: Array = s.get("grid_pos")
			assert(MonitorGrid.cell_in_bounds(gp[0], gp[1]))
		assert(primary_count == 1)

func _test_default_ids_unique():
	var presets = MonitorPresets.default_presets()
	var ids := {}
	for p in presets:
		assert(not ids.has(p["id"]))
		ids[p["id"]] = true

func _test_json_round_trip():
	var presets = MonitorPresets.default_presets()
	for p in presets:
		var json = JSON.stringify(p)
		var back = JSON.parse_string(json)
		assert(back["id"] == p["id"])
		assert(back["screens"].size() == p["screens"].size())

func _test_custom_preset_file_round_trip():
	# Uses a throwaway id derived from whatever's really on disk, and restores
	# the original file contents at the end, so running tests never corrupts
	# or leaves behind real saved presets on the dev machine.
	var before = MonitorPresets.load_custom_presets()
	var test_id = MonitorPresets.next_custom_id(before)
	var entry = {
		"version": 1,
		"id": test_id,
		"built_in": false,
		"screen_count": 1,
		"screens": [{"is_primary": true, "grid_mode": true, "grid_pos": [3, 1], "free_pos": null, "free_rot": null}],
	}
	var updated = before.duplicate()
	updated.append(entry)
	MonitorPresets.save_custom_presets(updated)
	var loaded = MonitorPresets.load_custom_presets()
	var found = false
	for p in loaded:
		if p.get("id") == test_id:
			found = true
	assert(found)
	assert(MonitorPresets.remove_custom_preset(test_id))
	var after = MonitorPresets.load_custom_presets()
	for p in after:
		assert(p.get("id") != test_id)
	MonitorPresets.save_custom_presets(before)
