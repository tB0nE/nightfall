extends Node3D

## Ty-Streamer: A Godot-based Moonlight client for XR.
## Handles 3D UI, Environment manipulation, and high-fidelity streaming.

enum AppMode { STREAM, ENV }

# -- Node References --
@onready var moon = $MoonlightStream
@onready var screen_mesh = $MeshInstance3D
@onready var ui_panel_3d = %UIPanel3D
@onready var ui_viewport = %UIViewport
@onready var stream_viewport = %StreamViewport
@onready var stream_target = %StreamTarget
@onready var detection_viewport = %DetectionViewport
@onready var detection_target = %DetectionTarget
@onready var config_mgr = MoonlightConfigManager.new()
@onready var comp_mgr = MoonlightComputerManager.new()
@onready var xr_origin = $XROrigin3D
@onready var xr_camera = $XROrigin3D/XRCamera3D
@onready var mouse_raycast = %RayCast3D
@onready var hand_raycast = %HandRayCast
@onready var right_hand = %RightHand
@onready var hit_dot = %HitDot
@onready var audio_player = %StreamAudioPlayer

# -- State Variables --
var stream_cfg: MoonlightStreamConfigurationResource
var stream_opts: MoonlightAdditionalStreamOptions

var current_host_id: int = -1
var is_streaming: bool = false
var stereo_mode: int = 0 # 0: 2D, 1: Stretch, 2: Crop
var current_mode: AppMode = AppMode.STREAM
var is_xr_active: bool = false
var was_clicking: bool = false
var mouse_captured_by_stream: bool = false
var suppress_input_frames: int = 0

var auto_detect_enabled: bool = true
var auto_detect_timer: float = 0.0
var auto_detect_running: bool = false
var detection_history: Array = []

var mouse_sensitivity: float = 0.002
var grabbed_node: Node3D = null
var grab_distance: float = 0.0
var grab_offset: Vector3 = Vector3.ZERO

var grabbed_bar: MeshInstance3D = null

var pad_buttons: int = 0
var pad_active: int = 0

