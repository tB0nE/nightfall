extends SceneTree
class UI extends RefCounted:
	func update_3d_btn_state(): pass
class Toast extends RefCounted:
	var messages: Array = []
	func show(text,_camera,seconds): messages.append([text,seconds])
class Owner extends Node3D:
	var settings := AppSettings.new()
	var _ui_sbs_btn: Button
	var ui_controller := UI.new()
	var composition_toast := Toast.new()
	var xr_camera: Node3D
	var screen_shortcuts = null
	var screens: Array = [null]
	func _log(_text): pass
class Controller extends SettingsController:
	var saved := ConfigFile.new()
	func apply_stereo(): pass
	func _save_setting(_button,_text): SettingsPersistence.write_host(saved,"host",main.settings.host)
func _init(): call_deferred("run")
func run():
	var owner := Owner.new()
	var controller := Controller.new(owner)
	controller.set_sbs_mode(2)
	controller.toggle_sbs_mode()
	assert(owner.settings.host.sbs_mode==0 and owner.settings.host.sbs_last_mode==2)
	var restored := HostSettings.new()
	SettingsPersistence.read_host(controller.saved,"host",restored,[60],[100],4,10)
	assert(restored.sbs_mode==0 and restored.sbs_last_mode==2)
	owner.settings.host = restored
	controller.toggle_sbs_mode()
	assert(owner.settings.host.sbs_mode==2)
	assert(owner.composition_toast.messages.back()==["SBS: Crop",2.5])
	controller.set_sbs_mode(1)
	controller.toggle_sbs_mode()
	controller.toggle_sbs_mode()
	assert(owner.settings.host.sbs_mode==1 and owner.composition_toast.messages.back()[0]=="SBS: Stretch")
	owner.settings.host = HostSettings.new()
	controller.toggle_sbs_mode()
	assert(owner.settings.host.sbs_mode==1,"A different host must not inherit the previous host's Crop choice")
	owner.free()
	print("SBS shortcut: selected mode, persistence, host isolation and popup passed")
	quit()
