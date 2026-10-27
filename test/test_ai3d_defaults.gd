extends SceneTree

class Stream extends RefCounted:
	func meteor_depth_info(): return {}

class Fixture extends Node3D:
	var settings := AppSettings.new()
	var is_streaming := false
	var stream_manager := Stream.new()
	var device_is_quest2 := false

class QuestSettings extends SettingsController:
	# Exercise Android Auto resolution on a headless Linux test runner.
	func ai3d_options_locked() -> bool: return true
	func is_android_ai3d_auto() -> bool:
		return main.settings.host.ai_3d_model == ANDROID_MODEL_AUTO

func _init():
	var owner := Fixture.new()
	var defaults := QuestSettings.new(owner)
	defaults.enforce_ai3d_platform_lock()
	# A fresh Quest 3 install has AI 3D off with Auto on the GPU; it must not
	# read as EdgePad-256-CPU before the user turns AI 3D on.
	assert(owner.settings.host.ai_3d_speed == 0)
	assert(owner.settings.host.ai_3d_model == SettingsController.ANDROID_MODEL_AUTO)
	assert(defaults.get_depth_backend_index() == SettingsController.AI3D_BACKEND_GPU)
	assert(defaults.get_depth_model_label() == "Auto")
	assert(defaults.get_depth_model_index() == 0, "AI 3D stays disabled; selecting GPU must not start inference")
	owner.settings.host.ai_3d_backend_pref = SettingsController.AI3D_BACKEND_CPU
	assert(defaults.get_depth_backend_index() == SettingsController.AI3D_BACKEND_CPU)

	# Stats name the model Auto runs (Rush_iam: EdgePad-512 showed as 384).
	owner.settings.host.ai_3d_backend_pref = SettingsController.AI3D_BACKEND_GPU
	owner.settings.host.ai_3d_speed = 1
	assert(defaults.active_android_depth_model_name() == "EdgePad-512")
	owner.device_is_quest2 = true
	assert(defaults.active_android_depth_model_name() == "EdgePad-256")
	owner.device_is_quest2 = false
	owner.settings.host.ai_3d_model = SettingsController.ANDROID_MODEL_LEGACY_EDGEPAD_384
	owner.settings.host.ai_3d_speed = 3
	assert(defaults.active_android_depth_model_name() == "EdgePad-384 (Reference)")

	# A GPU model change shows "Loading depth model…"; repeats and CPU don't.
	var gpu := SettingsController.AI3D_BACKEND_GPU
	var cpu := SettingsController.AI3D_BACKEND_CPU
	assert(SettingsController.depth_model_switch_loads(Vector2i(30, gpu), Vector2i(25, gpu)))
	assert(SettingsController.depth_model_switch_loads(Vector2i(0, cpu), Vector2i(25, gpu)), "turning AI 3D on loads too")
	assert(not SettingsController.depth_model_switch_loads(Vector2i(25, gpu), Vector2i(25, gpu)))
	assert(not SettingsController.depth_model_switch_loads(Vector2i(25, gpu), Vector2i(29, cpu)))
	assert(not SettingsController.depth_model_switch_loads(Vector2i(25, gpu), Vector2i(0, cpu)))
	owner.queue_free()
	print("All ai3d_defaults tests passed")
	quit()
