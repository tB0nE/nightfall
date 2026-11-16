extends ContentProvider

const RESOLUTIONS := [Vector2i(1920, 1080), Vector2i(2560, 1440)]
var render_size := Vector2i(1920, 1080)
var reported_render_size := Vector2i.ZERO

# Dedicated uploader retained for the app lifetime: never reuse the decoder's
# surface, and never destroy it while Android's producer still owns a reference.
var main: Node3D
var screen: VRScreen
var browser_id := 0
var _held_android_keys: Dictionary = {}
var uploader: RefCounted
var active := false
var suspended := false
var closing := false
var texture: Texture2D
var _opening_at := 0
var _pressed := false
var _position := Vector2.ZERO
var _modifiers := 0
var new_frame := false
var pages: Array = []
var selected_page := 0
var _pages_poll_at := 0
var _pages_snapshot := ""
var navigation: Dictionary = {}
var _edit_sequence := 0
var _returning_primary := false
# Browser-local choices must not overwrite a PC host's Meteor/model settings.
var depth_model_override := SettingsController.ANDROID_MODEL_AUTO
var depth_backend_override := SettingsController.AI3D_BACKEND_GPU
var depth_gpu_api_override := 0

func navigation_action(action: String) -> void:
	if not active or closing: return
	cancel_pointer()
	clear_gamepad()
	var bridge := _gamepad_bridge()
	if bridge: bridge.browserNavigationActionFor(browser_id, action)
	if action == "address" and main.virtual_keyboard and not main.virtual_keyboard.visible:
		main.virtual_keyboard.toggle()
	_pages_poll_at = 0

func tab_action(action: String, id: int = 0) -> void:
	if not active or closing:
		return
	cancel_pointer()
	clear_gamepad()
	var bridge := _gamepad_bridge()
	if bridge:
		bridge.browserTabActionFor(browser_id, action, id)
	_pages_poll_at = 0

func _poll_pages(force: bool = false) -> void:
	if not force and main.screen_sources.get("moving_tab") == true: return
	var now := Time.get_ticks_msec()
	if now < _pages_poll_at:
		return
	_pages_poll_at = now + 200
	var bridge := _gamepad_bridge()
	if not bridge:
		return
	var snapshot := str(bridge.browserTabsFor(browser_id))
	if snapshot == _pages_snapshot:
		return
	var data = JSON.parse_string(snapshot)
	if not data is Dictionary or not data.get("pages") is Array:
		return
	_pages_snapshot = snapshot
	pages = data.pages
	reported_render_size = Vector2i(int(data.get("width", 0)), int(data.get("height", 0)))
	selected_page = int(data.get("selected", 0))
	navigation = data.get("navigation", {})
	main.screen_sources.sync_browser_pages(pages, selected_page, screen)
	var sequence := int(navigation.get("editSequence", 0))
	if sequence != _edit_sequence:
		_edit_sequence = sequence
		var operation := str(navigation.get("editAction", ""))
		if operation != "" and int(navigation.get("editPage", -1)) == selected_page and main.screen_sources.focused_browser() == self:
			if operation == "select_all": _edit_raw(operation)
			else: main.clipboard_sharing.perform(operation, _edit_raw.bind(operation))
var _gamepad_java: Object
var _gamepad_sent := false
var _gamepad_input_enabled := true

func _gamepad_bridge() -> Object:
	if _gamepad_java == null and OS.get_name() == "Android":
		var wrapper: Object = Engine.get_singleton("JavaClassWrapper")
		if wrapper:
			_gamepad_java = wrapper.wrap("com.godot.game.GodotApp")
	return _gamepad_java

func gamepad_state(buttons: int, lt: int, rt: int, lx: int, ly: int, rx: int, ry: int) -> void:
	var bridge := _gamepad_bridge()
	if active and bridge:
		bridge.browserGamepadFor(browser_id, buttons, lt, rt, lx, ly, rx, ry)
		_gamepad_sent = true

func clear_gamepad() -> void:
	if _gamepad_sent:
		var bridge := _gamepad_bridge()
		if bridge:
			bridge.browserClearGamepadFor(browser_id)
		_gamepad_sent = false

func _init(owner: Node3D, target: VRScreen = null, id: int = 0):
	main = owner
	screen = target
	browser_id = id

func release_keys() -> void:
	if uploader:
		for code in _held_android_keys: uploader.browser_key(code, false, 0)
	_held_android_keys.clear()
	_modifiers = 0

func can_infer_depth() -> bool:
	return self == main.browser_prototype and active and texture != null and activity == Activity.VISIBLE

func desired_render_size() -> Vector2i:
	var fallback: Vector2i = RESOLUTIONS[clampi(main.settings.browser_resolution, 0, 1)]
	var tab: ScreenContentTab = screen.content_tabs.selected() if screen != null else null
	if tab != null and tab.kind == ScreenContentTab.BROWSER:
		var requested := tab.effective_resolution(fallback)
		if requested in RESOLUTIONS: return requested
	return fallback

