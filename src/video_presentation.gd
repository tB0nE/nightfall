class_name VideoPresentation
extends RefCounted

enum Path {
	MESH,
	LEGACY_MONO,
	LEGACY_STEREO,
	NATIVE,
}

var legacy_renderer
var native_renderer

func _init(p_legacy_renderer, p_native_renderer) -> void:
	legacy_renderer = p_legacy_renderer
	native_renderer = p_native_renderer

func set_legacy_renderer(renderer) -> void:
	legacy_renderer = renderer

static func resolve_path(composition_available: bool, native_eligible: bool, stereo_mode: int) -> Path:
	if not composition_available:
		return Path.MESH
	if native_eligible:
		return Path.NATIVE
	return Path.LEGACY_STEREO if stereo_mode > 0 else Path.LEGACY_MONO

static func uses_independent_screen_cursor(composition_active: bool, native_active: bool) -> bool:
	# A single cursor layer survives mono/stereo presentation changes. Moving
	# between that layer and cursors embedded in the video viewports leaves the
	# outgoing viewport hidden or disabled for a frame and proved unreliable on
	# Quest GLES. Keep one route for every composition-backed video mode.
	return composition_active or native_active

func requested_path(stereo_mode: int) -> Path:
	return resolve_path(
		legacy_renderer != null and legacy_renderer.available,
		can_render_native(),
		stereo_mode,
	)

func apply_mode(stereo_mode: int, media_active: bool) -> Path:
	var path := requested_path(stereo_mode)
	match path:
		Path.NATIVE:
			# NativeXrRendererManager activates itself after the decoder exposes
			# a valid video size. Activating legacy during that short window can
			# reacquire its old swapchain and race a restarted native session.
			pass
		Path.LEGACY_MONO:
			legacy_renderer.switch_to_comp_layer()
		Path.LEGACY_STEREO:
			legacy_renderer.switch_to_stereo_comp_layer()
		Path.MESH:
			# Preserve the existing fallback transition exactly. A stereo mode
			# can be returning from a previously active composition path; mono
			# startup is already on mesh and only probes composition availability.
			if stereo_mode > 0 and legacy_renderer.in_use:
				legacy_renderer.switch_to_mesh_rendering()
			elif stereo_mode == 0 and not legacy_renderer.in_use and media_active:
				legacy_renderer.switch_to_comp_layer()
	return path

func can_render_native() -> bool:
	return native_renderer != null and native_renderer.can_render_current_config()

func is_native_active() -> bool:
	return native_renderer != null and native_renderer.active

func process_frame(new_frame: bool) -> void:
	if native_renderer:
		native_renderer.process_frame(new_frame)

func setup_native() -> void:
	if native_renderer:
		native_renderer.setup()

func deactivate_native(restore_legacy: bool) -> void:
	if native_renderer:
		native_renderer.deactivate(restore_legacy)

func request_ambient_sample() -> void:
	if native_renderer:
		native_renderer.request_ambient_sample()

func set_stats_visible(value: bool) -> void:
	if native_renderer:
		native_renderer.set_stats_visible(value)

func request_stats_overlay_update() -> void:
	if native_renderer:
		native_renderer.request_stats_overlay_update()

func get_warp_gpu_ms() -> float:
	return native_renderer.get_warp_gpu_ms() if native_renderer else 0.0

func shutdown() -> void:
	if native_renderer:
		native_renderer.shutdown()
