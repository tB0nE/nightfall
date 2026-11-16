class_name AppPicker
extends RefCounted

## The welcome screen's app choice: the selected app's cover on the main page,
## a paged grid of the host's apps with their covers, and the last app used per
## host (by ID, falling back to its name, since a host can renumber its apps).
## Covers come from the host's /appasset (NightfallComputerManager.get_app_cover)
## and are fetched only for apps on screen, then cached for the session.

const COLUMNS := 6
const ROWS := 2
const PER_PAGE := COLUMNS * ROWS
const COVER_SIZE := Vector2(210, 280)
const TILE_SIZE := Vector2(230, 340)
const LAST_APP_FILE := "user://last_app.cfg"
const DEFAULT_APP_ID := 881448767

var main: Node3D
var welcome: RefCounted
var _covers := {}         # "host:app" -> Texture2D
var _requested := {}      # "host:app" -> true once asked for
var _tile_covers := {}    # app id -> TextureRect on the current page
var _page := 0
var _grid: GridContainer = null
var _page_label: Label = null
var _prev_btn: Button = null
var _next_btn: Button = null

func _init(owner: Node3D, welcome_screen: RefCounted) -> void:
	main = owner
	welcome = welcome_screen

## The "AppsScreen" page of the welcome UI.
func build(parent: Node) -> void:
	var screen := VBoxContainer.new()
	screen.name = "AppsScreen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_theme_constant_override("separation", 0)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	parent.add_child(screen)

	screen.add_child(_spacer(0, true))
	var heading := Label.new()
	heading.text = "Choose App"
	heading.add_theme_font_size_override("font_size", 48)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(heading)
	screen.add_child(_spacer(30))

	_grid = GridContainer.new()
	_grid.name = "AppGrid"
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 24)
	_grid.add_theme_constant_override("v_separation", 20)
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(_grid)
	screen.add_child(_spacer(0, true))

	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 24)
	nav.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	nav.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(nav)
	_prev_btn = _button("Previous", Vector2(220, 60))
	_page_label = Label.new()
	_page_label.add_theme_font_size_override("font_size", 26)
	_page_label.custom_minimum_size = Vector2(160, 60)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_page_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_next_btn = _button("Next", Vector2(220, 60))
	nav.add_child(_prev_btn)
	nav.add_child(_page_label)
	nav.add_child(_next_btn)
	screen.add_child(_spacer(16))
	var back_btn := _button("Back", Vector2(300, 60))
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(back_btn)
	screen.add_child(_spacer(40))

	_prev_btn.pressed.connect(func(): _show_page(_page - 1))
	_next_btn.pressed.connect(func(): _show_page(_page + 1))
	back_btn.pressed.connect(func(): welcome.show_welcome_screen("welcome"))

## Shows the page holding the selected app.
func open() -> void:
	_show_page(floori(float(main._selected_app_idx) / float(PER_PAGE)))

func _page_count() -> int:
	return maxi(1, ceili(float(main._available_apps.size()) / float(PER_PAGE)))

func _show_page(page: int) -> void:
	if _grid == null:
		return
	_page = clampi(page, 0, _page_count() - 1)
	for child in _grid.get_children():
		child.queue_free()
	_tile_covers.clear()
	var apps: Array = main._available_apps
	var start := _page * PER_PAGE
	for i in range(start, mini(start + PER_PAGE, apps.size())):
		_grid.add_child(_tile(i, apps[i]))
	_page_label.text = "%d / %d" % [_page + 1, _page_count()]
	_prev_btn.disabled = _page == 0
	_next_btn.disabled = _page >= _page_count() - 1

func _tile(index: int, app: Dictionary) -> Button:
	var app_id := int(app.get("id", DEFAULT_APP_ID))
	var tile := Button.new()
	tile.custom_minimum_size = TILE_SIZE
	tile.focus_mode = Control.FOCUS_NONE
	tile.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	if index == main._selected_app_idx:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.49, 0.45, 1.0, 0.35)
		style.border_color = Color(0.6, 0.57, 1.0, 1.0)
		style.set_border_width_all(4)
		style.set_corner_radius_all(10)
		tile.add_theme_stylebox_override("normal", style)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(box)
	var cover := TextureRect.new()
	cover.custom_minimum_size = COVER_SIZE
	cover.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.texture = cover_for(app_id)
	box.add_child(cover)
	_tile_covers[app_id] = cover
	var label := Label.new()
	label.text = String(app.get("name", "App"))
	label.add_theme_font_size_override("font_size", 22)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = 2
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	tile.pressed.connect(func(): select(index))
	return tile

