class_name ScreenTabStrip
extends RefCounted

# Shares the corner-controls viewport/layer. Rectangles use screen-width units,
# with y=0 at the video's top edge and positive y pointing down.
const TOP_MARGIN_RATIO := 0.135
const MAX_VISIBLE := 4
const CLOSE_RECT := Rect2(-0.48, -0.116, 0.038, 0.038)
const TAB_LEFT := -0.425
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
var browser: RefCounted
var hovered: StringName = &""
var _revealed := false
var popup := ""
var _packing_callback := Callable()
var _signature := ""
var _items: Array = []
var _reuse: Dictionary = {}
var _viewport: SubViewport
var _screen: VRScreen
var _background: Panel
var _dropdown_background: Panel
var _virtual_kind := "tab"
var _virtual_size := Vector2i(2560,1440)
var _virtual_field := 0
var _virtual_digits := ""
## Virtual monitor sizes by aspect ratio, after "Default" (match the host).
const VIRTUAL_RATIOS := [
	["16:9", [Vector2i(1920,1080),Vector2i(2560,1440),Vector2i(3840,2160),Vector2i(5120,2880),Vector2i(7680,4320)]],
	["21:9", [Vector2i(2560,1080),Vector2i(3440,1440),Vector2i(5120,2160)]],
	["4:3", [Vector2i(1440,1080),Vector2i(1600,1200),Vector2i(2880,2160)]],
]
var _virtual_ratio := 0
## Vertical Orientation: every listed size and ratio turned on its side.
var _virtual_vertical := false
## Whether the physical monitor list adds a "screen" or a "tab".
var _physical_kind := "screen"

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

func _init(owner: Node3D, target: VRScreen = null, provider: RefCounted = null):
	main = owner
	_screen = target
	browser = provider if provider != null else main.browser_prototype

static func visible_pages(pages: Array, selected: Variant) -> Array:
	var result := pages.slice(0, MAX_VISIBLE)
	if pages.size() > MAX_VISIBLE:
		for page in pages:
			if str(page.id) == str(selected) and not result.has(page):
				result[MAX_VISIBLE - 1] = page
	return result

static func page_rects(pages: Array, _selected: Variant, overflow := false) -> Array[Rect2]:
	var result: Array[Rect2] = []
	var x := TAB_LEFT
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
	if screen != _screen or viewport != _viewport:
		for item in _items:
			_discard(item)
		_items.clear()
		_reuse.clear()
		if is_instance_valid(_background): _background.queue_free()
		if is_instance_valid(_dropdown_background): _dropdown_background.queue_free()
		_background = null
		_dropdown_background = null
		popup = ""
		_revealed = false
		hovered = &""
	_screen = screen
	_viewport = viewport
	if not is_instance_valid(_background):
		_background = _make_background()
		_dropdown_background = _make_background()
	_signature = ""

func begin_pointer_frame() -> void: hovered = &""
func set_hover(action: StringName) -> void: hovered = action

