class_name StateManager
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func save_state():
	var save = ConfigFile.new()
	SettingsPersistence.write_app(save, main.settings)
	save.set_value("screen", "curvature", main.curvature)
	save.set_value("controller", "active", main.controller_mapper.active)
	save.set_value("controller", "ctrl_type", main.controller_mapper.ctrl_type)
	save.set_value("controller", "btn_toggle", main.controller_mapper.btn_toggle)
	save.set_value("controller", "primary_hand", main.controller_mapper.primary_hand)
	save.save("user://app_state.cfg")
	save_host_state()

func save_host_state():
	var ip = main.get_node("%IPInput").text
	if ip.is_empty():
		return
	var save = ConfigFile.new()
	save.load("user://host_state.cfg")
	var host: HostSettings = main.settings.host
	SettingsPersistence.write_host(save, ip, host)
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
	SettingsPersistence.read_host(
		save,
		ip,
		host,
		main.settings_controller.STREAM_FPS_RATES,
		main.resolution_scale_options,
		main.resolutions.size(),
		main.settings_controller.ai_3d_models.size())
	# Model may not actually belong to the loaded Type (main.ai_3d_backend_pref) -
	# persistence-codec migrations (including pre-Type legacy formats) can land here with
	# them disagreeing. Snaps Model to Type's first matching entry if so;
	# a no-op otherwise. Covers every branch above in one place rather than
	# repeating it in each.
	main.settings_controller.normalize_ai_3d_model_for_type()
	# Same "covers every branch above in one place" reasoning as
	# normalize_ai_3d_model_for_type() just above - Android locks Type/Model/
	# 3D Mode to GPU/ZipDepth-384-GPU/Standard regardless of what any branch
	# in the typed host settings. No-op on Linux.
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

	var load_info := SettingsPersistence.read_app(
		save,
		main.settings,
		main.passthrough_supported,
		main.settings_controller.get_sharpen_choices())
	main.curvature = save.get_value("screen", "curvature", 2)
	# Keep the existing diagnostic while migration details stay in the codec.
	if load_info.current_passthrough_value != null:
		var raw_saved = load_info.current_passthrough_value
		main._log("[PASSTHROUGH] load_state: raw_saved=%s passthrough_supported=%s -> passthrough_enabled=%s" % [str(raw_saved), str(main.passthrough_supported), str(main.passthrough_enabled)])
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
	if main.stream_backend and main.stream_backend._v2:
		main.stream_backend._v2.set_auto_reconnect(main.auto_reconnect_enabled)

	sync_ui_to_settings()
	main.settings_controller.apply_depth_gpu_priority(false)
