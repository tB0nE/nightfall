extends RefCounted

const COLUMNS := 4
const PER_PAGE := 8
var welcome: RefCounted
var _host_entries: Array = []
var discovered: Array = []
var _entries: Array = []
var _page := 0
var _grid: GridContainer
var _previous: Button
var _next: Button
var _page_label: Label
var _scan: Button
var _selected_id := -1

func _init(owner: RefCounted): welcome = owner

func build(parent: Node) -> void:
	var screen := VBoxContainer.new()
	screen.name = "ServerScreen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	parent.add_child(screen)
	_spacer(screen,0,true)
	var heading := Label.new()
	heading.text = "Select Server"
	heading.add_theme_font_size_override("font_size",48)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(heading)
	_spacer(screen,24)
	_grid = GridContainer.new()
	_grid.name = "ServerList"
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.add_theme_constant_override("h_separation",24)
	_grid.add_theme_constant_override("v_separation",16)
	screen.add_child(_grid)
	_spacer(screen,20)
	var pages := _row(screen)
	_previous = _button(pages,"Previous",func(): _show_page(_page-1))
	_page_label = Label.new()
	_page_label.custom_minimum_size = Vector2(140,60)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_page_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pages.add_child(_page_label)
	_next = _button(pages,"Next",func(): _show_page(_page+1))
	_spacer(screen,16)
	var actions := _row(screen)
	_scan = _button(actions,"Scan Network",func(): welcome.browse_mdns())
	_scan.name = "ScanBtn"
	_button(actions,"+",func(): welcome.show_welcome_screen("ip")).name = "AddServerBtn"
	_spacer(screen,0,true)
	_button(screen,"Clear Saved Servers",func(): welcome.clear_saved_servers()).name = "ClearServersBtn"
	_spacer(screen,12)
	_button(screen,"Back",func(): welcome.show_welcome_screen("welcome"))
	_spacer(screen,36)

func refresh(hosts: Array, selected_id: int, usb: bool) -> void:
	_selected_id = selected_id
	_host_entries.clear()
	for host in hosts:
		var ip := str(host.get("localaddress",""))
		var name := str(host.get("hostname",ip))
		var port := int(host.get("https_port",47984))
		var address := "%s:%d" % [ip,port]
		if usb and not str(host.get("usb_address","")).is_empty(): address += "  [USB]"
		_host_entries.append({"host":host,"saved":true,"name":name,"address":address})
	_rebuild()

func set_discovered(hosts: Array) -> void:
	discovered = hosts.duplicate(true)
	_rebuild()

func set_scanning(value: bool) -> void:
	_scan.disabled = value
	_scan.text = "Scanning..." if value else "Scan Network"

func _rebuild() -> void:
	_entries = _host_entries.duplicate()
	for host in discovered:
		var ip := str(host.get("ip",""))
		var port := int(host.get("port",47989))
		var known := false
		for saved in _host_entries:
			if str(saved.host.get("localaddress","")) == ip and int(saved.host.get("https_port",47984))+5 == port: known = true
		if not known:
			_entries.append({"host":host,"saved":false,"name":str(host.get("friendly_name",host.get("hostname",ip))),"address":welcome.pair_address(ip,port)})
	_show_page(_page)

func _show_page(page: int) -> void:
	var count := maxi(1,ceili(float(_entries.size())/PER_PAGE))
	_page = clampi(page,0,count-1)
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	for index in range(_page*PER_PAGE,mini((_page+1)*PER_PAGE,_entries.size())):
		_grid.add_child(_card(_entries[index]))
	_page_label.text = "%d / %d" % [_page+1,count]
	_previous.disabled = _page == 0
	_next.disabled = _page == count-1

func _card(entry: Dictionary) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(310,280)
	card.focus_mode = Control.FOCUS_NONE
	card.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10,0.12,0.18,0.9)
	style.set_corner_radius_all(10)
	style.border_color = Color(0.6,0.57,1,1) if entry.saved and int(entry.host.get("id",-1)) == _selected_id else Color(0.25,0.28,0.38,0.8)
	style.set_border_width_all(3)
	card.add_theme_stylebox_override("normal",style)
	var hover := style.duplicate()
	hover.bg_color = Color(0.23,0.23,0.36,0.95)
	card.add_theme_stylebox_override("hover",hover)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation",8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)
	var icon := TextureRect.new()
	icon.texture = preload("res://src/assets/pc_icon.svg")
	icon.custom_minimum_size = Vector2(120,130)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icon)
	for text in [entry.name,entry.address]:
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override("font_size",26 if text == entry.name else 20)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.max_lines_visible = 2
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(label)
	card.pressed.connect(func():
		if entry.saved: welcome.select_saved_server(entry.host)
		else: welcome.select_discovered_server(entry.host))
	return card

func _row(parent: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_theme_constant_override("separation",20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	return row

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(300,60)
	button.add_theme_font_size_override("font_size",26)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _spacer(parent: Node,height: int,expand := false) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = height
	if expand: spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(spacer)
