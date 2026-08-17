class_name SettingsController
extends RefCounted

var main: Node3D
var _restart_pending: bool = false
var _restart_seq: int = 0

var sbs_labels: Array = ["Off", "Stretch", "Crop"]
var ai_3d_labels: Array = ["2D", "MiDaS", "MiDaS-GPU", "MiDaS-NNAPI", "MiDaS-DMap"]
var idle_labels: Array = ["Off", "5m", "15m", "30m", "60m"]
var idle_values: Array = [0, 5, 15, 30, 60]

func _init(owner: Node3D):
	main = owner

func get_stereo_mode() -> int:
	if main.sbs_mode > 0:
		return main.sbs_mode
	if main.ai_3d_mode == 0:
		return 0
	elif main.ai_3d_mode == 1:
		return 3
	elif main.ai_3d_mode == 2:
		return 5
	elif main.ai_3d_mode == 3:
		return 6
	elif main.ai_3d_mode == 4:
		return 7
	else:
		return 4

func _save_setting(btn: Button, label: String):
	if btn:
		main.ui_controller.update_option_btn(btn, label)
	main.state_manager.save_state()

func cycle_sbs_mode():
	main.sbs_mode = (main.sbs_mode + 1) % 3
	_save_setting(main._ui_sbs_btn, sbs_labels[main.sbs_mode])
	main.ui_controller.update_3d_btn_state()
	apply_stereo()
	if main.sbs_mode > 0 and main.screens.size() > 1:
		main._ui_status_label.text = "SBS applies to primary screen only"

func cycle_ai_3d_mode():
	if OS.get_name() != "Android":
		return
	if main.sbs_mode > 0:
		return
	main.ai_3d_mode = (main.ai_3d_mode + 1) % 5
	_save_setting(main._ui_3d_btn, ai_3d_labels[main.ai_3d_mode])
	apply_stereo()

func apply_stereo():
	var mode = get_stereo_mode()
	if main.comp.available:
		if mode > 0:
			main.comp.switch_to_stereo_comp_layer()
		else:
			main.comp.switch_to_comp_layer()
	else:
		if mode > 0 and main.comp.in_use:
			main.comp.switch_to_mesh_rendering()
		elif mode == 0 and not main.comp.in_use and main.is_streaming:
			main.comp.switch_to_comp_layer()
	if main.screen_mesh.material_override is ShaderMaterial:
		main.screen_mesh.material_override.set_shader_parameter("stereo_mode", mode)
	if main.depth_estimator:
		# mode 7 (MiDaS-DMap) now visualizes upsampled_depth_texture (the real
		# post-upsample data the actual warp uses), not the raw pre-upsample
		# depth_texture, so it needs the warp passes running too.
		main.depth_estimator.set_enabled(mode >= 3, mode == 5 or mode == 6 or mode == 7)
		if mode >= 3 and main.depth_estimator.depth_texture:
			var de = main.depth_estimator
			var upsampled_tex = de.upsample_viewport.get_texture() if de.upsample_viewport else null
			var offset_tex = de.offset_viewport.get_texture() if de.offset_viewport else null
			if main.comp_shader_mat_left:
				main.comp_shader_mat_left.set_shader_parameter("depth_texture", de.depth_texture)
				main.comp_shader_mat_left.set_shader_parameter("upsampled_depth_texture", upsampled_tex)
				main.comp_shader_mat_left.set_shader_parameter("offset_texture", offset_tex)
			if main.comp_shader_mat_right:
				main.comp_shader_mat_right.set_shader_parameter("depth_texture", de.depth_texture)
				main.comp_shader_mat_right.set_shader_parameter("upsampled_depth_texture", upsampled_tex)
				main.comp_shader_mat_right.set_shader_parameter("offset_texture", offset_tex)
	# mode 7 (MiDaS-DMap) reuses the MiDaS-NNAPI model/inference (index 3) - it's
	# a pure visualization of that same depth data, not a separate source.
	main.stream_backend.set_depth_model(1 if mode == 4 else (2 if mode == 5 else (3 if mode == 6 or mode == 7 else 0)))

func toggle_passthrough():
	if not main.is_xr_active or not main.passthrough_supported:
		main._log("[PASSTHROUGH] toggle ignored: is_xr_active=%s passthrough_supported=%s" % [str(main.is_xr_active), str(main.passthrough_supported)])
		return
	main.passthrough_enabled = not main.passthrough_enabled
	apply_passthrough(main.passthrough_enabled)
	_save_setting(main._ui_pt_btn, "On" if main.passthrough_enabled else "Off")
	main._log("[PASSTHROUGH] toggled to %s and saved" % str(main.passthrough_enabled))

func apply_passthrough(enable: bool):
	if not main.is_xr_active:
		return
	_hide_all_backgrounds()
	var interface = XRServer.find_interface("OpenXR")
	if not interface:
		return
	if enable:
		main.get_viewport().transparent_bg = true
		main.world_env.environment.background_mode = Environment.BG_COLOR
		main.world_env.environment.background_color = Color(0, 0, 0, 0)
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	else:
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		main.get_viewport().transparent_bg = false
		apply_background(main.background_mode)

