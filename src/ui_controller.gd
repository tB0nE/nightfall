class_name UIController
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func setup_numpad():
	var keys = ["7","8","9","4","5","6","1","2","3",".","0","DEL"]
	for key in keys:
		var btn = Button.new()
		btn.text = key
		btn.custom_minimum_size = Vector2(60, 35)
		btn.size_flags_stretch_ratio = 1.0
		btn.pressed.connect(on_numpad_key.bind(key))
		main.get_node("%Numpad").add_child(btn)

func on_numpad_key(key: String):
	if key == "DEL":
		var text = main.get_node("%IPInput").text
		if text.length() > 0:
			main.get_node("%IPInput").text = text.substr(0, text.length() - 1)
	elif main.get_node("%IPInput").text.length() < 15:
		main.get_node("%IPInput").text += key

func on_ipinput_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		main.get_node("%Numpad").visible = true

func on_sbs_toggled():
	main.auto_detect_enabled = false
	main.stereo_mode = (main.stereo_mode + 1) % 3
	update_stereo_shader()
	update_mode_ui()

func on_resume_auto_pressed():
	main.auto_detect_enabled = true
	main.detection_history.clear()
	update_mode_ui()

func update_stereo_shader():
	main.screen_mesh.material_override.set_shader_parameter("stereo_mode", main.stereo_mode)
	var mode_names = ["2D Mode", "SBS Stretch", "SBS Crop"]
	main.get_node("%SBSToggle").text = "Mode: " + mode_names[main.stereo_mode]

func update_mode_ui():
	main.get_node("%ModeLabel").text = "Mode: " + ["STREAM", "ENV"][main.current_mode]
	main.get_node("%Crosshair").visible = (main.current_mode == 0 and not main.is_xr_active and not main.mouse_captured_by_stream)
	main.get_node("%Laser").visible = (main.current_mode == 0 and main.is_xr_active)
	main.get_node("%ResumeAutoButton").visible = !main.auto_detect_enabled
	if main.current_mode != 0:
		main.hit_dot.position = Vector2(-20, -20)
		main.get_node("%StreamHitDot").position = Vector2(-30, -30)
