class_name DepthEstimatorModule
extends RefCounted

var main: Node3D
var depth_viewport: SubViewport
var depth_target: ColorRect
var depth_target_mat: ShaderMaterial
var depth_texture: ImageTexture
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
# MiDaS-GPU only - see its use in process() for why this needs to be its own,
# much slower cadence than submit_interval above. ~5Hz - a starting point
# matching the rough order of magnitude of Gilleece/moonlight-android-xr's own
# "every 3rd frame" cadence at 90Hz (~30Hz, but their raw inference is ~3.5x
# faster than ours at ~13.5ms vs our ~47-51ms end-to-end, so a slower cadence
# here is the equivalent tradeoff for a slower model) - tune based on
# on-device FPS/GPU-utilization testing, not derived precisely.
const GPU_MODEL_SUBMIT_INTERVAL := 0.2
# Native output resolution of whichever model is currently active in
# DepthEstimator.java - 256 for MiDaS/Depth Anything, 768 for YOLO26-depth
# (see YOLO_INPUT_SIZE there). No longer a fixed constant: sync_model_size()
# below queries DepthEstimator.java's getModelSize() (via depth_bridge.cpp's
# JNI get_depth_model_size()) whenever settings_controller.gd's apply_stereo()
# switches the active model, and resizes depth_viewport/depth_texture to
# match - both submit_depth_frame() and the get_depth_map() size-match check
# in process() below depend on this being correct for the CURRENTLY active
# model, not just MiDaS.
var model_size: int = 256
var _poll_timer: float = 0.0

# stereo_mode 5/6 (MiDaS-GPU / MiDaS-Std)'s upsample+offset passes - see
# depth_upsample.gdshader / depth_offset.gdshader for what these compute.
# Run once per frame, shared by both eyes, at a quarter of the stream's own
# resolution (matches Gilleece/moonlight-android-xr's own upsampleWidth =
# videoWidth/4) rather than at raw 256x256 or, worse, at full per-eye
# resolution - the latter is what made the first attempt at this tank
# performance, since the same expensive bilateral/search work was repeated
# per eye per full-res pixel instead of once for the whole frame.
const PASS_DIVISOR := 4
# stereo_mode 10/11 (MiDaS-Fast / MiDaS-Fastest) only - shrinks the
# pre-pass's linear resolution further than PASS_DIVISOR, on the same
# GPU-cost theory as the throttle below. Selected via _pass_divisor in
# set_enabled() based on warp_tier. No power-of-2 requirement - this only
# ever feeds an integer division in GDScript (_resize_warp_passes(), called
# once per native_resolution change, not per-pixel/per-frame), so any
# divisor costs the same at runtime; only the resulting resolution (and
# therefore quality vs. GPU cost) changes.
const EX_PASS_DIVISOR := 10
const FASTEST_PASS_DIVISOR := 12
const PASS_MIN_SIZE := 160
# MiDaS-Fastest only: an absolute ceiling on the pre-pass size, equal to
# what MiDaS-Fast (EX_PASS_DIVISOR=10) already produces at 2560x1440 - the
# resolution it was tuned/tested at (2560/10=256, 1440/10=144, floored up
# to PASS_MIN_SIZE=160). FASTEST_PASS_DIVISOR alone still scales up
# proportionally with native_resolution, so at 4K (roughly double 1440p's
# linear dimensions) it costs ~4x more than at 1440p for the same divisor -
# that's the actual reason 4K costs more, not something a bigger divisor
# alone fixes. Clamping to this ceiling means going to 4K (or beyond) never
# makes MiDaS-Fastest's pre-pass more expensive than it already is at
# 1440p; below that, FASTEST_PASS_DIVISOR's own result is already smaller
# than this and the ceiling is a no-op.
const FASTEST_PASS_MAX_SIZE := Vector2i(256, 160)
var _pass_divisor: int = PASS_DIVISOR
var upsample_viewport: SubViewport
var upsample_mat: ShaderMaterial
var offset_viewport: SubViewport
var offset_mat: ShaderMaterial
# stereo_mode 10/11 only: throttles these two passes to UPDATE_ONCE on this
# timer instead of UPDATE_ALWAYS, re-rendering the occlusion search at
# warp_update_interval instead of every render frame (up to 90Hz), even
# though the depth data feeding them only refreshes at submit_interval's
# 20Hz. On-device testing (2026-08-18) found NO measurable FPS gain from
# this on stereo_mode 6 (MiDaS-Std, which stayed on UPDATE_ALWAYS as a
# result) - the pre-pass apparently isn't the actual bottleneck. Kept in
# these separate modes (not folded into MiDaS-Std) to keep poking at this
# without risking the known-good mode; the per-eye per-pixel Newton-
# refinement gather in yuv_display.gdshader (runs at full render resolution
# every frame regardless of this throttle) is the next suspect.
var warp_update_interval: float = 1.0 / 30.0
var _warp_timer: float = 0.0
var _warp_passes_active: bool = false
var _warp_throttled: bool = false
# 0 = MiDaS-Std (no throttling/shrinking - full quality, unthrottled), 1 =
# MiDaS-Fast, 2 = MiDaS-Fastest. Set via set_enabled()'s warp_tier param;
# drives _pass_divisor and WARP_NEWTON_PERIOD below.
var _warp_tier: int = 0
# stereo_mode 10/11 only - a 1-indexed counter, incremented every process()
# tick (one real render frame, see main.gd's _process()) while a throttled
# tier is active. Pushed to comp_shader_mat_left/right as warp_newton_steps
# (1 on the tick where counter % WARP_NEWTON_PERIOD[_warp_tier] == 0, else
# 0) - yuv_display.gdshader just reads that uniform directly rather than
# special-casing stereo_mode itself, so adding another tier only needs an
# entry here, not a shader change. MiDaS-Fast (tier 1) does 1 Newton step
# every 2nd frame (alternating); MiDaS-Fastest (tier 2) does 1 every 3rd
# frame, 0 the other two - both amortize that per-pixel refinement cost
# across frames instead of paying it every frame.
const WARP_NEWTON_PERIOD: Array[int] = [1, 2, 3]
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
	if _platform != "Android":
		main._log("[DEPTH] Depth estimation disabled on " + _platform)
		return
	depth_viewport = SubViewport.new()
	depth_viewport.name = "DepthViewport"
	depth_viewport.size = Vector2i(model_size, model_size)
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

	var img = Image.create(model_size, model_size, false, Image.FORMAT_L8)
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