## Makes `index` the selected app, remembers it for this host and returns to
## the main page.
func select(index: int) -> void:
	var apps: Array = main._available_apps
	if index < 0 or index >= apps.size():
		return
	main._selected_app_idx = index
	main._selected_app_id = int(apps[index].get("id", DEFAULT_APP_ID))
	remember()
	welcome.refresh_app_display()
	welcome.show_welcome_screen("welcome")

## The cached cover of `app_id` on the current host, or the PC icon while it
## loads (or when the host has none). Fetches it the first time.
func cover_for(app_id: int) -> Texture2D:
	# Desktop has local transparent artwork rather than the host's grey cover.
	for app in main._available_apps:
		if int(app.get("id", DEFAULT_APP_ID)) == app_id and String(app.get("name", "")).strip_edges().to_lower() == "desktop":
			return load("res://src/assets/desktop_cover.svg")
	var key := _cover_key(app_id)
	if _covers.has(key):
		return _covers[key]
	_request_cover(app_id)
	return load("res://src/assets/pc_icon.svg")

func has_cover(app_id: int) -> bool:
	return _covers.has(_cover_key(app_id))

func _cover_key(app_id: int) -> String:
	return "%d:%d" % [main.current_host_id, app_id]

func _request_cover(app_id: int) -> void:
	var host_id: int = main.current_host_id
	var key := _cover_key(app_id)
	if host_id < 0 or _requested.has(key) or main.stream_backend == null:
		return
	var cm = main.stream_backend.get_computer_manager()
	if cm == null or not cm.has_method("get_app_cover"):
		return
	_requested[key] = true
	cm.get_app_cover(host_id, app_id, func(texture: Texture2D) -> void:
		if texture == null:
			return
		_covers[key] = texture
		if host_id != main.current_host_id:
			return
		var rect = _tile_covers.get(app_id)
		if rect != null and is_instance_valid(rect):
			rect.texture = texture
		if app_id == main._selected_app_id:
			welcome.refresh_app_display())

## The host's key in LAST_APP_FILE: its server ID, else its address.
func _host_key() -> String:
	var cm = main.stream_backend.get_config_manager() if main.stream_backend else null
	if cm:
		for h in cm.get_hosts():
			if int(h.get("id", -1)) == main.current_host_id:
				var unique := String(h.get("server_unique_id", ""))
				return unique if not unique.is_empty() else String(h.get("localaddress", ""))
	return ""

func remember() -> void:
	var key := _host_key()
	var apps: Array = main._available_apps
	if key.is_empty() or main._selected_app_idx < 0 or main._selected_app_idx >= apps.size():
		return
	var save := ConfigFile.new()
	save.load(LAST_APP_FILE)
	save.set_value(key, "id", main._selected_app_id)
	save.set_value(key, "name", String(apps[main._selected_app_idx].get("name", "")))
	save.save(LAST_APP_FILE)

## Index of the app last used on this host in `apps`, by ID and then by name;
## 0 (the first app) when it's gone or nothing was saved.
func remembered_index(apps: Array) -> int:
	var key := _host_key()
	var save := ConfigFile.new()
	if key.is_empty() or save.load(LAST_APP_FILE) != OK or not save.has_section(key):
		return 0
	var saved_id := int(save.get_value(key, "id", -1))
	var saved_name := String(save.get_value(key, "name", ""))
	for i in apps.size():
		if int(apps[i].get("id", -1)) == saved_id:
			return i
	for i in apps.size():
		if not saved_name.is_empty() and String(apps[i].get("name", "")) == saved_name:
			return i
	return 0

func _spacer(height: int, expand := false) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	if expand:
		spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer

func _button(text: String, size: Vector2) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = size
	button.add_theme_font_size_override("font_size", 26)
	return button