func _log(msg: String):
	var f = FileAccess.open("user://debug.log", FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_line(msg)
		f.close()
	print(msg)

func _ready():
	OS.set_environment("CURL_CA_BUNDLE", "/system/etc/security/cacerts/")
	OS.set_environment("SSL_CERT_FILE", "/system/etc/security/cacerts/")
	_log("=== Ty-Streamer started ===")
	Engine.max_fps = 60
	
	%ScreenGrabBar.material_override = %ScreenGrabBar.material_override.duplicate()
	%MenuGrabBar.material_override = %MenuGrabBar.material_override.duplicate()
	
	# 1. Hide mouse cursor permanently for VR feel
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	# 2. Connect UI signals
	%PairButton.button_down.connect(_on_pair_pressed)
	%SBSToggle.button_down.connect(_on_sbs_toggled)
	%ResumeAutoButton.button_down.connect(_on_resume_auto_pressed)
	%ExitButton.pressed.connect(func(): get_tree().quit())
	%IPInput.gui_input.connect(_on_ipinput_gui_input)
	_setup_numpad()
	
	# 3. Initialize Moonlight Managers
	comp_mgr.set_config_manager(config_mgr)
	moon.set_config_manager(config_mgr)
	comp_mgr.pair_completed.connect(_on_pair_completed)
	
	# 4. Handle Streaming Lifecycle
	moon.connection_started.connect(func():
		is_streaming = true
		%StatusLabel.text = "Connected!"
		_log("[STREAM] Connection started!")
		_bind_texture()
		_setup_audio()
	)
	moon.connection_terminated.connect(func(_err, msg):
		is_streaming = false
		%StatusLabel.text = "Disconnected: " + str(msg)
		_log("[STREAM] Connection terminated: %s" % str(msg))
		if mouse_captured_by_stream:
			_release_stream_mouse()
		audio_player.stop()
	)
	
	# 5. Controller Signals
	right_hand.button_pressed.connect(_on_controller_button_pressed)
	
	# 6. Detect XR Environment
	var interface = XRServer.find_interface("OpenXR")
	if interface and interface.is_initialized():
		get_viewport().use_xr = true
		is_xr_active = true
		stereo_mode = 1 # Default to 3D in headset
		await get_tree().create_timer(0.5).timeout
		var cam_pos = xr_camera.global_position
		var cam_fwd = -xr_camera.global_transform.basis.z
		var cam_right = xr_camera.global_transform.basis.x
		screen_mesh.global_position = cam_pos + cam_fwd * 2.0
		screen_mesh.global_position.y -= 0.2
		var screen_to_cam = (cam_pos - screen_mesh.global_position).normalized()
		screen_mesh.rotation = Vector3.ZERO
		screen_mesh.rotation.y = atan2(screen_to_cam.x, screen_to_cam.z)
		var ui_dir = (cam_fwd - cam_right).normalized()
		ui_panel_3d.global_position = cam_pos + ui_dir * 1.8
		ui_panel_3d.global_position.y -= 0.4
		var ui_to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
		ui_panel_3d.rotation = Vector3.ZERO
		ui_panel_3d.rotation.y = atan2(ui_to_cam.x, ui_to_cam.z)
		screen_mesh.visible = false
		ui_panel_3d.visible = false
		await get_tree().process_frame
		screen_mesh.visible = true
		ui_panel_3d.visible = true
	else:
		is_xr_active = false
		stereo_mode = 0 # Default to 2D on desktop
	
	# 7. Load saved IP
	var save = ConfigFile.new()
	if save.load("user://last_connection.cfg") == OK:
		var saved_ip = save.get_value("connection", "ip", "")
		if saved_ip != "":
			%IPInput.text = saved_ip
	
	# 8. Final Setup
	_bind_texture()
	_update_mode_ui()
	_update_stereo_shader()
	
	Input.joy_connection_changed.connect(func(device, connected):
		print("[GAMEPAD] Device %d %s: %s" % [device, "connected" if connected else "disconnected", Input.get_joy_name(device)])
	)
	for pad in Input.get_connected_joypads():
		print("[GAMEPAD] Found device %d: %s" % [pad, Input.get_joy_name(pad)])

func _setup_audio():
	var audio_stream = moon.get_audio_stream()
	if audio_stream:
		audio_player.stream = audio_stream
		audio_player.play()
		print("Audio Stream Started")

func _bind_texture():
	var stream_tex = stream_viewport.get_texture()
	screen_mesh.material_override.set_shader_parameter("main_texture", stream_tex)
	detection_target.texture = stream_tex
	
	var ui_tex = ui_viewport.get_texture()
	ui_panel_3d.material_override.albedo_texture = ui_tex

func _process(delta):
	if Input.is_action_just_pressed("ui_focus_next"):
		if mouse_captured_by_stream:
			_release_stream_mouse()
		else:
			_switch_mode(AppMode.ENV if current_mode == AppMode.STREAM else AppMode.STREAM)
	
	if Input.is_key_pressed(KEY_CTRL) and Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT):
		if mouse_captured_by_stream:
			_release_stream_mouse()
		elif current_mode != AppMode.STREAM:
			_switch_mode(AppMode.STREAM)

	if not mouse_captured_by_stream:
		match current_mode:
			AppMode.STREAM:
				_handle_pointer_interaction()
			AppMode.ENV:
				_handle_env_movement(delta)

	# Auto-Detection Logic
	if is_streaming and auto_detect_enabled and not auto_detect_running:
		auto_detect_timer += delta
		if auto_detect_timer >= 0.3:
			auto_detect_timer = 0.0
			auto_detect_running = true
			_run_auto_detection()
	elif not is_streaming:
		auto_detect_timer = 0.0
			
	# Global Grab Logic
	if grabbed_node:
		var active_raycast = hand_raycast if is_xr_active else mouse_raycast
		var ray_tip = active_raycast.global_position + (-active_raycast.global_transform.basis.z * grab_distance)
		grabbed_node.global_position = ray_tip + grab_offset
		var cam_pos = xr_camera.global_position
		grabbed_node.rotation.y = atan2(cam_pos.x - grabbed_node.global_position.x, cam_pos.z - grabbed_node.global_position.z)
		
		var still_clicking = right_hand.get_float("trigger") > 0.5 if is_xr_active else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if not still_clicking:
			if grabbed_bar:
				_set_grab_bar_color(grabbed_bar, Color.WHITE)
				grabbed_bar = null
			grabbed_node = null

