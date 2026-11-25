extends SceneTree

func _init():
	assert(AppInfo.source_url() == "https://github.com/tB0nE/nightfall")
	# The desktop doesn't know its version: just the name.
	assert(AppInfo.title() == AppInfo.NAME)
	print("All app info tests passed")
	quit()
