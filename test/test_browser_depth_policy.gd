extends SceneTree

class Stream extends RefCounted:
	func meteor_depth_info(): return {"port": 47999, "key": "test-only"}

class Fixture extends Node3D:
	var settings := AppSettings.new()
	var is_streaming := true
	var stream_manager := Stream.new()
	var browser_prototype: RefCounted
	var device_is_quest2 := false

class QuestSettings extends SettingsController:
	# Exercise Android Auto resolution on a headless Linux test runner.
	func ai3d_options_locked() -> bool: return true
	func is_android_ai3d_auto() -> bool:
		return selected_depth_model_index() == ANDROID_MODEL_AUTO

func _init():
	var owner := Fixture.new()
	owner.browser_prototype = preload("res://src/browser_prototype.gd").new(owner)
	var defaults := QuestSettings.new(owner)
	owner.is_streaming = false
	defaults.enforce_ai3d_platform_lock()
	assert(owner.settings.host.ai_3d_speed == 0)
	assert(defaults.selected_depth_model_index() == SettingsController.ANDROID_MODEL_AUTO)
	assert(defaults.get_depth_backend_index() == SettingsController.AI3D_BACKEND_GPU)
	assert(defaults.get_depth_model_label() == "Auto")
	assert(defaults.get_ai_3d_gpu_api_label() == "OpenCL")
	assert(defaults.get_depth_model_index() == 0, "AI 3D stays disabled; selecting GPU must not start inference")
	owner.settings.host.ai_3d_backend_pref = SettingsController.AI3D_BACKEND_CPU
	assert(defaults.get_depth_backend_index() == SettingsController.AI3D_BACKEND_CPU)
	owner.is_streaming = true
	owner.settings.host.ai_3d_speed = 3
	owner.settings.host.ai_3d_model = SettingsController.ANDROID_MODEL_LEGACY_EDGEPAD_384
	owner.settings.host.ai_3d_backend_pref = SettingsController.AI3D_BACKEND_CPU
	owner.settings.host.ai_3d_meteor_declined = false
	var controller := QuestSettings.new(owner)
	assert(controller.meteor_depth_offered() and controller.meteor_depth_selected())
	var saved_model := owner.settings.host.ai_3d_model
	owner.browser_prototype.active = true
	assert(not controller.meteor_depth_offered() and not controller.meteor_depth_selected(), "A browser must never consume stream depth maps")
	assert(controller.selected_depth_model_index() == SettingsController.ANDROID_MODEL_AUTO)
	assert(controller.get_depth_backend_index() == SettingsController.AI3D_BACKEND_GPU)
	assert(controller.get_depth_model_index() == 25 and controller.get_ai_3d_gpu_api_effective() == 0)
	owner.device_is_quest2 = true
	assert(controller.get_depth_model_index() == 26 and controller.get_ai_3d_gpu_api_effective() == 1)
	owner.device_is_quest2 = false
	controller._auto_depth_fallback = true
	assert(controller.get_depth_model_index() == 26 and controller.get_ai_3d_gpu_api_effective() == 1)
	owner.browser_prototype.depth_model_override = SettingsController.ANDROID_MODEL_LEGACY_EDGEPAD_256
	owner.browser_prototype.depth_backend_override = SettingsController.AI3D_BACKEND_CPU
	assert(controller.get_depth_backend_index() == SettingsController.AI3D_BACKEND_CPU)
	assert(owner.settings.host.ai_3d_model == saved_model and not owner.settings.host.ai_3d_meteor_declined)
	owner.browser_prototype.active = false
	assert(controller.selected_depth_model_index() == saved_model)
	assert(controller.meteor_depth_selected(), "Returning to the stream retains its Meteor preference")
	owner.free()
	print("All browser_depth_policy tests passed")
	quit()
