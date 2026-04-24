extends Node3D

## Ty-Streamer: A Godot-based Moonlight client for XR.
## Handles 3D UI, Environment manipulation, and high-fidelity streaming.

enum AppMode { UI, ENV, STREAM }

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
var current_mode: AppMode = AppMode.UI
var is_xr_active: bool = false
var was_clicking: bool = false

var auto_detect_enabled: bool = true
var auto_detect_timer: float = 0.0
var detection_history: Array = [] # Stores last 5 detection results

var mouse_sensitivity: float = 0.002

func _ready():
	# 1. Connect UI signals
	%PairButton.button_down.connect(_on_pair_pressed)
	%SBSToggle.button_down.connect(_on_sbs_toggled)
	%ResumeAutoButton.button_down.connect(_on_resume_auto_pressed)
	%ExitButton.button_down.connect(func(): get_tree().quit())
	
	# 2. Initialize Moonlight Managers
	comp_mgr.set_config_manager(config_mgr)
	moon.set_config_manager(config_mgr)
	comp_mgr.pair_completed.connect(_on_pair_completed)
	
	# 3. Handle Streaming Lifecycle
	moon.connection_started.connect(func():
		is_streaming = true
		print("STREAM SUCCESS: Connected!")
		_bind_texture()
		_setup_audio()
	)
	moon.connection_terminated.connect(func(err, msg):
		is_streaming = false
		print("STREAM ERROR: ", err, " - ", msg)
		audio_player.stop()
	)
	
	# 4. Controller Signals
	right_hand.button_pressed.connect(_on_controller_button_pressed)
	
	# 5. Detect XR Environment
	var interface = XRServer.find_interface("OpenXR")
	if interface and interface.is_initialized():
		get_viewport().use_xr = true
		is_xr_active = true
		stereo_mode = 1 # Default to 3D in headset
	else:
		is_xr_active = false
		stereo_mode = 0 # Default to 2D on desktop
	
	# 6. Final Setup
	_bind_texture()
	_update_mode_ui()
	_update_stereo_shader()

## Starts the host audio stream and binds it to the AudioStreamPlayer.
func _setup_audio():
	var audio_stream = moon.get_audio_stream()
	if audio_stream:
		audio_player.stream = audio_stream
		audio_player.play()
		print("Audio Stream Started")

## Maps SubViewport textures to their respective 3D panels.
func _bind_texture():
	var stream_tex = stream_viewport.get_texture()
	screen_mesh.material_override.set_shader_parameter("main_texture", stream_tex)
	detection_target.texture = stream_tex # Feed detection engine
	
	var ui_tex = ui_viewport.get_texture()
	ui_panel_3d.material_override.albedo_texture = ui_tex

func _process(delta):
	# Handle Mode Switching (Tab Key Cycle)
	if Input.is_action_just_pressed("ui_focus_next"):
		match current_mode:
			AppMode.UI:
				_switch_mode(AppMode.ENV)
			AppMode.ENV:
				if is_streaming:
					_switch_mode(AppMode.STREAM)
				else:
					_switch_mode(AppMode.UI)
			AppMode.STREAM:
				_switch_mode(AppMode.UI)
	
	# Release Shortcut: Shift + F1 (Panic Escape to UI)
	if Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_F1):
		if current_mode != AppMode.UI:
			_switch_mode(AppMode.UI)

	# Mode-Specific Logic
	match current_mode:
		AppMode.UI:
			_handle_ui_interaction()
		AppMode.ENV:
			_handle_env_movement(delta)

	# Auto-Detection Logic
	if is_streaming and auto_detect_enabled:
		auto_detect_timer += delta
		if auto_detect_timer >= 0.3:
			auto_detect_timer = 0.0
			_run_auto_detection()

## Handles mode transitions, mouse capture, and UI updates.
func _switch_mode(new_mode: AppMode):
	current_mode = new_mode
	_update_mode_ui()
	if not is_xr_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if (current_mode != AppMode.UI) else Input.MOUSE_MODE_VISIBLE
	print("Switched to Mode: ", AppMode.keys()[current_mode])

func _update_mode_ui():
	%ModeLabel.text = "Mode: " + AppMode.keys()[current_mode]
	%Crosshair.visible = (current_mode == AppMode.UI and not is_xr_active)
	%Laser.visible = (current_mode == AppMode.UI and is_xr_active)
	%ResumeAutoButton.visible = !auto_detect_enabled
	if current_mode != AppMode.UI:
		hit_dot.position = Vector2(-20, -20)

## Simulates mouse interaction on the 3D menu panel using RayCasting.
func _handle_ui_interaction():
	var active_raycast = hand_raycast if is_xr_active else mouse_raycast
	if active_raycast.is_colliding():
		var collider = active_raycast.get_collider()
		if collider.get_parent() == ui_panel_3d:
			var hit_pos = active_raycast.get_collision_point()
			var local_pos = ui_panel_3d.to_local(hit_pos)
			
			# Map 3D coordinate to Viewport Pixel coordinate
			var pixel_x = (local_pos.x + 0.5) * 500
			var pixel_y = (0.3 - local_pos.y) * (300 / 0.6)
			var pixel_pos = Vector2(pixel_x, pixel_y)
			
			hit_dot.position = pixel_pos - (hit_dot.size / 2.0)
			
			var is_now_clicking = right_hand.get_float("trigger") > 0.5 if is_xr_active else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			hit_dot.color = Color(1, 0, 0) if is_now_clicking else Color(0, 1, 0)
			
			# Send Motion for hover highlights
			var motion = InputEventMouseMotion.new()
			motion.position = pixel_pos
			motion.global_position = pixel_pos
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT if is_now_clicking else 0
			ui_viewport.push_input(motion)
			
			# Handle Button Transitions
			if is_now_clicking and not was_clicking:
				_push_click(pixel_pos, true)
				was_clicking = true
			elif not is_now_clicking and was_clicking:
				_push_click(pixel_pos, false)
				was_clicking = false
			return
	if was_clicking:
		_push_click(hit_dot.position + (hit_dot.size/2.0), false)
		was_clicking = false
	hit_dot.position = Vector2(-20, -20)

