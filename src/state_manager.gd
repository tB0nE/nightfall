class_name StateManager
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func save_state():
	var save = ConfigFile.new()
	save.set_value("meta", "settings_version", AppSettings.APP_STATE_VERSION)
	save.set_value("screen", "bezel", main.settings.bezel_enabled)
	save.set_value("screen", "curvature", main.curvature)
	save.set_value("screen", "passthrough_enabled", main.settings.passthrough_enabled)
	save.set_value("screen", "background_mode", main.settings.background_mode)
	save.set_value("screen", "sharpen_mode", main.settings.sharpen_mode)
	save.set_value("screen", "brightness_pct", main.settings.brightness_pct)
	save.set_value("screen", "contrast_pct", main.settings.contrast_pct)
	save.set_value("screen", "gamma_pct", main.settings.gamma_pct)
	save.set_value("screen", "ambient_mode", main.settings.ambient_mode)
	save.set_value("screen", "ambient_color", main.settings.ambient_color)
	save.set_value("screen", "cursor_mode", main.settings.cursor_mode)
	save.set_value("screen", "pointer_steady", main.settings.pointer_steady)
	save.set_value("screen", "double_click_mode", main.settings.double_click_mode)
	save.set_value("screen", "codec_preference", main.settings.codec_preference)
	save.set_value("screen", "grid_mode_enabled", main.settings.grid_mode_enabled)
	save.set_value("diagnostics", "performance_overlay", main.settings.performance_overlay_enabled)
	save.set_value("ai_3d", "gpu_priority", main.settings.ai_3d_gpu_priority)
	save.set_value("controller", "active", main.controller_mapper.active)
	save.set_value("controller", "ctrl_type", main.controller_mapper.ctrl_type)
	save.set_value("controller", "btn_toggle", main.controller_mapper.btn_toggle)
	save.set_value("controller", "primary_hand", main.controller_mapper.primary_hand)
	save.set_value("controller", "hand_tracking_enabled", main.settings.tracking_mode)
	save.set_value("stream", "auto_reconnect", main.settings.auto_reconnect_enabled)
	save.set_value("stream", "quick_start", main.settings.quick_start_enabled)
	save.set_value("stream", "idle_timeout_min", main.settings.idle_timeout_min)
	save.set_value("local_capture", "restore_token", main.settings.pipewire_restore_token)
	save.save("user://app_state.cfg")
	save_host_state()

func save_host_state():
	var ip = main.get_node("%IPInput").text
	if ip.is_empty():
		return
	var save = ConfigFile.new()
	save.load("user://host_state.cfg")
	var host: HostSettings = main.settings.host
	save.set_value(ip, "host_settings_version", HostSettings.HOST_STATE_VERSION)
	save.set_value(ip, "fps", host.stream_fps)
	save.set_value(ip, "resolution_scale_pct", host.resolution_scale_pct)
	save.set_value(ip, "native_resolution", [host.native_resolution.x, host.native_resolution.y])
	save.set_value(ip, "is_polaris_host", host.is_polaris_host)
	save.set_value(ip, "resolution_idx", host.resolution_idx)
	save.set_value(ip, "sbs_mode", host.sbs_mode)
	save.set_value(ip, "ai_3d_model", host.ai_3d_model)
	save.set_value(ip, "ai_3d_speed", host.ai_3d_speed)
	# Marks the post-Fastest-removal ai_3d_speed range (0-3, was 0-4) -
	# 2026-08-25. The key name is unchanged so has_section_key(ip,
	# "ai_3d_speed") alone can't tell an old-range save from a new one; this
	# marker disambiguates. See load_host_state()'s migration below.
	save.set_value(ip, "ai_3d_speed_v2", true)
	save.set_value(ip, "ai_3d_debug", host.ai_3d_debug)
	# AI 3D tab (2026-08-28) - new fields, no migration needed (ai_3d_models
	# itself kept its original 5-entry indexing, see its own comment).
	save.set_value(ip, "ai_3d_last_mode", host.ai_3d_last_mode)
	save.set_value(ip, "ai_3d_backend_pref", host.ai_3d_backend_pref)
	save.set_value(ip, "ai_3d_hz_cap", host.ai_3d_hz_cap)
	save.set_value(ip, "ai_3d_separation_pct", host.ai_3d_separation_pct)
	save.set_value(ip, "ai_3d_convergence_pct", host.ai_3d_convergence_pct)
	save.set_value(ip, "ai_3d_cursor_position_v2", host.ai_3d_cursor_position)
	save.set_value(ip, "bitrate_idx", host.bitrate_idx)
	save.set_value(ip, "double_h", host.double_h)
	save.set_value(ip, "screen_layout", JSON.stringify(main.layout.to_dict()))
	var placements := []
	for s in main.screens:
		placements.append({
			"id": String(s.monitor_id),
			"pos": [s.position.x, s.position.y, s.position.z],
			"rot": [s.rotation.x, s.rotation.y, s.rotation.z],
			"size": [s.mesh_size.x, s.mesh_size.y],
			"curvature": s.curvature,
			"grid_mode": s.grid_mode,
			"grid_pos": [s.grid_pos.x, s.grid_pos.y],
		})
	save.set_value(ip, "screen_placements", JSON.stringify(placements))
	save.save("user://host_state.cfg")

