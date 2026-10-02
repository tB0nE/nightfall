extends SceneTree

func _init():
	_test_order_apps()
	print("All welcome_screen tests passed")
	quit()

func _names(apps: Array) -> Array:
	var names := []
	for app in apps:
		names.append(app["name"])
	return names

func _test_order_apps() -> void:
	var host_order := [
		{"name": "Photoshop", "id": 3},
		{"name": "Steam Big Picture", "id": 2},
		{"name": "Hades", "id": 4},
		{"name": "Desktop", "id": 1},
		{"name": "Celeste", "id": 5},
	]
	assert(_names(WelcomeScreen.order_apps(host_order)) == ["Desktop", "Steam Big Picture", "Photoshop", "Hades", "Celeste"])
	# Missing entries just fall through; case and whitespace don't matter.
	assert(_names(WelcomeScreen.order_apps([{"name": "Zed"}, {"name": " steam "}, {"name": "Alpha"}])) == [" steam ", "Zed", "Alpha"])
	assert(WelcomeScreen.order_apps([]).is_empty())
