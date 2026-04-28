extends Node3D

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
@onready var world_env = $WorldEnvironment

var current_host_id: int = -1
var is_streaming: bool = false
var stereo_mode: int = 0
var is_xr_active: bool = false
var was_clicking: bool = false
var mouse_captured_by_stream: bool = false
var suppress_input_frames: int = 0
var auto_detect_enabled: bool = false
var auto_detect_timer: float = 0.0
var auto_detect_running: bool = false
var detection_history: Array = []
var mouse_sensitivity: float = 0.002
var grabbed_node: Node3D = null
var grab_distance: float = 0.0
var grab_offset: Vector3 = Vector3.ZERO
var grabbed_bar: MeshInstance3D = null
var stats_timer: float = 0.0
var stats_fps: float = 0.0
var stats_frame_times: Array = []
var stats_network_events: int = 0
var passthrough_enabled: bool = false
var stream_fps: int = 60
var host_resolution: Vector2i = Vector2i(1920, 1080)

var stream_manager: StreamManager
var xr_interaction: XRInteraction
var input_handler: InputHandler
var ui_controller: UIController
var auto_detect: AutoDetect

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
	_log("=== Nightfall started ===")
	Engine.max_fps = 60

	stream_manager = StreamManager.new(self)
	xr_interaction = XRInteraction.new(self)
	input_handler = InputHandler.new(self)
	ui_controller = UIController.new(self)
	auto_detect = AutoDetect.new(self)

	%ScreenGrabBar.material_override = %ScreenGrabBar.material_override.duplicate()
	%MenuGrabBar.material_override = %MenuGrabBar.material_override.duplicate()

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	%PairButton.button_down.connect(func(): stream_manager.on_pair_pressed())
	%SBSToggle.button_down.connect(func(): ui_controller.on_sbs_toggled())
	%ResumeAutoButton.button_down.connect(func(): ui_controller.on_resume_auto_pressed())
	%ExitButton.pressed.connect(func(): get_tree().quit())
	%PassthroughButton.button_down.connect(func(): _toggle_passthrough())
	%FPSButton.button_down.connect(func(): _cycle_fps())
	%IPInput.gui_input.connect(func(e): ui_controller.on_ipinput_gui_input(e))
	ui_controller.setup_numpad()

	comp_mgr.set_config_manager(config_mgr)
	moon.set_config_manager(config_mgr)
	comp_mgr.pair_completed.connect(func(s, m): stream_manager.on_pair_completed(s, m))
	moon.log_message.connect(func(msg):
		if "dropped" in msg or "Unrecoverable" in msg or "Waiting for IDR" in msg:
			stats_network_events += 1
	)

	moon.connection_started.connect(func():
		is_streaming = true
		%StatusLabel.text = "Connecting..."
		_log("[STREAM] Connection started!")
		stream_manager.bind_texture()
		stream_manager.setup_audio()
	)
	moon.connection_terminated.connect(func(_err, msg):
		is_streaming = false
		%StatusLabel.text = "Disconnected: " + str(msg)
		_log("[STREAM] Connection terminated: %s" % str(msg))
		if mouse_captured_by_stream:
			input_handler.release_stream_mouse()
		audio_player.stop()
	)

	var interface = XRServer.find_interface("OpenXR")
	if interface and interface.is_initialized():
		var render_size = interface.get_render_target_size()
		_log("[XR] OpenXR render target: %dx%d" % [render_size.x, render_size.y])
		get_viewport().size = render_size
		get_viewport().use_xr = true
		is_xr_active = true
		stereo_mode = 1
		await get_tree().create_timer(0.5).timeout
		var cam_pos = xr_camera.global_position
		var cam_fwd = -xr_camera.global_transform.basis.z
		var cam_right = xr_camera.global_transform.basis.x
		screen_mesh.global_position = cam_pos + cam_fwd * 2.0
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
		_toggle_passthrough()
	else:
		is_xr_active = false
		stereo_mode = 0

	var save = ConfigFile.new()
	if save.load("user://last_connection.cfg") == OK:
		var saved_ip = save.get_value("connection", "ip", "")
		if saved_ip != "":
			%IPInput.text = saved_ip

	stream_manager.bind_texture()
	ui_controller.update_ui()
	ui_controller.update_stereo_shader()

	Input.joy_connection_changed.connect(func(device, connected):
		print("[GAMEPAD] Device %d %s: %s" % [device, "connected" if connected else "disconnected", Input.get_joy_name(device)])
	)
	for pad in Input.get_connected_joypads():
		print("[GAMEPAD] Found device %d: %s" % [pad, Input.get_joy_name(pad)])

func _process(delta):
	if Input.is_action_just_pressed("ui_focus_next"):
		if mouse_captured_by_stream:
			input_handler.release_stream_mouse()

	if Input.is_key_pressed(KEY_CTRL) and Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT):
		if mouse_captured_by_stream:
			input_handler.release_stream_mouse()

	if not mouse_captured_by_stream:
		xr_interaction.handle_pointer_interaction()

	auto_detect.process(delta)

	if is_streaming:
		stats_frame_times.append(delta)
		stats_timer += delta
		if stats_timer >= 0.5:
			var avg = 0.0
			for t in stats_frame_times:
				avg += t
			if stats_frame_times.size() > 0:
				avg /= stats_frame_times.size()
			stats_fps = 1.0 / avg if avg > 0 else 0.0
			stream_manager.update_stats()
			stats_timer = 0.0
			stats_frame_times.clear()

	if grabbed_node:
		xr_interaction.handle_grab()

func _input(event):
	input_handler.handle_input(event)

func _toggle_passthrough():
	if not is_xr_active:
		return
	var interface = XRServer.find_interface("OpenXR")
	if not interface:
		return
	if passthrough_enabled:
		interface.stop_passthrough()
		world_env.environment.background_mode = Environment.BG_MODE_COLOR
		world_env.environment.background_color = Color(0, 0, 0, 1)
		passthrough_enabled = false
		%PassthroughButton.text = "Passthrough: Off"
	else:
		if interface.start_passthrough():
			world_env.environment.background_mode = Environment.BG_MODE_KEEP
			passthrough_enabled = true
			%PassthroughButton.text = "Passthrough: On"

func _cycle_fps():
	var rates = [60, 90, 120]
	var idx = rates.find(stream_fps)
	stream_fps = rates[(idx + 1) % rates.size()]
	%FPSButton.text = "Refresh: %dHz" % stream_fps