func cycle_background():
	main.background_mode = (main.background_mode + 1) % main.background_labels.size()
	apply_background(main.background_mode)
	_save_setting(main._ui_bg_btn, main.background_labels[main.background_mode])

func apply_background(bg_mode: int):
	if not main.is_xr_active or main.passthrough_enabled:
		return
	_hide_all_backgrounds()
	main.world_env.environment.background_color = Color(0, 0, 0, 1 if bg_mode == 0 else 0)
	if bg_mode > 0:
		var bg_idx = bg_mode - 1
		if bg_idx >= 0 and bg_idx < main.bg_names.size():
			var bg = main.get_node_or_null(main.bg_names[bg_idx])
			if bg:
				bg.visible = true
				bg.emitting = true

func _hide_all_backgrounds():
	for name in main.bg_names:
		var bg = main.get_node_or_null(name)
		if bg:
			bg.visible = false
			bg.emitting = false

func cycle_smooth_mode():
	main.smooth_mode = (main.smooth_mode + 1) % main.smooth_labels.size()
	_save_setting(main._ui_render_btn, main.smooth_labels[main.smooth_mode])
	apply_filter()

func cycle_cursor_mode():
	main.cursor_mode = (main.cursor_mode + 1) % main.cursor_labels.size()
	_save_setting(main._ui_cursor_btn, main.cursor_labels[main.cursor_mode])

func cycle_steady():
	main.pointer_steady = (main.pointer_steady + 1) % main.pointer_steady_labels.size()
	main._steady_active = false
	_save_setting(main._ui_steady_btn, main.pointer_steady_labels[main.pointer_steady])

func is_codec_available(idx: int) -> bool:
	var client_ok = false
	var server_ok = false
	match idx:
		0:
			client_ok = main._client_codec_support.get("h264", true)
			server_ok = main._server_codec_support.get("h264", true)
		1:
			client_ok = main._client_codec_support.get("hevc", true)
			server_ok = main._server_codec_support.get("hevc", true)
		2:
			client_ok = main._client_codec_support.get("av1", true)
			server_ok = main._server_codec_support.get("av1", true)
		3:
			client_ok = main._client_codec_support.get("raw", true)
			server_ok = main._server_codec_support.get("raw", true)
	if main._server_codec_support.is_empty():
		return client_ok
	return client_ok and server_ok

func _get_available_codecs() -> PackedInt32Array:
	var result = PackedInt32Array()
	for i in range(main.codec_labels.size()):
		if is_codec_available(i):
			result.append(i)
	return result

func cycle_codec():
	var available = _get_available_codecs()
	if available.is_empty():
		return
	var cur_pos = available.find(main.codec_preference)
	if cur_pos >= 0:
		main.codec_preference = available[(cur_pos + 1) % available.size()]
	else:
		main.codec_preference = available[0]
	main.ui_controller.update_codec_btn()
	# H.264's hardware-decoder dimension cap in compute_requested_resolution() is keyed
	# off codec_preference - recompute host_resolution now that it just changed, or a
	# switch to H.264 while already at (e.g.) 100% would restart still requesting the
	# uncapped resolution left over from whatever codec was active before.
	main.host_resolution = main.compute_requested_resolution()
	refresh_resolution_btn_label()
	main.state_manager.save_state()
	if main.is_streaming:
		_schedule_stream_restart()

func fallback_codec():
	if is_codec_available(1):
		main.codec_preference = 1
	else:
		var available = _get_available_codecs()
		main.codec_preference = available[0] if not available.is_empty() else 0

func cycle_sharpen_mode():
	main.sharpen_mode = (main.sharpen_mode + 1) % main.sharpen_labels.size()
	_save_setting(main._ui_sharpen_btn, main.sharpen_labels[main.sharpen_mode])
	apply_filter()

func cycle_auto_reconnect():
	main.auto_reconnect_enabled = not main.auto_reconnect_enabled
	if main.stream_backend and main.stream_backend._v2:
		main.stream_backend._v2.set_auto_reconnect(main.auto_reconnect_enabled)
	_save_setting(main._ui_reconnect_btn, "On" if main.auto_reconnect_enabled else "Off")

func cycle_quick_start():
	main.quick_start_enabled = not main.quick_start_enabled
	_save_setting(main._ui_quick_start_btn, "On" if main.quick_start_enabled else "Off")

func cycle_idle_timeout():
	var idx = idle_values.find(main.idle_timeout_min)
	idx = (idx + 1) % idle_values.size()
	main.idle_timeout_min = idle_values[idx]
	_save_setting(main._ui_idle_btn, idle_labels[idx])