func invoke(action: StringName) -> void:
	if not _revealed: return
	for item in _items:
		if item.action == action and not item.enabled: return
	if action == &"packing:yes" or action == &"packing:no":
		var callback := _packing_callback
		_packing_callback = Callable()
		popup = ""
		if callback.is_valid(): callback.call(action == &"packing:yes")
		return
	if action == &"hover": return
	if main.screen_sources != null and main.screen_sources.get("switching_primary") == true: return
	if main.screen_sources != null and main.screen_sources.get("switching_tab") == true: return
	if browser.closing:
		return
	var command := String(action)
	main._log("[TABS] action=%s count=%d selected=%d" % [command, browser.pages.size(), browser.selected_page])
	if main.screen_sources and main.screen_sources.has_method("focus_browser"):
		main.screen_sources.focus_browser(browser)
	if command == "add":
		popup = "" if popup == "sources" else "sources"
	elif command == "overflow":
		popup = "" if popup == "tabs" else "tabs"
	elif command == "menu":
		popup = "" if popup == "settings" else "settings"
	elif command == "close":
		if browser.active: browser.tab_action("close", browser.selected_page)
		else: main.screen_sources.close_monitor_screen(_screen)
		popup = ""
	elif command == "browser":
		popup = "" if popup == "sources" else "sources"
	elif command == "tab:new":
		popup = "tab_types"
	elif command == "tab:browser":
		if not browser.active:
			main.screen_sources.select_browser_tab(_screen, 0, true)
		else: browser.tab_action("new")
		popup = ""
	elif command == "tab:monitor":
		main.screen_sources.select_monitor_tab(_screen)
		popup = ""
	elif command == "tab:physical":
		_physical_kind = "tab"
		popup = "physical_list"
	elif command.begins_with("physical:"):
		var id := StringName(command.trim_prefix("physical:"))
		if _physical_kind == "tab": main.screen_sources.add_monitor_tab(_screen, false, Vector2i.ZERO, id)
		else:
			var title := String(id)
			for choice in _physical_choices(): if choice.id == id: title = choice.label
			main.screen_sources.begin_screen_placement({"kind": &"physical", "id": id, "title": title})
		popup = ""
	elif command == "tab:virtual":
		_virtual_kind = "tab"
		popup = "virtual_resolution"
	elif command == "tab:start_stream":
		main.screen_sources.start_stream_tab(_screen)
		popup = ""
	elif command.begins_with("monitor:"):
		main.screen_sources.select_monitor_content_tab(_screen, StringName(command))
		popup = ""
	elif command == "tab:resolution":
		if not browser.active and _screen.monitor != null and _screen.monitor.hint.get("virtual",false):
			_virtual_kind = "edit"
			popup = "virtual_resolution"
		else: popup = "tab_resolution"
	elif command == "virtual:default":
		# A vertical Default has to name its size; the host's own is landscape.
		_apply_virtual_size(_oriented(_host_size()) if _virtual_vertical else Vector2i.ZERO)
	elif command == "virtual:vertical":
		_virtual_vertical = not _virtual_vertical
	elif command.begins_with("virtual:ratio:"):
		var index := int(command.trim_prefix("virtual:ratio:"))
		if index >= 0 and index < VIRTUAL_RATIOS.size():
			_virtual_ratio = index
			popup = "virtual_ratio"
	elif command.begins_with("virtual:size:"):
		var index := int(command.trim_prefix("virtual:size:"))
		var sizes: Array = VIRTUAL_RATIOS[_virtual_ratio][1]
		if index >= 0 and index < sizes.size(): _apply_virtual_size(_oriented(sizes[index]))
	elif command == "virtual:custom":
		_virtual_size = Vector2i(2560,1440)
		var tab := _screen.content_tabs.selected()
		if _virtual_kind == "edit" and tab != null and tab.resolution != Vector2i.ZERO: _virtual_size = tab.resolution
		_virtual_field = 0
		_virtual_digits = ""
		popup = "virtual_custom"
	elif command.begins_with("virtual:field:"):
		_virtual_field = int(command.trim_prefix("virtual:field:"))
		_virtual_digits = ""
	elif command.begins_with("virtual:key:"):
		var key := command.trim_prefix("virtual:key:")
		if key == "clear": _virtual_digits = ""
		elif key == "back":
			if _virtual_digits.is_empty(): _virtual_digits = str(_virtual_size[_virtual_field])
			_virtual_digits = _virtual_digits.left(maxi(0,_virtual_digits.length()-1))
		elif _virtual_digits.length() < 4: _virtual_digits += key
		_virtual_size[_virtual_field] = int(_virtual_digits) if not _virtual_digits.is_empty() else 0
	elif command == "virtual:create":
		if ScreenSources.valid_virtual_size(_virtual_size) and _virtual_size != Vector2i.ZERO: _apply_virtual_size(_virtual_size)
	elif command.begins_with("tab:res:"):
		var index := int(command.trim_prefix("tab:res:"))
		var choices := _resolution_choices()
		if index >= -1 and index < choices.size():
			var size: Vector2i = Vector2i.ZERO if index == -1 else choices[index]
			if browser.active: main.screen_sources.set_browser_tab_resolution(_screen, size)
			else: main.screen_sources.set_monitor_tab_resolution(_screen, size)
		popup = ""
	elif command == "screen:new":
		popup = "screen_types"
	elif command == "screen:browser":
		main.screen_sources.begin_screen_placement({"kind": &"browser", "title": "Browser"})
		popup = ""
	elif command == "screen:virtual":
		_virtual_kind = "screen"
		popup = "virtual_resolution"
	elif command == "screen:physical":
		_physical_kind = "screen"
		popup = "physical_list"
	elif command == "stream:new":
		main.screen_sources.add_stream_screen()
		popup = ""
	elif command == "screen:primary":
		main.screen_sources.make_primary(_screen)
		popup = ""
	elif command.begins_with("page:"):
		_select_page(int(command.trim_prefix("page:")))
		popup = ""
	elif command.begins_with("list:"):
		var id := command.trim_prefix("list:")
		_select_page(id if id.begins_with("monitor:") else int(id))
		popup = ""
	elif command.begins_with("nav:"):
		browser.navigation_action(command.trim_prefix("nav:"))
		popup = ""
	_signature = ""

