class_name StateManager
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func save_state():
	var save = ConfigFile.new()
	save.set_value("screen", "bezel", main.bezel_enabled)
	save.set_value("screen", "curvature", main.curvature)
	save.set_value("screen", "passthrough_enabled", main.passthrough_enabled)
	save.set_value("screen", "background_mode", main.background_mode)
	save.set_value("screen", "smooth_mode", main.smooth_mode)
	save.set_value("screen", "sharpen_mode", main.sharpen_mode)
	save.set_value("screen", "cursor_mode", main.cursor_mode)
	save.set_value("screen", "pointer_steady", main.pointer_steady)
	save.set_value("screen", "codec_preference", main.codec_preference)
	save.set_value("screen", "grid_mode_enabled", main.grid_mode_enabled)
	save.set_value("controller", "active", main.controller_mapper.active)
	save.set_value("controller", "ctrl_type", main.controller_mapper.ctrl_type)
	save.set_value("controller", "btn_toggle", main.controller_mapper.btn_toggle)
	save.set_value("controller", "primary_hand", main.controller_mapper.primary_hand)
	save.set_value("controller", "hand_tracking_enabled", main.tracking_mode)
	save.set_value("stream", "auto_reconnect", main.auto_reconnect_enabled)
	save.set_value("stream", "quick_start", main.quick_start_enabled)
	save.set_value("stream", "idle_timeout_min", main.idle_timeout_min)
	save.set_value("local_capture", "restore_token", main.pipewire_restore_token)
	save.save("user://app_state.cfg")
	save_host_state()