func toggle_host_cursor():
	if not main._host_cursor_toggle_supported or not main.is_streaming:
		return
	var target = not main.host_cursor_visible
	main.stream_backend.set_cursor_visible(main.current_host_id, target, func(response: Dictionary):
		if response.get("status", "") == "success":
			main.host_cursor_visible = response.get("visible", target)
			main.ui_controller.update_host_cursor_btn_state()
	)

func apply_filter():
	if not main.is_xr_active:
		return
	var filter_val = main.smooth_mode
	var sharp_val = float(main.sharpen_mode) * 0.5
	var mat = main.screen_mesh.material_override
	if mat and mat is ShaderMaterial:
		mat.set_shader_parameter("filter_mode", filter_val)
		mat.set_shader_parameter("sharpen", sharp_val)
		mat.set_shader_parameter("blur_scale", main.get_blur_scale(main.primary_screen))
	for s in main.screens:
		for cm in main.comp.get_shader_mats(s):
			if cm:
				cm.set_shader_parameter("filter_mode", filter_val)
				cm.set_shader_parameter("sharpen", sharp_val)
				cm.set_shader_parameter("blur_scale", main.get_blur_scale(s))

func apply_display_refresh_rate():
	if not main.is_xr_active:
		return
	var interface = XRServer.find_interface("OpenXR")
	if not interface:
		return
	var target_hz: float = 90.0
	match main.stream_fps:
		30: target_hz = 90.0
		60: target_hz = 72.0
		72: target_hz = 72.0
		90: target_hz = 90.0
		120: target_hz = 120.0
	var available = interface.get_available_display_refresh_rates()
	if available.is_empty():
		main._log("[REFRESH] No available refresh rates reported")
		main.display_refresh_rate = target_hz
		return
	var best: float = 0.0
	for rate in available:
		if rate >= target_hz and (best == 0.0 or rate < best):
			best = rate
	if best == 0.0:
		available.sort()
		best = available[available.size() - 1]
	interface.set_display_refresh_rate(best)
	main.display_refresh_rate = best
	Engine.max_fps = 0
	main._log("[REFRESH] Set headset to %.0fHz (target %.0fHz for %dfps)" % [best, target_hz, main.stream_fps])

func cycle_fps():
	var rates = [30, 60, 72, 90, 120]
	var idx = rates.find(main.stream_fps)
	main.stream_fps = rates[(idx + 1) % rates.size()]
	_save_setting(main._ui_fps_btn, "%d" % main.stream_fps)
	_schedule_stream_restart()

func cycle_resolution():
	if main.is_polaris_host:
		var opts = main.compute_resolution_options()
		# opts[0] is always the current max (see compute_resolution_options()) - find by
		# value for everything else, but treat "currently at-or-past the max" as being
		# at slot 0 rather than falling through to opts.find()'s -1-not-found case,
		# which used to skip straight past MAX to the second entry on the very next
		# click after a codec/monitor change made the old selection unreachable.
		var idx = 0 if main.resolution_scale_pct >= opts[0] else opts.find(main.resolution_scale_pct)
		main.resolution_scale_pct = opts[(maxi(idx, 0) + 1) % opts.size()]
	else:
		main.resolution_idx = (main.resolution_idx + 1) % main.resolutions.size()
	main.host_resolution = main.compute_requested_resolution()
	_save_setting(main._ui_res_btn, _resolution_btn_label())
	_schedule_stream_restart()

# The MAX ceiling (compute_resolution_options()[0]) depends on codec_preference
# and native_resolution, both of which can change without the user ever
# touching the resolution button itself (codec cycling, monitors being
# added/removed, the host's real desktop turning out a different size than
# assumed) - call this after any of those to keep the button's label honest
# instead of showing a stale percentage that no longer matches what's actually
# being requested.
func refresh_resolution_btn_label():
	if main._ui_res_btn:
		main.ui_controller.update_option_btn(main._ui_res_btn, _resolution_btn_label())

func _resolution_btn_label() -> String:
	if not main.is_polaris_host:
		return main.resolution_labels[main.resolution_idx]
	var opts = main.compute_resolution_options()
	# Show the actual resulting pixel dimensions, not just an abstract
	# percentage - a bare "%" doesn't tell you what you're really getting once
	# any of compute_requested_resolution()'s caps are in play (which is
	# exactly the case whenever this shows "MAX").
	var res = main.compute_requested_resolution()
	var dims = "%dx%d" % [res.x, res.y]
	if main.resolution_scale_pct >= opts[0]:
		return "MAX (%s)" % dims
	return "%d%% (%s)" % [main.resolution_scale_pct, dims]