func _select_page(id: Variant) -> void:
	if id is String: main.screen_sources.select_monitor_content_tab(_screen, StringName(id))
	elif id == -1: main.screen_sources.select_monitor_tab(_screen)
	elif not browser.active: main.screen_sources.select_browser_tab(_screen, id)
	else: browser.tab_action("select", id)

func _apply_virtual_size(size: Vector2i) -> void:
	if _virtual_kind == "edit": main.screen_sources.set_monitor_tab_resolution(_screen,size)
	elif _virtual_kind == "screen":
		var shown := _host_size() if size == Vector2i.ZERO else size
		var title := "Virtual %d × %d" % [shown.x, shown.y]
		main.screen_sources.begin_screen_placement({"kind": &"virtual", "size": size, "title": title})
	else: main.screen_sources.add_monitor_tab(_screen,true,size)
	popup = ""

## A listed size, turned vertical when Vertical Orientation is on.
func _oriented(size: Vector2i) -> Vector2i:
	return Vector2i(size.y, size.x) if _virtual_vertical else size

func _ratio_label(index: int) -> String:
	var ratio: String = VIRTUAL_RATIOS[index][0]
	if _virtual_vertical: ratio = "%s:%s" % [ratio.get_slice(":", 1), ratio.get_slice(":", 0)]
	return ratio

func _host_size() -> Vector2i:
	if main.screen_sources.has_method("host_monitor_size"): return main.screen_sources.host_monitor_size()
	return Vector2i(1920, 1080)

func _physical_choices() -> Array:
	if not main.screen_sources.has_method("physical_choices"): return []
	return main.screen_sources.physical_choices(_screen if _physical_kind == "tab" else null)

func _virtual_size_enabled(size: Vector2i) -> bool:
	var supported: bool = main.layout.virtual_modes_supported
	if not supported and size != Vector2i.ZERO: return false
	if _virtual_kind == "edit" or not main.screen_sources.has_method("monitor_size_available"): return true
	return main.screen_sources.monitor_size_available(true, size)