func _switch_mode(new_mode: AppMode):
	current_mode = new_mode
	_update_mode_ui()
	print("Switched to Mode: ", AppMode.keys()[current_mode])

func _update_mode_ui():
	%ModeLabel.text = "Mode: " + AppMode.keys()[current_mode]
	%Crosshair.visible = (current_mode == AppMode.STREAM and not is_xr_active and not mouse_captured_by_stream)
	%Laser.visible = (current_mode == AppMode.STREAM and is_xr_active)
	%ResumeAutoButton.visible = !auto_detect_enabled
	if current_mode != AppMode.STREAM:
		hit_dot.position = Vector2(-20, -20)
		%StreamHitDot.position = Vector2(-30, -30)

func _handle_pointer_interaction():
	var active_raycast = hand_raycast if is_xr_active else mouse_raycast
	
	if not grabbed_node:
		%ScreenGrabBar.visible = false
		%MenuGrabBar.visible = false
		if grabbed_bar:
			_set_grab_bar_color(grabbed_bar, Color.WHITE)
			grabbed_bar = null
	
	if active_raycast.is_colliding():
		var collider = active_raycast.get_collider()
		var parent = collider.get_parent()
		
		if parent == screen_mesh or parent == %ScreenGrabBar: %ScreenGrabBar.visible = true
		if parent == ui_panel_3d or parent == %MenuGrabBar: %MenuGrabBar.visible = true
		
		var is_now_clicking = right_hand.get_float("trigger") > 0.5 if is_xr_active else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		
		if parent == ui_panel_3d:
			var hit_pos = active_raycast.get_collision_point()
			var local_pos = ui_panel_3d.to_local(hit_pos)
			var pixel_pos = Vector2((local_pos.x + 0.5) * 500, (0.5 - local_pos.y) * 500)
			hit_dot.position = pixel_pos - (hit_dot.size / 2.0)
			hit_dot.color = Color(1, 0, 0) if is_now_clicking else Color(0, 1, 0)
			
			var motion = InputEventMouseMotion.new()
			motion.position = pixel_pos
			motion.global_position = pixel_pos
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT if is_now_clicking else 0
			ui_viewport.push_input(motion)
			
			if is_now_clicking and not was_clicking:
				_push_ui_click(pixel_pos, true)
				was_clicking = true
			elif not is_now_clicking and was_clicking:
				_push_ui_click(pixel_pos, false)
				was_clicking = false
			return
			
		elif parent == screen_mesh and is_streaming:
			var hit_pos = active_raycast.get_collision_point()
			var local_pos = screen_mesh.to_local(hit_pos)
			var mesh_size = screen_mesh.mesh.size
			var uv_x = clampf((local_pos.x + mesh_size.x * 0.5) / mesh_size.x, 0.0, 1.0)
			var uv_y = clampf((mesh_size.y * 0.5 - local_pos.y) / mesh_size.y, 0.0, 1.0)
			var host_x = int(uv_x * stream_viewport.size.x)
			var host_y = int(uv_y * stream_viewport.size.y)

			%StreamHitDot.position = Vector2(host_x - 10, host_y - 10)
			%StreamHitDot.size = Vector2(20, 20)
			%StreamHitDot.color = Color(0, 1, 0)

			if is_xr_active:
				moon.send_mouse_position_event(host_x, host_y, stream_viewport.size.x, stream_viewport.size.y)
				if is_now_clicking and not was_clicking:
					moon.send_mouse_button_event(7, MOUSE_BUTTON_LEFT)
					was_clicking = true
				elif not is_now_clicking and was_clicking:
					moon.send_mouse_button_event(8, MOUSE_BUTTON_LEFT)
					was_clicking = false
			else:
				if is_now_clicking and not was_clicking:
					moon.send_mouse_position_event(host_x, host_y, stream_viewport.size.x, stream_viewport.size.y)
					suppress_input_frames = 3
					_capture_stream_mouse()
					was_clicking = true
			return

		elif parent == %ScreenGrabBar or parent == %MenuGrabBar:
			if is_now_clicking and not grabbed_node:
				grabbed_node = parent.get_parent()
				grabbed_bar = parent
				var grab_point = active_raycast.get_collision_point()
				grab_distance = (grab_point - active_raycast.global_position).length()
				grab_offset = grabbed_node.global_position - grab_point
				_set_grab_bar_color(parent, Color(0.2, 0.5, 1.0))
				was_clicking = true
			elif not grabbed_node:
				_set_grab_bar_color(parent, Color(0, 1, 0))
			return

	elif was_clicking:
		was_clicking = false
	
	hit_dot.position = Vector2(-20, -20)
	%StreamHitDot.position = Vector2(-30, -30)

