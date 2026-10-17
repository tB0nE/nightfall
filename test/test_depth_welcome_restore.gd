extends SceneTree

class FakeSettings extends RefCounted:
	func get_stereo_mode(): return 6

class FakeComp extends RefCounted:
	var in_use := true

class FakeScreen extends RefCounted:
	var comp_viewport := SubViewport.new()

class FakeMain extends Node3D:
	var settings_controller := FakeSettings.new()
	var comp := FakeComp.new()
	var primary_screen := FakeScreen.new()
	var media_active := false
	func primary_media_active(): return media_active

class MeteorTeardownDepth extends DepthEstimatorModule:
	var resizes := 0
	func sync_model_size(): resizes += 1

func _init():
	var owner := FakeMain.new()
	var depth := DepthEstimatorModule.new(owner)
	var viewport: SubViewport = owner.primary_screen.comp_viewport
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	depth._update_mono_capture_requirement()
	assert(viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"Saved AI 3D must not disable the restored welcome viewport")
	owner.media_active = true
	depth._update_mono_capture_requirement()
	assert(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Active stereo media may still disable unused mono capture")
	owner.media_active = false
	depth._update_mono_capture_requirement()
	assert(viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
	var retiring := MeteorTeardownDepth.new(owner)
	retiring._meteor_in_use = true
	retiring.enabled = false
	retiring._set_meteor_in_use(false)
	assert(retiring.resizes == 0, "Stopping Meteor must not resize retired depth targets")
	retiring._meteor_in_use = true
	retiring.enabled = true
	owner.media_active = false
	retiring._set_meteor_in_use(false)
	assert(retiring.resizes == 0, "Welcome has no live depth consumer")
	retiring._meteor_in_use = true
	owner.media_active = true
	retiring._set_meteor_in_use(false)
	assert(retiring.resizes == 1, "A live local fallback still restores model dimensions")
	viewport.free()
	owner.free()
	print("All depth welcome restore tests passed")
	quit()