# Best-effort, cached, one-time-per-host-selection probe for whether this host
# is a Polaris server (which reports its real, possibly multi-monitor desktop
# size via a display-manifest extension no other GameStream-compatible host
# implements) vs everything else, e.g. Sunshine, which is client-driven - the
# client picks a resolution and the host adapts to match it, so there's
# nothing for it to report and main.is_polaris_host correctly defaults to
# false (the old fixed-list picker) for it. Deliberately decoupled from the
# connect/launch flow itself: the original pre-launch probe (removed in
# 6a5c17d) shared an HTTP/session lock with establish_stream() and was a
# plausible contributor to a real connection hang. This fires once when a
# host is selected in the welcome-screen UI, well before any stream launch,
# and never blocks or gates anything - is_polaris_host just keeps whatever
# value it already had (loaded from host_state.cfg, or the false default for
# a never-seen host) until this resolves.
func detect_polaris_host(ip: String, host_id: int):
	if ip.is_empty() or host_id < 0:
		return
	main.stream_backend.fetch_display_manifest(host_id, func(manifest: Dictionary):
		var was_polaris = main.is_polaris_host
		main.is_polaris_host = manifest is Dictionary and not manifest.is_empty()
		if main.is_polaris_host != was_polaris:
			refresh_resolution_btn_label()
			main.ui_controller.update_monitor_tab()
			main.state_manager.save_host_state()
	)

func cycle_bitrate():
	main.bitrate_idx += 1
	if main.bitrate_idx >= main.bitrate_labels.size():
		main.bitrate_idx = -1
	var label = main.bitrate_labels[main.bitrate_idx + 1] if main.bitrate_idx >= 0 else "Auto"
	_save_setting(main._ui_bitrate_btn, label)
	_schedule_stream_restart()

func cycle_double_h():
	main.double_h = not main.double_h
	main.state_manager.save_state()
	_schedule_stream_restart()

func _schedule_stream_restart():
	if not main.is_streaming or main.current_host_id < 0:
		return
	_restart_pending = true
	_restart_seq += 1
	var my_seq = _restart_seq
	await main.get_tree().create_timer(0.8).timeout
	if _restart_seq != my_seq:
		return
	_restart_pending = false
	main._log("[RESTART] Restarting stream")
	apply_display_refresh_rate()
	main._restarting_stream = true
	# Stop the composition layer shader from referencing the current session's
	# texture BEFORE tearing the connection down. stop_play_stream() triggers
	# native decoder cleanup, which frees the underlying GPU texture/uniform
	# set synchronously (on the decode/cleanup thread) - if the shader
	# material still points at it when that happens, the OpenXR compositor's
	# own render pass (independent of our own binding code) can end up
	# rebuilding a uniform set against an already-freed texture on the render
	# thread, which crashes (not just renders wrong). Clearing first and
	# yielding a frame gives the renderer a chance to actually pick up the
	# null texture before the free happens, closing that race instead of
	# just narrowing it.
	main._clear_comp_yuv_textures()
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	main.stream_backend.stop_play_stream()
	await main.get_tree().create_timer(0.5).timeout
	main.stream_manager.start_stream(main.current_host_id, main._selected_app_id)

func toggle_hand_tracking():
	main.tracking_mode = (main.tracking_mode + 1) % 2
	main.state_manager.save_state()
	main.state_manager.sync_ui_to_settings()

func apply_screen_layout(new_layout: ScreenLayout):
	var err = new_layout.validate(new_layout.frame_size)
	if err != "":
		main._log("[LAYOUT] Refusing invalid layout: %s" % err)
		return
	var wanted_ids: Array = []
	for m in new_layout.enabled_monitors():
		wanted_ids.append(m.id)
	# The screen about to be replaced as primary (e.g. the welcome screen's
	# placeholder on the very first real connect) - used below to hand its exact
	# position off to whatever takes over as primary, instead of add_screen()
	# positioning the new one "next to" a screen that's about to disappear.
	var old_primary_being_replaced: VRScreen = main.primary_screen if (main.primary_screen and not wanted_ids.has(main.primary_screen.monitor_id)) else null
	var new_primary: VRScreen = null
	# add_screen() positions each new VRScreen relative to whichever screens
	# already exist, purely by insertion order (grows left/right of primary).
	# The manifest's monitor array order is the host's own RandR enumeration
	# order, not spatial order (confirmed: a 4-monitor grid capture came back
	# as [HDMI-0, DP-0, DP-2, DP-4], not left-to-right) - inserting in that
	# raw order scattered screens in VR space in an order that didn't match
	# their real desktop_rect positions, looking "scrambled". Sort by real
	# x-position first so insertion order matches physical left-to-right order.
	var ordered_monitors := new_layout.enabled_monitors()
	ordered_monitors.sort_custom(func(a, b): return a.desktop_rect.position.x < b.desktop_rect.position.x)
	for m in ordered_monitors:
		var existing: VRScreen = null
		for s in main.screens:
			if s.monitor_id == m.id:
				existing = s
				break
		var s = existing if existing else main.add_screen(m.id, m.desktop_rect.position.x, m.is_primary)
		if s == null:
			continue
		s.apply_monitor(m, new_layout.frame_size)
		if m.is_primary:
			new_primary = s
	if old_primary_being_replaced and new_primary and new_primary != old_primary_being_replaced:
		new_primary.global_transform = old_primary_being_replaced.global_transform
	main.layout = new_layout
	# Reassign primary BEFORE removing unwanted screens below - remove_screen()
	# refuses to remove whatever is currently primary_screen (a real safety net
	# for normal add/remove-monitor flows), but on the very first real connect
	# the welcome screen's placeholder VRScreen *is* primary_screen, with a
	# monitor_id that's essentially never going to match the real manifest's
	# primary id. Removing in the old order left that placeholder permanently
	# stuck (un-removable, since it was still primary_screen at removal time)
	# with its own grab bar, while the real primary got added next to it
	# instead of replacing it - "screen appears in the wrong position, two
	# grab bars" was this, not a positioning bug in add_screen() itself.
	if new_primary and new_primary != main.primary_screen:
		main.set_primary_screen(new_primary)
		# Stereo/AI-3D (switch_to_stereo_comp_layer()) only ever activates
		# whatever was primary AT THE TIME it was called - it sets up that
		# screen's own comp_cylinder_left/right visibility, viewport update
		# mode, and stereo_mode shader param, none of which set_primary_screen()
		# above carries over to the new primary. On the very first real
		# connect (this branch always runs then: the welcome screen's
		# placeholder VRScreen is primary with a monitor_id that can't match
		# any real manifest id), that left the real primary silently stuck in
		# flat/non-stereo comp-layer mode even with SBS/AI-3D still toggled
		# on - looked correct on the welcome screen (where it WAS applied)
		# and broken the moment the stream's real manifest swapped primary in.
		apply_stereo()
	for s in main.screens.duplicate():
		if not wanted_ids.has(s.monitor_id):
			main.remove_screen(s.monitor_id)
	main.screen_manager.resize_screen_to_aspect(new_layout.frame_size.x, new_layout.frame_size.y)
	if main.comp.available:
		main.comp.update_cylinder_params()
	if main.comp.in_use and main.is_streaming:
		main.comp.invalidate_yuv_cache()
		main.comp.bind_yuv_textures()
	main.ui_controller.update_monitor_tab()

