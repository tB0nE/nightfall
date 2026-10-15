extends SceneTree

class FakeDepth extends RefCounted:
	var enabled := true
	func set_enabled(value: bool): enabled = value

class FakePresentation extends RefCounted:
	var stopped := false
	func deactivate_native(_restore: bool): stopped = true

class FakeSettings extends RefCounted:
	var restores := 0
	func apply_stereo(): restores += 1

class FakeSources extends RefCounted:
	signal changed
	func browser_closed(): changed.emit()

class FakeUploader extends RefCounted:
	var closed := false
	func close_browser_prototype(): closed = true

class FakeMain extends Node3D:
	var depth_estimator := FakeDepth.new()
	var video_presentation := FakePresentation.new()
	var settings_controller := FakeSettings.new()
	var screen_sources := FakeSources.new()
	var session_lifecycle := SessionLifecycle.new()
	var comp_shader_mat = null
	var comp_shader_mat_left = null
	var comp_shader_mat_right = null
	var screen_mesh := MeshInstance3D.new()
	func get_welcome_content_texture(): return null
	func primary_media_active(): return false
	func _log(_message: String): pass

func _init():
	_run.call_deferred()

func _run():
	var owner := FakeMain.new()
	root.add_child(owner)
	var browser = load("res://src/browser_prototype.gd").new(owner)
	var uploader := FakeUploader.new()
	browser.uploader = uploader
	browser.active = true
	browser.stop()
	assert(not browser.active and browser.closing)
	assert(not owner.depth_estimator.enabled)
	assert(owner.video_presentation.stopped and uploader.closed)
	assert(owner.settings_controller.restores == 0, "Never reactivate legacy in the closing frame")
	for _frame in range(4):
		await process_frame
	assert(not browser.closing)
	assert(owner.settings_controller.restores == 1)
	# A PC connection started during the drain owns presentation now.
	browser.active = true
	browser.stop()
	owner.session_lifecycle.begin_connect()
	for _frame in range(4):
		await process_frame
	assert(not browser.closing)
	assert(owner.settings_controller.restores == 1, "A late browser close cannot restore over a PC connection")
	owner.screen_mesh.free()
	owner.free()
	print("All browser_close tests passed")
	quit()
