class_name DepthEstimatorModule
extends RefCounted

var main: Node3D
var depth_viewport: SubViewport
var depth_target: ColorRect
var depth_target_mat: ShaderMaterial
var depth_texture: ImageTexture
var depth_revision: int = 0
var enabled: bool = false
var submit_timer: float = 0.0
# 20Hz, matching Gilleece/moonlight-android-xr's own cadence comment ("depth
# arrives at about 20Hz") and their own tuned/shipped default - trusted as
# measured rather than re-litigated here. A 10Hz middle ground was tried
# after the JNI depth pipeline was fixed from being silently broken (see git
# history around 2026-08-17) to rule out this cadence as the cause of
# DMap detail loss / GPU-NNAPI stutter observed at 20Hz, but the user
# confirmed on-device that 20Hz gives back full DMap detail (a clock widget
# that had disappeared) - so the stutter and detail-loss symptoms are NOT
# from this cadence. More likely cause: depth_upsample.gdshader /
# depth_offset.gdshader's own per-render-frame warp passes (see
# _setup_warp_passes() below), since baseline stereo_mode 3/4 (which skips
# those passes entirely) stays smooth even though its own postProcess does
# MORE CPU work per call via dilate+blur. That's the next thing to fix, not
# this value.
var submit_interval: float = 0.05
# The Java GPU worker owns the 20 Hz inference clock. Match it here rather than
# paying for synchronous GPU readbacks which the latest-frame mailbox discards.
const GPU_FRAME_PUBLISH_INTERVAL := 0.05
const GPU_BOOST_REFRESH_INTERVAL := 15.0
# Native output dimensions of whichever model is currently active in
# DepthEstimator.java. No longer assumed square: sync_model_size() queries
# width and height whenever settings_controller.gd switches the active model,
# then resizes depth_viewport/depth_texture to match.
var model_width: int = 256
var model_height: int = 256
var _poll_timer: float = 0.0
var _backend_status_timer: float = 0.0
var _size_mismatch_log_timer: float = 0.0
var _perf_window: float = 0.0
var _perf_capture_usec: int = 0
var _perf_submit_usec: int = 0
var _perf_submitted: int = 0
var _perf_updates: int = 0
var _gpu_boost_active: bool = false
var _gpu_boost_refresh_timer: float = 0.0
var _native_depth_capture_active: bool = false
var _direct_stream_source_bound: bool = false
var _native_renderer_active: bool = false