func _resolution_choices() -> Array:
	return browser.RESOLUTIONS if browser.active else main.resolutions

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
	if (String(action).begins_with("page:") and action != &"page:-1") or action == &"browser":
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
	if action == &"close":
		for box in [style, hover_style, active_style]:
			box.set_corner_radius_all(1000)
			box.content_margin_left = 0
			box.content_margin_right = 0
		style.bg_color = Color(0.72, 0.08, 0.12, 0.95)
		hover_style.bg_color = Color(0.95, 0.15, 0.20, 1.0)
		active_style.bg_color = style.bg_color
	panel.add_theme_stylebox_override("normal", style)
	panel.add_theme_stylebox_override("hover", style)
	panel.add_theme_stylebox_override("pressed", style)
	_viewport.add_child(panel)
	var area := Area3D.new()
	area.collision_layer = 2 if action == &"hover" else 0
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
	var browser_active: bool = browser.active
	var pages: Array = browser.pages.duplicate()
	var selected: Variant = browser.selected_page if browser_active else -1
	if not _screen.content_tabs.tabs.is_empty():
		pages = []
		for tab in _screen.content_tabs.tabs:
			if tab.kind == ScreenContentTab.STREAM:
				pages.append({"id": String(tab.id), "title": tab.title if not tab.title.is_empty() else "Desktop"})
			elif String(tab.id).begins_with("browser:page:"):
				pages.append({"id": int(String(tab.id).trim_prefix("browser:page:")), "title": tab.title})
		var active_tab := _screen.content_tabs.selected()
		if active_tab != null and active_tab.kind == ScreenContentTab.STREAM: selected = String(active_tab.id)
	# A non-actionable backdrop bridges gaps and the route into dropdowns.
	var hover_bottom := 0.0
	var offer_stream: bool = main.screen_sources != null and main.screen_sources.has_method("can_offer_stream_screen") \
		and main.screen_sources.can_offer_stream_screen()
	var edit_resolution: bool = main.screen_sources.has_method("can_edit_monitor_tab_resolution") \
		and main.screen_sources.can_edit_monitor_tab_resolution(_screen)
	if not edit_resolution and main.screen_sources.has_method("can_edit_browser_tab_resolution"):
		edit_resolution = main.screen_sources.can_edit_browser_tab_resolution(_screen)
	var add_physical: bool = main.screen_sources.has_method("can_add_monitor_screen") and main.screen_sources.can_add_monitor_screen(false)
	var add_virtual: bool = main.screen_sources.has_method("can_add_monitor_screen") and main.screen_sources.can_add_monitor_screen(true)
	var tab_physical: bool = main.screen_sources.has_method("can_add_monitor_tab") and main.screen_sources.can_add_monitor_tab(_screen, false)
	var tab_virtual: bool = main.screen_sources.has_method("can_add_monitor_tab") and main.screen_sources.can_add_monitor_tab(_screen, true)
	var add_screen: bool = main.screen_sources.can_add_browser_screen() or main.screen_sources.can_add_stream_screen() or add_physical or add_virtual
	if not pages.is_empty():
		var visible := visible_pages(pages, selected)
		var rects := page_rects(visible, selected, pages.size() > MAX_VISIBLE)
		for i in visible.size():
			var page: Dictionary = visible[i]
			var action := StringName(page.id) if page.id is String else StringName("page:%d" % int(page.id))
			_add(action, ("↗ " if main.screen_sources.get("dragged_tab_source") == _screen and draggable_tab(action) == main.screen_sources.get("dragged_tab_id") else "") + str(page.get("title", "Browser")), rects[i], str(page.id) == str(selected))
	else:
		_add(&"current", "PC monitor" if main.is_streaming else "Welcome", Rect2(TAB_LEFT, -0.116, 0.32 - TAB_LEFT, 0.038), true, false)
	var can_close: bool = browser_active and browser.selected_page > 0
	if not browser_active and main.screen_sources.has_method("can_close_monitor_screen"):
		can_close = main.screen_sources.can_close_monitor_screen(_screen)
	_add(&"close", "×", CLOSE_RECT, false, can_close)
	var can_browser: bool = (browser_active and browser.pages.size() < 8) or (not browser_active and main.screen_sources.can_switch_content_tab(_screen))
	var can_primary: bool = main.screen_sources != null and main.screen_sources.has_method("can_make_primary") \
		and main.screen_sources.can_make_primary(_screen)
	_add(&"browser", "+ Add", Rect2(0.33, -0.116, 0.15, 0.038), false, can_browser or add_screen or edit_resolution or can_primary)
	if pages.size() > MAX_VISIBLE:
		_add(&"overflow", "Tabs", Rect2(0.26, -0.116, 0.06, 0.038))
	if browser_active:
		var nav: Dictionary = browser.navigation
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
	if popup == "packing_confirmation":
		_add(&"packing:label", "Full-resolution H.264 limit reached", Rect2(0.01, -0.014, 0.47, 0.04), false, false)
		_add(&"packing:yes", "Switch to HEVC and add", Rect2(0.01, 0.03, 0.47, 0.04))
		_add(&"packing:no", "Keep current setup", Rect2(0.01, 0.074, 0.47, 0.04))
	elif popup == "sources":
		var row := 0
		for entry in [[&"screen:new", "Add Screen", add_screen, true],
				[&"tab:new", "Add Tab", can_browser or tab_physical or tab_virtual or not main.is_streaming, true],
				[&"tab:resolution", "Modify Screen", true, edit_resolution],
				[&"screen:primary", "Make Primary", can_primary, _screen != main.primary_screen]]:
			if not entry[3]: continue
			_add(entry[0], entry[1], Rect2(0.19, -0.014 + row * 0.044, 0.29, 0.04), false, entry[2])
			row += 1
	elif popup == "tab_types":
		_add(&"tab:browser", "Browser", Rect2(0.19, -0.014, 0.29, 0.04), false, can_browser)
		if main.is_streaming:
			_add(&"tab:virtual", "Virtual Monitor", Rect2(0.19, 0.03, 0.29, 0.04), false, tab_virtual)
			_add(&"tab:physical", "Physical Monitor", Rect2(0.19, 0.074, 0.29, 0.04), false, tab_physical)
		else:
			_add(&"tab:start_stream", "Start stream", Rect2(0.19, 0.03, 0.29, 0.04))
	elif popup == "screen_types":
		_add(&"screen:browser", "Browser", Rect2(0.19, -0.014, 0.29, 0.04), false, main.screen_sources.can_add_browser_screen())
		_add(&"screen:virtual", "Virtual Monitor", Rect2(0.19, 0.03, 0.29, 0.04), false, add_virtual)
		_add(&"screen:physical", "Physical Monitor", Rect2(0.19, 0.074, 0.29, 0.04), false, add_physical)
		if offer_stream:
			_add(&"stream:new", "Desktop connection", Rect2(0.19, 0.118, 0.29, 0.04), false, main.screen_sources.can_add_stream_screen())
	elif popup == "physical_list":
		var choices := _physical_choices()
		for i in choices.size():
			_add(StringName("physical:%s" % String(choices[i].id)), choices[i].label, Rect2(0.19, -0.014 + i * 0.036, 0.29, 0.033), false, choices[i].enabled)
		if choices.is_empty():
			_add(&"physical:none", "No other monitors", Rect2(0.19, -0.014, 0.29, 0.033), false, false)
	elif popup == "virtual_resolution":
		var supported: bool = main.layout.virtual_modes_supported
		var default_size := _oriented(_host_size())
		_add(&"virtual:default", "Default (%d × %d)" % [default_size.x, default_size.y], Rect2(0.19, -0.014, 0.29, 0.033), false,
			_virtual_size_enabled(default_size if _virtual_vertical else Vector2i.ZERO))
		for i in VIRTUAL_RATIOS.size():
			_add(StringName("virtual:ratio:%d" % i), "%s  ›" % _ratio_label(i), Rect2(0.19, 0.022 + i * 0.036, 0.29, 0.033), false, supported)
		var below := 0.022 + VIRTUAL_RATIOS.size() * 0.036
		_add(&"virtual:vertical", "Vertical Orientation: %s" % ("On" if _virtual_vertical else "Off"), Rect2(0.19, below, 0.29, 0.033), _virtual_vertical, supported)
		_add(&"virtual:custom", "Custom resolution", Rect2(0.19, below + 0.036, 0.29, 0.033), false, supported)
	elif popup == "virtual_ratio":
		var sizes: Array = VIRTUAL_RATIOS[_virtual_ratio][1]
		for i in sizes.size():
			var size: Vector2i = _oriented(sizes[i])
			_add(StringName("virtual:size:%d" % i), "%d × %d" % [size.x, size.y], Rect2(0.19, -0.014 + i * 0.036, 0.29, 0.033), false, _virtual_size_enabled(size))
	elif popup == "virtual_custom":
		_add(&"virtual:field:0","W: %d"%_virtual_size.x,Rect2(0.19,-0.014,0.14,0.036),_virtual_field == 0)
		_add(&"virtual:field:1","H: %d"%_virtual_size.y,Rect2(0.34,-0.014,0.14,0.036),_virtual_field == 1)
		var keys := ["7","8","9","4","5","6","1","2","3","clear","0","back"]
		for i in keys.size():
			_add(StringName("virtual:key:"+keys[i]),"⌫" if keys[i] == "back" else ("Clear" if keys[i] == "clear" else keys[i]),Rect2(0.19+(i%3)*0.098,0.028+(i/3)*0.036,0.094,0.033))
		_add(&"virtual:create","Apply" if _virtual_kind == "edit" else "Create",Rect2(0.19,0.18,0.29,0.036),false,ScreenSources.valid_virtual_size(_virtual_size) and _virtual_size != Vector2i.ZERO and (_virtual_kind == "edit" or (main.screen_sources.monitor_size_available(true,_virtual_size) if main.screen_sources.has_method("monitor_size_available") else true)))
	elif popup == "tab_resolution":
		var tab := _screen.content_tabs.selected()
		var resolutions := _resolution_choices()
		_add(&"tab:res:-1", "Default", Rect2(0.03, -0.014, 0.4, 0.033), tab != null and tab.resolution == Vector2i.ZERO)
		for i in resolutions.size():
			var resolution: Vector2i = resolutions[i]
			_add(StringName("tab:res:%d" % i), "%d × %d" % [resolution.x, resolution.y],
				Rect2(0.03, 0.022 + i * 0.036, 0.4, 0.033), tab != null and tab.resolution == resolution)
	elif popup == "settings":
		var entries := [["home", "Home"], ["bookmarks", "Bookmarks"],
			["privacy", "Privacy"], ["blocking", "Blocking"]]
		for i in entries.size():
			_add(StringName("nav:" + entries[i][0]), entries[i][1], Rect2(0.19, -0.014 + i * 0.044, 0.29, 0.04))
	elif popup == "tabs":
		for i in pages.size():
			var page: Dictionary = pages[i]
			_add(StringName("list:%s" % str(page.id)), str(page.get("title", "Browser")),
				Rect2(0.03, -0.014 + i * 0.036, 0.4, 0.033), str(page.id) == str(selected))
	# The backdrop covers the open dropdown's rows.
	if popup != "":
		for item in _items:
			if item.rect.position.y > -0.02: hover_bottom = maxf(hover_bottom, item.rect.end.y + 0.012)
	_add(&"hover", "", Rect2(-0.5, -0.132, 1.0, hover_bottom + 0.132))
	for item in _reuse.values(): _discard(item)
	_reuse.clear()

