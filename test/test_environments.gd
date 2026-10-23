extends SceneTree

func _init():
	# Black, three particle backgrounds, the Cinema, then the user's own room.
	var particles := 3
	assert(EnvironmentManager.room_for_background(0, particles) == &"")
	assert(EnvironmentManager.room_for_background(3, particles) == &"")
	assert(EnvironmentManager.room_for_background(4, particles) == EnvironmentManager.CINEMA)
	assert(EnvironmentManager.room_for_background(5, particles) == EnvironmentManager.CUSTOM)
	var main_node = load("res://main.gd").new()
	var labels: Array = main_node.background_labels
	main_node.free()
	assert(labels.size() == particles + 3 and labels[4] == "Cinema" and labels[5] == "Your Room")
	assert(ResourceLoader.exists(EnvironmentManager.CINEMA_SCENE), "the cinema model is bundled")

	# Cycling skips Your Room until one is imported.
	assert(SettingsController.next_background(4, 6, particles, false) == 0)
	assert(SettingsController.next_background(4, 6, particles, true) == 5)
	assert(SettingsController.next_background(5, 6, particles, true) == 0)

	# Without an XR session nothing changes, and the screen isn't held.
	var manager := EnvironmentManager.new(Node3D.new())
	manager.main.set("is_xr_active", false)
	assert(not manager.is_holding_screen())
	manager.main.free()

	_test_custom_room()
	print("All environments tests passed")
	quit()

# A .glb written by Godot loads back with its triangles counted and bounds
# measured, so it can be stood on the floor.
func _test_custom_room() -> void:
	assert(EnvironmentManager.load_custom_room("user://no_such_room.glb").has("error"))
	var root := Node3D.new()
	root.name = "Room"
	var floor := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4, 2, 6)
	floor.mesh = box
	floor.position = Vector3(1, 3, 0)
	root.add_child(floor)
	floor.owner = root
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	assert(document.append_from_scene(root, state) == OK)
	var path := "user://test_room.glb"
	assert(document.write_to_filesystem(state, path) == OK)
	root.free()

	var loaded := EnvironmentManager.load_custom_room(path)
	assert(not loaded.has("error"), str(loaded.get("error", "")))
	assert(loaded.triangles == 12, "a box has 12 triangles, got %d" % loaded.triangles)
	var bounds: AABB = loaded.bounds
	assert(bounds.position.is_equal_approx(Vector3(-1, 2, -3)) and bounds.size.is_equal_approx(Vector3(4, 2, 6)))
	loaded.node.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var not_glb := FileAccess.open("user://not_a_room.glb", FileAccess.WRITE)
	not_glb.store_string("hello")
	not_glb.close()
	assert(EnvironmentManager.load_custom_room("user://not_a_room.glb").has("error"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://not_a_room.glb"))