# stereo_mode 5/6 (MiDaS-GPU / MiDaS-Std)'s upsample+offset passes - see
# depth_upsample.gdshader / depth_offset.gdshader for what these compute.
# Run once per frame, shared by both eyes, at a quarter of the stream's own
# resolution (matches Gilleece/moonlight-android-xr's own upsampleWidth =
# videoWidth/4) rather than at raw 256x256 or, worse, at full per-eye
# resolution - the latter is what made the first attempt at this tank
# performance, since the same expensive bilateral/search work was repeated
# per eye per full-res pixel instead of once for the whole frame.
const PASS_DIVISOR := 4
# stereo_mode 10 (MiDaS-Fast) only - shrinks the pre-pass's linear
# resolution further than PASS_DIVISOR, on the same GPU-cost theory as the
# throttle below. Selected via _pass_divisor in set_enabled() based on
# warp_tier. No power-of-2 requirement - this only ever feeds an integer
# division in GDScript (_resize_warp_passes(), called once per
# native_resolution change, not per-pixel/per-frame), so any divisor costs
# the same at runtime; only the resulting resolution (and therefore quality
# vs. GPU cost) changes.
const EX_PASS_DIVISOR := 10
const PASS_MIN_SIZE := 160
var _pass_divisor: int = PASS_DIVISOR
var upsample_viewport: SubViewport
var upsample_mat: ShaderMaterial
var offset_viewport: SubViewport
var offset_mat: ShaderMaterial
# stereo_mode 10 only: throttles these two passes to UPDATE_ONCE on this
# timer instead of UPDATE_ALWAYS, re-rendering the occlusion search at
# warp_update_interval instead of every render frame (up to 90Hz), even
# though the depth data feeding them only refreshes at submit_interval's
# 20Hz. On-device testing (2026-08-18) found NO measurable FPS gain from
# this on stereo_mode 6 (MiDaS-Std, which stayed on UPDATE_ALWAYS as a
# result) - the pre-pass apparently isn't the actual bottleneck. Kept in
# this separate mode (not folded into MiDaS-Std) to keep poking at this
# without risking the known-good mode; the per-eye per-pixel Newton-
# refinement gather in yuv_display.gdshader (runs at full render resolution
# every frame regardless of this throttle) is the next suspect.
var warp_update_interval: float = 1.0 / 30.0
var _warp_timer: float = 0.0
var _warp_passes_active: bool = false
var _warp_throttled: bool = false
# 0 = MiDaS-Std (no throttling/shrinking - full quality, unthrottled), 1 =
# MiDaS-Fast. Set via set_enabled()'s warp_tier param; drives _pass_divisor
# and WARP_NEWTON_PERIOD below. Fastest (tier 2) was removed 2026-08-25 -
# on-device benchmarking found it near-identical to Fast at every tested
# resolution, not worth the extra tier.
var _warp_tier: int = 0
# stereo_mode 10 only - a 1-indexed counter, incremented every process()
# tick (one real render frame, see main.gd's _process()) while a throttled
# tier is active. Pushed to comp_shader_mat_left/right as warp_newton_steps
# (1 on the tick where counter % WARP_NEWTON_PERIOD[_warp_tier] == 0, else
# 0) - yuv_display.gdshader just reads that uniform directly rather than
# special-casing stereo_mode itself. MiDaS-Fast (tier 1) does 1 Newton step
# every 2nd frame (alternating), amortizing that per-pixel refinement cost
# across frames instead of paying it every frame.
const WARP_NEWTON_PERIOD: Array[int] = [1, 2]
var _warp_frame_counter: int = 0
# Matches Gilleece/moonlight-android-xr's own shipped default separation
# (0.5% of frame width). Tested bumping this to 0.02 (~3.3x) on the theory
# that magnitude was the remaining gap for why the depth effect still felt
# weak overall despite edges (taskbar etc.) looking correct - on-device
# testing found NO improvement at all, ruling magnitude out as the (sole)
# cause. Something more fundamental is still missing; revisit before trying
# magnitude again. See conversation history around 2026-08-17 for the full
# investigation (occlusion search, robust-range normalization, letterboxing,
# aliasing, render-order, and GPU-contention fixes all landed first and are
# confirmed working - this is what's left after all of that).
var _pass_parallax: float = 0.006
var _pass_size: Vector2i = Vector2i.ZERO

var _platform: String

func _init(owner: Node3D):
	main = owner
	_platform = OS.get_name()

