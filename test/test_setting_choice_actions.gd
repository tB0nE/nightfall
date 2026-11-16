extends SceneTree

class Owner extends Node3D:
	var settings := AppSettings.new()
	var _ui_3d_hz_cap_btn: Button
	var _ui_3d_separation_btn: Button
	var _ui_3d_convergence_btn: Button
	var resolutions := [Vector2i(1280, 720), Vector2i(1920, 1080)]
	func compute_resolution_options() -> Array: return [150, 100, 75]

class Controller extends SettingsController:
	var commits := 0
	var saves := 0
	var resolution_commits := 0
	func _save_setting(_button: Button, _label: String): saves += 1
	func _schedule_ai_3d_commit(_delay_seconds: float = 0.6): commits += 1
	func _commit_resolution_selection(): resolution_commits += 1

func _init():
	var owner := Owner.new()
	var controller := Controller.new(owner)
	owner.settings.host.ai_3d_speed = 3
	controller.set_ai_3d_hz_cap(60)
	assert(owner.settings.host.ai_3d_hz_cap == 60 and controller.commits == 1)
	controller.set_ai_3d_hz_cap(60)
	controller.set_ai_3d_hz_cap(999)
	assert(controller.commits == 1)
	controller.set_ai_3d_separation(50)
	assert(owner.settings.host.ai_3d_separation_pct == 50 and controller.commits == 2)
	controller.set_ai_3d_separation(150)
	assert(controller.commits == 2, "Removed separation values must stay unavailable")
	owner.settings.host.sbs_mode = 1
	controller.set_ai_3d_convergence(70)
	assert(owner.settings.host.ai_3d_convergence_pct == 50 and controller.commits == 2)
	owner.settings.host.sbs_mode = 0
	controller.set_ai_3d_convergence(70)
	assert(owner.settings.host.ai_3d_convergence_pct == 70 and controller.commits == 3)
	owner.settings.host.ai_3d_speed = 1
	controller.set_ai_3d_hz_cap(30)
	assert(controller.commits == 3, "Auto retains its Hz policy")
	controller.set_resolution(0, false)
	assert(owner.settings.host.resolution_idx == 0 and controller.resolution_commits == 1)
	controller.set_resolution(0, false)
	controller.set_resolution(999, false)
	controller.set_resolution(100, true)
	assert(controller.resolution_commits == 1)
	owner.settings.host.is_polaris_host = true
	controller.set_resolution(75, true)
	assert(owner.settings.host.resolution_scale_pct == 75 and controller.resolution_commits == 2)
	controller.set_resolution(999, true)
	assert(controller.resolution_commits == 2)
	owner.free()
	print("All setting choice action tests passed")
	quit()
