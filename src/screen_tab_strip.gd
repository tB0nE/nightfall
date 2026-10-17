class_name ScreenTabStrip
extends RefCounted

# Shares the corner-controls viewport/layer. Rectangles use screen-width units,
# with y=0 at the video's top edge and positive y pointing down.
const TOP_MARGIN_RATIO := 0.135
const MAX_VISIBLE := 4
const BROWSER_ICON := preload("res://src/assets/screen_shortcuts/browser.svg")
const NAV_ICONS := {
	"nav:back": preload("res://src/assets/screen_shortcuts/browser_back.svg"),
	"nav:forward": preload("res://src/assets/screen_shortcuts/browser_forward.svg"),
	"nav:reload": preload("res://src/assets/screen_shortcuts/browser_refresh.svg"),
	"menu": preload("res://src/assets/screen_shortcuts/browser_menu.svg"),
}
const STOP_ICON := preload("res://src/assets/screen_shortcuts/browser_stop.svg")
const PANEL_RECT := Rect2(-0.5, -0.13, 1.0, 0.118)
var main: Node3D
var hovered: StringName = &""
var popup := ""
var _signature := ""
var _items: Array = []
var _reuse: Dictionary = {}
var _viewport: SubViewport
var _screen: VRScreen
var _background: Panel
var _dropdown_background: Panel

func _make_background() -> Panel:
	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.10, 0.92)
	style.set_corner_radius_all(32)
	panel.add_theme_stylebox_override("panel", style)
	panel.z_index = -1
	_viewport.add_child(panel)
	return panel

func _position_background(panel: Panel, rect: Rect2, surface_size: Vector2, margin: float, scale_px: float) -> void:
	panel.position = Vector2((rect.position.x * _screen.mesh_size.x + surface_size.x * 0.5) * scale_px,
		(rect.position.y * _screen.mesh_size.x + margin) * scale_px)
	panel.size = rect.size * _screen.mesh_size.x * scale_px

func _init(owner: Node3D): main = owner

static func visible_pages(pages: Array, selected: int) -> Array:
	var result := pages.slice(0, MAX_VISIBLE)
	if pages.size() > MAX_VISIBLE:
		for page in pages:
			if int(page.id) == selected and not result.has(page):
				result[MAX_VISIBLE - 1] = page
	return result

static func page_rects(pages: Array, _selected: int, overflow := false) -> Array[Rect2]:
	var result: Array[Rect2] = []
	var x := -0.48
	var right := 0.25 if overflow or pages.size() > MAX_VISIBLE else 0.32
	var width := (right - x - maxf(pages.size() - 1, 0) * 0.009) / maxf(pages.size(), 1)
	for page in pages:
		result.append(Rect2(x, -0.116, width, 0.038))
		x += width + 0.009
	return result

static func hit_faces(rect: Rect2, mesh_size: Vector2, base_radius: float) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var radius := maxf(base_radius, 0.001) + 0.003
	var top := mesh_size.y * 0.5 - rect.position.y * mesh_size.x
	var bottom := top - rect.size.y * mesh_size.x
	# Bound chord error for the wide hover backdrop too; coarse chords can
	# otherwise protrude through the smaller buttons on curved screens.
	var segments := maxi(8, ceili(rect.size.x * mesh_size.x / 0.06))
	for i in range(segments):
		var x0 := (rect.position.x + rect.size.x * i / float(segments)) * mesh_size.x
		var x1 := (rect.position.x + rect.size.x * (i + 1) / float(segments)) * mesh_size.x
		# Clear the screen collider's 5 mm front face, including segment
		# approximation error, so dropdown rows win rays over the video.
		# The viewer is on local +Z. Positive offset is in front of the
		# screen; negative offsets place menu targets behind its collider.
		var p0 := Vector3(sin(x0 / radius) * radius, top, base_radius - cos(x0 / radius) * radius + 0.015)
		var p1 := Vector3(sin(x1 / radius) * radius, top, base_radius - cos(x1 / radius) * radius + 0.015)
		var p2 := Vector3(p0.x, bottom, p0.z)
		var p3 := Vector3(p1.x, bottom, p1.z)
		faces.append_array(PackedVector3Array([p0, p1, p2, p1, p3, p2]))
	return faces

func attach(screen: VRScreen, viewport: SubViewport) -> void:
	if screen != main.primary_screen:
		return
	_screen = screen
	_viewport = viewport
	if not is_instance_valid(_background):
		_background = _make_background()
		_dropdown_background = _make_background()
	_signature = ""