func start() -> void:
	if activity == Activity.CLOSED or active or closing:
		return
	if self == main.browser_prototype and not main.screen_sources.can_open_browser():
		return
	if suspended:
		resume_from_tab()
		return
	if not main.screen_sources.allocate_primary_browser_slot(self): return
	if not uploader:
		uploader = ClassDB.instantiate("TextureUploader")
	uploader.set_browser_id(browser_id)
	if self == main.browser_prototype or screen == null: screen = main.primary_screen
	main.screen_sources.register_browser(screen, self)
	active = true
	_pages_snapshot = ""
	_pages_poll_at = 0
	_gamepad_input_enabled = true
	generation += 1
	set_activity(Activity.VISIBLE)
	_opening_at = Time.get_ticks_msec()
	render_size = desired_render_size()
	uploader.start_browser_prototype(render_size.x, render_size.y)
	main.screen_sources.browser_opened(self)
	main.screen_sources.focus_browser(self)
	main._log("[BROWSER] Opening GPU surface prototype")

func stop(close_workspace: bool = false, restore_monitor: bool = false) -> void:
	if (not active and not suspended) or _returning_primary:
		return
	if self == main.browser_prototype and main.screen_sources.has_method("stream_screen"):
		var welcome: VRScreen = main.screen_sources.stream_screen()
		if welcome != null and welcome != screen:
			_return_to_welcome_then_stop(welcome)
			return
	cancel_pointer()
	clear_gamepad()
	release_keys()
	closing = true
	if self == main.browser_prototype:
		if close_workspace and main.screen_sources.has_method("stop_secondary_browsers"):
			main.screen_sources.stop_secondary_browsers()
		main.depth_estimator.set_enabled(false)
		# Retire the native consumer before closing its SurfaceTexture producer.
		main.video_presentation.deactivate_native(false)
	elif screen != null:
		for layer in [screen.comp_cylinder, screen.comp_cylinder_left, screen.comp_cylinder_right,
			screen.comp_grab_bar, screen.comp_corner_layer]:
			if layer: layer.visible = false
	uploader.close_browser_prototype()
	active = false
	suspended = false
	pages = []
	selected_page = 0
	navigation = {}
	generation += 1
	set_activity(Activity.SUSPENDED)
	texture = null
	_modifiers = 0
	if self == main.browser_prototype:
		bind_texture()
		main.screen_sources.browser_closed()
		_restore_welcome_after_close(generation, restore_monitor and not close_workspace)
	else:
		_remove_secondary_after_close(generation)
	main._log("[BROWSER] Closed id=%d; %s" % [browser_id,
		"draining before welcome restore" if self == main.browser_prototype else "retiring secondary screen only"])

func suspend_for_tab() -> bool:
	if not active or closing: return false
	var bridge := _gamepad_bridge()
	# JavaClass resolves static Java methods dynamically; has_method() does not
	# enumerate them (including the working navigation and tab APIs).
	if bridge == null: return false
	cancel_pointer()
	clear_gamepad()
	release_keys()
	bridge.browserContentVisibleFor(browser_id, false)
	active = false
	suspended = true
	# The producer/surface stays allocated. Keep its last image so resuming a
	# static page does not depend on Android immediately emitting a new frame.
	new_frame = false
	generation += 1
	set_activity(Activity.SUSPENDED)
	return true

func resume_from_tab() -> bool:
	if not suspended or closing: return false
	var bridge := _gamepad_bridge()
	if bridge == null: return false
	bridge.browserContentVisibleFor(browser_id, true)
	suspended = false
	active = true
	_opening_at = Time.get_ticks_msec()
	_pages_snapshot = ""
	_pages_poll_at = 0
	generation += 1
	set_activity(Activity.VISIBLE)
	main.screen_sources.focus_browser(self)
	if texture != null: bind_texture()
	return true

func _return_to_welcome_then_stop(welcome: VRScreen) -> void:
	_returning_primary = true
	var restored: bool = await main.screen_sources.make_primary(welcome)
	_returning_primary = false
	if restored: stop()

func _remove_secondary_after_close(token: int) -> void:
	for _frame in range(3): await main.get_tree().process_frame
	if generation != token: return
	closing = false
	if is_instance_valid(screen) and main.screen_sources.secondary_browser_closed(screen): return
	if is_instance_valid(screen): main.screen_sources.remove_browser_screen(screen)

func _restore_welcome_after_close(token: int, restore_monitor: bool = false) -> void:
	# Do not reacquire the legacy composition swapchain in the same XR frame
	# that removed the native browser layers. Also keep inactive depth textures
	# untouched until the next real inference session.
	for _frame in range(3):
		await main.get_tree().process_frame
	if generation != token:
		return
	closing = false
	if restore_monitor and main.screen_sources.has_method("restore_stream_after_browser_close"):
		if await main.screen_sources.restore_stream_after_browser_close(screen): return
		if generation != token: return
	if not main.primary_media_active() and main.session_lifecycle.phase in [
		SessionLifecycle.Phase.BOOT, SessionLifecycle.Phase.SERVER_SELECTION,
		SessionLifecycle.Phase.FAILED]:
		main.settings_controller.apply_stereo()
	main.screen_sources.changed.emit()

