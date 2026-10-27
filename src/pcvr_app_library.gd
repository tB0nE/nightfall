extends VBoxContainer
## Reuses the existing settings viewport: no additional OpenXR layer.
var controller
var control
var offset := 0
var total := 0
var _status: Label
var _grid: GridContainer
var _page: Label
var _icons: Dictionary = {}
var _textures: Dictionary = {}
var _cards: Array = []
var _launch_pending := false

func setup(ui) -> void:
	controller = ui
	add_theme_constant_override("separation", 12)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	add_child(header)
	var back: Button = ui.make_action_btn("Back")
	back.pressed.connect(ui.close_vr_apps)
	header.add_child(back)
	var title := Label.new()
	title.text = "VR Apps"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	header.add_child(title)
	var refresh: Button = ui.make_action_btn("Refresh")
	refresh.pressed.connect(refresh_apps)
	header.add_child(refresh)
	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_grid)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	add_child(footer)
	var previous: Button = ui.make_action_btn("Previous")
	previous.pressed.connect(func(): offset = maxi(0, offset - 4); refresh_apps())
	footer.add_child(previous)
	_page = Label.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_child(_page)
	var next: Button = ui.make_action_btn("Next")
	next.pressed.connect(func():
		if offset + 4 < total: offset += 4; refresh_apps())
	footer.add_child(next)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 20)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.y = 46
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)

func open_library() -> void:
	var active = controller.main.welcome_screen.get_xr_control()
	if control != active:
		if control != null and control.library_reply.is_connected(_reply): control.library_reply.disconnect(_reply)
		control = active
		control.library_reply.connect(_reply)
	refresh_apps()

func refresh_apps() -> void:
	_launch_pending = false
	_status.text = "Loading installed VR apps…"
	if control == null or not control.request_library("list", "", offset):
		_status.text = "Update Meteor to use VR Apps." if control != null and control.state in ["watching", "prepared"] else "Connect to your Meteor desktop to browse VR apps."

func _reply(value: Dictionary) -> void:
	if not visible: return
	if value.has("error"):
		_launch_pending = false
		for button in _grid.get_children(): button.disabled = false
		_status.text = str(value.error)
		return
	match str(value.get("action", "")):
		"list":
			if int(value.get("offset", -1)) != offset: return
			_cards = value.get("apps", [])
			offset = int(value.get("offset", 0))
			total = int(value.get("total", 0))
			for node in _grid.get_children(): _grid.remove_child(node); node.queue_free()
			_icons.clear()
			for card in _cards:
				if card is Dictionary and card.has_all(["key", "name", "source", "vr", "ready"]): _add_card(card)
			_page.text = "%d–%d of %d" % [mini(offset + 1, total), mini(offset + 4, total), total]
			_status.text = "Choose an app to launch." if total > 0 else "No installed Steam VR apps found."
		"art":
			var key := str(value.get("key", ""))
			var encoded := str(value.get("image", ""))
			if encoded.is_empty() or encoded.length() > 2400: return
			var image := Image.new()
			if image.load_webp_from_buffer(Marshalls.base64_to_raw(encoded)) == OK:
				var texture := ImageTexture.create_from_image(image)
				_textures[key] = texture
				_apply_icon(key, texture)
		"launch": _status.text = str(value.get("message", "Starting app…"))

func _apply_icon(key: String, texture: Texture2D) -> void:
	if not _icons.has(key) or not is_instance_valid(_icons[key]): return
	var slot: PanelContainer = _icons[key]
	for child in slot.get_children(): slot.remove_child(child); child.queue_free()
	var image := TextureRect.new()
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; void fragment(){vec4 c=texture(TEXTURE,UV);vec2 p=abs(UV-vec2(0.5))-vec2(0.42);float d=length(max(p,vec2(0.0)))-0.08;COLOR=c;COLOR.a*=1.0-smoothstep(-0.005,0.005,d);}"
	var material := ShaderMaterial.new()
	material.shader = shader
	image.material = material
	slot.add_child(image)

func _add_card(card: Dictionary) -> void:
	var button: Button = controller.make_action_btn("")
	button.custom_minimum_size = Vector2(176, 210)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(button)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 8; column.offset_right = -8; column.offset_top = 8; column.offset_bottom = -8
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(column)
	var icon := PanelContainer.new()
	icon.custom_minimum_size = Vector2(112, 112)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.12, 0.2, 0.3, 1)
	background.set_corner_radius_all(12)
	icon.add_theme_stylebox_override("panel", background)
	column.add_child(icon)
	var initial := Label.new()
	initial.text = str(card.name).left(1).to_upper()
	initial.add_theme_font_size_override("font_size", 48)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(initial)
	var name_label := Label.new()
	name_label.text = str(card.name)
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.max_lines_visible = 2
	name_label.custom_minimum_size.y = 48
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(name_label)
	var source := Label.new()
	source.text = str(card.source) + (" · Needs setup" if not card.ready else "")
	source.add_theme_font_size_override("font_size", 16)
	source.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	source.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(source)
	var key := str(card.key)
	_icons[key] = icon
	if _textures.has(key): _apply_icon(key, _textures[key])
	else: control.request_library("art", key)
	button.pressed.connect(func():
		if _launch_pending: return
		if control.state == "prepared": _status.text = "Exit the current XR game before launching another app."
		elif not card.ready: _status.text = "Add Meteor launch options in this game’s Steam properties first."
		else:
			_launch_pending = true
			for tile in _grid.get_children(): tile.disabled = true
			_status.text = "Starting " + str(card.name) + "…"
			control.request_library("launch", key))