func begin_pointer_frame() -> void: hovered = &""
func set_hover(action: StringName) -> void: hovered = action

func invoke(action: StringName) -> void:
	for item in _items:
		if item.action == action and not item.enabled: return
	if action == &"hover": return
	if main.browser_prototype.closing:
		return
	var command := String(action)
	main._log("[TABS] action=%s count=%d selected=%d" % [command, main.browser_prototype.pages.size(), main.browser_prototype.selected_page])
	if command == "add":
		popup = "" if popup == "sources" else "sources"
	elif command == "overflow":
		popup = "" if popup == "tabs" else "tabs"
	elif command == "menu":
		popup = "" if popup == "settings" else "settings"
	elif command == "close":
		main.browser_prototype.tab_action("close", main.browser_prototype.selected_page)
		popup = ""
	elif command.begins_with("close:"):
		main.browser_prototype.tab_action("close", int(command.trim_prefix("close:")))
		popup = ""
	elif command in ["browser", "source:browser"]:
		if main.browser_prototype.active:
			main.browser_prototype.tab_action("new")
		elif main.screen_sources.can_open_browser():
			main.browser_prototype.start()
		popup = ""
	elif command.begins_with("page:"):
		main.browser_prototype.tab_action("select", int(command.trim_prefix("page:")))
		popup = ""
	elif command.begins_with("list:"):
		main.browser_prototype.tab_action("select", int(command.trim_prefix("list:")))
		popup = ""
	elif command.begins_with("nav:"):
		main.browser_prototype.navigation_action(command.trim_prefix("nav:"))
		popup = ""
	_signature = ""

func _add(action: StringName, title: String, rect: Rect2, selected := false, enabled := true) -> void:
	if _reuse.has(action):
		var existing: Dictionary = _reuse[action]
		_reuse.erase(action)
		if is_instance_valid(existing.panel) and is_instance_valid(existing.area) and is_instance_valid(existing.fallback):
			existing.title = title
			existing.rect = rect
			existing.selected = selected
			existing.enabled = enabled
			existing.fallback.text = title
			_items.append(existing)
			return
		_discard(existing)
	# Draw caption and background in one CanvasItem. Do not depend on deferred
	# child-container layout inside the compositor-owned transparent viewport.
	var panel := Button.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.focus_mode = Control.FOCUS_NONE
	panel.alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.clip_text = true
	panel.text = title
	panel.add_theme_font_size_override("font_size", 30)
	if action == &"nav:address":
		panel.alignment = HORIZONTAL_ALIGNMENT_LEFT
		panel.add_theme_font_size_override("font_size", 26)
	panel.add_theme_color_override("font_color", Color.WHITE)
	panel.add_theme_color_override("font_hover_color", Color.WHITE)
	panel.add_theme_color_override("font_pressed_color", Color.WHITE)
	if String(action).begins_with("page:") or action == &"browser":
		panel.icon = BROWSER_ICON
		panel.add_theme_constant_override("icon_max_width", 28)
	if NAV_ICONS.has(String(action)):
		panel.icon = NAV_ICONS[String(action)]
		panel.add_theme_constant_override("icon_max_width", 30)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.06)
	style.set_corner_radius_all(16)
	style.content_margin_left = 14
	style.content_margin_right = 14
	var hover_style: StyleBoxFlat = style.duplicate()
	hover_style.bg_color = Color(0.18, 0.18, 0.21, 1.0)
	var active_style: StyleBoxFlat = style.duplicate()
	active_style.bg_color = Color(1, 1, 1, 0.16)
	panel.add_theme_stylebox_override("normal", style)
	panel.add_theme_stylebox_override("hover", style)
	panel.add_theme_stylebox_override("pressed", style)
	_viewport.add_child(panel)
	var area := Area3D.new()
	area.collision_layer = 2 if enabled else 0
	area.collision_mask = 0
	area.monitoring = false
	area.set_meta(&"nf_role", &"screen_tab")
	area.set_meta(&"nf_action", action)
	var collision := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	collision.shape = shape
	area.add_child(collision)
	_screen.add_child(area)
	var fallback := Label3D.new()
	fallback.text = title
	fallback.font_size = 32
	fallback.no_depth_test = true
	_screen.add_child(fallback)
	_items.append({"action": action, "title": title, "rect": rect, "selected": selected,
		"enabled": enabled, "panel": panel, "label": panel, "area": area, "fallback": fallback, "geometry": [],
		"styles": [style, hover_style, active_style]})

