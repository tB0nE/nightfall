extends SceneTree
const Monitor = preload("res://test/fixtures/meteor_xr_godot/main.gd")

func _init() -> void:
	var node := Monitor.new()
	node.legacy_monitor = false
	var path := "user://diagnostic-ledger-test.jsonl"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("first\npartial")
	file.close()
	assert(node._count_encoded_lines(path) == 1)
	assert(node._count_encoded_lines(path) == 1) # No reread/recount.
	file = FileAccess.open(path, FileAccess.READ_WRITE)
	file.seek_end()
	file.store_string(" end\nthird\n")
	file.close()
	assert(node._count_encoded_lines(path) == 3)
	assert(node.monitor_bytes == FileAccess.get_file_as_bytes(path).size())
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("short\n")
	file.close()
	assert(node._count_encoded_lines(path) == -1)
	node.ledger_position = 0
	node.ledger_lines = 0
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("x".repeat(131072) + "\n")
	file.close()
	assert(node._count_encoded_lines(path) == 0) # Read cap bisects the record.
	assert(node._count_encoded_lines(path) == 1)
	assert(node._count_encoded_lines(path) == 1)
	DirAccess.remove_absolute(path)
	node.free()
	print("All xr_diagnostic_ledger tests passed")
	quit()
