extends SceneTree
const Policy = preload("res://src/pcvr_timing_policy.gd")
const Settings = preload("res://src/settings_controller.gd")
const Streams = preload("res://src/stream_manager.gd")

class UI extends RefCounted:
	func update_option_btn(button: Button, text: String) -> void: button.text = text

class Owner extends Node3D:
	var settings := AppSettings.new()
	var settings_controller
	var ui_controller := UI.new()
	var _ui_fps_btn := Button.new()

func _init() -> void:
	_test_effective_stream_settings()
	var timing := Policy.new()
	assert(timing.effective_fps(90) == 90)
	assert(not timing.begin(90, 120)) # Not a supported transport profile yet.
	assert(not timing.begin(60, 0))
	assert(not timing.begin(60, NAN))
	assert(timing.begin(60, 120))
	assert(timing.active and timing.display_hz == 120)
	assert(timing.effective_fps(90) == 60)
	assert(timing.effective_fps(144) == 60) # Saved preference can differ, untouched.
	assert(not timing.begin(20, 72)) # Cannot replace an active session's timing.
	assert(timing.stream_fps == 60 and timing.display_hz == 120)
	timing.end()
	assert(not timing.active and timing.effective_fps(90) == 90)
	timing.end() # Cleanup is idempotent.
	assert(timing.begin(60, 72)) # FPS and hardware Hz are deliberately distinct.
	assert(timing.display_hz == 72)
	timing.end()
	assert(timing.begin(72, 120))
	assert(timing.stream_fps == 72 and timing.display_hz == 72)
	timing.end()
	print("All pcvr_timing_policy tests passed")
	quit()

func _test_effective_stream_settings() -> void:
	var owner := Owner.new()
	owner.settings.host.stream_fps = 90
	owner.settings_controller = Settings.new(owner)
	var streams := Streams.new(owner)
	assert(streams.effective_stream_fps() == 90)
	assert(owner.settings_controller.pcvr_timing.begin(60, 120))
	owner.settings_controller.refresh_pcvr_timing_ui()
	assert(owner._ui_fps_btn.disabled and owner._ui_fps_btn.text == "60 (PCVR)")
	assert(streams.effective_stream_fps() == 60)
	owner.settings_controller.cycle_fps()
	assert(owner.settings.host.stream_fps == 90, "PCVR must not overwrite saved desktop FPS")
	owner.settings_controller.pcvr_timing.end()
	owner.settings_controller.refresh_pcvr_timing_ui()
	assert(streams.effective_stream_fps() == 90)
	assert(not owner._ui_fps_btn.disabled and owner._ui_fps_btn.text == "90")
	owner._ui_fps_btn.free()
	owner.free()