func close() -> void:
	stop()
	super.close()

func process() -> void:
	new_frame = false
	if not active:
		return
	_poll_pages()
	if desired_render_size() != render_size and main.screen_sources.can_edit_browser_tab_resolution(screen):
		main.screen_sources.resize_browser_tab(screen, desired_render_size())
	var input_enabled: bool = not main.ui_visible and not main.virtual_keyboard.visible and not main.screen_sources.switching_tab
	if input_enabled != _gamepad_input_enabled:
		_gamepad_input_enabled = input_enabled
		var bridge := _gamepad_bridge()
		if bridge:
			bridge.browserInputEnabledFor(browser_id, input_enabled)
	var state: int = uploader.poll_browser_prototype()
	if state < 0 or (state == 0 and Time.get_ticks_msec() - _opening_at > 1000):
		stop(false, true)
		return
	if not texture and Time.get_ticks_msec() - _opening_at > 15000:
		main._log("[BROWSER] Timed out waiting for GPU frame")
		stop(false, true)
		return
	if uploader.consume_new_frame():
		new_frame = true
		if not texture:
			texture = uploader.get_shader_material().get_shader_parameter("tex_y")
			bind_texture()
			if self == main.browser_prototype:
				main.settings_controller.apply_stereo()
			if main.screen_sources.focused_browser() == self:
				var bridge := _gamepad_bridge()
				if bridge: bridge.browserFocus(browser_id)
			main._log("[BROWSER] First GPU frame ready")
		frame_available.emit(generation)

func bind_texture() -> void:
	if self != main.browser_prototype:
		if screen == null: return
		for mat in [screen.comp_shader_mat, screen.comp_shader_mat_left, screen.comp_shader_mat_right, screen.material_override]:
			if mat is ShaderMaterial:
				mat.set_shader_parameter("main_texture", texture)
				mat.set_shader_parameter("yuv_mode", 0)
				mat.set_shader_parameter("stereo_mode", 0)
				mat.set_shader_parameter("uv_region", Vector4(0, 0, 1, 1))
		if screen.comp_viewport:
			screen.comp_base_size = render_size
			main.comp.update_bezel()
			screen.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		if screen.comp_cylinder: screen.comp_cylinder.visible = true
		main.comp.update_cylinder_params()
		return
	var current: Texture2D = main.get_welcome_content_texture()
	if active and screen != null:
		screen.uv_region = Vector4(0, 0, 1, 1)
		screen.resize_to_aspect(render_size.x, render_size.y)
	for mat in [main.comp_shader_mat, main.comp_shader_mat_left, main.comp_shader_mat_right, main.screen_mesh.material_override]:
		if mat is ShaderMaterial:
			mat.set_shader_parameter("main_texture", current)
			mat.set_shader_parameter("yuv_mode", 0)
			if active: mat.set_shader_parameter("uv_region", Vector4(0, 0, 1, 1))

func pointer(uv: Vector2, pressed: bool) -> void:
	_position = uv.clamp(Vector2.ZERO, Vector2.ONE) * Vector2(render_size)
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

func scroll_high_res(amount: int, uv: Vector2) -> void:
	var bridge := _gamepad_bridge()
	if active and bridge:
		var pixel := uv.clamp(Vector2.ZERO, Vector2.ONE) * Vector2(render_size)
		bridge.browserScrollFor(browser_id, pixel.x, pixel.y, float(amount) / 120.0)

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
		if pressed: _held_android_keys[android_code] = true
		else: _held_android_keys.erase(android_code)

# Transfer owns screen removal/monitor restoration. Do not invoke normal close
# callbacks here: they would treat the move as a request to close the workspace.
func retire_after_transfer() -> void:
	cancel_pointer()
	clear_gamepad()
	release_keys()
	if uploader: uploader.close_browser_prototype()
	active = false
	suspended = false
	pages = []
	selected_page = 0
	texture = null
	navigation = {}
	_pages_snapshot = ""
	generation += 1
	set_activity(Activity.SUSPENDED)

func context_menu(uv: Vector2) -> void:
	if not active: return
	main.screen_sources.focus_browser(self)
	var pixel := uv.clamp(Vector2.ZERO, Vector2.ONE) * Vector2(render_size)
	var bridge := _gamepad_bridge()
	if bridge: bridge.browserNavigationActionFor(browser_id, "context:%f,%f" % [pixel.x, pixel.y])

func _edit_raw(operation: String) -> void:
	var bridge := _gamepad_bridge()
	if active and bridge: bridge.browserNavigationActionFor(browser_id, "edit:" + operation)

func physical_key(event: InputEventKey) -> void:
	_modifiers = (1 if event.shift_pressed else 0) | (4096 if event.ctrl_pressed else 0) | (2 if event.alt_pressed else 0) | (65536 if event.meta_pressed else 0)
	key(event.keycode, 3 if event.pressed else 4)
