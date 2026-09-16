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

static func write_host(config: ConfigFile, section: String, host: HostSettings) -> void:
	config.set_value(section, "host_settings_version", HostSettings.HOST_STATE_VERSION)
	config.set_value(section, "fps", host.stream_fps)
	config.set_value(section, "resolution_scale_pct", host.resolution_scale_pct)
	config.set_value(section, "native_resolution", [host.native_resolution.x, host.native_resolution.y])
	config.set_value(section, "is_polaris_host", host.is_polaris_host)
	config.set_value(section, "resolution_idx", host.resolution_idx)
	config.set_value(section, "sbs_mode", host.sbs_mode)
	config.set_value(section, "ai_3d_model", host.ai_3d_model)
	config.set_value(section, "ai_3d_speed", host.ai_3d_speed)
	# Distinguishes the current four-value speed range from the historical five-value range.
	config.set_value(section, "ai_3d_speed_v2", true)
	config.set_value(section, "ai_3d_debug", host.ai_3d_debug)
	config.set_value(section, "ai_3d_last_mode", host.ai_3d_last_mode)
	config.set_value(section, "ai_3d_backend_pref", host.ai_3d_backend_pref)
	config.set_value(section, "ai_3d_hz_cap", host.ai_3d_hz_cap)
	config.set_value(section, "ai_3d_separation_pct", host.ai_3d_separation_pct)
	config.set_value(section, "ai_3d_convergence_pct", host.ai_3d_convergence_pct)
	config.set_value(section, "ai_3d_cursor_position_v2", host.ai_3d_cursor_position)
	config.set_value(section, "ai_3d_depth_sync", host.ai_3d_depth_sync)
	config.set_value(section, "bitrate_idx", host.bitrate_idx)
	config.set_value(section, "double_h", host.double_h)

