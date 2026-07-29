class_name DepthEstimatorModule
extends RefCounted

var main: Node3D
var depth_viewport: SubViewport
var depth_target: TextureRect
var depth_texture: ImageTexture
var enabled: bool = false
var submit_timer: float = 0.0
var submit_interval: float = 0.1
var model_size: int = 256
var _poll_timer: float = 0.0

var _platform: String

func _init(owner: Node3D):
	main = owner
	_platform = OS.get_name()

func setup():
	if _platform != "Android":
		main._log("[DEPTH] Depth estimation disabled on " + _platform)
		return
	depth_viewport = SubViewport.new()
	depth_viewport.name = "DepthViewport"
	depth_viewport.size = Vector2i(model_size, model_size)
	depth_viewport.disable_3d = true
	depth_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	depth_viewport.transparent_bg = true

	depth_target = TextureRect.new()
	depth_target.name = "DepthTarget"
	depth_target.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	depth_target.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	depth_target.size = Vector2i(model_size, model_size)
	depth_target.set_anchors_preset(Control.PRESET_FULL_RECT)
	depth_viewport.add_child(depth_target)
	main.add_child(depth_viewport)

	var img = Image.create(model_size, model_size, false, Image.FORMAT_L8)
	depth_texture = ImageTexture.create_from_image(img)
	if main.primary_screen and main.primary_screen.material_override is ShaderMaterial:
		main.primary_screen.material_override.set_shader_parameter("depth_texture", depth_texture)
	if main.comp_shader_mat_left:
		main.comp_shader_mat_left.set_shader_parameter("depth_texture", depth_texture)
	if main.comp_shader_mat_right:
		main.comp_shader_mat_right.set_shader_parameter("depth_texture", depth_texture)

func bind_stream_texture():
	if not depth_target:
		return
	if main.comp.in_use and main.primary_screen and main.primary_screen.comp_viewport:
		depth_target.texture = main.primary_screen.comp_viewport.get_texture()
	elif main.stream_viewport:
		depth_target.texture = main.stream_viewport.get_texture()

func set_enabled(val: bool):
	enabled = val
	if depth_viewport:
		depth_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if val else SubViewport.UPDATE_DISABLED

func process(delta: float):
	if not enabled or not main.is_streaming:
		return

	if main.stream_backend.has_method("submit_depth_frame"):
		submit_timer += delta
		if submit_timer >= submit_interval:
			submit_timer = 0.0
			var img = depth_viewport.get_texture().get_image()
			if img != null and not img.is_empty():
				var data = img.get_data()
				if data.size() > 0:
					main.stream_backend.submit_depth_frame(data, model_size, model_size)

	if main.stream_backend.has_method("get_depth_map"):
		_poll_timer += delta
		if _poll_timer >= submit_interval:
			_poll_timer = 0.0
			var depth_bytes = main.stream_backend.get_depth_map()
			if depth_bytes != null and depth_bytes.size() == model_size * model_size:
				var depth_image = Image.create_from_data(model_size, model_size, false, Image.FORMAT_L8, depth_bytes)
				depth_texture.update(depth_image)