# ---------------------------------------------------------------------------
# Monitors tab (grid-mode redesign): staged Monitors/Virtual counts + preset
# picker, committed together by Apply. Nothing below auto-restarts the stream
# or touches main.layout/screens until apply_staged_monitor_config() runs -
# per spec this needed "a lot more to consider" than the old per-toggle
# auto-restart behavior above. Grid/free screen placement here is purely
# client-side VR presentation (MonitorGrid) and never touches ScreenLayout/
# MonitorSpec beyond enabled/is_primary, which apply_screen_layout() (above,
# unmodified) already owns.
# ---------------------------------------------------------------------------

func _real_monitor_count() -> int:
	var count = 0
	for m in main.layout.monitors:
		if not m.hint.get("virtual", false) and m.capturable:
			count += 1
	return count

func staged_total() -> int:
	return main._staged_physical_count + main._staged_virtual_count

func _clear_staged_preset_if_mismatched():
	if main._staged_preset_id == &"":
		return
	var p = MonitorPresets.find_preset(String(main._staged_preset_id))
	if p.is_empty() or p.get("screen_count", -1) != staged_total():
		main._staged_preset_id = &""

# Call whenever the Monitors tab is opened, so its dropdowns reflect what's
# actually live rather than whatever was last staged in a previous visit.
func sync_staged_from_current_layout():
	var real_enabled = 0
	var virtual_enabled = 0
	for m in main.layout.monitors:
		if not m.enabled:
			continue
		if m.hint.get("virtual", false):
			virtual_enabled += 1
		else:
			real_enabled += 1
	main._staged_physical_count = maxi(real_enabled, 1)
	main._staged_virtual_count = virtual_enabled
	main._staged_preset_id = &""

func stage_monitor_count(n: int):
	main._staged_physical_count = clampi(n, 1, maxi(_real_monitor_count(), 1))
	main._staged_virtual_count = clampi(main._staged_virtual_count, 0, main.MAX_SCREENS - main._staged_physical_count)
	_clear_staged_preset_if_mismatched()
	main._log("[LAYOUT] stage_monitor_count(%d): real_monitor_count=%d -> staged_physical=%d" % [n, _real_monitor_count(), main._staged_physical_count])

func stage_virtual_count(n: int):
	main._staged_virtual_count = clampi(n, 0, main.MAX_SCREENS - main._staged_physical_count)
	_clear_staged_preset_if_mismatched()

func select_monitor_preset(id: StringName):
	if MonitorPresets.find_preset(String(id)).is_empty():
		return
	main._staged_preset_id = id