func save_host_state():
	var ip = main.get_node("%IPInput").text
	if ip.is_empty():
		return
	var save = ConfigFile.new()
	save.load("user://host_state.cfg")
	save.set_value(ip, "fps", main.stream_fps)
	save.set_value(ip, "resolution_scale_pct", main.resolution_scale_pct)
	save.set_value(ip, "native_resolution", [main.native_resolution.x, main.native_resolution.y])
	save.set_value(ip, "is_polaris_host", main.is_polaris_host)
	save.set_value(ip, "resolution_idx", main.resolution_idx)
	save.set_value(ip, "sbs_mode", main.sbs_mode)
	save.set_value(ip, "ai_3d_model", main.ai_3d_model)
	save.set_value(ip, "ai_3d_speed", main.ai_3d_speed)
	save.set_value(ip, "ai_3d_debug", main.ai_3d_debug)
	save.set_value(ip, "bitrate_idx", main.bitrate_idx)
	save.set_value(ip, "double_h", main.double_h)
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
	main.stream_fps = save.get_value(ip, "fps", 60)
	main.resolution_scale_pct = save.get_value(ip, "resolution_scale_pct", 100)
	if not main.resolution_scale_options.has(main.resolution_scale_pct):
		main.resolution_scale_pct = 100
	var native_arr = save.get_value(ip, "native_resolution", [1920, 1080])
	main.native_resolution = Vector2i(native_arr[0], native_arr[1])
	main.is_polaris_host = save.get_value(ip, "is_polaris_host", false)
	main.resolution_idx = clampi(save.get_value(ip, "resolution_idx", 1), 0, main.resolutions.size() - 1)
	main.bitrate_idx = save.get_value(ip, "bitrate_idx", -1)
	main.double_h = save.get_value(ip, "double_h", false)
	if save.has_section_key(ip, "sbs_mode"):
		main.sbs_mode = clampi(save.get_value(ip, "sbs_mode", 0), 0, 2)
		if save.has_section_key(ip, "ai_3d_speed"):
			main.ai_3d_model = clampi(save.get_value(ip, "ai_3d_model", 0), 0, main.settings_controller.ai_3d_models.size() - 1)
			main.ai_3d_speed = clampi(save.get_value(ip, "ai_3d_speed", 0), 0, 4)
			main.ai_3d_debug = clampi(save.get_value(ip, "ai_3d_debug", 0), 0, 3)
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
					1: main.ai_3d_speed = 3 # Fastest
					2: main.ai_3d_speed = 2 # Fast
					3: main.ai_3d_speed = 4 # Standard
					_: main.ai_3d_speed = 1 # Auto
				match old_model:
					1: main.ai_3d_model = 1 # MiDaS-192
					2: main.ai_3d_model = 3 # YOLO26-N-256
					3: main.ai_3d_model = 4 # YOLO26-N-320
					4: main.ai_3d_model = 5 # YOLO26-N-384
					5: main.ai_3d_model = 2 # MiDaS-256
					6: main.ai_3d_model = 0 # MiDaS-256-GPU
					7: main.ai_3d_model = 6 # DA-V2-196
					8: main.ai_3d_model = 7 # DA-V2-252
					_: main.ai_3d_model = 2 # MiDaS-256 (fallback)
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
				main.ai_3d_model = 1 # MiDaS-192
				match old:
					1: main.ai_3d_speed = 2 # Fast
					3: main.ai_3d_speed = 3 # Fastest
					_: main.ai_3d_speed = 4 # Standard (old modes 0, 2, 4-6)
	elif save.has_section_key(ip, "stereo_mode"):
		var old = clampi(save.get_value(ip, "stereo_mode", 0), 0, 4)
		if old <= 2:
			main.sbs_mode = old
			main.ai_3d_speed = 0
		else:
			main.sbs_mode = 0
			main.ai_3d_model = 1 # MiDaS-192
			main.ai_3d_speed = 1 # Auto
	if main.screen_mesh.material_override is ShaderMaterial:
		main.screen_mesh.material_override.set_shader_parameter("stereo_mode", main.settings_controller.get_stereo_mode())
	main.ui_controller.update_option_btn(main._ui_sbs_btn, main.settings_controller.sbs_labels[main.sbs_mode])
	main.ui_controller.update_option_btn(main._ui_3d_speed_btn, main.settings_controller.ai_3d_speed_labels[main.ai_3d_speed])
	main.ui_controller.update_option_btn(main._ui_3d_btn, main.settings_controller.ai_3d_models[main.ai_3d_model].label)
	main.ui_controller.update_option_btn(main._ui_3d_debug_btn, main.settings_controller.ai_3d_debug_labels[main.ai_3d_debug])
	main.ui_controller.update_3d_btn_state()
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
		main.ui_controller.update_option_btn(main._ui_render_btn, main.smooth_labels[clampi(main.smooth_mode, 0, main.smooth_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_sharpen_btn, main.sharpen_labels[clampi(main.sharpen_mode, 0, main.sharpen_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_cursor_btn, main.cursor_labels[clampi(main.cursor_mode, 0, main.cursor_labels.size() - 1)])
		main.ui_controller.update_option_btn(main._ui_steady_btn, main.pointer_steady_labels[clampi(main.pointer_steady, 0, main.pointer_steady_labels.size() - 1)])
		main.ui_controller.update_codec_btn()
		main.ui_controller.update_option_btn(main._ui_reconnect_btn, "On" if main.auto_reconnect_enabled else "Off")
		if main._ui_quick_start_btn:
			main.ui_controller.update_option_btn(main._ui_quick_start_btn, "On" if main.quick_start_enabled else "Off")
		var idle_idx = main.settings_controller.idle_values.find(main.idle_timeout_min)
		if idle_idx < 0: idle_idx = 0
		main.ui_controller.update_option_btn(main._ui_idle_btn, main.settings_controller.idle_labels[idle_idx])
		if main.controller_mapper:
			main.ui_controller.update_btn_toggle_btn()
			main.ui_controller.update_primary_btn()
		main.ui_controller.update_monitor_tab()
	if main.screen_manager:
		main.screen_manager.update_bezel_size()
	if main.settings_controller:
		main.settings_controller.apply_filter()

func load_state():
	MonitorPresets.write_default_presets_snapshot()
	var save = ConfigFile.new()
	var err = save.load("user://app_state.cfg")
	main._log("[STATE] load_state called. Load result: %d" % err)
	if err != OK:
		main._log("[STATE] load failed or not found, applying default curvature and syncing...")
		main.screen_manager.apply_curvature()
		sync_ui_to_settings()
		return

	main.bezel_enabled = save.get_value("screen", "bezel", true)
	main.curvature = save.get_value("screen", "curvature", 2)
	main.background_mode = save.get_value("screen", "background_mode", 0)
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
		main.passthrough_enabled = raw_saved and main.passthrough_supported
		main._log("[PASSTHROUGH] load_state: raw_saved=%s passthrough_supported=%s -> passthrough_enabled=%s" % [str(raw_saved), str(main.passthrough_supported), str(main.passthrough_enabled)])
	elif save.has_section_key("screen", "passthrough"):
		var old = clampi(save.get_value("screen", "passthrough", 0), 0, 5)
		if main.passthrough_supported:
			main.passthrough_enabled = (old == 0)
			main.background_mode = maxi(old - 1, 0)
		else:
			main.passthrough_enabled = false
			main.background_mode = old
	else:
		main.passthrough_enabled = false
	main.smooth_mode = save.get_value("screen", "smooth_mode", save.get_value("screen", "render_mode", 0))
	main.sharpen_mode = save.get_value("screen", "sharpen_mode", 0)
	main.cursor_mode = save.get_value("screen", "cursor_mode", 1)
	var saved_steady = save.get_value("screen", "pointer_steady", 1)
	if saved_steady is bool:
		main.pointer_steady = 1 if saved_steady else 0
	else:
		main.pointer_steady = int(saved_steady)
	main.codec_preference = save.get_value("screen", "codec_preference", 1)
	main.grid_mode_enabled = save.get_value("screen", "grid_mode_enabled", true)
	var raw_tracking = save.get_value("controller", "hand_tracking_enabled", 0)
	if raw_tracking is bool:
		main.tracking_mode = 1 if raw_tracking else 0
	else:
		main.tracking_mode = int(raw_tracking)
	if main.controller_mapper:
		if save.has_section_key("controller", "active"):
			main.controller_mapper.active = save.get_value("controller", "active", false)
			main.controller_mapper.ctrl_type = clampi(save.get_value("controller", "ctrl_type", 0), 0, 2)
			if main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.KEYBOARD:
				main.controller_mapper.ctrl_type = ControllerMapper.CtrlType.KBMOUSE
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
	main.auto_reconnect_enabled = save.get_value("stream", "auto_reconnect", true)
	main.quick_start_enabled = save.get_value("stream", "quick_start", false)
	main.idle_timeout_min = save.get_value("stream", "idle_timeout_min", 0)
	main.pipewire_restore_token = save.get_value("local_capture", "restore_token", "")
	if main.stream_backend and main.stream_backend._v2:
		main.stream_backend._v2.set_auto_reconnect(main.auto_reconnect_enabled)

	sync_ui_to_settings()