func _discard(item: Dictionary) -> void:
	if is_instance_valid(item.area):
		item.area.collision_layer = 0
		item.area.queue_free()
	if is_instance_valid(item.panel): item.panel.queue_free()
	if is_instance_valid(item.fallback): item.fallback.queue_free()

func _rebuild() -> void:
	# Title/popup changes must not destroy and recreate every live hit target.
	_reuse.clear()
	for item in _items: _reuse[item.action] = item
	_items.clear()
	var browser_active: bool = main.browser_prototype.active
	var pages: Array = main.browser_prototype.pages
	var selected: int = main.browser_prototype.selected_page
	# A non-actionable backdrop bridges gaps and the route into dropdowns.
	var hover_bottom := 0.0
	if popup == "sources": hover_bottom = 0.125
	elif popup == "settings": hover_bottom = 0.17
	elif popup == "tabs": hover_bottom = maxf(0.0, pages.size() * 0.036 + 0.025)
	if browser_active and not pages.is_empty():
		var visible := visible_pages(pages, selected)
		var rects := page_rects(visible, selected, pages.size() > MAX_VISIBLE)
		for i in visible.size():
			var page: Dictionary = visible[i]
			_add(StringName("page:%d" % int(page.id)), str(page.get("title", "Browser")),
				rects[i], int(page.id) == selected)
		for i in visible.size():
			var close_rect: Rect2 = rects[i]
			close_rect.position.x = close_rect.end.x - 0.032
			close_rect.size.x = 0.032
			_add(StringName("close:%d" % int(visible[i].id)), "x", close_rect)
	else:
		_add(&"current", "PC monitor" if main.is_streaming else "Welcome", Rect2(-0.48, -0.116, 0.80, 0.038), true, false)
	var can_browser: bool = (browser_active and pages.size() < 8) or (not browser_active and main.screen_sources.can_open_browser())
	_add(&"browser", "+ Browser", Rect2(0.33, -0.116, 0.15, 0.038), false, can_browser)
	if pages.size() > MAX_VISIBLE:
		_add(&"overflow", "Tabs", Rect2(0.26, -0.116, 0.06, 0.038))
	if browser_active:
		var nav: Dictionary = main.browser_prototype.navigation
		var address_text := str(nav.get("address", ""))
		if address_text.is_empty(): address_text = "Address or search"
		var x := -0.48
		for entry in [["back", "", 0.05], ["forward", "", 0.05],
			["reload", "", 0.05], ["address", address_text, 0.724]]:
			var enabled := bool(nav.get(entry[0], false)) if entry[0] in ["back", "forward"] else true
			_add(StringName("nav:" + entry[0]), entry[1], Rect2(x, -0.064, entry[2], 0.038),
				entry[0] == "address" and bool(nav.get("editing", false)), enabled)
			x += float(entry[2]) + 0.009
		_add(&"menu", "", Rect2(0.43, -0.064, 0.05, 0.038), popup == "settings")
	if popup == "sources":
		_add(&"source:browser", "Add browser", Rect2(0.12, -0.014, 0.31, 0.04), false, can_browser)
		_add(&"pc", "PC monitor — connect first" if not main.is_streaming else "PC monitor — use Screens", Rect2(0.12, 0.03, 0.31, 0.04), false, false)
		_add(&"local", "Local media — not available yet", Rect2(0.12, 0.074, 0.31, 0.04), false, false)
	elif popup == "settings":
		var entries := [["home", "Home"], ["bookmarks", "Bookmarks"],
			["privacy", "Privacy"], ["blocking", "Blocking"]]
		for i in entries.size():
			_add(StringName("nav:" + entries[i][0]), entries[i][1], Rect2(0.19, -0.014 + i * 0.044, 0.29, 0.04))
	elif popup == "tabs":
		for i in pages.size():
			var page: Dictionary = pages[i]
			_add(StringName("list:%d" % int(page.id)), str(page.get("title", "Browser")),
				Rect2(0.03, -0.014 + i * 0.036, 0.4, 0.033), int(page.id) == selected)
	_add(&"hover", "", Rect2(-0.5, -0.132, 1.0, hover_bottom + 0.132))
	for item in _reuse.values(): _discard(item)
	_reuse.clear()

