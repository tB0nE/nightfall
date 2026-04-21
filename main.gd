extends Node3D

@onready var moon = $MoonlightStream
@onready var screen_mesh = $MeshInstance3D
@onready var config_mgr = MoonlightConfigManager.new()
@onready var comp_mgr = MoonlightComputerManager.new()
@onready var xr_origin = $XROrigin3D

# Keep references alive to prevent garbage collection
var stream_cfg: MoonlightStreamConfigurationResource
var stream_opts: MoonlightAdditionalStreamOptions

var current_host_id: int = -1
var is_streaming: bool = false
var sbs_enabled: bool = false
var mouse_captured: bool = false

func _ready():
	%PairButton.pressed.connect(_on_pair_pressed)
	%SBSToggle.pressed.connect(_on_sbs_toggled)
	
	comp_mgr.set_config_manager(config_mgr)
	moon.set_config_manager(config_mgr)
	
	comp_mgr.pair_completed.connect(_on_pair_completed)
	
	moon.connection_started.connect(func():
		is_streaming = true
		print("STREAM SUCCESS: Connected!")
		_bind_texture()
	)
	moon.connection_terminated.connect(func(err, msg):
		is_streaming = false
		mouse_captured = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		print("STREAM ERROR: ", err, " - ", msg)
	)
	moon.log_message.connect(func(msg): print("MOONLIGHT LOG: ", msg))
	
	_bind_texture()

	var interface = XRServer.find_interface("OpenXR")
	if interface and interface.is_initialized():
		get_viewport().use_xr = true
		$CanvasLayer.hide()
		sbs_enabled = true
		screen_mesh.material_override.set_shader_parameter("stereo_enabled", true)
		print("XR Mode: Stereo Split Enabled")
	else:
		sbs_enabled = false
		print("Running in Flat Mode - Stereo Split Disabled")
		screen_mesh.material_override.set_shader_parameter("stereo_enabled", false)

func _bind_texture():
	var viewport_tex = %SubViewport.get_texture()
	screen_mesh.material_override.set_shader_parameter("main_texture", viewport_tex)

func _process(delta):
	# Dual Navigation (WASD + Arrows)
	var move_speed = 3.0
	var rot_speed = 2.0
	
	var move_dir = 0
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		move_dir -= 1
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		move_dir += 1
		
	var rot_dir = 0
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		rot_dir += 1
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		rot_dir -= 1
		
	if move_dir != 0:
		xr_origin.global_translate(xr_origin.global_transform.basis.z * move_dir * move_speed * delta)
	if rot_dir != 0:
		xr_origin.rotate_y(rot_dir * rot_speed * delta)

func _input(event):
	# Mouse Capture Logic
	if event is InputEventMouseButton and event.pressed:
		if not mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true
			print("Mouse Captured - Controlling Host PC")
	
	# Mouse Release Logic (Shift + Escape)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE and Input.is_key_pressed(KEY_SHIFT):
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			mouse_captured = false
			print("Mouse Released - Controlling Godot UI")

	# Forward input to Moonlight ONLY when captured
	if is_streaming and mouse_captured:
		if moon.has_method("handle_input"):
			moon.handle_input(event)

func _on_pair_pressed():
	var ip = %IPInput.text
	if ip.is_empty():
		ip = "127.0.0.1"
		%IPInput.text = ip
	
	config_mgr.load_config()
	var paired_host_id = -1
	for h in config_mgr.get_hosts():
		if h.has("localaddress") and h.localaddress == ip:
			paired_host_id = h.id
			break
			
	if paired_host_id != -1:
		start_stream(paired_host_id, 881448767)
	else:
		print("Starting pair with: ", ip)
		var pin = comp_mgr.start_pair(ip, 47989)
		print("PIN: ", pin)

func _on_pair_completed(success: bool, _msg: String):
	if success:
		config_mgr.load_config()
		var ip = %IPInput.text
		for h in config_mgr.get_hosts():
			if h.localaddress == ip:
				var apps = config_mgr.get_apps(int(h.id))
				var desktop_app_id = -1
				for app in apps:
					if app.get("name", "").to_lower().find("desktop") != -1:
						desktop_app_id = int(app["id"])
				if desktop_app_id != -1:
					start_stream(int(h.id), desktop_app_id)
				break

func start_stream(host_id: int, app_id: int):
	print("Starting Performance Mode stream (1080p, HW Decode, Color)...")
	
	stream_cfg = MoonlightStreamConfigurationResource.new()
	stream_cfg.set_width(1920)
	stream_cfg.set_height(1080)
	stream_cfg.set_fps(60)
	stream_cfg.set_bitrate(20000)
	
	stream_opts = MoonlightAdditionalStreamOptions.new()
	stream_opts.set_disable_hw_acceleration(false)
	stream_opts.set_disable_audio(false)
	stream_opts.set_disable_video(false)
	stream_opts.set_verbose(true)
	
	moon.set_render_target(%StreamTarget)
	moon.start_play_stream(host_id, app_id, stream_cfg, stream_opts)
	_bind_texture()

func _on_sbs_toggled():
	sbs_enabled = !sbs_enabled
	screen_mesh.material_override.set_shader_parameter("stereo_enabled", sbs_enabled)
	
	if sbs_enabled:
		%SBSToggle.text = "Disable SBS Mode"
		print("SBS Mode Enabled")
	else:
		%SBSToggle.text = "Enable SBS Mode"
		print("SBS Mode Disabled (2D)")
