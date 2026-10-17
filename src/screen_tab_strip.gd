class_name ScreenTabStrip
extends RefCounted

# Shares the corner-controls viewport/layer. Rectangles use screen-width units,
# with y=0 at the video's top edge and positive y pointing down.
const TOP_MARGIN_RATIO := 0.135
const MAX_VISIBLE := 4
const BROWSER_ICON := preload("res://src/assets/screen_shortcuts/browser.svg")
var main: Node3D
var hovered: StringName = &""
var popup := ""
var _signature := ""
var _items: Array = []
var _reuse: Dictionary = {}
var _viewport: SubViewport
var _screen: VRScreen

func _init(owner: Node3D): main = owner

static func visible_pages(pages: Array, selected: int) -> Array:
	var result := pages.slice(0, MAX_VISIBLE)
	if pages.size() > MAX_VISIBLE:
		for page in pages:
			if int(page.id) == selected and not result.has(page):
				result[MAX_VISIBLE - 1] = page
	return result

static func page_rects(pages: Array, selected: int) -> Array[Rect2]:
	var result: Array[Rect2] = []
	var x := -0.43
	for page in pages:
		var width := 0.25 if int(page.id) == selected else 0.125
		result.append(Rect2(x, -0.116, width, 0.038))
		x += width + 0.012
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
	elif command == "close":
		main.browser_prototype.tab_action("close", main.browser_prototype.selected_page)
		popup = ""
	elif command == "browser":
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
	panel.add_theme_color_override("font_color", Color.WHITE)
	panel.add_theme_color_override("font_hover_color", Color.WHITE)
	panel.add_theme_color_override("font_pressed_color", Color.WHITE)
	if String(action).begins_with("page:") or action == &"browser":
		panel.icon = BROWSER_ICON
		panel.add_theme_constant_override("icon_max_width", 28)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.13, 0.22, 0.9)
	style.set_corner_radius_all(10)
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
		"enabled": enabled, "panel": panel, "label": panel, "area": area, "fallback": fallback, "geometry": []})

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
	elif popup == "tabs": hover_bottom = maxf(0.0, pages.size() * 0.036 + 0.025)
	if browser_active and not pages.is_empty():
		var visible := visible_pages(pages, selected)
		var rects := page_rects(visible, selected)
		for i in visible.size():
			var page: Dictionary = visible[i]
			_add(StringName("page:%d" % int(page.id)), str(page.get("title", "Browser")),
				rects[i], int(page.id) == selected)
	else:
		_add(&"current", "PC monitor" if main.is_streaming else "Welcome", Rect2(-0.43, -0.116, 0.32, 0.038), true, false)
	_add(&"close", "x", Rect2(0.26, -0.116, 0.05, 0.038), false, browser_active)
	_add(&"add", "+", Rect2(0.32, -0.116, 0.05, 0.038))
	_add(&"overflow", "...", Rect2(0.38, -0.116, 0.05, 0.038), false, pages.size() > MAX_VISIBLE)
	if browser_active:
		var nav: Dictionary = main.browser_prototype.navigation
		var address_text := str(nav.get("address", ""))
		if address_text.is_empty(): address_text = "Address or search"
		var x := -0.43
		for entry in [["back", "<", 0.045], ["forward", ">", 0.045],
			["reload", "Stop" if nav.get("loading", false) else "Reload", 0.065],
			["home", "Home", 0.055], ["address", address_text, 0.29],
			["go", "Go", 0.045], ["bookmarks", "Saved", 0.075],
			["blocking", "Blocking", 0.08], ["privacy", "Privacy", 0.075]]:
			var enabled := bool(nav.get(entry[0], false)) if entry[0] in ["back", "forward"] else true
			_add(StringName("nav:" + entry[0]), entry[1], Rect2(x, -0.064, entry[2], 0.038),
				entry[0] == "address" and bool(nav.get("editing", false)), enabled)
			x += float(entry[2]) + 0.006
	if popup == "sources":
		var can_browser: bool = (browser_active and pages.size() < 8) or (not browser_active and main.screen_sources.can_open_browser())
		_add(&"browser", "Add browser", Rect2(0.12, -0.014, 0.31, 0.04), false, can_browser)
		_add(&"pc", "PC monitor — connect first" if not main.is_streaming else "PC monitor — use Screens", Rect2(0.12, 0.03, 0.31, 0.04), false, false)
		_add(&"local", "Local media — not available yet", Rect2(0.12, 0.074, 0.31, 0.04), false, false)
	elif popup == "tabs":
		for i in pages.size():
			var page: Dictionary = pages[i]
			_add(StringName("list:%d" % int(page.id)), str(page.get("title", "Browser")),
				Rect2(0.03, -0.014 + i * 0.036, 0.4, 0.033), int(page.id) == selected)
	_add(&"hover", "", Rect2(-0.46, -0.132, 0.92, hover_bottom + 0.132))
	for item in _reuse.values(): _discard(item)
	_reuse.clear()

func update(screen: VRScreen, surface_size: Vector2, margin: float, revealed: bool) -> void:
	if screen != _screen or not is_instance_valid(_viewport):
		return
	if not revealed and popup != "":
		popup = ""
	var signature := str([main.browser_prototype.pages, main.browser_prototype.selected_page,
		main.browser_prototype.active, main.browser_prototype.navigation, main.is_streaming, popup])
	if signature != _signature:
		_signature = signature
		_rebuild()
	var scale_px := CompositionScreenControls.CORNER_ATLAS_WIDTH / surface_size.x
	for item in _items:
		var rect: Rect2 = item.rect
		var highlighted: bool = hovered == item.action
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
		# Keep the backdrop behind actionable targets. Disabled menu rows
		# absorb input too, rather than clicking the web page underneath.
		item.area.position.z = -0.006 if item.action == &"hover" else 0.0
		item.area.collision_layer = 2
		var painted := rect
		if highlighted and String(item.action).begins_with("page:") and not item.selected:
			# Only the artwork expands. Physics slots/neighbours never move.
			painted.size.x = 0.30
			painted.position.x = clampf(rect.get_center().x - 0.15, -0.43, 0.13)
		item.panel.position = Vector2((painted.position.x * screen.mesh_size.x + surface_size.x * 0.5) * scale_px,
			(painted.position.y * screen.mesh_size.x + margin) * scale_px)
		item.panel.size = painted.size * screen.mesh_size.x * scale_px
		item.panel.visible = revealed and item.action != &"hover"
		item.panel.z_index = 20 if highlighted else 10
		item.panel.modulate = Color(0.45, 0.72, 1.0, 0.95) if item.selected else Color(1, 1, 1, 0.95 if highlighted else 0.75)
		if not item.enabled and not item.selected:
			item.panel.modulate.a = 0.35
		item.label.text = item.title
		if String(item.action).begins_with("page:") and not item.selected and not highlighted:
			item.label.text = ""
		item.fallback.position = local_position
		item.fallback.rotation.y = -angle
		item.fallback.pixel_size = screen.mesh_size.x / 1536.0
		item.fallback.visible = revealed and not main.comp.in_use and item.action != &"hover"
