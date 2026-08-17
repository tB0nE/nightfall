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
var model_size: int = 256
var _poll_timer: float = 0.0

# stereo_mode 5/6 (MiDaS-GPU / MiDaS-NNAPI)'s upsample+offset passes - see
# depth_upsample.gdshader / depth_offset.gdshader for what these compute.
# Run once per frame, shared by both eyes, at a quarter of the stream's own
# resolution (matches Gilleece/moonlight-android-xr's own upsampleWidth =
# videoWidth/4) rather than at raw 256x256 or, worse, at full per-eye
# resolution - the latter is what made the first attempt at this tank
# performance, since the same expensive bilateral/search work was repeated
# per eye per full-res pixel instead of once for the whole frame.
const PASS_DIVISOR := 4
const PASS_MIN_SIZE := 160
var upsample_viewport: SubViewport
var upsample_mat: ShaderMaterial
var offset_viewport: SubViewport
var offset_mat: ShaderMaterial
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
	var target = Vector2i(maxi(src.x / PASS_DIVISOR, PASS_MIN_SIZE), maxi(src.y / PASS_DIVISOR, PASS_MIN_SIZE))
	if target == _pass_size:
		return
	_pass_size = target
	upsample_viewport.size = target
	offset_viewport.size = target
	offset_mat.set_shader_parameter("disp_texels", _pass_parallax * float(target.x))
	for mat in [main.comp_shader_mat_left, main.comp_shader_mat_right]:
		if mat:
			mat.set_shader_parameter("mode5_parallax", _pass_parallax)

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

func set_enabled(val: bool, run_warp_passes: bool = false):
	enabled = val
	if depth_viewport:
		depth_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if val else SubViewport.UPDATE_DISABLED
	# Only stereo_mode 5/6 (MiDaS-GPU / MiDaS-NNAPI) consume these - leave them
	# off for the older modes 3/4 so they stay a clean, unaffected performance
	# baseline to compare against.
	var run_passes = val and run_warp_passes
	if upsample_viewport:
		upsample_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if run_passes else SubViewport.UPDATE_DISABLED
	if offset_viewport:
		offset_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if run_passes else SubViewport.UPDATE_DISABLED

func process(delta: float):
	if not enabled or not main.is_streaming:
		return

	_resize_warp_passes()

	if main.stream_backend.has_method("submit_depth_frame"):
		submit_timer += delta
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
