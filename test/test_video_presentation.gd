extends SceneTree

class FakeLegacyRenderer:
	extends RefCounted
	var available := true
	var in_use := false
	var calls: Array[String] = []

	func switch_to_comp_layer() -> void:
		calls.append("mono")

	func switch_to_stereo_comp_layer() -> void:
		calls.append("stereo")

	func switch_to_mesh_rendering() -> void:
		calls.append("mesh")

class FakeNativeRenderer:
	extends RefCounted
	var eligible := false
	var active := false

	func can_render_current_config() -> bool:
		return eligible

func _init():
	_test_path_resolution()
	_test_path_application()
	_test_cursor_path()
	_test_depth_sync_delay()
	print("All video_presentation tests passed")
	quit()

func _test_path_resolution() -> void:
	assert(VideoPresentation.resolve_path(false, false, 0) == VideoPresentation.Path.MESH)
	assert(VideoPresentation.resolve_path(false, false, 6) == VideoPresentation.Path.MESH)
	assert(VideoPresentation.resolve_path(false, true, 0) == VideoPresentation.Path.MESH)
	assert(VideoPresentation.resolve_path(true, false, 0) == VideoPresentation.Path.LEGACY_MONO)
	assert(VideoPresentation.resolve_path(true, false, 1) == VideoPresentation.Path.LEGACY_STEREO)
	assert(VideoPresentation.resolve_path(true, true, 0) == VideoPresentation.Path.NATIVE)
	assert(VideoPresentation.resolve_path(true, true, 6) == VideoPresentation.Path.NATIVE)

func _test_path_application() -> void:
	var legacy := FakeLegacyRenderer.new()
	var native := FakeNativeRenderer.new()
	var presentation := VideoPresentation.new(legacy, native)
	assert(presentation.apply_mode(0, true) == VideoPresentation.Path.LEGACY_MONO)
	assert(legacy.calls == ["mono"])
	legacy.calls.clear()
	assert(presentation.apply_mode(6, true) == VideoPresentation.Path.LEGACY_STEREO)
	assert(legacy.calls == ["stereo"])
	legacy.calls.clear()
	native.eligible = true
	assert(presentation.apply_mode(6, true) == VideoPresentation.Path.NATIVE)
	assert(legacy.calls.is_empty())
	native.eligible = false
	legacy.available = false
	legacy.in_use = true
	assert(presentation.apply_mode(6, true) == VideoPresentation.Path.MESH)
	assert(legacy.calls == ["mesh"])
	legacy.calls.clear()
	legacy.in_use = false
	assert(presentation.apply_mode(0, true) == VideoPresentation.Path.MESH)
	assert(legacy.calls == ["mono"])

func _test_cursor_path() -> void:
	assert(not VideoPresentation.uses_independent_screen_cursor(false, false))
	assert(VideoPresentation.uses_independent_screen_cursor(true, false))
	assert(VideoPresentation.uses_independent_screen_cursor(false, true))
	assert(VideoPresentation.uses_independent_screen_cursor(true, true))

func _test_depth_sync_delay() -> void:
	# A minimum one-frame delay keeps the retained colour ring populated.
	assert(NativeXrRendererManager.depth_sync_delay_frames(0.0, 60, false) == 1)
	# GPU capture itself completes one render tick after the source frame.
	assert(NativeXrRendererManager.depth_sync_delay_frames(0.0, 90, true) == 1)
	assert(NativeXrRendererManager.depth_sync_delay_frames(12.0, 90, true) == 2)
	assert(NativeXrRendererManager.depth_sync_delay_frames(8.0, 120, false) == 1)
	# The native ring intentionally bounds presentation latency to two frames.
	assert(NativeXrRendererManager.depth_sync_delay_frames(50.0, 120, true) == 2)
	assert(NativeXrRendererManager.depth_sync_delay_frames(-5.0, 0, false) == 1)