func _set_grab_bar_color(bar: MeshInstance3D, color: Color):
	bar.material_override.albedo_color = color

func _push_ui_click(pos: Vector2, pressed: bool):
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	ui_viewport.push_input(event)

func _setup_numpad():
	var keys = ["7","8","9","4","5","6","1","2","3",".","0","DEL"]
	for key in keys:
		var btn = Button.new()
		btn.text = key
		btn.custom_minimum_size = Vector2(60, 35)
		btn.size_flags_stretch_ratio = 1.0
		btn.pressed.connect(_on_numpad_key.bind(key))
		%Numpad.add_child(btn)

func _on_numpad_key(key: String):
	if key == "DEL":
		var text = %IPInput.text
		if text.length() > 0:
			%IPInput.text = text.substr(0, text.length() - 1)
	elif %IPInput.text.length() < 15:
		%IPInput.text += key

func _on_ipinput_gui_input(event):
	if event is InputEventMouseButton and event.pressed:
		%Numpad.visible = true

func _on_controller_button_pressed(button_name: String):
	match button_name:
		"by_button": _switch_mode(AppMode.STREAM)
		"ax_button": _switch_mode(AppMode.ENV)

func _handle_env_movement(delta):
	var move_speed = 3.0
	var move_dir = Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move_dir -= xr_origin.global_transform.basis.z
	if Input.is_key_pressed(KEY_S): move_dir += xr_origin.global_transform.basis.z
	if Input.is_key_pressed(KEY_A): move_dir -= xr_origin.global_transform.basis.x
	if Input.is_key_pressed(KEY_D): move_dir += xr_origin.global_transform.basis.x
	if move_dir != Vector3.ZERO:
		xr_origin.global_translate(move_dir.normalized() * move_speed * delta)