# Builds the ScreenLayout implied by the current staged counts: the N
# leftmost real (non-virtual) monitors from the live manifest, plus M
# client-side-only virtual placeholders (hint.virtual=true, see
# stream_manager.gd::_compute_capture_outputs() for why those are excluded
# from the real outputs= request). Real monitors' frame_rect/desktop_rect are
# carried over untouched; only enabled/is_primary and the synthetic virtual
# entries are new.
func _build_staged_layout() -> ScreenLayout:
	var real_monitors: Array = []
	for m in main.layout.monitors:
		# Excludes capturable=false (connected-but-disabled host outputs) too, not just
		# virtual placeholders - otherwise the N-leftmost-by-x pick below can select a
		# monitor the host will always refuse, silently wasting a slot (the host drops it
		# from capture but this client still thinks it asked for N real monitors).
		if not m.hint.get("virtual", false) and m.capturable:
			real_monitors.append(m)
	main._log("[LAYOUT] _build_staged_layout: main.layout.monitors=%d real=%d staged_physical=%d staged_virtual=%d source=%s" % [main.layout.monitors.size(), real_monitors.size(), main._staged_physical_count, main._staged_virtual_count, str(main.layout.source)])
	if real_monitors.is_empty():
		return null
	real_monitors.sort_custom(func(a, b): return a.desktop_rect.position.x < b.desktop_rect.position.x)
	var phys_count = clampi(main._staged_physical_count, 1, real_monitors.size())
	var picked: Array = real_monitors.slice(0, phys_count)

	var new_layout := ScreenLayout.new()
	new_layout.version = main.layout.version
	new_layout.source = main.layout.source
	new_layout.frame_size = main.layout.frame_size
	new_layout.desktop_bounds = main.layout.desktop_bounds

	for m in real_monitors:
		var nm := ScreenLayout.MonitorSpec.new()
		nm.id = m.id
		nm.label = m.label
		nm.frame_rect = m.frame_rect
		nm.desktop_rect = m.desktop_rect
		nm.hint = {}
		nm.enabled = picked.has(m)
		nm.is_primary = false
		new_layout.monitors.append(nm)

	var vcount = clampi(main._staged_virtual_count, 0, main.MAX_SCREENS - phys_count)
	_append_virtual_placeholders(new_layout, vcount)

	var enabled := new_layout.enabled_monitors()
	if enabled.is_empty():
		return null
	enabled[0].is_primary = true
	return new_layout

# Client-side-only synthetic monitors (no real RandR output behind them - see
# stream_manager.gd::_compute_capture_outputs(), which skips hint.virtual
# entries when building the real outputs= request). Placed just past the real
# desktop's right edge so they don't overlap any real monitor's desktop_rect.
func _append_virtual_placeholders(layout: ScreenLayout, vcount: int):
	var max_x = layout.desktop_bounds.position.x + layout.desktop_bounds.size.x
	for i in range(vcount):
		var vm := ScreenLayout.MonitorSpec.new()
		vm.id = StringName("virtual_%d" % i)
		vm.label = ""
		vm.enabled = true
		vm.is_primary = false
		vm.frame_rect = Rect2i(0, 0, layout.frame_size.x, layout.frame_size.y)
		vm.desktop_rect = Rect2i(max_x + i * layout.frame_size.x, layout.desktop_bounds.position.y, layout.frame_size.x, layout.frame_size.y)
		vm.hint = {"virtual": true}
		layout.monitors.append(vm)

# Primary first (never repositioned by preset apply - it's the free-mode
# anchor everything else is placed relative to), then the rest sorted by real
# desktop x position - deterministic and matches apply_screen_layout()'s own
# insertion order in the common case.
func _screens_in_ordinal_order() -> Array:
	if not main.primary_screen:
		return []
	var rest: Array = []
	for s in main.screens:
		if s != main.primary_screen:
			rest.append(s)
	rest.sort_custom(func(a, b):
		var ax = a.monitor.desktop_rect.position.x if a.monitor else a.global_position.x
		var bx = b.monitor.desktop_rect.position.x if b.monitor else b.global_position.x
		return ax < bx
	)
	var ordered: Array = [main.primary_screen]
	ordered.append_array(rest)
	return ordered

func _place_secondaries_default(secondaries: Array):
	var primary: VRScreen = main.primary_screen
	if primary.grid_pos == Vector2i(-1, -1):
		primary.grid_pos = Vector2i(3, 1)
	primary.grid_mode = true
	var occupied: Array = [primary.grid_pos]
	for s in secondaries:
		var cand = main.nearest_free_grid_cell(s.global_position, occupied, primary.grid_pos.x, primary.grid_pos.y)
		if cand.x < 0:
			continue
		occupied.append(cand)
		s.grid_mode = true
		s.grid_pos = cand
		s.global_transform = main.grid_cell_transform(cand.x, cand.y, primary.grid_pos.x, primary.grid_pos.y)