func hide_controls() -> void:
	if not _revealed and popup == "": return
	_revealed = false
	popup = ""
	if _background: _background.hide()
	if _dropdown_background: _dropdown_background.hide()
	for item in _items:
		item.panel.hide()
		item.fallback.hide()
		item.area.collision_layer = 2 if item.action == &"hover" else 0

func update(screen: VRScreen, surface_size: Vector2, margin: float, revealed: bool) -> void:
	if screen != _screen or not is_instance_valid(_viewport):
		return
	revealed = revealed or popup == "packing_confirmation" or main.screen_sources.get("dragged_tab_source") == screen
	_revealed = revealed
	# Welcome already has Open Browser. Remove both artwork and hit targets
	# here, without hiding the corner resize controls sharing this layer.
	if not browser.active and not main.is_streaming and not browser.suspended:
		_revealed = false
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
	var signature := str([browser.pages, browser.selected_page,
		_screen.content_tabs.to_dict(),
		browser.active, browser.suspended, browser.navigation, browser.closing, main.is_streaming,
		browser.get("render_size"), _screen.content_tabs.selected().resolution if _screen.content_tabs.selected() != null else Vector2i.ZERO,
		main.get("stream_manager").get("capacity_revision") if main.get("stream_manager") != null else 0,
		main.screen_sources.get("dragged_tab_id"), main.screen_sources.get("dragged_tab_source"),
		main.screens.size(), main.primary_screen, popup, _host_size(), _virtual_vertical, _virtual_kind, _virtual_ratio, _physical_kind, _physical_choices(), _virtual_size, _virtual_field, _virtual_digits,
		main.screen_sources.can_open_browser(), main.screen_sources.can_add_browser_screen(),
		main.screen_sources.can_offer_stream_screen(), main.screen_sources.can_add_stream_screen(),
		main.screen_sources.can_add_monitor_screen(false) if main.screen_sources.has_method("can_add_monitor_screen") else false,
		main.screen_sources.can_add_monitor_screen(true) if main.screen_sources.has_method("can_add_monitor_screen") else false,
		main.screen_sources.can_add_monitor_tab(_screen, false) if main.screen_sources.has_method("can_add_monitor_tab") else false,
		main.screen_sources.can_add_monitor_tab(_screen, true) if main.screen_sources.has_method("can_add_monitor_tab") else false,
		main.screen_sources.can_make_primary(_screen),
		main.screen_sources.can_close_monitor_screen(_screen) if main.screen_sources.has_method("can_close_monitor_screen") else false])
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
		var is_page := command.begins_with("page:") or command.begins_with("monitor:")
		var is_close := command == "close"
		var page_id := command.get_slice(":", 1)
		var tab_hovered: bool = hovered == item.action
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
		var show_close := is_close and revealed
		# Keep the backdrop behind actionable targets. Disabled menu rows
		# absorb input too, rather than clicking the web page underneath.
		item.area.position.z = -0.006 if item.action == &"hover" else (0.003 if is_close else 0.0)
		item.area.collision_layer = 2 if item.action == &"hover" or (revealed and (not is_close or show_close)) else 0
		var painted := rect
		item.panel.position = Vector2((painted.position.x * screen.mesh_size.x + surface_size.x * 0.5) * scale_px,
			(painted.position.y * screen.mesh_size.x + margin) * scale_px)
		item.panel.size = painted.size * screen.mesh_size.x * scale_px
		item.panel.visible = revealed and item.action != &"hover" and (not is_close or show_close)
		item.panel.z_index = 30 if is_close else (20 if highlighted else 10)
		var button_style: StyleBoxFlat = item.styles[1 if highlighted else (2 if item.selected else 0)]
		item.panel.add_theme_stylebox_override("normal", button_style)
		var ink := Color.WHITE if is_close else (Color(0.55, 0.78, 1.0, 0.9) if item.selected else Color(1, 1, 1, 1.0 if highlighted else 0.6))
		if not item.enabled and not item.selected: ink.a = 0.25
		item.panel.add_theme_color_override("font_color", ink)
		item.panel.add_theme_color_override("icon_normal_color", ink)
		item.label.text = item.title
		if item.action == &"nav:reload":
			item.panel.icon = STOP_ICON if browser.navigation.get("loading", false) else NAV_ICONS["nav:reload"]
		item.fallback.position = local_position
		item.fallback.rotation.y = -angle
		item.fallback.pixel_size = screen.mesh_size.x / 1536.0
		item.fallback.visible = revealed and not main.comp.in_use and item.action != &"hover" and (not is_close or show_close)

func confirm_hevc(callback: Callable) -> void:
	dismiss_packing_confirmation()
	_packing_callback = callback
	popup = "packing_confirmation"
	_signature = ""

func dismiss_packing_confirmation() -> void:
	if popup == "packing_confirmation": popup = ""
	if _packing_callback.is_valid():
		var callback := _packing_callback
		_packing_callback = Callable()
		callback.call(false)

func draggable_tab(action: StringName) -> StringName:
	var command := String(action)
	var id := action if command.begins_with("monitor:") else StringName("browser:page:" + command.trim_prefix("page:"))
	return id if (command.begins_with("monitor:") or command.begins_with("page:")) and _screen.content_tabs.find_tab(id) != null else &""
