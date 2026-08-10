extends SceneTree

func _init():
	_test_default_presets_shape()
	_test_default_ids_unique()
	_test_json_round_trip()
	_test_custom_preset_file_round_trip()
	print("All monitor_presets tests passed")
	quit()

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
