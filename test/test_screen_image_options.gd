extends SceneTree

class FakeSources:
	extends RefCounted
	func is_browser_screen(_screen) -> bool: return false

class FakeMain:
	extends Node3D
	var settings := AppSettings.new()
	var screen_sources := FakeSources.new()
	var layout := ScreenLayout.single(Vector2i(1920, 1080))
	var is_streaming := true
	var primary_screen: VRScreen
	func primary_media_size() -> Vector2i: return Vector2i(2560, 1080)

func _init():
	var wide := ScreenImageOptions.crop_region(Vector2i(1920, 1080), 1)
	assert(wide.is_equal_approx(Vector4(0, 5.0 / 42.0, 1, 16.0 / 21.0)))
	var narrow := ScreenImageOptions.crop_region(Vector2i(1920, 1080), 2)
	assert(narrow.is_equal_approx(Vector4(0.125, 0, 0.75, 1)))
	assert(ScreenImageOptions.content_uv(Vector2(0, 0.5), narrow).is_equal_approx(Vector2(0.125, 0.5)))
	assert(ScreenImageOptions.content_uv(Vector2(1, 0.5), narrow).is_equal_approx(Vector2(0.875, 0.5)))
	assert(ScreenImageOptions.crop_region(Vector2i(2560, 1080), 3).is_equal_approx(Vector4(0.125, 0, 0.75, 1)))
	assert(ScreenImageOptions.crop_region(Vector2i.ZERO, 1) == Vector4(0, 0, 1, 1))
	assert(ScreenImageOptions.crop_region(Vector2i(1920,1080), 0) == Vector4(0, 0, 1, 1))
	var settings := AppSettings.new()
	assert(settings.screen_crop_mode == 0 and settings.screen_key_mode == 0)
	settings.screen_crop_mode = 2
	settings.screen_key_mode = 1
	settings.screen_key_tolerance = 2
	settings.screen_host_background = true
	var config := ConfigFile.new()
	SettingsPersistence.write_app(config, settings)
	var loaded := AppSettings.new()
	SettingsPersistence.read_app(config, loaded, true, [0])
	assert(loaded.screen_host_background)
	assert(loaded.screen_crop_mode == 2 and loaded.screen_key_mode == 1 and loaded.screen_key_tolerance == 2)
	loaded.reset_display()
	assert(not loaded.screen_host_background)
	assert(loaded.screen_crop_mode == 0 and loaded.screen_key_mode == 0 and loaded.screen_key_tolerance == 1)
	# Moving the tracking origin up a floor and rotating it must not move
	# a room-fixed object, even when XROrigin itself has an application offset.
	var old_from_new := Transform3D(Basis(Vector3.UP, 1.2), Vector3(3, 2.8, -1))
	var world_from_tracking := Transform3D(Basis(Vector3.UP, -0.4), Vector3(-2, 0.2, 3))
	var object_old := Transform3D(Basis(Vector3.UP, 0.7), Vector3(0.3, 1.4, -2.16))
	var move := WorkspaceStability.correction(old_from_new, world_from_tracking)
	var old_tracking_object := world_from_tracking.affine_inverse() * object_old
	var new_tracking_object := world_from_tracking.affine_inverse() * (move * object_old)
	assert((old_from_new * new_tracking_object).is_equal_approx(old_tracking_object))
	assert(WorkspaceStability.correction(Transform3D.IDENTITY, world_from_tracking).is_equal_approx(Transform3D.IDENTITY))
	var owner := FakeMain.new()
	var screen := VRScreen.new()
	owner.primary_screen = screen
	screen.monitor = ScreenLayout.MonitorSpec.new()
	screen.monitor.frame_rect = Rect2i(0, 0, 1920, 1080)
	owner.settings.screen_crop_mode = 3
	var options := ScreenImageOptions.new(owner)
	assert(options.crop_for(screen).is_equal_approx(Vector4(0.125, 0, 0.75, 1)))
	owner.layout.source = &"host_manifest"
	assert(options.crop_for(screen) == Vector4(0, 0, 1, 1))
	# Manual crop must never affect a secondary screen.
	var secondary := VRScreen.new()
	owner.settings.screen_crop_mode = 2
	assert(options.crop_for(secondary) == Vector4(0, 0, 1, 1))
	secondary.free()
	# Bright content with persistent, symmetric 21:9 bars.
	var image := Image.create(128, 72, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	image.fill_rect(Rect2i(0, 9, 128, 54), Color(0.7, 0.5, 0.3))
	var detector := AutoScreenCrop.new()
	assert(AutoScreenCrop.detect(image, Vector2i(1920,1080)) == 1)
	for i in 4: assert(not detector.observe(image, Vector2i(1920,1080)))
	assert(detector.observe(image, Vector2i(1920,1080)))
	assert(detector.region.is_equal_approx(Vector4(0, 9.0 / 72.0, 1, 54.0 / 72.0)))
	var confirmed := detector.region
	var dark := Image.create(128, 72, false, Image.FORMAT_RGBA8)
	dark.fill(Color.BLACK)
	for i in 8: assert(not detector.observe(dark, Vector2i(1920,1080)))
	assert(detector.region == confirmed)
	# A subtitle in a bar requests the full picture, preserving that content.
	image.fill_rect(Rect2i(35, 66, 55, 2), Color.WHITE)
	assert(AutoScreenCrop.detect(image, Vector2i(1920,1080)) == 0)
	# Sustained full-frame content clears a previous crop.
	image.fill(Color(0.4, 0.5, 0.6))
	for i in 4: assert(not detector.observe(image, Vector2i(1920,1080)))
	assert(detector.observe(image, Vector2i(1920,1080)))
	assert(detector.region == AutoScreenCrop.IDENTITY)
	# A measured 4:3 border is removed exactly, without a sample-pixel margin.
	detector.reset()
	image.fill(Color.BLACK)
	image.fill_rect(Rect2i(16, 0, 96, 72), Color.WHITE)
	for i in 5: detector.observe(image, Vector2i(1920,1080))
	assert(detector.region.is_equal_approx(Vector4(0.125, 0, 0.75, 1)))
	# Nearby real-world ratios must use measured edges, not the nominal 21:9.
	detector.reset()
	image.fill(Color.BLACK)
	image.fill_rect(Rect2i(0, 8, 128, 56), Color.WHITE)
	for i in 5: detector.observe(image, Vector2i(1920,1080))
	assert(detector.region.is_equal_approx(Vector4(0, 8.0 / 72.0, 1, 56.0 / 72.0)))
	# Changing boundaries within the same preset restarts confirmation.
	image.fill(Color.BLACK)
	image.fill_rect(Rect2i(0, 9, 128, 54), Color.WHITE)
	var previous := detector.region
	for i in 4:
		detector.observe(image, Vector2i(1920,1080))
		assert(detector.region == previous)
	assert(detector.observe(image, Vector2i(1920,1080)))
	assert(detector.region.is_equal_approx(Vector4(0, 9.0 / 72.0, 1, 54.0 / 72.0)))
	# Auto survives persistence without changing existing numeric presets.
	settings.screen_crop_mode = ScreenImageOptions.AUTO_MODE
	SettingsPersistence.write_app(config, settings)
	SettingsPersistence.read_app(config, loaded, true, [0])
	assert(loaded.screen_crop_mode == ScreenImageOptions.AUTO_MODE)
	screen.free()
	owner.free()
	print("All screen_image_options tests passed")
	quit()
