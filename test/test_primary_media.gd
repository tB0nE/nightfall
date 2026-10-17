extends SceneTree

class FakeBrowser extends RefCounted:
	var render_size := Vector2i(1920, 1080)
	var active := false
	var texture: Texture2D
	var uploader := RefCounted.new()

class FakeVideo extends Node:
	func get_video_width(): return 2560
	func get_video_height(): return 1440

func _init():
	# Exercise production routing without entering the scene tree/XR runtime.
	var app = load("res://main.gd").new()
	var video := FakeVideo.new()
	app.stream_backend = StreamBackend.new(video)
	var browser := FakeBrowser.new()
	app.browser_prototype = browser
	assert(not app.primary_media_active())
	assert(app.primary_capture_source() == app.stream_backend)
	assert(app.primary_media_size() == Vector2i(2560, 1440))
	browser.active = true
	assert(not app.primary_media_active(), "Wait for the first browser texture")
	browser.texture = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	assert(app.primary_media_active(), "Browser AI must not require a stream")
	assert(app.primary_capture_source() == browser.uploader)
	assert(app.primary_media_size() == Vector2i(1920, 1080))
	browser.render_size = Vector2i(2560, 1440)
	assert(app.primary_media_size() == Vector2i(2560, 1440))
	assert(not app.is_streaming, "Browser selection must not fake a PC session")
	browser.active = false
	assert(not app.primary_media_active())
	app.session_lifecycle.stream_started()
	assert(app.primary_media_active())
	assert(app.primary_capture_source() == app.stream_backend)
	app.free()
	video.free()
	print("All primary_media tests passed")
	quit()