static func read_host(
		config: ConfigFile,
		section: String,
		host: HostSettings,
		fps_rates: Array,
		resolution_scale_options: Array,
		resolution_count: int,
		ai_model_count: int) -> void:
	host.stream_fps = int(config.get_value(section, "fps", 60))
	if not fps_rates.has(host.stream_fps):
		host.stream_fps = 60
	host.resolution_scale_pct = config.get_value(section, "resolution_scale_pct", 100)
	if not resolution_scale_options.has(host.resolution_scale_pct):
		host.resolution_scale_pct = 100
	var native_arr = config.get_value(section, "native_resolution", [1920, 1080])
	host.native_resolution = Vector2i(native_arr[0], native_arr[1])
	host.is_polaris_host = config.get_value(section, "is_polaris_host", false)
	host.resolution_idx = clampi(config.get_value(section, "resolution_idx", 1), 0, resolution_count - 1)
	host.bitrate_idx = config.get_value(section, "bitrate_idx", -1)
	host.double_h = config.get_value(section, "double_h", false)
	if config.has_section_key(section, "sbs_mode"):
		host.sbs_mode = clampi(config.get_value(section, "sbs_mode", 0), 0, 2)
		if config.has_section_key(section, "ai_3d_speed"):
			# ai_3d_models is back to its original 5-entry indexing (2026-08-28,
			# see its own comment) - no migration needed here, same as before
			# the brief 3-entry detour.
			host.ai_3d_model = clampi(config.get_value(section, "ai_3d_model", 0), 0, ai_model_count - 1)
			host.ai_3d_debug = clampi(config.get_value(section, "ai_3d_debug", 0), 0, 3)
			host.ai_3d_last_mode = clampi(config.get_value(section, "ai_3d_last_mode", 1), 1, 3)
			host.ai_3d_backend_pref = 1 if config.get_value(section, "ai_3d_backend_pref", 2) == 1 else 2
			host.ai_3d_hz_cap = config.get_value(section, "ai_3d_hz_cap", 20)
			if not [12, 15, 20, 30, 40].has(host.ai_3d_hz_cap):
				host.ai_3d_hz_cap = 20
			host.ai_3d_separation_pct = config.get_value(section, "ai_3d_separation_pct", 100)
			if not [50, 75, 100, 125, 150].has(host.ai_3d_separation_pct):
				host.ai_3d_separation_pct = 100
			host.ai_3d_convergence_pct = config.get_value(section, "ai_3d_convergence_pct", 50)
			if not [30, 40, 50, 60, 70].has(host.ai_3d_convergence_pct):
				host.ai_3d_convergence_pct = 50
			if config.has_section_key(section, "ai_3d_cursor_position_v2"):
				host.ai_3d_cursor_position = clampi(config.get_value(section, "ai_3d_cursor_position_v2", 0), -1, 1)
			else:
				# Migrate the short-lived seven-position control: old Default,
				# Right, and Right+ are the new Left, Default, and Right.
				host.ai_3d_cursor_position = clampi(config.get_value(section, "ai_3d_cursor_position", 1) - 1, -1, 1)
			host.ai_3d_depth_sync = bool(config.get_value(section, "ai_3d_depth_sync", false))
			if config.has_section_key(section, "ai_3d_speed_v2"):
				host.ai_3d_speed = clampi(config.get_value(section, "ai_3d_speed", 1), 0, 3)
			else:
				# Migrate the pre-2026-08-25 5-label range (Off/Auto/Fast/
				# Fastest/Standard, 0-4) to the new 4-label range
				# (Off/Auto/Fast/Standard, 0-3) - old index 3 (Fastest,
				# removed - near-identical to Fast on-device) falls back to
				# Fast (new index 2); old index 4 (Standard) shifts down to
				# new index 3. 0/1/2 (Off/Auto/Fast) are unchanged.
				var old_speed = clampi(config.get_value(section, "ai_3d_speed", 1), 0, 4)
				match old_speed:
					3: host.ai_3d_speed = 2 # Fastest -> Fast
					4: host.ai_3d_speed = 3 # Standard (shifted)
					_: host.ai_3d_speed = old_speed # Off/Auto/Fast unchanged
		elif config.has_section_key(section, "ai_3d_model"):
			# Migrate the old 4-control config format (2026-08-24 collapse to
			# two controls - see settings_controller.gd's ai_3d_speed_labels/
			# ai_3d_models comment) - old ai_3d_model was 0=Off plus 8 models
			# in a different order (Off, MiDaS-192, YOLO-256/320/384,
			# MiDaS-256, MiDaS-256-GPU, DA-V2-196/252); old ai_3d_quality was
			# 0=Auto/1=Fastest/2=Fast/3=Standard, with no on/off state of its
			# own (that lived in ai_3d_model==0 instead).
			var old_model = clampi(config.get_value(section, "ai_3d_model", 0), 0, 8)
			var old_quality = clampi(config.get_value(section, "ai_3d_quality", 0), 0, 3)
			host.ai_3d_debug = clampi(config.get_value(section, "ai_3d_debug", 0), 0, 3)
			if old_model == 0:
				host.ai_3d_speed = 0
				host.ai_3d_model = 0
			else:
				match old_quality:
					1: host.ai_3d_speed = 2 # Fastest -> Fast (removed 2026-08-25)
					2: host.ai_3d_speed = 2 # Fast
					3: host.ai_3d_speed = 3 # Standard
					_: host.ai_3d_speed = 1 # Auto
				match old_model:
					1: host.ai_3d_model = 2 # MiDaS-192
					2: host.ai_3d_model = 3 # YOLO26-N-256 (removed, fallback MiDaS-256)
					3: host.ai_3d_model = 3 # YOLO26-N-320 (removed, fallback MiDaS-256)
					4: host.ai_3d_model = 3 # YOLO26-N-384 (removed, fallback MiDaS-256)
					5: host.ai_3d_model = 3 # MiDaS-256
					6: host.ai_3d_model = 0 # MiDaS-256-GPU
					7: host.ai_3d_model = 4 # DA-V2-196 (removed, fallback DA-V2-252)
					8: host.ai_3d_model = 4 # DA-V2-252
					_: host.ai_3d_model = 3 # MiDaS-256 (fallback)
		elif config.has_section_key(section, "ai_3d_mode"):
			# Migrate the old flat 0-6 "3D AI" cycle (2026-08-18 split into
			# independent controls) - 0=Off, 1=Fast, 2=Standard, 3=Fastest,
			# 4-6=DMap/-Raw/-Input debug views (always at Standard quality,
			# since the old scheme had no independent quality selection for
			# them). Lands on MiDaS-192 (model index 1) same as the
			# 2026-08-18 migration always did.
			var old = clampi(config.get_value(section, "ai_3d_mode", 0), 0, 6)
			host.ai_3d_debug = 0 if old < 4 else old - 3
			if old == 0:
				host.ai_3d_speed = 0
				host.ai_3d_model = 0
			else:
				host.ai_3d_model = 2 # MiDaS-192
				match old:
					1: host.ai_3d_speed = 2 # Fast
					3: host.ai_3d_speed = 2 # Fastest -> Fast (removed 2026-08-25)
					_: host.ai_3d_speed = 3 # Standard (old modes 0, 2, 4-6)
	elif config.has_section_key(section, "stereo_mode"):
		var old = clampi(config.get_value(section, "stereo_mode", 0), 0, 4)
		if old <= 2:
			host.sbs_mode = old
			host.ai_3d_speed = 0
		else:
			host.sbs_mode = 0
			host.ai_3d_model = 2 # MiDaS-192
			host.ai_3d_speed = 1 # Auto
