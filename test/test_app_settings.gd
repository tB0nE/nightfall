extends SceneTree

func _init():
	_test_display_defaults()
	_test_display_reset()
	_test_general_defaults_and_reset()
	_test_host_defaults()
	_test_platform_policy()
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

func _test_host_defaults() -> void:
	var host := AppSettings.new().host
	assert(host.stream_fps == 60)
	assert(host.resolution_scale_pct == 100)
	assert(host.native_resolution == Vector2i(1920, 1080))
	assert(not host.is_polaris_host)
	assert(host.resolution_idx == 1)
	assert(host.bitrate_idx == -1)
	assert(not host.double_h)
	assert(host.sbs_mode == 0)
	assert(host.ai_3d_model == 0)
	assert(host.ai_3d_speed == 0)
	assert(host.ai_3d_debug == 0)
	assert(host.ai_3d_last_mode == 1)
	assert(host.ai_3d_backend_pref == 2)
	assert(host.ai_3d_hz_cap == 20)
	assert(host.ai_3d_separation_pct == 100)
	assert(host.ai_3d_convergence_pct == 50)
	assert(host.ai_3d_cursor_position == 0)

func _test_platform_policy() -> void:
	assert(SettingsPlatformPolicy.ai3d_options_locked("Android"))
	assert(not SettingsPlatformPolicy.ai3d_options_locked("Linux"))
	assert(SettingsPlatformPolicy.depth_gpu_priority_available("Android"))
	assert(not SettingsPlatformPolicy.depth_gpu_priority_available("Linux"))
	var labels := ["0%", "10%", "20%", "30%", "40%", "50%", "Runtime", "Runtime Quality"]
	assert(SettingsPlatformPolicy.sharpen_choices("Android", 6, 7, labels.size()) == [0, 6, 7])
	assert(SettingsPlatformPolicy.sharpen_choices("Linux", 6, 7, labels.size()) == range(8))
	assert(SettingsPlatformPolicy.sharpen_label("Android", 6, 6, 7, labels) == "Runtime")
	assert(SettingsPlatformPolicy.sharpen_label("Android", 7, 6, 7, labels) == "Runtime Quality")
	assert(SettingsPlatformPolicy.sharpen_label("Android", 4, 6, 7, labels) == "Off")
	assert(SettingsPlatformPolicy.sharpen_label("Linux", 4, 6, 7, labels) == "40%")

func _test_general_defaults_and_reset() -> void:
	var settings := AppSettings.new()
	settings.cursor_mode = 0
	settings.pointer_steady = 3
	settings.double_click_mode = 1
	settings.tracking_mode = 1
	settings.codec_preference = 3
	settings.grid_mode_enabled = false
	settings.performance_overlay_enabled = true
	settings.ai_3d_gpu_priority = 1
	settings.auto_reconnect_enabled = false
	settings.quick_start_enabled = true
	settings.idle_timeout_min = 60
	settings.pipewire_restore_token = "token"

	settings.reset_general()
	assert(settings.cursor_mode == 1)
	assert(settings.pointer_steady == 1)
	assert(settings.double_click_mode == 0)
	assert(settings.tracking_mode == 0)
	assert(settings.codec_preference == 1)
	assert(settings.grid_mode_enabled)
	assert(not settings.performance_overlay_enabled)
	assert(settings.ai_3d_gpu_priority == 0)
	assert(settings.auto_reconnect_enabled)
	assert(not settings.quick_start_enabled)
	assert(settings.idle_timeout_min == 0)
	assert(settings.pipewire_restore_token.is_empty())

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