# Sized off native_resolution (the stream's real resolution) rather than a
# fixed constant, so the passes track resolution changes/restarts. Cheap to
# call every frame - it's a no-op once the size matches.
func _resize_warp_passes():
	# upsample_mat decodes YUV directly (see depth_upsample.gdshader) and
	# needs the same uv_region the primary screen's own materials use, so
	# its "hi" color sample lands on the same frame position the final
	# gather shader will warp. Kept outside the resize early-return below
	# since the primary screen's region can change independently of the
	# stream's own resolution (e.g. a monitor-selection change).
	if upsample_mat and main.primary_screen:
		upsample_mat.set_shader_parameter("uv_region", main.primary_screen.uv_region)

	var src = main.native_resolution
	if src.x <= 0 or src.y <= 0:
		return
	var target = Vector2i(maxi(src.x / _pass_divisor, PASS_MIN_SIZE), maxi(src.y / _pass_divisor, PASS_MIN_SIZE))
	if _warp_tier == 2:
		target = Vector2i(mini(target.x, FASTEST_PASS_MAX_SIZE.x), mini(target.y, FASTEST_PASS_MAX_SIZE.y))
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
# stream_backend.set_depth_model() switches the active Java-side model -
# setActiveModel() busy-waits out any in-flight inference before returning,
# so getModelSize() is already correct for the new model by the time this
# runs. Resizes depth_viewport (the capture source fed INTO the model) and
# recreates depth_texture's image (the model's OUTPUT, read back via
# get_depth_map()) in place via set_image() rather than a new ImageTexture -
# every consumer (primary_screen, comp_shader_mat_left/right) already holds
# a reference to this same object, so updating its image data keeps those
# bindings valid instead of needing to re-push a new texture reference
# everywhere depth_texture is used.
func sync_model_size():
	if not main.stream_backend or not depth_viewport or not depth_texture:
		return
	var new_size = main.stream_backend.get_depth_model_size()
	if new_size <= 0 or new_size == model_size:
		return
	model_size = new_size
	depth_viewport.size = Vector2i(model_size, model_size)
	var img = Image.create(model_size, model_size, false, Image.FORMAT_L8)
	depth_texture.set_image(img)

func bind_stream_texture():
	if not depth_target:
		return
	# comp.in_use (switch_to_stereo_comp_layer() active) EXPLICITLY sets
	# primary_screen.comp_viewport (the mono viewport) to UPDATE_DISABLED in
	# favor of comp_viewport_left/right - depth capture used to silently
	# freeze on whatever the mono viewport last rendered before switching to
	# stereo (often mid-welcome-screen), feeding MiDaS a single stale frame
	# forever instead of live video (fixed by forcing it back to
	# UPDATE_ALWAYS in settings_controller.gd's apply_stereo() whenever
	# depth is enabled). comp_viewport_left is NOT a valid depth-capture
	# source: it's rendered by comp_shader_mat_left, the SAME material
	# whose stereo_mode we set to 7/8/9 for the DMap debug views - sourcing
	# depth capture from it would mean depth_guide_texture circularly
	# depends on its own output (DMap modes) or MiDaS sees the
	# already-warped stereo image instead of plain video (warp modes 5/6,
	# compounding distortion frame over frame). The mono comp_viewport
	# (comp_shader_mat, permanently stereo_mode=0) is the only semantically
	# correct source.
	if main.comp.in_use and main.primary_screen and main.primary_screen.comp_viewport:
		depth_target_mat.set_shader_parameter("source_tex", main.primary_screen.comp_viewport.get_texture())
	elif main.stream_viewport:
		depth_target_mat.set_shader_parameter("source_tex", main.stream_viewport.get_texture())

