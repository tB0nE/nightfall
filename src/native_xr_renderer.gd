class_name NativeXrRendererManager
extends RefCounted

# Production bridge for the Android/GLES composition-layer renderer. The
# legacy Godot viewport path remains live as a fallback and for multi-monitor
# and depth diagnostic modes.

var main: Node3D
var renderer = null
var provider_registered := false
var active := false
var stream_started := false
var legacy_disabled := false
var failure_reason := ""
var _last_size := Vector2i.ZERO
var _last_mode := -1
var _last_eligible := false
var _stats_upload_delay := -1
var _stale_recovery_until_msec := 0

const STALE_EYE_RECOVERY_MSEC := 2000

func _init(owner: Node3D) -> void:
	main = owner

func setup() -> void:
	if OS.get_name() != "Android":
		failure_reason = "non-Android platform"
		return
	if RenderingServer.get_current_rendering_method() != "gl_compatibility":
		failure_reason = "renderer is not GLES"
		return
	if "--nf-legacy-video" in OS.get_cmdline_user_args():
		failure_reason = "legacy override"
		return
	if not ClassDB.class_exists("NightfallXrRenderer"):
		failure_reason = "native extension unavailable"
		return
	renderer = ClassDB.instantiate("NightfallXrRenderer")
	if renderer == null or not renderer.register_provider():
		renderer = null
		failure_reason = "composition provider registration failed"
		return
	provider_registered = true
	main._log("[NATIVE-XR] Composition provider registered")

func _mode() -> int:
	return main.settings_controller.get_stereo_mode() if main.settings_controller else 0

func _eligible() -> bool:
	if not provider_registered or not main.is_streaming or main.screens.size() != 1:
		return false
	# _schedule_stream_restart() deactivates this renderer, then awaits a
	# couple of frame boundaries before actually freeing the decoder/texture
	# state via stop_play_stream(). process_frame() -> refresh() runs every
	# frame regardless, so without this guard _eligible() keeps returning
	# true through those awaits and re-activates the renderer (renderer.start())
	# right as the decoder/OES state it reads is about to be torn down -
	# a null-pointer GLThread crash inside NightfallStream::stop_stream()'s
	# call chain, confirmed via adb logcat crash buffer (SIGSEGV, fault
	# addr 0xe0, repeated across a test session with heavy setting toggling).
	if main._restarting_stream:
		return false
	# A per-eye freeze -- stale pose/subImage resubmitted at the OpenXR
	# layer-collection level while the other eye keeps updating normally --
	# has been observed on-device, triggered by head rotation and unrelated
	# to any setting change (see has_stale_eye_layer()'s C++ comment for the
	# detection mechanism). The legacy renderer doesn't submit per-eye
	# composition layers, so it isn't subject to this. Rather than leave the
	# affected eye stuck indefinitely, fall back to legacy for a cooldown
	# window and then let this renderer resume automatically -- a transient
	# outage instead of a stuck frame.
	if active and renderer.has_stale_eye_layer():
		_stale_recovery_until_msec = Time.get_ticks_msec() + STALE_EYE_RECOVERY_MSEC
		main._log("[NATIVE-XR] Stale eye layer detected; falling back to legacy renderer for %dms" % STALE_EYE_RECOVERY_MSEC)
		return false
	if Time.get_ticks_msec() < _stale_recovery_until_msec:
		return false
	# Auto-detection and the optional shader filters consume the legacy RGB
	# viewport. Fall back while they are selected instead of silently showing
	# stale detection data or ignoring a user's picture setting.
	if main.auto_detect_enabled or main.smooth_mode != 0 or main.sharpen_mode != 0:
		return false
	var mode := _mode()
	if mode >= 7 and mode <= 9:
		return false
	if main.primary_screen and main.primary_screen.curvature > 0 and not renderer.supports_cylinder():
		return false
	return true

func refresh() -> void:
	var eligible := _eligible()
	if not eligible:
		if active:
			deactivate(true)
		_last_eligible = false
		return
	var size := Vector2i(main.stream_backend.get_video_width(), main.stream_backend.get_video_height())
	if size.x <= 0 or size.y <= 0:
		return
	var mode := _mode()
	if not stream_started or size != _last_size:
		if not renderer.start(size.x, size.y):
			failure_reason = "swapchain or GLES initialization failed"
			main._log("[NATIVE-XR] Start failed; retaining legacy renderer")
			deactivate(true)
			return
		stream_started = true
		_last_size = size
		main._log("[NATIVE-XR] Native stream renderer ready at %dx%d" % [size.x, size.y])
	active = true
	_last_mode = mode
	_last_eligible = true
	_sync_geometry()
	# Hand off immediately after the native swapchain is ready. Keeping the
	# legacy Texture2DRD proxies alive while a restarted decoder is replacing
	# their backing textures can make Godot's GLThread dereference a null
	# remap target. The native renderer simply remains black until its first
	# decoder frame arrives, normally less than one display interval later.
	if not legacy_disabled:
		main.stream_backend.set_native_direct_mode(true)
		if main.depth_estimator:
			main.depth_estimator.set_native_renderer_active(true)
		_disable_legacy_video()
		legacy_disabled = true
		renderer.set_overlay_visible(main.performance_overlay_enabled)
		if main.performance_overlay_enabled:
			request_stats_overlay_update()
		main._log("[NATIVE-XR] Native renderer active; legacy full-resolution passes disabled")

