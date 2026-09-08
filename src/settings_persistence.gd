class_name SettingsPersistence
extends RefCounted

## ConfigFile encoding and legacy migrations for typed settings objects.
## This codec does not touch UI, renderers, stream sessions, or filesystem paths.

const BRIGHTNESS_VALUES: Array = [-20, -10, 0, 10, 20]
const PICTURE_SCALE_VALUES: Array = [50, 75, 100, 125, 150]

static func write_app(config: ConfigFile, settings: AppSettings) -> void:
	config.set_value("meta", "settings_version", AppSettings.APP_STATE_VERSION)
	config.set_value("screen", "bezel", settings.bezel_enabled)
	config.set_value("screen", "passthrough_enabled", settings.passthrough_enabled)
	config.set_value("screen", "background_mode", settings.background_mode)
	config.set_value("screen", "sharpen_mode", settings.sharpen_mode)
	config.set_value("screen", "brightness_pct", settings.brightness_pct)
	config.set_value("screen", "contrast_pct", settings.contrast_pct)
	config.set_value("screen", "gamma_pct", settings.gamma_pct)
	config.set_value("screen", "ambient_mode", settings.ambient_mode)
	config.set_value("screen", "ambient_color", settings.ambient_color)
	config.set_value("screen", "cursor_mode", settings.cursor_mode)
	config.set_value("screen", "pointer_steady", settings.pointer_steady)
	config.set_value("screen", "double_click_mode", settings.double_click_mode)
	config.set_value("screen", "codec_preference", settings.codec_preference)
	config.set_value("screen", "grid_mode_enabled", settings.grid_mode_enabled)
	config.set_value("diagnostics", "performance_overlay", settings.performance_overlay_enabled)
	config.set_value("ai_3d", "gpu_priority", settings.ai_3d_gpu_priority)
	config.set_value("controller", "hand_tracking_enabled", settings.tracking_mode)
	config.set_value("stream", "auto_reconnect", settings.auto_reconnect_enabled)
	config.set_value("stream", "quick_start", settings.quick_start_enabled)
	config.set_value("stream", "idle_timeout_min", settings.idle_timeout_min)
	config.set_value("local_capture", "restore_token", settings.pipewire_restore_token)

static func read_app(
		config: ConfigFile,
		settings: AppSettings,
		passthrough_supported: bool,
		sharpen_choices: Array) -> Dictionary:
	settings.bezel_enabled = config.get_value(
		"screen", "bezel", AppSettings.DEFAULT_BEZEL_ENABLED)
	settings.background_mode = config.get_value(
		"screen", "background_mode", AppSettings.DEFAULT_BACKGROUND_MODE)

	var result := {"current_passthrough_value": null}
	# The current key takes precedence when both formats exist. Old files stored
	# passthrough and background together as 0=on, 1-5=background while off.
	if config.has_section_key("screen", "passthrough_enabled"):
		var raw_saved = config.get_value(
			"screen", "passthrough_enabled", AppSettings.DEFAULT_PASSTHROUGH_ENABLED)
		settings.passthrough_enabled = raw_saved and passthrough_supported
		result.current_passthrough_value = raw_saved
	elif config.has_section_key("screen", "passthrough"):
		var old := clampi(config.get_value("screen", "passthrough", 0), 0, 5)
		if passthrough_supported:
			settings.passthrough_enabled = old == 0
			settings.background_mode = maxi(old - 1, 0)
		else:
			settings.passthrough_enabled = false
			settings.background_mode = old
	else:
		settings.passthrough_enabled = AppSettings.DEFAULT_PASSTHROUGH_ENABLED

	var max_sharpen_mode: int = sharpen_choices.max() if not sharpen_choices.is_empty() else 0
	settings.sharpen_mode = clampi(config.get_value(
		"screen", "sharpen_mode", AppSettings.DEFAULT_SHARPEN_MODE), 0, max_sharpen_mode)
	if not sharpen_choices.has(settings.sharpen_mode):
		settings.sharpen_mode = AppSettings.DEFAULT_SHARPEN_MODE
	settings.brightness_pct = config.get_value(
		"screen", "brightness_pct", AppSettings.DEFAULT_BRIGHTNESS_PCT)
	if not BRIGHTNESS_VALUES.has(settings.brightness_pct):
		settings.brightness_pct = AppSettings.DEFAULT_BRIGHTNESS_PCT
	settings.contrast_pct = config.get_value(
		"screen", "contrast_pct", AppSettings.DEFAULT_CONTRAST_PCT)
	if not PICTURE_SCALE_VALUES.has(settings.contrast_pct):
		settings.contrast_pct = AppSettings.DEFAULT_CONTRAST_PCT
	settings.gamma_pct = config.get_value(
		"screen", "gamma_pct", AppSettings.DEFAULT_GAMMA_PCT)
	if not PICTURE_SCALE_VALUES.has(settings.gamma_pct):
		settings.gamma_pct = AppSettings.DEFAULT_GAMMA_PCT
	settings.ambient_mode = clampi(
		config.get_value("screen", "ambient_mode", AppSettings.DEFAULT_AMBIENT_MODE), 0, 3)
	settings.ambient_color = clampi(
		config.get_value("screen", "ambient_color", AppSettings.DEFAULT_AMBIENT_COLOR), 0, 5)
	settings.cursor_mode = config.get_value(
		"screen", "cursor_mode", AppSettings.DEFAULT_CURSOR_MODE)
	var saved_steady = config.get_value(
		"screen", "pointer_steady", AppSettings.DEFAULT_POINTER_STEADY)
	if saved_steady is bool:
		settings.pointer_steady = 1 if saved_steady else 0
	else:
		settings.pointer_steady = clampi(int(saved_steady), 0, 3)
	settings.double_click_mode = clampi(config.get_value(
		"screen", "double_click_mode", AppSettings.DEFAULT_DOUBLE_CLICK_MODE), 0, 1)
	settings.codec_preference = config.get_value(
		"screen", "codec_preference", AppSettings.DEFAULT_CODEC_PREFERENCE)
	settings.grid_mode_enabled = config.get_value(
		"screen", "grid_mode_enabled", AppSettings.DEFAULT_GRID_MODE_ENABLED)
	settings.performance_overlay_enabled = config.get_value(
		"diagnostics", "performance_overlay", AppSettings.DEFAULT_PERFORMANCE_OVERLAY_ENABLED)
	settings.ai_3d_gpu_priority = clampi(config.get_value(
		"ai_3d", "gpu_priority", AppSettings.DEFAULT_AI_3D_GPU_PRIORITY), 0, 1)
	var raw_tracking = config.get_value(
		"controller", "hand_tracking_enabled", AppSettings.DEFAULT_TRACKING_MODE)
	settings.tracking_mode = (1 if raw_tracking else 0) if raw_tracking is bool else int(raw_tracking)
	settings.auto_reconnect_enabled = config.get_value(
		"stream", "auto_reconnect", AppSettings.DEFAULT_AUTO_RECONNECT_ENABLED)
	settings.quick_start_enabled = config.get_value(
		"stream", "quick_start", AppSettings.DEFAULT_QUICK_START_ENABLED)
	settings.idle_timeout_min = config.get_value(
		"stream", "idle_timeout_min", AppSettings.DEFAULT_IDLE_TIMEOUT_MIN)
	settings.pipewire_restore_token = config.get_value(
		"local_capture", "restore_token", AppSettings.DEFAULT_PIPEWIRE_RESTORE_TOKEN)
	return result