func _push_click(pos: Vector2, pressed: bool):
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	ui_viewport.push_input(event)

func _on_controller_button_pressed(button_name: String):
	match button_name:
		"by_button": _switch_mode(AppMode.UI)
		"ax_button": _switch_mode(AppMode.ENV)
		"trigger_click":
			if current_mode != AppMode.UI and current_mode != AppMode.STREAM:
				_switch_mode(AppMode.STREAM)

## Standard FPS movement for positioning the camera in the virtual room.
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
	# 1. Forward Gamepad and Stream Input
	if is_streaming:
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			_forward_gamepad_input(event)
			return
		
		if current_mode == AppMode.STREAM:
			if event is InputEventMouseMotion:
				moon.send_mouse_move_event(event.relative.x, event.relative.y)
			elif event is InputEventMouseButton:
				moon.send_mouse_button_event(1 if event.pressed else 2, event.button_index)
			elif event is InputEventKey:
				if not (event.keycode == KEY_F1 and Input.is_key_pressed(KEY_SHIFT)):
					moon.send_keyboard_event(event.keycode, 1 if event.pressed else 2, 0)
	
	# 2. Camera Rotation (Mouse Look) in UI/ENV modes
	if current_mode != AppMode.STREAM and not is_xr_active:
		if event is InputEventMouseMotion:
			xr_origin.rotate_y(-event.relative.x * mouse_sensitivity)
			xr_camera.rotate_x(-event.relative.y * mouse_sensitivity)
			xr_camera.rotation.x = clamp(xr_camera.rotation.x, -PI/2, PI/2)

func _forward_gamepad_input(event):
	# The Moonlight GDExtension handle_input natively supports Joypad events
	if moon.has_method("handle_input"):
		moon.handle_input(event)

func _on_pair_pressed():
	var ip = %IPInput.text
	if ip.is_empty(): ip = "127.0.0.1"
	config_mgr.load_config()
	var paired_host_id = -1
	for h in config_mgr.get_hosts():
		if h.has("localaddress") and h.localaddress == ip:
			paired_host_id = h.id
			break
	if paired_host_id != -1:
		start_stream(paired_host_id, 881448767)
		_switch_mode(AppMode.STREAM)
	else:
		var pin = comp_mgr.start_pair(ip, 47989)
		print("PIN: ", pin)

func _on_pair_completed(success: bool, _msg: String):
	if success:
		config_mgr.load_config()
		var ip = %IPInput.text
		for h in config_mgr.get_hosts():
			if h.localaddress == ip:
				start_stream(h.id, 881448767)
				_switch_mode(AppMode.STREAM)
				break

## Initiates a 4K Performance Stream with 50Mbps bitrate.
func start_stream(host_id: int, app_id: int):
	print("Starting 4K Performance Stream (3840x2160, 50Mbps)...")
	stream_cfg = MoonlightStreamConfigurationResource.new()
	stream_cfg.set_width(3840)
	stream_cfg.set_height(2160)
	stream_cfg.set_fps(60)
	stream_cfg.set_bitrate(50000)
	
	stream_opts = MoonlightAdditionalStreamOptions.new()
	stream_opts.set_disable_hw_acceleration(false)
	stream_opts.set_disable_audio(false)
	stream_opts.set_disable_video(false)
	
	moon.set_render_target(stream_target)
	moon.start_play_stream(host_id, app_id, stream_cfg, stream_opts)
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

## Analyzes a 64x32 downsampled frame to determine stream format.
func _run_auto_detection():
	var img = detection_viewport.get_texture().get_image()
	if !img or img.get_width() < 64: return
	
	# 1. Check for SBS (Correlation between halves)
	var total_diff = 0.0
	for y in range(8, 24): # Sample middle rows to avoid taskbars
		for x in range(0, 32):
			var left_pixel = img.get_pixel(x, y).v
			var right_pixel = img.get_pixel(x + 32, y).v
			total_diff += abs(left_pixel - right_pixel)
	
	var avg_diff = total_diff / (16 * 32)
	var detected_mode = 0
	
	if avg_diff < 0.12: # Threshold for "mostly identical"
		# 2. Check for Crop (Black bars at top/bottom)
		var top_brightness = 0.0
		var center_brightness = 0.0
		for x in range(0, 64):
			top_brightness += img.get_pixel(x, 2).v
			center_brightness += img.get_pixel(x, 16).v
		
		# If edges are significantly darker than the center
		if top_brightness < (center_brightness * 0.3):
			detected_mode = 2 # Crop
		else:
			detected_mode = 1 # Stretch
	else:
		detected_mode = 0 # 2D
		
	# 3. Hysteresis (Filter out flickering)
	detection_history.append(detected_mode)
	if detection_history.size() > 5:
		detection_history.pop_front()
		
	# Only switch if all last 5 checks agree
	var all_match = true
	for val in detection_history:
		if val != detected_mode:
			all_match = false
			break
			
	if all_match and detection_history.size() >= 5 and detected_mode != stereo_mode:
		print("Auto-Detected Change: ", detected_mode)
		stereo_mode = detected_mode
		_update_stereo_shader()