func setup():
	# AI-3D depth estimation is native (no JNI/JVM) on Linux as of 2026-08-20
	# (see depth_bridge.cpp's NIGHTFALL_PLATFORM_LINUX branch/MidasDepthEngine) -
	# same "Android or Linux" check as settings_controller.gd's
	# _ai_3d_supported(). This guard used to be the ONLY thing gating AI-3D to
	# Android; missing this second copy of it when Linux support was added
	# left depth_viewport/depth_texture/upsample_viewport/offset_viewport
	# etc. all null while the rest of the pipeline (now unlocked via
	# settings_controller.gd) assumed setup() had actually run - a real
	# crash (segfault) the moment AI-3D activated on Linux, since several
	# call sites (_resize_warp_passes() in particular) don't null-check
	# before using these.
	if _platform != "Android" and _platform != "Linux":
		main._log("[DEPTH] Depth estimation disabled on " + _platform)
		return
	depth_viewport = SubViewport.new()
	depth_viewport.name = "DepthViewport"
	depth_viewport.size = Vector2i(model_width, model_height)
	depth_viewport.disable_3d = true
	depth_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	depth_viewport.transparent_bg = true

	# A plain shader-sampled ColorRect, NOT a TextureRect+STRETCH_SCALE (see
	# depth_downscale.gdshader for why that was replaced - it showed a
	# persistent crop to a sub-region of the frame, most likely a stale
	# cached source-size in TextureRect's stretch math not tracking
	# comp_viewport's live resizes). UV 0..1 always covers the FULL current
	# source texture with plain texture() sampling - depth_texture is
	# assumed to cover frame UV 0..1 1:1 everywhere else in the pipeline
	# (the warp shaders index into it via tile_uv directly), matching
	# Gilleece/moonlight-android-xr's own downscale (DOWNSCALE_FRAGMENT_SRC):
	# a plain UV stretch with no aspect correction at all.
	depth_target = ColorRect.new()
	depth_target.name = "DepthTarget"
	depth_target.set_anchors_preset(Control.PRESET_FULL_RECT)
	depth_target_mat = ShaderMaterial.new()
	depth_target_mat.shader = load("res://src/shaders/depth_downscale.gdshader")
	depth_target.material = depth_target_mat
	depth_viewport.add_child(depth_target)
	main.add_child(depth_viewport)

	var img = Image.create(model_width, model_height, false, Image.FORMAT_L8)
	depth_texture = ImageTexture.create_from_image(img)

	_setup_warp_passes()

	if main.primary_screen and main.primary_screen.material_override is ShaderMaterial:
		main.primary_screen.material_override.set_shader_parameter("depth_texture", depth_texture)
		main.primary_screen.material_override.set_shader_parameter("depth_guide_texture", depth_viewport.get_texture())
	if main.comp_shader_mat_left:
		main.comp_shader_mat_left.set_shader_parameter("depth_texture", depth_texture)
		main.comp_shader_mat_left.set_shader_parameter("upsampled_depth_texture", upsample_viewport.get_texture())
		main.comp_shader_mat_left.set_shader_parameter("offset_texture", offset_viewport.get_texture())
		main.comp_shader_mat_left.set_shader_parameter("depth_guide_texture", depth_viewport.get_texture())
	if main.comp_shader_mat_right:
		main.comp_shader_mat_right.set_shader_parameter("depth_texture", depth_texture)
		main.comp_shader_mat_right.set_shader_parameter("upsampled_depth_texture", upsample_viewport.get_texture())
		main.comp_shader_mat_right.set_shader_parameter("offset_texture", offset_viewport.get_texture())
		main.comp_shader_mat_right.set_shader_parameter("depth_guide_texture", depth_viewport.get_texture())

func _setup_warp_passes():
	upsample_viewport = SubViewport.new()
	upsample_viewport.name = "DepthUpsampleViewport"
	upsample_viewport.disable_3d = true
	upsample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	upsample_viewport.transparent_bg = true
	var upsample_rect = ColorRect.new()
	upsample_rect.color = Color.WHITE
	upsample_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	upsample_mat = ShaderMaterial.new()
	upsample_mat.shader = load("res://src/shaders/depth_upsample.gdshader")
	upsample_mat.set_shader_parameter("depth_texture", depth_texture)
	upsample_mat.set_shader_parameter("depth_guide_texture", depth_viewport.get_texture())
	upsample_rect.material = upsample_mat
	upsample_viewport.add_child(upsample_rect)
	main.add_child(upsample_viewport)

	offset_viewport = SubViewport.new()
	offset_viewport.name = "DepthOffsetViewport"
	offset_viewport.disable_3d = true
	offset_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	offset_viewport.transparent_bg = true
	var offset_rect = ColorRect.new()
	offset_rect.color = Color.WHITE
	offset_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_mat = ShaderMaterial.new()
	offset_mat.shader = load("res://src/shaders/depth_offset.gdshader")
	offset_mat.set_shader_parameter("upsampled_depth_texture", upsample_viewport.get_texture())
	offset_rect.material = offset_mat
	offset_viewport.add_child(offset_rect)
	main.add_child(offset_viewport)

	_resize_warp_passes()

