extends SceneTree

class Sources extends ScreenSources:
	func is_browser_screen(screen: VRScreen) -> bool:
		return screen != null and screen.get_meta(&"test_browser", false)

func _init() -> void:
	var owner = load("res://main.gd").new()
	owner.screen_sources = Sources.new(owner)
	var screen := VRScreen.new()
	owner.settings.cursor_mode = AppSettings.CURSOR_MODE_HIDDEN
	# A welcome screen has no host pointer to replace the hidden VR pointer.
	assert(not owner.hides_screen_cursor(screen))
	assert(owner.screen_cursor_mode(screen) == 0)
	owner.session_lifecycle.media_active = true
	assert(owner.hides_screen_cursor(screen))
	# A browser retains a circle even alongside a live desktop stream.
	screen.set_meta(&"test_browser", true)
	assert(not owner.hides_screen_cursor(screen))
	assert(owner.screen_cursor_mode(screen) == 0)
	assert(owner.screen_cursor_mode(null) == 0)
	owner.settings.cursor_mode = 1
	assert(owner.screen_cursor_mode(screen) == 1)
	screen.free()
	owner.free()
	print("All cursor visibility tests passed")
	quit()