# Applies the selected preset's per-screen grid/free position onto the
# VRScreens apply_screen_layout() just created/kept, in ordinal order. Falls
# back to a sane grid default (primary keeps its grid_pos or [3,1], others
# auto-placed via nearest_free_cell) when no preset is staged or its
# screen_count no longer matches what's actually enabled.
func _apply_preset_positions_to_screens():
	var ordered: Array = _screens_in_ordinal_order()
	if ordered.is_empty():
		return
	var primary: VRScreen = ordered[0]
	var preset := {}
	if main._staged_preset_id != &"":
		var p = MonitorPresets.find_preset(String(main._staged_preset_id))
		if not p.is_empty() and p.get("screen_count", -1) == ordered.size():
			preset = p
	if preset.is_empty():
		_place_secondaries_default(ordered.slice(1))
	else:
		var screens_data: Array = preset.get("screens", [])
		for i in range(ordered.size()):
			var s: VRScreen = ordered[i]
			var data: Dictionary = screens_data[i]
			var is_grid: bool = data.get("grid_mode", true)
			s.grid_mode = is_grid
			if is_grid:
				var gp: Array = data.get("grid_pos", [3, 1])
				s.grid_pos = Vector2i(gp[0], gp[1])
			if s == primary:
				continue
			if is_grid:
				s.global_transform = main.grid_cell_transform(s.grid_pos.x, s.grid_pos.y, primary.grid_pos.x, primary.grid_pos.y)
			else:
				var fp: Array = data.get("free_pos", [s.position.x, s.position.y, s.position.z])
				var fr: Array = data.get("free_rot", [s.rotation.x, s.rotation.y, s.rotation.z])
				s.position = Vector3(fp[0], fp[1], fp[2])
				s.rotation = Vector3(fr[0], fr[1], fr[2])
	# Primary itself is deliberately never repositioned above (it's the free-
	# mode anchor everything else is placed relative to) - but Godot's
	# CollisionObject3D only pushes a node's transform to PhysicsServer3D on
	# NOTIFICATION_TRANSFORM_CHANGED, which a node that never actually moves
	# never receives. Confirmed live: right after adding a second monitor,
	# primary's own pointer/raycast interaction went laggy/unusable (its
	# Area3D's physics-side transform was stale relative to whatever the new
	# secondary's Area3D just did to the broadphase) until manually grabbing
	# and moving primary even slightly, which fixed it - because a real grab
	# always writes global_position, firing the notification this never
	# otherwise gets. Reassigning to its own current transform is a no-op
	# geometrically but still fires that notification, without needing an
	# actual (visible) move.
	primary.global_transform = primary.global_transform
	if main.comp.available:
		main.comp.update_cylinder_params()

# Re-derives world transform for every grid-mode secondary from its existing
# grid_pos. Needed whenever curvature changes: a grid cell's world position
# depends on curvature/radius (_grid_screen_transforms() measures gaps against
# the curved edge, see main.gd), but grid_pos itself is just coordinates and
# doesn't change with curvature - so without this, a screen placed under the
# old curvature keeps its old (now wrong) position/rotation until something
# else, like a drag, happens to recompute it.
func reflow_grid_screens():
	var primary: VRScreen = main.primary_screen
	if not primary or primary.grid_pos == Vector2i(-1, -1):
		return
	for s in main.screens:
		if s == primary or not s.grid_mode or s.grid_pos == Vector2i(-1, -1):
			continue
		s.global_transform = main.grid_cell_transform(s.grid_pos.x, s.grid_pos.y, primary.grid_pos.x, primary.grid_pos.y)