# Sized off the REAL decoded stream resolution (2026-08-20, was
# main.native_resolution) rather than a fixed constant, so the passes track
# resolution changes/restarts. Cheap to call every frame - it's a no-op once
# the size matches. main.native_resolution is ONLY ever updated from a real
# host manifest (Polaris hosts) - Sunshine/GameStream hosts never send one,
# so for them it just stays at whatever stale value was last loaded from
# saved state (a previous host/session), completely disconnected from
# whatever resolution is actually being requested/decoded right now. This
# was the root cause of a real on-device bug (garbled horizontal band with
# AI-3D on, 21:9 2K specifically): the warp gather's own internal working
# resolution (target below) silently mismatched the real content's aspect,
# throwing off the offset-search math in depth_offset.gdshader/
# yuv_display.gdshader's Newton refinement. main.stream_viewport.size is
# always current (set directly from the video backend's real reported
# dimensions in stream_manager.gd's resize_stream_viewport()) regardless of
# host type - the same fix pattern as screen_manager.gd's
# resize_screen_to_aspect() (GitHub issue #17).
func _resize_warp_passes():
	# upsample_mat decodes YUV directly (see depth_upsample.gdshader) and
	# needs the same uv_region the primary screen's own materials use, so
	# its "hi" color sample lands on the same frame position the final
	# gather shader will warp. Kept outside the resize early-return below
	# since the primary screen's region can change independently of the
	# stream's own resolution (e.g. a monitor-selection change).
	if main.primary_screen:
		if depth_target_mat:
			depth_target_mat.set_shader_parameter("uv_region", main.primary_screen.uv_region)
		if upsample_mat:
			upsample_mat.set_shader_parameter("uv_region", main.primary_screen.uv_region)

	if not main.primary_screen or not main.stream_viewport:
		return
	var uv = main.primary_screen.uv_region
	var src = Vector2i(int(float(main.stream_viewport.size.x) * uv.z), int(float(main.stream_viewport.size.y) * uv.w))
	if src.x <= 0 or src.y <= 0:
		return
	var target = Vector2i(maxi(src.x / _pass_divisor, PASS_MIN_SIZE), maxi(src.y / _pass_divisor, PASS_MIN_SIZE))
	if target == _pass_size:
		return
	_pass_size = target
	upsample_viewport.size = target
	offset_viewport.size = target
	offset_mat.set_shader_parameter("disp_texels", _pass_parallax * float(target.x))
	for mat in [main.comp_shader_mat_left, main.comp_shader_mat_right]:
		if mat:
			mat.set_shader_parameter("mode5_parallax", _pass_parallax)

# Called from settings_controller.gd's apply_stereo() right after
# stream_backend.configure_depth() switches the active Java-side model -
# switchActiveModel() busy-waits out any in-flight inference before returning,
# so getModelWidth()/getModelHeight() are already correct for the new model
# by the time this runs. Resizes depth_viewport (the capture source fed INTO
# the model) and
# recreates depth_texture's image (the model's OUTPUT, read back via
# get_depth_map()) in place via set_image() rather than a new ImageTexture -
# every consumer (primary_screen, comp_shader_mat_left/right) already holds
# a reference to this same object, so updating its image data keeps those
# bindings valid instead of needing to re-push a new texture reference
# everywhere depth_texture is used.
func sync_model_size():
	if not main.stream_backend or not depth_viewport or not depth_texture:
		return
	var new_width = main.stream_backend.get_depth_model_width()
	var new_height = main.stream_backend.get_depth_model_height()
	if new_width <= 0 or new_height <= 0:
		return
	if new_width == model_width and new_height == model_height:
		return
	model_width = new_width
	model_height = new_height
	depth_viewport.size = Vector2i(model_width, model_height)
	var img = Image.create(model_width, model_height, false, Image.FORMAT_L8)
	depth_texture.set_image(img)

