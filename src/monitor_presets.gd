class_name MonitorPresets
extends RefCounted

# Preset JSON schema (shared by built-in and user-saved presets):
# {
#   "version": 1,
#   "id": "default_2_side_by_side",
#   "built_in": true,
#   "screen_count": 2,
#   "screens": [
#     {"is_primary": true,  "grid_mode": true,  "grid_pos": [2, 1], "free_pos": null,          "free_rot": null},
#     {"is_primary": false, "grid_mode": false, "grid_pos": null,   "free_pos": [1.4,0.1,-0.6], "free_rot": [0,0.3,0]}
#   ]
# }
# Screens are addressed purely by ordinal position (primary first, then array
# order) - never by real monitor id/label - so presets stay portable across
# different hosts/monitor manifests. No curvature field: curvature is the
# single existing global setting (main.curvature), applied as-is at Apply
# time, orthogonal to presets. Presets have no display name - they're
# identified by their rendered grid picture, not text.

const CUSTOM_PRESETS_PATH := "user://monitor_presets_custom.json"
const DEFAULT_PRESETS_SNAPSHOT_PATH := "user://monitor_presets_default.json"


static func _screen(is_primary: bool, gx: int, gy: int) -> Dictionary:
	return {
		"is_primary": is_primary,
		"grid_mode": true,
		"grid_pos": [gx, gy],
		"free_pos": null,
		"free_rot": null,
	}


static func _default(id: String, screens: Array) -> Dictionary:
	return {
		"version": 1,
		"id": id,
		"built_in": true,
		"screen_count": screens.size(),
		"screens": screens,
	}


# The 8 default presets, verbatim from the spec ([gx,gy] = top-left block of
# each screen's 2x2 footprint on the 8x4 grid, first entry is always primary).
# Compiled into the app (const, not loaded from a file) so a runtime bug or a
# corrupted user:// file can never take these out - see
# write_default_presets_snapshot() for the separate, non-authoritative,
# on-device-inspectable mirror of this data.
static func default_presets() -> Array:
	return [
		_default("default_1_single", [
			_screen(true, 3, 1),
		]),
		_default("default_2_side_by_side", [
			_screen(true, 2, 1),
			_screen(false, 4, 1),
		]),
		_default("default_2_stacked", [
			_screen(true, 3, 2),
			_screen(false, 3, 0),
		]),
		_default("default_3_row", [
			_screen(true, 3, 1),
			_screen(false, 1, 1),
			_screen(false, 5, 1),
		]),
		_default("default_3_two_over_one", [
			_screen(true, 3, 2),
			_screen(false, 2, 0),
			_screen(false, 4, 0),
		]),
		_default("default_4_one_over_three", [
			_screen(true, 3, 2),
			_screen(false, 3, 0),
			_screen(false, 1, 2),
			_screen(false, 5, 2),
		]),
		_default("default_4_grid", [
			_screen(true, 2, 2),
			_screen(false, 4, 0),
			_screen(false, 2, 0),
			_screen(false, 4, 2),
		]),
		_default("default_4_row", [
			_screen(true, 0, 1),
			_screen(false, 2, 1),
			_screen(false, 4, 1),
			_screen(false, 6, 1),
		]),
	]


static func load_custom_presets() -> Array:
	if not FileAccess.file_exists(CUSTOM_PRESETS_PATH):
		return []
	var f = FileAccess.open(CUSTOM_PRESETS_PATH, FileAccess.READ)
	if not f:
		return []
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary and parsed.get("presets") is Array:
		return parsed["presets"]
	return []


static func save_custom_presets(presets: Array) -> void:
	var f = FileAccess.open(CUSTOM_PRESETS_PATH, FileAccess.WRITE)
	if not f:
		return
	f.store_string(JSON.stringify({"version": 1, "presets": presets}))
	f.close()


# Purely for on-device inspectability (adb/file manager) - this file is never
# read back, so a corrupted copy of it can never break anything; default_presets()
# above (compiled into the app) is the sole source of truth for built-ins.
static func write_default_presets_snapshot() -> void:
	var f = FileAccess.open(DEFAULT_PRESETS_SNAPSHOT_PATH, FileAccess.WRITE)
	if not f:
		return
	f.store_string(JSON.stringify({"version": 1, "presets": default_presets()}))
	f.close()


static func all_presets() -> Array:
	var out := default_presets()
	out.append_array(load_custom_presets())
	return out


static func find_preset(id: String) -> Dictionary:
	for p in all_presets():
		if p.get("id", "") == id:
			return p
	return {}


static func next_custom_id(existing_customs: Array) -> String:
	var used := {}
	for p in existing_customs:
		used[p.get("id", "")] = true
	var n := 1
	while used.has("custom_%d" % n):
		n += 1
	return "custom_%d" % n


static func remove_custom_preset(id: String) -> bool:
	var customs = load_custom_presets()
	var filtered := []
	var removed := false
	for p in customs:
		if p.get("id", "") == id:
			removed = true
		else:
			filtered.append(p)
	if removed:
		save_custom_presets(filtered)
	return removed