func set_enabled(val: bool, run_warp_passes: bool = false, warp_tier: int = 0):
	enabled = val
	if depth_viewport:
		# Tried throttling this to UPDATE_ONCE at submit_interval's 20Hz
		# instead of UPDATE_ALWAYS (2026-08-18) on the theory that
		# re-rendering the downscale every render frame for 20Hz-consumed
		# data was wasted GPU work - on-device testing found NO measurable
		# FPS gain, just the throttle's own added pipeline latency, so
		# reverted. Unlike the warp passes, this pass apparently isn't worth
		# throttling - it's a single cheap fullscreen blit, not the
		# occlusion-search work those passes do.
		depth_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if val else SubViewport.UPDATE_DISABLED
	# Only stereo_mode 5/6/10/11 (MiDaS-GPU / MiDaS-Std / MiDaS-Fast /
	# MiDaS-Fastest) consume these - leave them off for the older modes 3/4
	# so they stay a clean, unaffected performance baseline to compare
	# against. Tiers 1/2 throttle via _warp_timer in process() (UPDATE_ONCE);
	# tier 0 (MiDaS-Std) stays UPDATE_ALWAYS - see warp_update_interval's
	# comment above for why.
	_warp_passes_active = val and run_warp_passes
	_warp_tier = warp_tier if _warp_passes_active else 0
	_warp_throttled = _warp_tier > 0
	_warp_timer = 0.0
	_warp_frame_counter = 0
	match _warp_tier:
		1: _pass_divisor = EX_PASS_DIVISOR
		2: _pass_divisor = FASTEST_PASS_DIVISOR
		_: _pass_divisor = PASS_DIVISOR
	_push_warp_newton_steps(2 if _warp_tier == 0 else 0)
	var mode: int = (SubViewport.UPDATE_ONCE if _warp_throttled else SubViewport.UPDATE_ALWAYS) if _warp_passes_active else SubViewport.UPDATE_DISABLED
	if upsample_viewport:
		upsample_viewport.render_target_update_mode = mode
	if offset_viewport:
		offset_viewport.render_target_update_mode = mode

func _push_warp_newton_steps(steps: int):
	if main.comp_shader_mat_left:
		main.comp_shader_mat_left.set_shader_parameter("warp_newton_steps", steps)
	if main.comp_shader_mat_right:
		main.comp_shader_mat_right.set_shader_parameter("warp_newton_steps", steps)

func process(delta: float):
	if not enabled or not main.is_streaming:
		return

	_resize_warp_passes()

	if _warp_passes_active and _warp_throttled:
		_warp_frame_counter += 1
		var period: int = WARP_NEWTON_PERIOD[_warp_tier]
		_push_warp_newton_steps(1 if (_warp_frame_counter % period == 0) else 0)
		_warp_timer += delta
		if _warp_timer >= warp_update_interval:
			_warp_timer = 0.0
			upsample_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			offset_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	if main.stream_backend.has_method("submit_depth_frame"):
		submit_timer += delta
		# MiDaS-GPU used to need its own, much slower cadence than the CPU
		# models share above (confirmed on-device, 2026-08-19: TFLite's GPU
		# delegate runs its compute shaders on the SAME physical GPU that
		# renders the VR scene, so every inference call is real GPU time
		# directly competing with the render thread - unlike MiDaS/YOLO26
		# (CPU/XNNPACK), which are fully decoupled from what renders each
		# frame. Running it at the same 20Hz cadence as the CPU models drove
		# GPU utilization to 94% and roughly halved frame rate). But MiDaS-GPU
		# is now REMOVED from selection entirely (2026-08-19, still performed
		# poorly even throttled - see settings_controller.gd's
		# ai_3d_model_labels comment) - GPU_MODEL_SUBMIT_INTERVAL is dead code
		# below, kept only in case it's revived, since no current ai_3d_model
		# value maps to it and hardcoding a check against a specific index
		# here would silently misfire against whatever CPU model ends up at
		# that index instead (this exact bug happened once already when
		# YOLO26-S's removal shifted index 3 out from under this check).
		if submit_timer >= submit_interval:
			submit_timer = 0.0
			var img = depth_viewport.get_texture().get_image()
			if img != null and not img.is_empty():
				var data = img.get_data()
				if data.size() > 0:
					main.stream_backend.submit_depth_frame(data, model_size, model_size)

	if main.stream_backend.has_method("get_depth_map"):
		_poll_timer += delta
		if _poll_timer >= submit_interval:
			_poll_timer = 0.0
			var depth_bytes = main.stream_backend.get_depth_map()
			if depth_bytes != null and depth_bytes.size() == model_size * model_size:
				var depth_image = Image.create_from_data(model_size, model_size, false, Image.FORMAT_L8, depth_bytes)
				depth_texture.update(depth_image)