func bind_stream_texture():
	if not depth_target_mat:
		return
	# Compatibility path for a backend that cannot expose decoder textures.
	# In composition mode this needs the plain mono viewport, but unlike the
	# old path it is enabled only while this fallback is actually in use.
	var was_direct = _direct_stream_source_bound
	_direct_stream_source_bound = false
	var source_tex = null
	if main.comp.in_use and main.primary_screen and main.primary_screen.comp_viewport:
		source_tex = main.primary_screen.comp_viewport.get_texture()
	elif main.stream_viewport:
		source_tex = main.stream_viewport.get_texture()
	depth_target_mat.set_shader_parameter("main_texture", source_tex)
	depth_target_mat.set_shader_parameter("yuv_mode", 0)
	_update_mono_capture_requirement()
	if was_direct:
		main._log("[DEPTH] Decoder textures unavailable; mono capture fallback enabled")

func bind_decoder_textures(tex_y, tex_u, tex_v, yuv_mode: int, cmt: int, cr: int):
	if not depth_target_mat:
		return
	var was_direct = _direct_stream_source_bound
	depth_target_mat.set_shader_parameter("tex_y", tex_y)
	depth_target_mat.set_shader_parameter("tex_u", tex_u)
	depth_target_mat.set_shader_parameter("tex_v", tex_v)
	depth_target_mat.set_shader_parameter("yuv_mode", yuv_mode)
	depth_target_mat.set_shader_parameter("color_matrix_type", cmt)
	depth_target_mat.set_shader_parameter("color_range", cr)
	_direct_stream_source_bound = true
	_update_mono_capture_requirement()
	if not was_direct:
		main._log("[DEPTH] Direct decoder source bound; redundant mono capture disabled")

func refresh_stream_source():
	if _direct_stream_source_bound:
		_update_mono_capture_requirement()
	else:
		bind_stream_texture()

func _update_mono_capture_requirement():
	if not main.primary_screen or not main.primary_screen.comp_viewport or not main.settings_controller:
		return
	# The mono viewport is the visible output in normal 2D mode and must remain
	# active there. In stereo modes it exists only as the legacy depth fallback.
	if main.comp.in_use and main.settings_controller.get_stereo_mode() > 0:
		var needs_fallback = enabled and not _direct_stream_source_bound and not _native_renderer_active
		main.primary_screen.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if needs_fallback else SubViewport.UPDATE_DISABLED

func set_native_renderer_active(value: bool) -> void:
	if _native_renderer_active == value:
		return
	_native_renderer_active = value
	_update_render_pass_modes()
	_update_mono_capture_requirement()

func _update_render_pass_modes() -> void:
	if depth_viewport:
		depth_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled and not _native_renderer_active else SubViewport.UPDATE_DISABLED
	var warp_mode := SubViewport.UPDATE_DISABLED
	if _warp_passes_active and not _native_renderer_active:
		warp_mode = SubViewport.UPDATE_ONCE if _warp_throttled else SubViewport.UPDATE_ALWAYS
	if upsample_viewport:
		upsample_viewport.render_target_update_mode = warp_mode
	if offset_viewport:
		offset_viewport.render_target_update_mode = warp_mode

func set_enabled(val: bool, run_warp_passes: bool = false, warp_tier: int = 0):
	enabled = val
	_update_mono_capture_requirement()
	if not val or main.settings_controller.get_depth_backend_index() != 2:
		_set_gpu_performance_hint(false)
	if depth_viewport and not _native_renderer_active:
		# Tried throttling this to UPDATE_ONCE at submit_interval's 20Hz
		# instead of UPDATE_ALWAYS (2026-08-18) on the theory that
		# re-rendering the downscale every render frame for 20Hz-consumed
		# data was wasted GPU work - on-device testing found NO measurable
		# FPS gain, just the throttle's own added pipeline latency, so
		# reverted. Unlike the warp passes, this pass apparently isn't worth
		# throttling - it's a single cheap fullscreen blit, not the
		# occlusion-search work those passes do.
		depth_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if val else SubViewport.UPDATE_DISABLED
	# Only stereo_mode 5/6/10 (MiDaS-GPU / MiDaS-Std / MiDaS-Fast) consume
	# these - leave them off for the older modes 3/4 so they stay a clean,
	# unaffected performance baseline to compare against. Tier 1 throttles
	# via _warp_timer in process() (UPDATE_ONCE); tier 0 (MiDaS-Std) stays
	# UPDATE_ALWAYS - see warp_update_interval's comment above for why.
	_warp_passes_active = val and run_warp_passes
	_warp_tier = warp_tier if _warp_passes_active else 0
	_warp_throttled = _warp_tier > 0
	_warp_timer = 0.0
	_warp_frame_counter = 0
	match _warp_tier:
		1: _pass_divisor = EX_PASS_DIVISOR
		_: _pass_divisor = PASS_DIVISOR

	_push_warp_newton_steps(2 if _warp_tier == 0 else 0)
	_update_render_pass_modes()

