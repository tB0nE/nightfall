extends SceneTree

class FakeMain:
	extends Node3D
	var layout: ScreenLayout = null
	var media := Vector2i.ZERO

	func primary_media_size() -> Vector2i:
		return media

func _init():
	_test_screen_part()
	print("All native_xr_screens tests passed")
	quit()

func _screen(rect: Rect2i) -> VRScreen:
	var screen := VRScreen.new()
	screen.monitor = ScreenLayout.MonitorSpec.new()
	screen.monitor.frame_rect = rect
	return screen

func _close(a: float, b: float) -> bool:
	return absf(a - b) < 0.00001

func _test_screen_part() -> void:
	var main := FakeMain.new()
	main.layout = ScreenLayout.new()
	main.layout.frame_size = Vector2i(5120, 2880)
	main.media = Vector2i(5120, 2880)
	var native := NativeXrRendererManager.new(main)

	# A screen that fills the frame needs no crop.
	main.layout.frame_size = Vector2i(2560, 1440)
	main.media = Vector2i(2560, 1440)
	var whole := _screen(Rect2i(0, 0, 2560, 1440))
	var part := native.screen_part(whole)
	assert(part.pixels == Vector2i(2560, 1440))
	assert((part.crop as PackedFloat32Array).is_empty(), "A lone screen draws the whole frame")

	# Four screens in a 2x2 grid: the bottom-right one is its quarter, half a texel inset.
	main.layout.frame_size = Vector2i(5120, 2880)
	main.media = Vector2i(5120, 2880)
	var corner := _screen(Rect2i(2560, 1440, 2560, 1440))
	part = native.screen_part(corner)
	assert(part.pixels == Vector2i(2560, 1440))
	var crop: PackedFloat32Array = part.crop
	assert(crop.size() == 4)
	assert(_close(crop[0], 0.5 + 0.5 / 5120.0))
	assert(_close(crop[1], 0.5 + 0.5 / 2880.0))
	assert(_close(crop[2], 0.5 - 1.0 / 5120.0))
	assert(_close(crop[3], 0.5 - 1.0 / 2880.0))

	# A decoded frame smaller than the planned one scales each screen's pixels with it.
	main.media = Vector2i(2560, 1440)
	part = native.screen_part(corner)
	assert(part.pixels == Vector2i(1280, 720), "Pixels follow the decoded frame, not the plan")

	# A screen without a monitor (the welcome surface) falls back to the whole frame.
	var welcome := VRScreen.new()
	part = native.screen_part(welcome)
	assert((part.crop as PackedFloat32Array).is_empty())
	assert(native.screen_part(null).is_empty())
	for screen in [whole, corner, welcome]:
		screen.free()
	main.free()