func load_host_state(ip: String):
	if ip.is_empty():
		return
	var save = ConfigFile.new()
	if save.load("user://host_state.cfg") != OK:
		return
	if not save.has_section(ip):
		return
	var host: HostSettings = main.settings.host
	host.stream_fps = int(save.get_value(ip, "fps", 60))
	if not main.settings_controller.STREAM_FPS_RATES.has(host.stream_fps):
		host.stream_fps = 60
	host.resolution_scale_pct = save.get_value(ip, "resolution_scale_pct", 100)
	if not main.resolution_scale_options.has(host.resolution_scale_pct):
		host.resolution_scale_pct = 100
	var native_arr = save.get_value(ip, "native_resolution", [1920, 1080])
	host.native_resolution = Vector2i(native_arr[0], native_arr[1])
	host.is_polaris_host = save.get_value(ip, "is_polaris_host", false)
	host.resolution_idx = clampi(save.get_value(ip, "resolution_idx", 1), 0, main.resolutions.size() - 1)
	host.bitrate_idx = save.get_value(ip, "bitrate_idx", -1)
	host.double_h = save.get_value(ip, "double_h", false)
	if save.has_section_key(ip, "sbs_mode"):
		main.sbs_mode = clampi(save.get_value(ip, "sbs_mode", 0), 0, 2)
		if save.has_section_key(ip, "ai_3d_speed"):
			# ai_3d_models is back to its original 5-entry indexing (2026-08-28,
			# see its own comment) - no migration needed here, same as before
			# the brief 3-entry detour.
			main.ai_3d_model = clampi(save.get_value(ip, "ai_3d_model", 0), 0, main.settings_controller.ai_3d_models.size() - 1)
			main.ai_3d_debug = clampi(save.get_value(ip, "ai_3d_debug", 0), 0, 3)
			main.ai_3d_last_mode = clampi(save.get_value(ip, "ai_3d_last_mode", 1), 1, 3)
			main.ai_3d_backend_pref = 1 if save.get_value(ip, "ai_3d_backend_pref", 2) == 1 else 2
			main.ai_3d_hz_cap = save.get_value(ip, "ai_3d_hz_cap", 20)
			if not [12, 15, 20, 30, 40].has(main.ai_3d_hz_cap):
				main.ai_3d_hz_cap = 20
			main.ai_3d_separation_pct = save.get_value(ip, "ai_3d_separation_pct", 100)
			if not [50, 75, 100, 125, 150].has(main.ai_3d_separation_pct):
				main.ai_3d_separation_pct = 100
			main.ai_3d_convergence_pct = save.get_value(ip, "ai_3d_convergence_pct", 50)
			if not [30, 40, 50, 60, 70].has(main.ai_3d_convergence_pct):
				main.ai_3d_convergence_pct = 50
			if save.has_section_key(ip, "ai_3d_cursor_position_v2"):
				main.ai_3d_cursor_position = clampi(save.get_value(ip, "ai_3d_cursor_position_v2", 0), -1, 1)
			else:
				# Migrate the short-lived seven-position control: old Default,
				# Right, and Right+ are the new Left, Default, and Right.
				main.ai_3d_cursor_position = clampi(save.get_value(ip, "ai_3d_cursor_position", 1) - 1, -1, 1)
			if save.has_section_key(ip, "ai_3d_speed_v2"):
				main.ai_3d_speed = clampi(save.get_value(ip, "ai_3d_speed", 1), 0, 3)
			else:
				# Migrate the pre-2026-08-25 5-label range (Off/Auto/Fast/
				# Fastest/Standard, 0-4) to the new 4-label range
				# (Off/Auto/Fast/Standard, 0-3) - old index 3 (Fastest,
				# removed - near-identical to Fast on-device) falls back to
				# Fast (new index 2); old index 4 (Standard) shifts down to
				# new index 3. 0/1/2 (Off/Auto/Fast) are unchanged.
				var old_speed = clampi(save.get_value(ip, "ai_3d_speed", 1), 0, 4)
				match old_speed:
					3: main.ai_3d_speed = 2 # Fastest -> Fast
					4: main.ai_3d_speed = 3 # Standard (shifted)
					_: main.ai_3d_speed = old_speed # Off/Auto/Fast unchanged
		elif save.has_section_key(ip, "ai_3d_model"):
			# Migrate the old 4-control save format (2026-08-24 collapse to
			# two controls - see settings_controller.gd's ai_3d_speed_labels/
			# ai_3d_models comment) - old ai_3d_model was 0=Off plus 8 models
			# in a different order (Off, MiDaS-192, YOLO-256/320/384,
			# MiDaS-256, MiDaS-256-GPU, DA-V2-196/252); old ai_3d_quality was
			# 0=Auto/1=Fastest/2=Fast/3=Standard, with no on/off state of its
			# own (that lived in ai_3d_model==0 instead).
			var old_model = clampi(save.get_value(ip, "ai_3d_model", 0), 0, 8)
			var old_quality = clampi(save.get_value(ip, "ai_3d_quality", 0), 0, 3)
			main.ai_3d_debug = clampi(save.get_value(ip, "ai_3d_debug", 0), 0, 3)
			if old_model == 0:
				main.ai_3d_speed = 0
				main.ai_3d_model = 0
			else:
				match old_quality:
					1: main.ai_3d_speed = 2 # Fastest -> Fast (removed 2026-08-25)
					2: main.ai_3d_speed = 2 # Fast
					3: main.ai_3d_speed = 3 # Standard
					_: main.ai_3d_speed = 1 # Auto
				match old_model:
					1: main.ai_3d_model = 2 # MiDaS-192
					2: main.ai_3d_model = 3 # YOLO26-N-256 (removed, fallback MiDaS-256)
					3: main.ai_3d_model = 3 # YOLO26-N-320 (removed, fallback MiDaS-256)
					4: main.ai_3d_model = 3 # YOLO26-N-384 (removed, fallback MiDaS-256)
					5: main.ai_3d_model = 3 # MiDaS-256
					6: main.ai_3d_model = 0 # MiDaS-256-GPU
					7: main.ai_3d_model = 4 # DA-V2-196 (removed, fallback DA-V2-252)
					8: main.ai_3d_model = 4 # DA-V2-252
					_: main.ai_3d_model = 3 # MiDaS-256 (fallback)
		elif save.has_section_key(ip, "ai_3d_mode"):
			# Migrate the old flat 0-6 "3D AI" cycle (2026-08-18 split into
			# independent controls) - 0=Off, 1=Fast, 2=Standard, 3=Fastest,
			# 4-6=DMap/-Raw/-Input debug views (always at Standard quality,
			# since the old scheme had no independent quality selection for
			# them). Lands on MiDaS-192 (model index 1) same as the
			# 2026-08-18 migration always did.
			var old = clampi(save.get_value(ip, "ai_3d_mode", 0), 0, 6)
			main.ai_3d_debug = 0 if old < 4 else old - 3
			if old == 0:
				main.ai_3d_speed = 0
				main.ai_3d_model = 0
			else:
				main.ai_3d_model = 2 # MiDaS-192
				match old:
					1: main.ai_3d_speed = 2 # Fast
					3: main.ai_3d_speed = 2 # Fastest -> Fast (removed 2026-08-25)
					_: main.ai_3d_speed = 3 # Standard (old modes 0, 2, 4-6)
	elif save.has_section_key(ip, "stereo_mode"):
		var old = clampi(save.get_value(ip, "stereo_mode", 0), 0, 4)
		if old <= 2:
			main.sbs_mode = old
			main.ai_3d_speed = 0
		else:
			main.sbs_mode = 0
			main.ai_3d_model = 2 # MiDaS-192
			main.ai_3d_speed = 1 # Auto
	# Model may not actually belong to the loaded Type (main.ai_3d_backend_pref) -
	# every migration branch above (including the pre-Type-existing legacy
	# ones, which never touch ai_3d_backend_pref at all) can land here with
	# them disagreeing. Snaps Model to Type's first matching entry if so;
	# a no-op otherwise. Covers every branch above in one place rather than
	# repeating it in each.
	main.settings_controller.normalize_ai_3d_model_for_type()
	# Same "covers every branch above in one place" reasoning as
	# normalize_ai_3d_model_for_type() just above - Android locks Type/Model/
	# 3D Mode to GPU/ZipDepth-384-GPU/Standard regardless of what any branch
	# above (including old-format migrations) landed on. No-op on Linux.
	main.settings_controller.enforce_ai3d_platform_lock()
	# update_stereo_shader() (2026-08-28 - replaces a hand-duplicated copy of
	# its own logic that lived here, "since this doesn't call that function
	# directly" per its own old comment) already sets the stereo_mode
	# uniform, every AI-3D button label (including the new AI 3D tab's
	# controls, which that duplicate never knew about), and
	# update_3d_btn_state() - no reason to keep two copies of this in sync.
	main.ui_controller.update_stereo_shader()
	main.ui_controller.update_option_btn(main._ui_fps_btn, "%d" % main.stream_fps)
	main.host_resolution = main.compute_requested_resolution()
	main.settings_controller.refresh_resolution_btn_label()
	main.ui_controller.update_monitor_tab()
	var bitrate_label = main.bitrate_labels[main.bitrate_idx + 1] if main.bitrate_idx >= 0 else "Auto"
	main.ui_controller.update_option_btn(main._ui_bitrate_btn, bitrate_label)
	main.settings_controller.apply_stereo()
	if main.depth_estimator:
		main.depth_estimator.set_enabled(main.settings_controller.get_stereo_mode() >= 3)
	main.settings_controller.apply_stereo()

	var layout_json = save.get_value(ip, "screen_layout", "")
	var loaded_layout: ScreenLayout = null
	if not layout_json.is_empty():
		var parsed = JSON.parse_string(layout_json)
		if parsed is Dictionary:
			var candidate = ScreenLayout.from_dict(parsed)
			if candidate.validate(candidate.frame_size) == "":
				loaded_layout = candidate
			else:
				main._log("[LAYOUT] Saved layout failed validation, using single()")
	if loaded_layout == null:
		loaded_layout = ScreenLayout.single(main.layout.frame_size if main.layout else Vector2i(1920, 1080))
	main.settings_controller.apply_screen_layout(loaded_layout)

	var placements_json = save.get_value(ip, "screen_placements", "")
	if not placements_json.is_empty():
		var placements = JSON.parse_string(placements_json)
		if placements is Array:
			for entry in placements:
				var mid = StringName(entry.get("id", ""))
				for s in main.screens:
					if s.monitor_id == mid:
						var pos = entry.get("pos", [0, 0, 0])
						var rot = entry.get("rot", [0, 0, 0])
						var size = entry.get("size", [s.mesh_size.x, s.mesh_size.y])
						s.position = Vector3(pos[0], pos[1], pos[2])
						s.rotation = Vector3(rot[0], rot[1], rot[2])
						s.mesh_size = Vector2(size[0], size[1])
						s.curvature = entry.get("curvature", s.curvature)
						s.grid_mode = entry.get("grid_mode", s.grid_mode)
						var gp = entry.get("grid_pos", [s.grid_pos.x, s.grid_pos.y])
						s.grid_pos = Vector2i(gp[0], gp[1])
						s.apply_curvature()
						break
		# The composition layer cylinder (the surface actually visible in the
		# headset) is a separate node with its own world position/radius, only
		# ever synced by an explicit update_cylinder_params() call - it does NOT
		# follow along automatically just because a screen's mesh transform above
		# was restored. Without this, the flat mesh (and its grab_bar child) jump
		# to the saved position/rotation while the cylinder stays wherever the
		# generic startup pass left it, until a manual grab forces a resync.
		if main.comp:
			main.comp.update_cylinder_params()
		# These placements describe how screens should look while actively
		# streaming to this host, not the pre-connect welcome UI - but this runs
		# during boot (_init_textures_and_ui(), called after _init_ui() already
		# reset the welcome screen to a fixed 16:9), so a saved non-16:9 layout
		# would otherwise squish the welcome screen the user sees before they've
		# even connected. Re-assert the welcome layout now if we're not
		# streaming; it'll be replaced by the host's real manifest/layout once a
		# connection actually starts.
		if not main.is_streaming and main.welcome_screen:
			main.welcome_screen.show_welcome_screen(main._welcome_screen)