func _sync_geometry() -> void:
	if not active or not main.primary_screen:
		return
	var screen: VRScreen = main.primary_screen
	var transform: Transform3D = screen.global_transform
	var radius: float = screen.get_cylinder_radius() if screen.curvature > 0 else 1.0
	var central_angle: float = screen.mesh_size.x / radius if screen.curvature > 0 else 0.01
	if screen.curvature > 0:
		var screen_forward: Vector3 = -screen.global_transform.basis.z
		transform.origin = screen.global_position - screen_forward * radius
	var view_dist := maxf((screen.global_position - main.xr_camera.global_position).length(), 0.5)
	var sort_order := clampi(int((10.0 - view_dist) * 10.0), 1, 100)
	renderer.set_geometry(transform, screen.mesh_size.x, screen.mesh_size.y,
			screen.curvature, radius, central_angle, sort_order, main.bezel_enabled)

func _disable_legacy_video() -> void:
	var screen = main.primary_screen
	if not screen:
		return
	for layer in [screen.comp_cylinder, screen.comp_cylinder_left, screen.comp_cylinder_right]:
		if layer:
			layer.visible = false
	for viewport in [screen.comp_viewport, screen.comp_viewport_left, screen.comp_viewport_right]:
		if viewport:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

func process_frame(new_frame: bool) -> void:
	refresh()
	_process_stats_upload()
	if not active or not new_frame:
		return
	var oes_id: int = main.stream_backend.get_oes_texture_id()
	if oes_id == 0:
		# This is normal during decoder startup/restart. Retain the prepared
		# native swapchain and wait for the first published OES frame instead
		# of thrashing back into the legacy renderer.
		return
	var mode := _mode()
	var depth_id := 0
	var guide_id := 0
	var separation := 0.0
	if mode == 6 or mode == 10 or mode == 11:
		var depth = main.depth_estimator
		if depth and depth.depth_texture:
			guide_id = main.stream_backend.get_native_depth_guide_texture_id()
			if guide_id != 0:
				depth_id = RenderingServer.texture_get_native_handle(depth.depth_texture.get_rid())
				separation = depth._pass_parallax
	var matrix: PackedFloat32Array = main.stream_backend.get_oes_transform_matrix()
	if matrix.size() < 16:
		return
	var fence: int = main.stream_backend.get_oes_ready_fence()
	renderer.submit_frame(true, oes_id, depth_id, guide_id, matrix,
			3.0, main.primary_screen.mesh_size.x, false, separation,
			false, main.passthrough_enabled, fence, mode,
			main.depth_estimator.depth_revision if main.depth_estimator else 0)

func request_stats_overlay_update() -> void:
	if active:
		if renderer and stream_started:
			renderer.set_overlay_visible(main.performance_overlay_enabled)
		_stats_upload_delay = 1

func set_stats_visible(value: bool) -> void:
	if renderer and stream_started:
		renderer.set_overlay_visible(value)
	if value:
		request_stats_overlay_update()

func _process_stats_upload() -> void:
	if _stats_upload_delay < 0 or not active or not renderer.has_rendered_frame():
		return
	if _stats_upload_delay > 0:
		_stats_upload_delay -= 1
		return
	_stats_upload_delay = -1
	if not main.comp or not main.comp.stats_viewport:
		return
	var image: Image = main.comp.stats_viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	if image.get_size() != Vector2i(768, 512):
		image.resize(768, 512)
	# Godot Images are top-left-origin while glTexSubImage2D feeds the OpenXR
	# overlay texture bottom-left-origin data.
	image.flip_y()
	renderer.upload_overlay(image.get_data(), 768, 512)

func deactivate(restore_legacy: bool) -> void:
	if main.stream_backend:
		main.stream_backend.set_native_direct_mode(false)
	if main.depth_estimator:
		main.depth_estimator.set_native_renderer_active(false)
	active = false
	legacy_disabled = false
	_stats_upload_delay = -1
	if stream_started and renderer:
		renderer.stop_stream()
	stream_started = false
	_last_size = Vector2i.ZERO
	if restore_legacy and main.is_streaming and main.comp and main.comp.available:
		var mode := _mode()
		if mode > 0:
			main.comp.switch_to_stereo_comp_layer()
		else:
			main.comp.switch_to_comp_layer()
		# Re-sync the legacy overlay now that this renderer is no longer the
		# one presenting it - see toggle_performance_overlay()'s comment for
		# why the two display paths must stay mutually exclusive.
		main.comp.set_stats_visible(main.performance_overlay_enabled and main.is_streaming)

func shutdown() -> void:
	if main.stream_backend:
		main.stream_backend.set_native_direct_mode(false)
	if main.depth_estimator:
		main.depth_estimator.set_native_renderer_active(false)
	active = false
	legacy_disabled = false
	stream_started = false
	if renderer:
		renderer.shutdown()
	renderer = null
	provider_registered = false

func get_warp_gpu_ms() -> float:
	return renderer.get_warp_gpu_ms() if renderer and active else 0.0
