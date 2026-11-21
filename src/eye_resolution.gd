class_name EyeResolution
extends Node
## Renders each screen's composition viewports at the resolution the headset
## can actually show, instead of always at the stream's resolution.
##
## The compositor scales those viewports onto however many display pixels the
## screen covers. A 2576-wide stream on a screen that covers ~1300 headset
## pixels was warped (AI 3D) and converted at full size for both eyes, then
## averaged away. Measured on a Steam Frame with EdgePad-512: rendering at
## 1600x680 instead freed enough GPU time for depth to go from ~16 to ~21-25
## maps/s at 90 Hz. Close-up screens still get full resolution.
##
## Resizing a SubViewport that backs an OpenXR composition layer recreates its
## swapchain, which has raced in-flight submissions on Quest (see
## stream_manager.gd's resize_stream_viewport()). So sizes move in a few fixed
## steps, only after the wanted step has held for a while, and the feature is
## on by default only on Linux. --nf-eye-resolution=full turns the module off;
## Screen Res in Settings > Display (Full, Auto 1-6) controls it otherwise.

const CHECK_INTERVAL := 0.5
# Rendered pixels per estimated display pixel. The estimate uses the app's eye
# buffer size, which is below the panel's native resolution (and lenses pack
# more pixels into the centre), so this has to be well above 1: on a Steam
# Frame 1.25 left text visibly soft at ~1.5 m and 2.0 was still noticeable up
# close. Screen Res (Settings > Display, Auto 1-6) picks one of these, 1 = barely
# lowers the resolution ... 6 = strongest.
const STRENGTH_SHARPNESS := [3.5, 3.0, 2.5, 2.0, 1.5, 1.25]
const STEPS := [0.375, 0.5, 0.625, 0.75, 0.875, 1.0]
# Seconds a new step must be wanted before switching (sharper sooner).
const RAISE_AFTER := 0.5
const LOWER_AFTER := 2.0

var main
# Overrides the Screen Res strength when set above 0 (testing through the dev bridge).
var sharpness := 0.0
var _timer := 0.0
var _pending := {}   # VRScreen -> [step, seconds wanted]

static func mode(args: PackedStringArray) -> String:
	for arg in args:
		if arg.begins_with("--nf-eye-resolution="):
			return arg.get_slice("=", 1)
	return "auto" if OS.get_name() == "Linux" else "full"

static func wanted() -> bool:
	return mode(OS.get_cmdline_args() + OS.get_cmdline_user_args()) == "auto"

func _init(owner) -> void:
	main = owner
	name = "EyeResolution"

func _process(delta: float) -> void:
	_timer += delta
	if _timer < CHECK_INTERVAL:
		return
	var elapsed := _timer
	_timer = 0.0
	if not main.is_xr_active or main.comp == null or not main.comp.in_use:
		return
	if not main.settings.eye_resolution_auto:
		_restore_full_resolution()
		return
	if main.video_presentation != null and main.video_presentation.can_render_native():
		return
	var pixels_per_tangent := _pixels_per_tangent()
	if pixels_per_tangent <= 0.0:
		return
	# Forget screens that have been closed.
	for s in _pending.keys():
		if not is_instance_valid(s) or not main.screens.has(s):
			_pending.erase(s)
	var changed := false
	for s in main.screens:
		if main.screen_sources.is_browser_screen(s) or s.comp_base_size.x <= 0:
			continue
		var step := _wanted_step(s, pixels_per_tangent)
		if is_equal_approx(step, s.comp_render_scale):
			_pending.erase(s)
			continue
		var pending: Array = _pending.get(s, [step, 0.0])
		pending = [step, pending[1] + elapsed] if is_equal_approx(pending[0], step) else [step, 0.0]
		_pending[s] = pending
		if pending[1] >= (RAISE_AFTER if step > s.comp_render_scale else LOWER_AFTER):
			main._log("[EYE-RES] %s: %s -> %s (scale %.3f)" % [s.name, str(s.comp_render_size()),
				str(Vector2i(roundi(s.comp_base_size.x * step), roundi(s.comp_base_size.y * step))), step])
			s.comp_render_scale = step
			_pending.erase(s)
			changed = true
	if changed:
		main.comp.update_bezel()
		main.comp.update_cylinder_params()

# Headset pixels per unit of view tangent at the centre of the left eye.
func _pixels_per_tangent() -> float:
	var interface := XRServer.find_interface("OpenXR")
	if interface == null or not interface.is_initialized():
		return 0.0
	var render_size: Vector2 = interface.get_render_target_size()
	if render_size.x <= 0.0 or render_size.y <= 0.0:
		return 0.0
	var projection: Projection = interface.get_projection_for_view(0, render_size.x / render_size.y, 0.05, 100.0)
	return render_size.x * projection.x.x * 0.5

func _wanted_step(s: VRScreen, pixels_per_tangent: float) -> float:
	var distance := maxf((s.global_position - main.xr_camera.global_position).length(), 0.1)
	# Horizontal span of the screen in view tangents, times display pixels.
	var strength := clampi(main.settings.eye_resolution_strength, 1, STRENGTH_SHARPNESS.size())
	var factor: float = sharpness if sharpness > 0.0 else STRENGTH_SHARPNESS[strength - 1]
	var shown := s.mesh_size.x / distance * pixels_per_tangent * factor
	var needed := shown / float(s.comp_base_size.x)
	for step in STEPS:
		if step >= needed:
			return step
	return 1.0

func _restore_full_resolution() -> void:
	_pending.clear()
	var changed := false
	for s in main.screens:
		if s.comp_render_scale < 0.999:
			s.comp_render_scale = 1.0
			changed = true
	if changed:
		main._log("[EYE-RES] Screen Res: Full")
		main.comp.update_bezel()
		main.comp.update_cylinder_params()