func _set_gpu_performance_hint(use_boost: bool, force: bool = false):
	if OS.get_name() != "Android" or (_gpu_boost_active == use_boost and not force):
		return
	var interface = XRServer.find_interface("OpenXR")
	if not interface or not interface.has_method("set_gpu_level"):
		return
	var level = OpenXRInterface.PERF_SETTINGS_LEVEL_BOOST if use_boost else OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH
	interface.set_gpu_level(level)
	_gpu_boost_active = use_boost
	_gpu_boost_refresh_timer = 0.0
	main._log("[DEPTH] GPU performance hint: %s" % ("BOOST" if use_boost else "SUSTAINED_HIGH"))

func _push_warp_newton_steps(steps: int):
	if main.comp_shader_mat_left:
		main.comp_shader_mat_left.set_shader_parameter("warp_newton_steps", steps)
	if main.comp_shader_mat_right:
		main.comp_shader_mat_right.set_shader_parameter("warp_newton_steps", steps)

func process(delta: float):
	# GPU boost fires whenever depth inference is ACTUALLY running on GPU
	# (main.stream_backend.get_effective_depth_backend() == 2), not just
	# when the legacy "MiDaS-256-GPU" model entry (index 6) is picked
	# directly - the separate 3D Backend control (2026-08-22) lets MiDaS-256
	# (index 5) also end up running on GPU via Auto/GPU backend selection.
	var effective_gpu = main.stream_backend and main.stream_backend.get_effective_depth_backend() == 2
	var should_boost = enabled and effective_gpu and main.is_streaming
	if should_boost:
		_gpu_boost_refresh_timer += delta
		if not _gpu_boost_active or _gpu_boost_refresh_timer >= GPU_BOOST_REFRESH_INTERVAL:
			_set_gpu_performance_hint(true, _gpu_boost_active)
	elif _gpu_boost_active:
		_set_gpu_performance_hint(false)
	if not enabled or not main.is_streaming:
		return

	_resize_warp_passes()
	_backend_status_timer += delta
	if _backend_status_timer >= 0.25:
		_backend_status_timer = 0.0
		main.settings_controller.refresh_depth_backend_status(true)

	if _warp_passes_active and _warp_throttled and not _native_renderer_active:
		_warp_frame_counter += 1
		var period: int = WARP_NEWTON_PERIOD[_warp_tier]
		_push_warp_newton_steps(1 if (_warp_frame_counter % period == 0) else 0)
		_warp_timer += delta
		if _warp_timer >= warp_update_interval:
			_warp_timer = 0.0
			upsample_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			offset_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	if main.stream_backend.has_method("submit_depth_frame"):
		var native_capture_available: bool = (
			_platform == "Android"
			and main.stream_backend.has_method("supports_native_depth_capture")
			and main.stream_backend.supports_native_depth_capture()
		)
		if native_capture_available != _native_depth_capture_active:
			_native_depth_capture_active = native_capture_available
			main._log("[DEPTH] Capture path: %s" % ("native GLES async" if native_capture_available else "Godot viewport fallback"))

		# Polling a completed PBO only copies an already-signalled model-sized
		# result. The GLES render thread never waits for it; if a transfer is
		# late, the latest-frame policy simply picks it up on a later frame.
		if native_capture_available:
			var native_data: PackedByteArray = main.stream_backend.consume_native_depth_capture()
			if native_data.size() == model_width * model_height * 4:
				var native_submit_start = Time.get_ticks_usec()
				main.stream_backend.submit_depth_frame(native_data, model_width, model_height)
				_perf_submit_usec += Time.get_ticks_usec() - native_submit_start
				_perf_submitted += 1

		submit_timer += delta
		var active_submit_interval = GPU_FRAME_PUBLISH_INTERVAL if main.settings_controller.get_depth_backend_index() == 2 and OS.get_name() == "Android" else submit_interval
		if submit_timer >= active_submit_interval:
			submit_timer -= active_submit_interval
			if native_capture_available:
				main.stream_backend.request_native_depth_capture(model_width, model_height)
			else:
				var capture_start = Time.get_ticks_usec()
				var img = depth_viewport.get_texture().get_image()
				if img != null and not img.is_empty():
					# Godot Images are top-left-origin while SubViewport's GPU
					# framebuffer readback via get_texture().get_image() comes
					# back bottom-left-origin (same GLES/Compatibility-renderer
					# quirk native_xr_renderer.gd's stats-overlay capture already
					# works around with this identical flip_y() call) - without
					# this, the model's input (and therefore its whole output
					# depth map) is vertically flipped, even though a live GPU
					# sample of the same depth_viewport texture (depth_guide_texture,
					# used by the DMap-Input debug view) looks correct, since that
					# path never goes through this CPU readback at all.
					img.flip_y()
					var data = img.get_data()
					_perf_capture_usec += Time.get_ticks_usec() - capture_start
					if data.size() > 0:
						var submit_start = Time.get_ticks_usec()
						main.stream_backend.submit_depth_frame(data, model_width, model_height)
						_perf_submit_usec += Time.get_ticks_usec() - submit_start
						_perf_submitted += 1

	if main.stream_backend.has_method("get_depth_map"):
		var depth_bytes = main.stream_backend.get_depth_map()
		if depth_bytes != null and depth_bytes.size() == model_width * model_height:
			var depth_image = Image.create_from_data(model_width, model_height, false, Image.FORMAT_L8, depth_bytes)
			depth_texture.update(depth_image)
			depth_revision += 1
			_perf_updates += 1
		elif depth_bytes != null and depth_bytes.size() > 0:
			# Diagnostic (2026-09-04) for a "depth map doesn't correspond to
			# the frame" report - a mismatch here means the Java side's
			# actual output size (whatever model is really active there)
			# disagrees with GDScript's model dimensions,
			# so this frame's depth_texture update is silently skipped and
			# the view keeps showing the last-good (now stale/wrong) data
			# instead. Throttled to avoid spamming every frame while stuck.
			_size_mismatch_log_timer += delta
			if _size_mismatch_log_timer >= 1.0:
				_size_mismatch_log_timer = 0.0
				main._log("[DEPTH] Size mismatch: got %d bytes, expected %d (model=%dx%d) - texture update skipped" % [depth_bytes.size(), model_width * model_height, model_width, model_height])

	_perf_window += delta
	if _perf_window >= 1.0:
		var capture_ms = float(_perf_capture_usec) / maxf(float(_perf_submitted), 1.0) / 1000.0
		var submit_ms = float(_perf_submit_usec) / maxf(float(_perf_submitted), 1.0) / 1000.0
		var capture_value = "async-native" if _native_depth_capture_active else "%.2fms" % capture_ms
		print("[DEPTH-PERF] capture=%s submit=%.2fms requested=%.1fHz updates=%.1fHz model=%d" % [capture_value, submit_ms, float(_perf_submitted) / _perf_window, float(_perf_updates) / _perf_window, main.ai_3d_model])
		_perf_window = 0.0
		_perf_capture_usec = 0
		_perf_submit_usec = 0
		_perf_submitted = 0
		_perf_updates = 0