func sync_ui_to_settings():
	if main.bezel_mesh:
		main.bezel_mesh.visible = main.bezel_enabled and not main.comp.in_use
	if main.ui_controller:
		main.ui_controller.update_option_btn(main._ui_bezel_btn, "On" if main.bezel_enabled else "Off")
		main.ui_controller.update_option_btn(main._ui_hand_tracking_btn, main.tracking_labels[clampi(main.tracking_mode, 0, main.tracking_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_curve_btn, main.curvature_labels[clampi(main.curvature, 0, main.curvature_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_pt_btn, "On" if main.passthrough_enabled else "Off")
		main.ui_controller.update_option_btn(main._ui_bg_btn, main.background_labels[clampi(main.background_mode, 0, main.background_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_sharpen_btn, main.settings_controller.get_sharpen_label(main.sharpen_mode))
		main.ui_controller.update_option_btn(main._ui_brightness_btn, "%+d%%" % main.brightness_pct)
		main.ui_controller.update_option_btn(main._ui_contrast_btn, "%d%%" % main.contrast_pct)
		main.ui_controller.update_option_btn(main._ui_gamma_btn, "%d%%" % main.gamma_pct)
		main.ui_controller.update_ambient_btn_state()
		main.ui_controller.update_option_btn(main._ui_3d_cursor_position_btn, main.settings_controller.get_ai_3d_cursor_position_label())
		main.ui_controller.update_option_btn(main._ui_cursor_btn, main.cursor_labels[clampi(main.cursor_mode, 0, main.cursor_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_steady_btn, main.pointer_steady_labels[clampi(main.pointer_steady, 0, main.pointer_steady_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_3d_priority_btn, main.settings_controller.ai_3d_gpu_priority_labels[main.ai_3d_gpu_priority])
		main.ui_controller.update_option_btn(main._ui_double_click_btn, main.double_click_mode_labels[clampi(main.double_click_mode, 0, main.double_click_mode_labels.size() - 1)])
		main.ui_controller.update_codec_btn()
		main.ui_controller.update_option_btn(main._ui_reconnect_btn, "On" if main.auto_reconnect_enabled else "Off")
		if main._ui_quick_start_btn:
			main.ui_controller.update_option_btn(main._ui_quick_start_btn, "On" if main.quick_start_enabled else "Off")
		var idle_idx = main.settings_controller.idle_values.find(main.idle_timeout_min)
		if idle_idx < 0: idle_idx = 0
		main.ui_controller.update_option_btn(main._ui_idle_btn, main.settings_controller.idle_labels[idle_idx])
		main.ui_controller.update_stats_btn_state()
		if main.controller_mapper:
			main.ui_controller.update_btn_toggle_btn()
			main.ui_controller.update_primary_btn()
		main.ui_controller.update_monitor_tab()
	if main.screen_manager:
		main.screen_manager.update_bezel_size()
	if main.settings_controller:
		main.settings_controller.apply_filter()
	if main.comp:
		main.comp.apply_ambient_settings()

func load_state():
	MonitorPresets.write_default_presets_snapshot()
	var save = ConfigFile.new()
	var err = save.load("user://app_state.cfg")
	main._log("[STATE] load_state called. Load result: %d" % err)
	if err != OK:
		main._log("[STATE] load failed or not found, applying default curvature and syncing...")
		main.screen_manager.apply_curvature()
		sync_ui_to_settings()
		main.settings_controller.apply_depth_gpu_priority(false)
		return

	main.settings.bezel_enabled = save.get_value("screen", "bezel", AppSettings.DEFAULT_BEZEL_ENABLED)
	main.curvature = save.get_value("screen", "curvature", 2)
	main.settings.background_mode = save.get_value("screen", "background_mode", AppSettings.DEFAULT_BACKGROUND_MODE)
	# "passthrough_enabled" is the current format, always written by
	# save_state() - prefer it whenever present. The old "passthrough" int key
	# (0=on, 1-5=off with a specific background) predates that and is never
	# written or cleared anymore, so a save file that has both (any file
	# saved by a current build that started from an old one) would otherwise
	# have this permanently prioritize a stale value no toggle can ever
	# change. Only fall back to it as a one-time migration for a save file
	# that's never been touched by the current format at all.
	if save.has_section_key("screen", "passthrough_enabled"):
		var raw_saved = save.get_value("screen", "passthrough_enabled", false)
		main.settings.passthrough_enabled = raw_saved and main.passthrough_supported
		main._log("[PASSTHROUGH] load_state: raw_saved=%s passthrough_supported=%s -> passthrough_enabled=%s" % [str(raw_saved), str(main.passthrough_supported), str(main.passthrough_enabled)])
	elif save.has_section_key("screen", "passthrough"):
		var old = clampi(save.get_value("screen", "passthrough", 0), 0, 5)
		if main.passthrough_supported:
			main.settings.passthrough_enabled = (old == 0)
			main.settings.background_mode = maxi(old - 1, 0)
		else:
			main.settings.passthrough_enabled = false
			main.settings.background_mode = old
	else:
		main.settings.passthrough_enabled = AppSettings.DEFAULT_PASSTHROUGH_ENABLED
	main.settings.sharpen_mode = clampi(save.get_value("screen", "sharpen_mode", AppSettings.DEFAULT_SHARPEN_MODE), 0, main.sharpen_labels.size() - 1)
	if OS.get_name() == "Android" and not main.settings_controller.get_sharpen_choices().has(main.settings.sharpen_mode):
		main.settings.sharpen_mode = AppSettings.DEFAULT_SHARPEN_MODE
	main.settings.brightness_pct = save.get_value("screen", "brightness_pct", AppSettings.DEFAULT_BRIGHTNESS_PCT)
	if not [-20, -10, 0, 10, 20].has(main.settings.brightness_pct):
		main.settings.brightness_pct = AppSettings.DEFAULT_BRIGHTNESS_PCT
	main.settings.contrast_pct = save.get_value("screen", "contrast_pct", AppSettings.DEFAULT_CONTRAST_PCT)
	if not [50, 75, 100, 125, 150].has(main.settings.contrast_pct):
		main.settings.contrast_pct = AppSettings.DEFAULT_CONTRAST_PCT
	main.settings.gamma_pct = save.get_value("screen", "gamma_pct", AppSettings.DEFAULT_GAMMA_PCT)
	if not [50, 75, 100, 125, 150].has(main.settings.gamma_pct):
		main.settings.gamma_pct = AppSettings.DEFAULT_GAMMA_PCT
	main.settings.ambient_mode = clampi(save.get_value("screen", "ambient_mode", AppSettings.DEFAULT_AMBIENT_MODE), 0, main.ambient_mode_labels.size() - 1)
	main.settings.ambient_color = clampi(save.get_value("screen", "ambient_color", AppSettings.DEFAULT_AMBIENT_COLOR), 0, main.ambient_color_labels.size() - 1)
	main.settings.cursor_mode = save.get_value("screen", "cursor_mode", AppSettings.DEFAULT_CURSOR_MODE)
	var saved_steady = save.get_value("screen", "pointer_steady", AppSettings.DEFAULT_POINTER_STEADY)
	if saved_steady is bool:
		main.settings.pointer_steady = 1 if saved_steady else 0
	else:
		main.settings.pointer_steady = clampi(int(saved_steady), 0, main.pointer_steady_labels.size() - 1)
	main.settings.double_click_mode = clampi(save.get_value("screen", "double_click_mode", AppSettings.DEFAULT_DOUBLE_CLICK_MODE), 0, 1)
	main.settings.codec_preference = save.get_value("screen", "codec_preference", AppSettings.DEFAULT_CODEC_PREFERENCE)
	main.settings.grid_mode_enabled = save.get_value("screen", "grid_mode_enabled", AppSettings.DEFAULT_GRID_MODE_ENABLED)
	main.settings.performance_overlay_enabled = save.get_value("diagnostics", "performance_overlay", AppSettings.DEFAULT_PERFORMANCE_OVERLAY_ENABLED)
	main.settings.ai_3d_gpu_priority = clampi(save.get_value("ai_3d", "gpu_priority", AppSettings.DEFAULT_AI_3D_GPU_PRIORITY), 0, 1)
	var raw_tracking = save.get_value("controller", "hand_tracking_enabled", 0)
	if raw_tracking is bool:
		main.settings.tracking_mode = 1 if raw_tracking else 0
	else:
		main.settings.tracking_mode = int(raw_tracking)
	if main.controller_mapper:
		if save.has_section_key("controller", "active"):
			main.controller_mapper.active = save.get_value("controller", "active", false)
			main.controller_mapper.ctrl_type = clampi(save.get_value("controller", "ctrl_type", 0), 0, 2)
		else:
			var old_mode = clampi(save.get_value("controller", "mode", 0), 0, 2)
			if old_mode == 0:
				main.controller_mapper.active = false
			else:
				main.controller_mapper.active = true
				main.controller_mapper.ctrl_type = 1 if old_mode == 1 else 0
		if main.ui_controller:
			main.ui_controller.update_ctrl_mode_btn()
			main.ui_controller.update_ctrl_type_btn()
		main.controller_mapper.btn_toggle = clampi(save.get_value("controller", "btn_toggle", 1), 0, 2)
		main.controller_mapper.primary_hand = clampi(save.get_value("controller", "primary_hand", 0), 0, 2)
		if main.ui_controller:
			main.ui_controller.update_btn_toggle_btn()
			main.ui_controller.update_primary_btn()
	main.screen_manager.apply_curvature()
	main.settings.auto_reconnect_enabled = save.get_value("stream", "auto_reconnect", AppSettings.DEFAULT_AUTO_RECONNECT_ENABLED)
	main.settings.quick_start_enabled = save.get_value("stream", "quick_start", AppSettings.DEFAULT_QUICK_START_ENABLED)
	main.settings.idle_timeout_min = save.get_value("stream", "idle_timeout_min", AppSettings.DEFAULT_IDLE_TIMEOUT_MIN)
	main.settings.pipewire_restore_token = save.get_value("local_capture", "restore_token", AppSettings.DEFAULT_PIPEWIRE_RESTORE_TOKEN)
	if main.stream_backend and main.stream_backend._v2:
		main.stream_backend._v2.set_auto_reconnect(main.auto_reconnect_enabled)

	sync_ui_to_settings()
	main.settings_controller.apply_depth_gpu_priority(false)
