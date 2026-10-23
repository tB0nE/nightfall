extends SceneTree

func _init():
	# Black, three particle backgrounds, then the Cinema room.
	var particles := 3
	assert(EnvironmentManager.room_for_background(0, particles) == &"")
	assert(EnvironmentManager.room_for_background(3, particles) == &"")
	assert(EnvironmentManager.room_for_background(4, particles) == EnvironmentManager.CINEMA)
	var labels: Array = load("res://main.gd").new().background_labels
	assert(labels.size() == particles + 2 and labels.back() == "Cinema")
	assert(ResourceLoader.exists(EnvironmentManager.CINEMA_SCENE), "the cinema model is bundled")

	# Without an XR session nothing changes, and the screen isn't held.
	var manager := EnvironmentManager.new(Node3D.new())
	manager.main.set("is_xr_active", false)
	assert(not manager.is_holding_screen())
	manager.main.free()
	print("All environments tests passed")
	quit()