func update(screen: VRScreen, surface_size: Vector2, margin: float, revealed: bool) -> void:
	if screen != _screen or not is_instance_valid(_viewport):
		return
	# Welcome already has Open Browser. Remove both artwork and hit targets
	# here, without hiding the corner resize controls sharing this layer.
	if not main.browser_prototype.active and not main.is_streaming:
		popup = ""
		hovered = &""
		_background.visible = false
		_dropdown_background.visible = false
		for item in _items:
			item.panel.visible = false
			item.fallback.visible = false
			item.area.collision_layer = 0
		return
	if not revealed and popup != "":
		popup = ""
	var signature := str([main.browser_prototype.pages, main.browser_prototype.selected_page,
		main.browser_prototype.active, main.browser_prototype.navigation, main.is_streaming, popup])
	if signature != _signature:
		_signature = signature
		_rebuild()
	var scale_px := CompositionScreenControls.CORNER_ATLAS_WIDTH / surface_size.x
	_position_background(_background, PANEL_RECT, surface_size, margin, scale_px)
	_background.visible = revealed
	_dropdown_background.visible = revealed and popup != ""
	if popup != "":
		var hover_bottom: float = _items[-1].rect.end.y
		var dropdown_rect := Rect2(0.18, -0.02, 0.31, 0.19) if popup == "settings" else Rect2(0.02, -0.02, 0.47, maxf(0.15, hover_bottom + 0.02))
		_position_background(_dropdown_background, dropdown_rect, surface_size, margin, scale_px)
	for item in _items:
		var rect: Rect2 = item.rect
		var command := String(item.action)
		var is_page := command.begins_with("page:")
		var is_close := command.begins_with("close:")
		var page_id := command.get_slice(":", 1)
		var tab_hovered := hovered == StringName("page:" + page_id) or hovered == StringName("close:" + page_id)
		var highlighted: bool = hovered == item.action or (is_page and tab_hovered)
		var center := (rect.position + rect.size * 0.5) * screen.mesh_size.x
		var radius := maxf(screen._comp_cyl_radius, 0.001)
		var angle := center.x / radius
		var local_position := Vector3(sin(angle) * radius,
			screen.mesh_size.y * 0.5 - center.y, radius * (1.0 - cos(angle)) + 0.004)
		var geometry := [rect, screen.mesh_size, radius]
		if item.geometry != geometry:
			item.geometry = geometry
			var shape: ConcavePolygonShape3D = item.area.get_child(0).shape
			shape.set_faces(hit_faces(rect, screen.mesh_size, radius))
		var show_close := is_close and revealed and tab_hovered
		# Keep the backdrop behind actionable targets. Disabled menu rows
		# absorb input too, rather than clicking the web page underneath.
		item.area.position.z = -0.006 if item.action == &"hover" else (0.003 if is_close else 0.0)
		item.area.collision_layer = 2 if not is_close or show_close else 0
		var painted := rect
		item.panel.position = Vector2((painted.position.x * screen.mesh_size.x + surface_size.x * 0.5) * scale_px,
			(painted.position.y * screen.mesh_size.x + margin) * scale_px)
		item.panel.size = painted.size * screen.mesh_size.x * scale_px
		item.panel.visible = revealed and item.action != &"hover" and (not is_close or show_close)
		item.panel.z_index = 30 if is_close else (20 if highlighted else 10)
		var button_style: StyleBoxFlat = item.styles[1 if highlighted else (2 if item.selected else 0)]
		item.panel.add_theme_stylebox_override("normal", button_style)
		if is_page:
			button_style.content_margin_right = 52
		var ink := Color(0.55, 0.78, 1.0, 0.9) if item.selected else Color(1, 1, 1, 1.0 if highlighted else 0.6)
		if not item.enabled and not item.selected: ink.a = 0.25
		item.panel.add_theme_color_override("font_color", ink)
		item.panel.add_theme_color_override("icon_normal_color", ink)
		item.label.text = item.title
		if item.action == &"nav:reload":
			item.panel.icon = STOP_ICON if main.browser_prototype.navigation.get("loading", false) else NAV_ICONS["nav:reload"]
		item.fallback.position = local_position
		item.fallback.rotation.y = -angle
		item.fallback.pixel_size = screen.mesh_size.x / 1536.0
		item.fallback.visible = revealed and not main.comp.in_use and item.action != &"hover" and (not is_close or show_close)
