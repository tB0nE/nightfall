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
	main.stereo_mode = (main.stereo_mode + 1) % 4
	update_stereo_shader()

func on_resume_auto_pressed():
	main.auto_detect_enabled = true
	main.detection_history.clear()
	update_ui()

func update_stereo_shader():
	main.screen_mesh.material_override.set_shader_parameter("stereo_mode", main.stereo_mode)
	var mode_names = ["2D Mode", "SBS Stretch", "SBS Crop", "AI 3D"]
	main.get_node("%SBSToggle").text = "Mode: " + mode_names[main.stereo_mode]
	if main.depth_estimator:
		main.depth_estimator.set_enabled(main.stereo_mode == 3)

func update_ui():
	main.get_node("%Crosshair").visible = (not main.is_xr_active and not main.mouse_captured_by_stream)
	main.get_node("%Laser").visible = main.is_xr_active
	main.get_node("%ResumeAutoButton").visible = !main.auto_detect_enabled