# The only place that actually calls apply_screen_layout() from the new
# Monitors tab. Cycling the Monitors/Virtual dropdowns or picking a preset
# (Row 1/Row 2) never restarts anything on their own - clarification #9 asked
# for that ("a lot more to consider") - but Apply is the explicit commit
# point, and if the real (server-facing) monitor selection actually changed,
# the host needs a fresh outputs= request to capture the new set.
#
# A monitor's frame_rect (its position within the CAPTURED/composited video
# frame) is only meaningful once it's actually part of a live capture - one
# we haven't asked the host to capture yet reports frame_rect (0,0) in the
# manifest (there's no video content for it at all), which
# apply_screen_layout()'s validate() correctly refuses. So when the real
# selection changes, this does NOT try to build/position VR screens against
# that stale/invalid geometry up front - it only updates which real monitors
# are enabled/primary (what the next launch's outputs= will request) and
# restarts; the restart's own fresh manifest response
# (stream_manager.gd::_on_v2_launch_response) re-derives and applies a fully
# valid ScreenLayout once the host actually replies with real geometry for the
# new set, and finish_pending_monitor_apply() (called from there) finishes the
# job - adding virtual placeholders (never reported by any real manifest) and
# positioning every screen per the staged preset.
func apply_staged_monitor_config():
	var target = _build_staged_layout()
	if target == null:
		main._log("[LAYOUT] apply_staged_monitor_config: _build_staged_layout() returned null (no real monitors known yet)")
		return
	var old_real_ids: Array = []
	for m in main.layout.enabled_monitors():
		if not m.hint.get("virtual", false):
			old_real_ids.append(m.id)
	var new_real_ids: Array = []
	for m in target.enabled_monitors():
		if not m.hint.get("virtual", false):
			new_real_ids.append(m.id)
	var real_changed = old_real_ids != new_real_ids
	main._log("[LAYOUT] apply_staged_monitor_config: staged=%d+%dvirtual old_real=%s new_real=%s real_changed=%s streaming=%s" % [main._staged_physical_count, main._staged_virtual_count, str(old_real_ids), str(new_real_ids), str(real_changed), str(main.is_streaming)])

	if real_changed and main.is_streaming:
		var new_primary = target.get_primary()
		var new_primary_id = new_primary.id if new_primary else &""
		for m in main.layout.monitors:
			if m.hint.get("virtual", false):
				continue
			m.enabled = new_real_ids.has(m.id)
			m.is_primary = (m.id == new_primary_id)
		# Narrowing to exactly one real monitor makes the resulting capture
		# size exactly knowable right now, client-side: that monitor's own
		# frame_rect (already reported in the last manifest) doesn't change
		# size when captured alone - only its position within the composite
		# does (ScreenLayout always repositions a lone monitor to the
		# origin). Update native_resolution before scheduling the restart so
		# the very first launch of the new session already requests the
		# right size, instead of restarting at the OLD (still-cached)
		# composite size and relying on _process()'s "doesn't match cached
		# size" mismatch-retry to correct it via a SECOND restart -
		# confirmed via logcat to cost a real ~10s stall decoding an
		# oversized stream before self-correcting. General N>1 targets are
		# deliberately left to that same mismatch-retry (see its comment in
		# main.gd) - an arbitrary multi-monitor composite's exact frame_size
		# depends on host-side gap-filling this client can't predict.
		if new_real_ids.size() == 1:
			for m in main.layout.monitors:
				if m.id == new_real_ids[0]:
					main.native_resolution = m.frame_rect.size
					break
		main._pending_monitor_apply = true
		_schedule_stream_restart()
	else:
		apply_screen_layout(target)
		_apply_preset_positions_to_screens()

	main.host_resolution = main.compute_requested_resolution()
	main.state_manager.save_host_state()
	if main._ui_status_label:
		if real_changed and main.is_streaming:
			main.ui_controller.set_status("Applying - restarting stream for new monitor selection...")
		elif main._staged_virtual_count > 0:
			main.ui_controller.set_status("%d virtual monitor(s) - placeholder only, not yet requested from server" % main._staged_virtual_count)
		else:
			main.ui_controller.set_status("Monitor layout applied")

# Called once by stream_manager.gd's launch-response handler right after it
# applies the fresh post-restart manifest (real frame_rect data now valid for
# the newly-requested set). Re-adds any staged virtual placeholders (the
# server-sourced manifest only ever describes real outputs, so
# apply_screen_layout() would otherwise have just dropped them) and applies
# the staged preset's grid/free positions now that every screen actually exists.
func finish_pending_monitor_apply():
	if main._staged_virtual_count > 0:
		var with_virtual := ScreenLayout.new()
		with_virtual.version = main.layout.version
		with_virtual.source = main.layout.source
		with_virtual.frame_size = main.layout.frame_size
		with_virtual.desktop_bounds = main.layout.desktop_bounds
		with_virtual.monitors = main.layout.monitors.duplicate()
		_append_virtual_placeholders(with_virtual, main._staged_virtual_count)
		apply_screen_layout(with_virtual)
	_apply_preset_positions_to_screens()

func save_current_as_preset():
	var ordered = _screens_in_ordinal_order()
	if ordered.is_empty():
		return
	var screens_data: Array = []
	for s in ordered:
		var gp = s.grid_pos if s.grid_pos != Vector2i(-1, -1) else Vector2i(3, 1)
		screens_data.append({
			"is_primary": s == main.primary_screen,
			"grid_mode": s.grid_mode,
			"grid_pos": [gp.x, gp.y],
			"free_pos": [s.position.x, s.position.y, s.position.z],
			"free_rot": [s.rotation.x, s.rotation.y, s.rotation.z],
		})
	var customs = MonitorPresets.load_custom_presets()
	var id = MonitorPresets.next_custom_id(customs)
	customs.append({
		"version": 1,
		"id": id,
		"built_in": false,
		"screen_count": screens_data.size(),
		"screens": screens_data,
	})
	MonitorPresets.save_custom_presets(customs)
	main._staged_preset_id = StringName(id)
	if main._ui_status_label:
		main.ui_controller.set_status("Preset saved")

func remove_selected_preset():
	if main._staged_preset_id == &"":
		return
	var p = MonitorPresets.find_preset(String(main._staged_preset_id))
	if p.is_empty() or p.get("built_in", false):
		return
	MonitorPresets.remove_custom_preset(String(main._staged_preset_id))
	main._staged_preset_id = &""
	if main._ui_status_label:
		main.ui_controller.set_status("Preset removed")

func toggle_grid_mode():
	main.grid_mode_enabled = not main.grid_mode_enabled
	main.state_manager.save_state()
	if main._ui_grid_mode_btn:
		main.ui_controller.update_option_btn(main._ui_grid_mode_btn, "On" if main.grid_mode_enabled else "Off")
