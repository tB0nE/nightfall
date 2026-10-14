extends RefCounted

# Dedicated uploader retained for the app lifetime: never reuse the decoder's
# surface, and never destroy it while Android's producer still owns a reference.
var main: Node3D
var uploader: RefCounted
var active := false
var texture: Texture2D
var _opening_at := 0
var _pressed := false
var _position := Vector2.ZERO
var _modifiers := 0

func _init(owner: Node3D):
	main = owner

func start() -> void:
	if active or main.is_streaming or not OS.has_feature("android"):
		return
	if not uploader:
		uploader = ClassDB.instantiate("TextureUploader")
	active = true
	_opening_at = Time.get_ticks_msec()
	uploader.start_browser_prototype()
	main._log("[BROWSER] Opening GPU surface prototype")

func stop() -> void:
	if not active:
		return
	cancel_pointer()
	uploader.close_browser_prototype()
	active = false
	texture = null
	_modifiers = 0
	bind_texture()
	main._log("[BROWSER] Closed; welcome screen restored")

func process() -> void:
	if not active:
		return
	var state: int = uploader.poll_browser_prototype()
	if state < 0 or (state == 0 and Time.get_ticks_msec() - _opening_at > 1000):
		stop()
		return
	if not texture and Time.get_ticks_msec() - _opening_at > 15000:
		main._log("[BROWSER] Timed out waiting for GPU frame")
		stop()
		return
	if uploader.consume_new_frame() and not texture:
		texture = uploader.get_shader_material().get_shader_parameter("tex_y")
		bind_texture()
		main._log("[BROWSER] First GPU frame ready")

func bind_texture() -> void:
	var current: Texture2D = main.get_welcome_content_texture()
	for mat in [main.comp_shader_mat, main.comp_shader_mat_left, main.comp_shader_mat_right, main.screen_mesh.material_override]:
		if mat is ShaderMaterial:
			mat.set_shader_parameter("main_texture", current)
			mat.set_shader_parameter("yuv_mode", 0)

func pointer(uv: Vector2, pressed: bool) -> void:
	_position = uv.clamp(Vector2.ZERO, Vector2.ONE) * Vector2(1920, 1080)
	var action := 2
	if pressed != _pressed:
		action = 0 if pressed else 1
	elif not pressed:
		action = 7
	uploader.browser_pointer(_position.x, _position.y, action)
	_pressed = pressed

func cancel_pointer() -> void:
	if _pressed and uploader:
		uploader.browser_pointer(_position.x, _position.y, 3)
	_pressed = false

func scroll(direction: int) -> void:
	var code := 93 if direction > 0 else 92
	uploader.browser_key(code, true, _modifiers)
	uploader.browser_key(code, false, _modifiers)

func key(code: int, action: int) -> void:
	var android_code := -1
	var pressed := action == 3
	var flag := 0
	match code:
		KEY_SHIFT:
			android_code = 59
			flag = 1
		KEY_CTRL:
			android_code = 113
			flag = 4096
		KEY_ALT:
			android_code = 57
			flag = 2
		KEY_CAPSLOCK: android_code = 115
		KEY_BACKSPACE: android_code = 67
		KEY_ENTER: android_code = 66
		KEY_TAB: android_code = 61
		KEY_ESCAPE: android_code = 111
		KEY_DELETE: android_code = 112
		KEY_INSERT: android_code = 124
		KEY_LEFT: android_code = 21
		KEY_RIGHT: android_code = 22
		KEY_UP: android_code = 19
		KEY_DOWN: android_code = 20
		KEY_HOME: android_code = 122
		KEY_END: android_code = 123
		KEY_PAGEUP: android_code = 92
		KEY_PAGEDOWN: android_code = 93
		KEY_SPACE: android_code = 62
		_:
			if code >= KEY_A and code <= KEY_Z:
				android_code = 29 + code - KEY_A
			elif code >= KEY_0 and code <= KEY_9:
				android_code = 7 + code - KEY_0
			elif code >= KEY_F1 and code <= KEY_F12:
				android_code = 131 + code - KEY_F1
			else:
				android_code = {KEY_MINUS: 69, KEY_EQUAL: 70, KEY_COMMA: 55, KEY_PERIOD: 56, KEY_SLASH: 76, KEY_BACKSLASH: 73, KEY_BRACKETLEFT: 71, KEY_BRACKETRIGHT: 72, KEY_SEMICOLON: 74, KEY_APOSTROPHE: 75, KEY_QUOTELEFT: 68}.get(code, -1)
	if flag:
		_modifiers = _modifiers | flag if pressed else _modifiers & ~flag
	if android_code >= 0:
		uploader.browser_key(android_code, pressed, _modifiers)