func _input(event):
	if mouse_captured_by_stream and is_streaming:
		if event is InputEventKey and event.pressed \
			and event.keycode == KEY_ESCAPE \
			and Input.is_key_pressed(KEY_CTRL) \
			and Input.is_key_pressed(KEY_ALT):
				_release_stream_mouse()
				return
		if suppress_input_frames > 0:
			suppress_input_frames -= 1
			return
		if event is InputEventMouseMotion:
			moon.send_mouse_move_event(int(event.relative.x), int(event.relative.y))
		elif event is InputEventMouseButton:
			var action = 7 if event.pressed else 8
			moon.send_mouse_button_event(action, event.button_index)
		elif event is InputEventKey:
			moon.send_keyboard_event(event.keycode, 3 if event.pressed else 4, 0)
		elif event is InputEventJoypadButton:
			if event.pressed:
				pad_buttons |= (1 << event.button_index)
			else:
				pad_buttons &= ~(1 << event.button_index)
			pad_active |= (1 << event.device)
			print("[GAMEPAD] Button dev=%d btn=%d pressed=%s mask=%d" % [event.device, event.button_index, event.pressed, pad_buttons])
			_send_controller(event.device)
		elif event is InputEventJoypadMotion:
			pad_active |= (1 << event.device)
			_send_controller(event.device)
		return
	
	if not is_xr_active and event is InputEventMouseMotion:
		xr_origin.rotate_y(-event.relative.x * mouse_sensitivity)
		xr_camera.rotate_x(-event.relative.y * mouse_sensitivity)
		xr_camera.rotation.x = clamp(xr_camera.rotation.x, -PI/2, PI/2)

	if event is InputEventKey and ui_viewport.gui_get_focus_owner():
		ui_viewport.push_input(event)
		return

	if is_streaming:
		if event is InputEventJoypadButton:
			if event.pressed:
				pad_buttons |= (1 << event.button_index)
			else:
				pad_buttons &= ~(1 << event.button_index)
			pad_active |= (1 << event.device)
			print("[GAMEPAD] Button dev=%d btn=%d pressed=%s mask=%d" % [event.device, event.button_index, event.pressed, pad_buttons])
			_send_controller(event.device)
			return
		elif event is InputEventJoypadMotion:
			pad_active |= (1 << event.device)
			_send_controller(event.device)
			return
		
		if current_mode == AppMode.STREAM:
			if event is InputEventKey:
				moon.send_keyboard_event(event.keycode, 3 if event.pressed else 4, 0)

func _float_to_short(val: float) -> int:
	return int(clampf(val, -1.0, 1.0) * 32767.0)

func _send_controller(device: int):
	var lx = Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
	var ly = Input.get_joy_axis(device, JOY_AXIS_LEFT_Y)
	var rx = Input.get_joy_axis(device, JOY_AXIS_RIGHT_X)
	var ry = Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y)
	var _lt = Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)
	var _rt = Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT)
	moon.send_controller_event(pad_active, pad_buttons, device, _float_to_short(lx), _float_to_short(ly), _float_to_short(rx), _float_to_short(ry))

func _capture_stream_mouse():
	mouse_captured_by_stream = true
	was_clicking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	%Crosshair.visible = false
	%StreamHitDot.position = Vector2(-30, -30)
	print("[MOUSE] Stream captured - move/click controls remote. Shift+F1 to release.")

func _release_stream_mouse():
	mouse_captured_by_stream = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_mode_ui()
	print("[MOUSE] Released - back to pointer mode.")

func _on_pair_pressed():
	var ip = %IPInput.text
	%Numpad.visible = false
	if ip.is_empty(): ip = "127.0.0.1"
	var save = ConfigFile.new()
	save.set_value("connection", "ip", ip)
	save.save("user://last_connection.cfg")
	config_mgr.load_config()
	var paired_host_id = -1
	for h in config_mgr.get_hosts():
		if h.has("localaddress") and h.localaddress == ip:
			paired_host_id = h.id
			break
	if paired_host_id != -1:
		current_host_id = paired_host_id
		%StatusLabel.text = "Already paired, starting stream..."
		start_stream(paired_host_id, 881448767)
	else:
		%StatusLabel.text = "Pairing with " + ip + "..."
		_log("[PAIR] Starting pair with %s:47989..." % ip)
		var pin = comp_mgr.start_pair(ip, 47989)
		_log("[PAIR] start_pair returned: %s (type=%s)" % [str(pin), str(typeof(pin))])
		if str(pin) == "" or str(pin) == "0":
			%StatusLabel.text = "Failed to connect to " + ip
			%PairButton.text = "Pair & Start Stream"
			%PairButton.disabled = false
			_log("[PAIR] FAILED - no pin returned")
			return
		%StatusLabel.text = "PIN: " + str(pin) + "\nEnter on Sunshine host"
		%PairButton.text = "Waiting for pair..."
		%PairButton.disabled = true

