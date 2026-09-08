extends SceneTree

func _init():
	_test_display_defaults()
	_test_display_reset()
	print("All app_settings tests passed")
	quit()

func _test_display_defaults() -> void:
	var settings := AppSettings.new()
	assert(settings.bezel_enabled)
	assert(not settings.passthrough_enabled)
	assert(settings.background_mode == 0)
	assert(settings.sharpen_mode == 0)
	assert(settings.brightness_pct == 0)
	assert(settings.contrast_pct == 100)
	assert(settings.gamma_pct == 100)
	assert(settings.ambient_mode == 0)
	assert(settings.ambient_color == 0)

func _test_display_reset() -> void:
	var settings := AppSettings.new()
	settings.bezel_enabled = false
	settings.passthrough_enabled = true
	settings.background_mode = 3
	settings.sharpen_mode = 7
	settings.brightness_pct = 20
	settings.contrast_pct = 150
	settings.gamma_pct = 50
	settings.ambient_mode = 3
	settings.ambient_color = 5

	settings.reset_display()
	assert(settings.bezel_enabled)
	assert(not settings.passthrough_enabled)
	assert(settings.background_mode == 0)
	assert(settings.sharpen_mode == 0)
	assert(settings.brightness_pct == 0)
	assert(settings.contrast_pct == 100)
	assert(settings.gamma_pct == 100)
	assert(settings.ambient_mode == 0)
	assert(settings.ambient_color == 0)