func _on_pair_completed(success: bool, _msg: String):
	_log("[PAIR] pair_completed: success=%s msg=%s" % [str(success), str(_msg)])
	%StatusLabel.text = "Pair " + ("OK" if success else "FAILED: " + str(_msg))
	%PairButton.text = "Pair & Start Stream"
	%PairButton.disabled = false
	if success:
		%StatusLabel.text = "Pairing successful, starting stream..."
		config_mgr.load_config()
		var ip = %IPInput.text
		for h in config_mgr.get_hosts():
			if h.localaddress == ip:
				current_host_id = h.id
				start_stream(h.id, 881448767)
				break

func start_stream(host_id: int, app_id: int):
	_log("[STREAM] Starting stream host_id=%d app_id=%d" % [host_id, app_id])
	stream_cfg = MoonlightStreamConfigurationResource.new()
	stream_cfg.set_width(1920)
	stream_cfg.set_height(1080)
	stream_cfg.set_fps(60)
	stream_cfg.set_bitrate(20000)
	stream_opts = MoonlightAdditionalStreamOptions.new()
	stream_opts.set_disable_hw_acceleration(false)
	stream_opts.set_disable_audio(false)
	stream_opts.set_disable_video(false)
	moon.set_render_target(stream_target)
	moon.start_play_stream(host_id, app_id, stream_cfg, stream_opts)
	_log("[STREAM] start_play_stream called")
	await get_tree().create_timer(0.1).timeout
	_bind_texture()

func _on_sbs_toggled():
	auto_detect_enabled = false
	stereo_mode = (stereo_mode + 1) % 3
	_update_stereo_shader()
	_update_mode_ui()

func _on_resume_auto_pressed():
	auto_detect_enabled = true
	detection_history.clear()
	_update_mode_ui()

func _update_stereo_shader():
	screen_mesh.material_override.set_shader_parameter("stereo_mode", stereo_mode)
	var mode_names = ["2D Mode", "SBS Stretch", "SBS Crop"]
	%SBSToggle.text = "Mode: " + mode_names[stereo_mode]

func _run_auto_detection():
	detection_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img = detection_viewport.get_texture().get_image()
	if !img or img.get_width() < 64:
		auto_detect_running = false
		return
	img.convert(Image.FORMAT_L8)
	var data = img.get_data()
	var w = img.get_width()
	var total_diff = 0.0
	var center_seam = 0.0
	for y in range(4, 28):
		var row_offset = y * w
		for x in range(0, 32):
			total_diff += absf(float(data[row_offset + x]) - float(data[row_offset + x + 32]))
		center_seam += absf(float(data[row_offset + 31]) - float(data[row_offset + 32]))
	var avg_diff = total_diff / (24.0 * 32.0) / 255.0
	var avg_seam = center_seam / 24.0 / 255.0
	var detected_mode = 0
	if avg_seam > 0.08:
		var top_brightness = 0.0
		var center_brightness = 0.0
		var row_top = 2 * w
		var row_center = 16 * w
		for x in range(0, 64):
			top_brightness += float(data[row_top + x])
			center_brightness += float(data[row_center + x])
		var avg_top = top_brightness / 64.0 / 255.0
		var avg_center = center_brightness / 64.0 / 255.0
		detected_mode = 2 if top_brightness < (center_brightness * 0.3) else 1
		print("[AUTO-SBS] SBS: seam=%.4f diff=%.4f top=%.2f center=%.2f -> %s" % [avg_seam, avg_diff, avg_top, avg_center, "CROP" if detected_mode == 2 else "STRETCH"])
	else:
		print("[AUTO-SBS] 2D: seam=%.4f diff=%.4f" % [avg_seam, avg_diff])
	detection_history.append(detected_mode)
	if detection_history.size() > 5:
		detection_history.pop_front()
	var all_match = true
	for val in detection_history:
		if val != detected_mode:
			all_match = false
			break
	if all_match and detection_history.size() >= 5 and detected_mode != stereo_mode:
		stereo_mode = detected_mode
		_update_stereo_shader()
	auto_detect_running = false
