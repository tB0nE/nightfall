class_name WelcomeScreen
extends RefCounted

var main: Node3D
var mdns_browsing: bool = false
var wol_sender: WolSender = WolSender.new()

func _init(owner: Node3D):
	main = owner

func build_welcome_ui():
	var root = main.welcome_viewport.get_node("WelcomeRoot")
	for child in root.get_children():
		child.queue_free()

	var twilight_images = ["res://src/assets/early_twilight.png", "res://src/assets/late_twilight.png"]
	var bg = TextureRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.texture = load(twilight_images[randi() % twilight_images.size()])
	bg.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	var screens = Node.new()
	screens.name = "Screens"
	root.add_child(screens)

	build_welcome_screen(screens)
	build_server_screen(screens)
	build_ip_screen(screens)
	build_pin_screen(screens)

	show_welcome_screen("welcome")

func build_welcome_screen(parent: Node):
	var screen = VBoxContainer.new()
	screen.name = "WelcomeScreen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_theme_constant_override("separation", 0)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(screen)

	var top_spacer = Control.new()
	top_spacer.custom_minimum_size = Vector2(0, 120)
	top_spacer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(top_spacer)

	var title = Label.new()
	title.text = "Nightfall"
	title.add_theme_font_size_override("font_size", 72)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "Moonlight Streaming for Quest"
	subtitle.add_theme_font_size_override("font_size", 24)
	subtitle.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(subtitle)

	var mid_spacer = Control.new()
	mid_spacer.custom_minimum_size = Vector2(0, 0)
	mid_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(mid_spacer)

	var server_info = VBoxContainer.new()
	server_info.add_theme_constant_override("separation", 2)
	server_info.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	server_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(server_info)

	var host_label = Label.new()
	host_label.name = "WelcomeHostName"
	host_label.add_theme_font_size_override("font_size", 32)
	host_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	host_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	server_info.add_child(host_label)

	var ip_label = Label.new()
	ip_label.name = "WelcomeHostIP"
	ip_label.add_theme_font_size_override("font_size", 20)
	ip_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	ip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	server_info.add_child(ip_label)

	var btn_spacer = Control.new()
	btn_spacer.custom_minimum_size = Vector2(0, 0)
	btn_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(btn_spacer)

	var pc_icon = TextureRect.new()
	pc_icon.texture = load("res://src/assets/pc_icon.svg")
	pc_icon.custom_minimum_size = Vector2(280, 280)
	pc_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pc_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pc_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pc_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(pc_icon)

	var connect_btn = Button.new()
	connect_btn.name = "WelcomeConnect"
	connect_btn.custom_minimum_size = Vector2(400, 80)
	connect_btn.add_theme_font_size_override("font_size", 32)
	connect_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	connect_btn.text = "Connect"
	screen.add_child(connect_btn)

	var wol_btn = Button.new()
	wol_btn.name = "WelcomeWol"
	wol_btn.custom_minimum_size = Vector2(400, 60)
	wol_btn.add_theme_font_size_override("font_size", 24)
	wol_btn.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0, 0.8))
	wol_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	wol_btn.text = "Wake PC"
	wol_btn.visible = false
	screen.add_child(wol_btn)

	var spacer1 = Control.new()
	spacer1.name = "Spacer1"
	spacer1.custom_minimum_size = Vector2(0, 10)
	spacer1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(spacer1)

	var app_btn = Button.new()
	app_btn.name = "WelcomeAppBtn"
	app_btn.custom_minimum_size = Vector2(400, 60)
	app_btn.add_theme_font_size_override("font_size", 24)
	app_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	app_btn.text = "App: Desktop"
	app_btn.visible = false
	screen.add_child(app_btn)

	var spacer2 = Control.new()
	spacer2.name = "Spacer2"
	spacer2.custom_minimum_size = Vector2(0, 10)
	spacer2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(spacer2)

	var change_btn = Button.new()
	change_btn.name = "WelcomeChangeServer"
	change_btn.custom_minimum_size = Vector2(400, 60)
	change_btn.add_theme_font_size_override("font_size", 24)
	change_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	change_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	change_btn.text = "Select Server"
	change_btn.visible = false
	screen.add_child(change_btn)

	var spacer3 = Control.new()
	spacer3.custom_minimum_size = Vector2(0, 10)
	spacer3.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(spacer3)

	var exit_btn = Button.new()
	exit_btn.name = "WelcomeExit"
	exit_btn.custom_minimum_size = Vector2(400, 60)
	exit_btn.add_theme_font_size_override("font_size", 28)
	exit_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	exit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	exit_btn.text = "Exit"
	screen.add_child(exit_btn)

	var bottom_pad = Control.new()
	bottom_pad.custom_minimum_size = Vector2(0, 40)
	bottom_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_pad)

	connect_btn.pressed.connect(func():
		var btn_text = connect_btn.text
		var current_ip = main.get_node("%IPInput").text
		if btn_text == "Pair" or btn_text == "Select Server":
			show_welcome_screen("server")
		elif btn_text == "Connect" and current_ip.is_empty():
			show_welcome_screen("server")
		else:
			connect_btn.text = "Connecting..."
			connect_btn.disabled = true
			main.start_connect_timeout()
			main.stream_manager.on_pair_pressed()
	)
	wol_btn.pressed.connect(func():
		var current_ip = main.get_node("%IPInput").text
		var mac = _get_host_mac(current_ip)
		if mac.is_empty():
			main._log("[WOL] No MAC address found for " + current_ip)
			wol_btn.text = "No MAC"
			return
		main._log("[WOL] Sending WoL to " + mac + " via " + current_ip)
		wol_sender.send_wol_to_host(mac, current_ip)
		wol_btn.text = "Sent!"
		await main.get_tree().create_timer(2.0).timeout
		wol_btn.text = "Wake PC"
	)
	change_btn.pressed.connect(func(): show_welcome_screen("server"))
	app_btn.button_down.connect(func(): cycle_app())
	exit_btn.pressed.connect(func(): main.get_tree().quit())

func build_server_screen(parent: Node):
	var screen = VBoxContainer.new()
	screen.name = "ServerScreen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_theme_constant_override("separation", 0)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	parent.add_child(screen)

	var top_spacer = Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(top_spacer)

	var heading = Label.new()
	heading.text = "Select Server"
	heading.add_theme_font_size_override("font_size", 48)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(heading)

	var list_spacer = Control.new()
	list_spacer.custom_minimum_size = Vector2(0, 40)
	list_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(list_spacer)

	var server_list = VBoxContainer.new()
	server_list.name = "ServerList"
	server_list.add_theme_constant_override("separation", 12)
	server_list.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	server_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(server_list)

	var discover_list = VBoxContainer.new()
	discover_list.name = "DiscoverList"
	discover_list.add_theme_constant_override("separation", 8)
	discover_list.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	discover_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(discover_list)

	var scan_btn = Button.new()
	scan_btn.name = "ScanBtn"
	scan_btn.custom_minimum_size = Vector2(400, 70)
	scan_btn.add_theme_font_size_override("font_size", 28)
	scan_btn.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1.0))
	scan_btn.text = "Scan Network"
	scan_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(scan_btn)

	var add_btn = Button.new()
	add_btn.name = "AddServerBtn"
	add_btn.custom_minimum_size = Vector2(400, 80)
	add_btn.add_theme_font_size_override("font_size", 36)
	add_btn.text = "+"
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(add_btn)

	var bottom_spacer = Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_spacer)

	var clear_btn = Button.new()
	clear_btn.name = "ClearServersBtn"
	clear_btn.custom_minimum_size = Vector2(400, 60)
	clear_btn.add_theme_font_size_override("font_size", 24)
	clear_btn.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5, 1.0))
	clear_btn.text = "Clear Saved Servers"
	clear_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(clear_btn)

	var clear_spacer = Control.new()
	clear_spacer.custom_minimum_size = Vector2(0, 16)
	clear_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(clear_spacer)

	var back_btn = Button.new()
	back_btn.custom_minimum_size = Vector2(300, 60)
	back_btn.add_theme_font_size_override("font_size", 28)
	back_btn.text = "Back"
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(back_btn)

	var bottom_margin = Control.new()
	bottom_margin.custom_minimum_size = Vector2(0, 40)
	bottom_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_margin)

	add_btn.pressed.connect(func(): show_welcome_screen("ip"))
	scan_btn.pressed.connect(func(): browse_mdns())
	clear_btn.pressed.connect(func(): clear_saved_servers())
	back_btn.pressed.connect(func(): show_welcome_screen("welcome"))

func build_ip_screen(parent: Node):
	var screen = VBoxContainer.new()
	screen.name = "IPScreen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_theme_constant_override("separation", 0)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	parent.add_child(screen)

	var top_spacer = Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(top_spacer)

	var heading = Label.new()
	heading.text = "Enter Server IP"
	heading.add_theme_font_size_override("font_size", 48)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(heading)

	var ip_spacer = Control.new()
	ip_spacer.custom_minimum_size = Vector2(0, 40)
	ip_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(ip_spacer)

	var ip_center = HBoxContainer.new()
	ip_center.alignment = BoxContainer.ALIGNMENT_CENTER
	ip_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(ip_center)

	var ip_input = LineEdit.new()
	ip_input.name = "IPField"
	ip_input.custom_minimum_size = Vector2(600, 80)
	ip_input.add_theme_font_size_override("font_size", 36)
	ip_input.placeholder_text = "e.g. 192.168.1.100"
	ip_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	ip_center.add_child(ip_input)

	var numpad_spacer = Control.new()
	numpad_spacer.custom_minimum_size = Vector2(0, 30)
	numpad_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(numpad_spacer)

	var numpad_center = CenterContainer.new()
	numpad_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(numpad_center)

	var numpad = GridContainer.new()
	numpad.name = "IPNumpad"
	numpad.columns = 3
	numpad.add_theme_constant_override("h_separation", 8)
	numpad.add_theme_constant_override("v_separation", 8)
	numpad_center.add_child(numpad)

	var keys = ["7","8","9","4","5","6","1","2","3",".","0","DEL"]
	for key in keys:
		var btn = Button.new()
		btn.text = key
		btn.custom_minimum_size = Vector2(120, 80)
		btn.add_theme_font_size_override("font_size", 36)
		numpad.add_child(btn)
		btn.pressed.connect(func():
			var text = ip_input.text
			if key == "DEL":
				if text.length() > 0:
					ip_input.text = text.substr(0, text.length() - 1)
			elif text.length() < 15:
				ip_input.text = text + key
		)

	var btn_spacer = Control.new()
	btn_spacer.custom_minimum_size = Vector2(0, 30)
	btn_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(btn_spacer)

	var pair_btn = Button.new()
	pair_btn.name = "PairBtn"
	pair_btn.custom_minimum_size = Vector2(400, 90)
	pair_btn.add_theme_font_size_override("font_size", 36)
	pair_btn.text = "Pair"
	pair_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(pair_btn)

	var bottom_spacer = Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_spacer)

	var back_btn = Button.new()
	back_btn.custom_minimum_size = Vector2(300, 60)
	back_btn.add_theme_font_size_override("font_size", 28)
	back_btn.text = "Back"
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(back_btn)

	var bottom_margin = Control.new()
	bottom_margin.custom_minimum_size = Vector2(0, 40)
	bottom_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_margin)

	pair_btn.pressed.connect(func():
		var ip = ip_input.text
		if ip.is_empty():
			return
		main._connecting_ip = ip
		main.get_node("%IPInput").text = ip
		start_pair(ip)
	)
	back_btn.pressed.connect(func(): show_welcome_screen("server"))

func build_pin_screen(parent: Node):
	var screen = VBoxContainer.new()
	screen.name = "PINScreen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_theme_constant_override("separation", 0)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	parent.add_child(screen)

	var top_spacer = Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(top_spacer)

	var heading = Label.new()
	heading.text = "Enter PIN on Host"
	heading.add_theme_font_size_override("font_size", 40)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(heading)

	var pin_spacer = Control.new()
	pin_spacer.custom_minimum_size = Vector2(0, 40)
	pin_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(pin_spacer)

	var pin_label = Label.new()
	pin_label.name = "PINLabel"
	pin_label.add_theme_font_size_override("font_size", 80)
	pin_label.add_theme_color_override("font_color", Color(0.4, 0.7, 1, 1))
	pin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pin_label.text = "----"
	pin_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(pin_label)

	var bottom_spacer = Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_spacer)

	var back_btn = Button.new()
	back_btn.custom_minimum_size = Vector2(400, 90)
	back_btn.add_theme_font_size_override("font_size", 36)
	back_btn.text = "Back"
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	screen.add_child(back_btn)

	var bottom_margin = Control.new()
	bottom_margin.custom_minimum_size = Vector2(0, 40)
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bottom_margin)

	back_btn.pressed.connect(func(): show_welcome_screen("server"))

const WELCOME_FRAME := Vector2i(1920, 1080)

func show_welcome_screen(name: String):
	main._welcome_screen = name
	# The welcome UI is rendered on the same shared mesh/material as the stream
	# (see main.gd's comp_shader_mat main_texture reuse), and several code paths
	# can leave that mesh in a non-16:9 state that main.layout doesn't reflect:
	# a multi-monitor stream attempt that reshapes it before the connection
	# outcome is known, or load_host_state() restoring a saved per-screen
	# mesh_size/position directly onto main.screens without ever touching
	# main.layout. Checking main.layout.frame_size alone can silently miss
	# both, so force this back to a fixed 16:9 unconditionally instead of
	# trying to detect every way it could have drifted - this function is only
	# ever shown while not actively streaming, and apply_screen_layout() is
	# cheap enough to call on every navigation click.
	if not main.is_streaming:
		main.settings_controller.apply_screen_layout(ScreenLayout.single(WELCOME_FRAME))
	var root = main.welcome_viewport.get_node("WelcomeRoot/Screens")
	for child in root.get_children():
		child.visible = false
	match name:
		"welcome":
			root.get_node_or_null("WelcomeScreen").visible = true
			update_welcome_info()
		"server":
			root.get_node_or_null("ServerScreen").visible = true
			populate_server_list()
		"ip":
			root.get_node_or_null("IPScreen").visible = true
		"pin":
			var pin_screen = root.get_node_or_null("PINScreen")
			if pin_screen:
				pin_screen.visible = true
			var pin_label = root.get_node_or_null("PINScreen/PINLabel")
			if pin_label:
				pin_label.text = main._pair_pin if not main._pair_pin.is_empty() else "----"

func update_welcome_info():
	var root = main.welcome_viewport.get_node_or_null("WelcomeRoot")
	if not root:
		return
	var screens = root.get_node_or_null("Screens")
	if not screens:
		return
	var ws = screens.get_node_or_null("WelcomeScreen")
	if not ws:
		return
	var host_label = ws.get_node_or_null("WelcomeHostName")
	var ip_label = ws.get_node_or_null("WelcomeHostIP")
	var connect_btn = ws.get_node_or_null("WelcomeConnect")
	var app_btn = ws.get_node_or_null("WelcomeAppBtn")
	var change_btn = ws.get_node_or_null("WelcomeChangeServer")
	var wol_btn = ws.get_node_or_null("WelcomeWol")
	var spacer1 = ws.get_node_or_null("Spacer1")
	var spacer2 = ws.get_node_or_null("Spacer2")

	var saved_ip = main.get_node("%IPInput").text
	var has_saved = not saved_ip.is_empty()
	var _cm = main.stream_backend.get_config_manager() if main.stream_backend else null
	var _hosts = _cm.get_hosts() if _cm else []
	var has_hosts = _hosts.size() > 0

	var host_name = main._last_hostname
	if host_name.is_empty():
		for h in _hosts:
			if h.has("localaddress") and h.localaddress == saved_ip:
				var hname = h.get("hostname", "")
				if hname != saved_ip and not hname.is_empty():
					host_name = hname
				break

	if has_saved:
		if connect_btn and connect_btn.text != "Connecting...":
			connect_btn.text = "Connect"
			connect_btn.disabled = false
		if not host_name.is_empty():
			if host_label: host_label.text = host_name
			if ip_label: ip_label.text = saved_ip
		else:
			if host_label: host_label.text = saved_ip
			if ip_label: ip_label.text = ""
		if app_btn: app_btn.visible = true
		if change_btn: change_btn.visible = true
		if spacer1: spacer1.visible = true
		if spacer2: spacer2.visible = true
		var has_mac = not _get_host_mac(saved_ip).is_empty()
		if wol_btn: wol_btn.visible = has_mac
		if main.current_host_id >= 0:
			query_app_list()
		elif not main._available_apps.is_empty():
			if app_btn: app_btn.text = "App: %s" % main._available_apps[main._selected_app_idx].get("name", "Desktop")
	else:
		if has_hosts:
			if connect_btn: connect_btn.text = "Connect"
		else:
			if connect_btn: connect_btn.text = "Pair"
		if host_label: host_label.text = ""
		if ip_label: ip_label.text = ""
		if app_btn: app_btn.visible = false
		if change_btn: change_btn.visible = true
		if wol_btn: wol_btn.visible = false
		if spacer1: spacer1.visible = false
		if spacer2: spacer2.visible = true

func reset_connect_button():
	var root = main.welcome_viewport.get_node_or_null("WelcomeRoot")
	if not root:
		return
	var screens = root.get_node_or_null("Screens")
	if not screens:
		return
	var ws = screens.get_node_or_null("WelcomeScreen")
	if not ws:
		return
	var connect_btn = ws.get_node_or_null("WelcomeConnect")
	if connect_btn:
		connect_btn.text = "Connect"
		connect_btn.disabled = false

func save_last_ip(ip: String):
	var save = ConfigFile.new()
	save.set_value("connection", "ip", ip)
	save.save("user://last_connection.cfg")

func browse_mdns():
	if mdns_browsing:
		return
	mdns_browsing = true
	var ss = main.welcome_viewport.get_node_or_null("WelcomeRoot/Screens/ServerScreen")
	if not ss:
		mdns_browsing = false
		return
	var discover_list = ss.get_node_or_null("DiscoverList")
	var scan_btn = ss.get_node_or_null("ScanBtn")
	if discover_list:
		for child in discover_list.get_children():
			child.queue_free()
	if scan_btn:
		scan_btn.text = "Scanning..."
		scan_btn.disabled = true
	var hosts = await main.stream_manager.browse_mdns()
	if discover_list:
		for child in discover_list.get_children():
			child.queue_free()
	if hosts.size() > 0 and discover_list:
		for host in hosts:
			var ip = host.get("ip", "")
			var friendly = host.get("friendly_name", host.get("hostname", ip))
			main._log("[mDNS] Discovered: ip='" + ip + "' friendly='" + friendly + "' port=" + str(host.get("port", "?")))
			var btn = Button.new()
			btn.custom_minimum_size = Vector2(400, 60)
			btn.add_theme_font_size_override("font_size", 22)
			btn.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0, 1.0))
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			btn.text = friendly + "  " + ip
			var btn_style = StyleBoxFlat.new()
			btn_style.set_bg_color(Color(0.15, 0.18, 0.25, 0.9))
			btn_style.set_border_width_all(1)
			btn_style.set_border_color(Color(0.3, 0.4, 0.6, 0.8))
			btn_style.set_corner_radius_all(8)
			btn_style.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", btn_style)
			var hover_style = btn_style.duplicate()
			hover_style.set_bg_color(Color(0.2, 0.25, 0.35, 1.0))
			btn.add_theme_stylebox_override("hover", hover_style)
			var press_style = btn_style.duplicate()
			press_style.set_bg_color(Color(0.3, 0.35, 0.5, 1.0))
			btn.add_theme_stylebox_override("pressed", press_style)
			btn.pressed.connect(func():
				main._log("[mDNS] Selected host: ip='" + ip + "' friendly='" + friendly + "'")
				main.get_node("%IPInput").text = ip
				save_last_ip(ip)
				main.state_manager.load_host_state(ip)
				var _cm4 = main.stream_backend.get_config_manager() if main.stream_backend else null
				var found_host = false
				for h in (_cm4.get_hosts() if _cm4 else []):
					if h.has("localaddress") and h.localaddress == ip:
						main.current_host_id = h.id
						found_host = true
						break
				if found_host:
					show_welcome_screen("welcome")
				else:
					start_pair(ip)
			)
			discover_list.add_child(btn)
	if scan_btn:
		scan_btn.text = "Scan Network"
		scan_btn.disabled = false
	mdns_browsing = false

func populate_server_list():
	var screens = main.welcome_viewport.get_node("WelcomeRoot/Screens")
	var ss = screens.get_node("ServerScreen")
	var server_list = ss.get_node("ServerList")
	for child in server_list.get_children():
		child.queue_free()

	var _cm2 = main.stream_backend.get_config_manager() if main.stream_backend else null
	var hosts = _cm2.get_hosts() if _cm2 else []
	for h in hosts:
		var ip = h.get("localaddress", "")
		var hname = h.get("hostname", "")
		if hname == ip:
			hname = ""
		var display = hname if not hname.is_empty() else ip
		var btn = Button.new()
		btn.custom_minimum_size = Vector2(400, 80)
		btn.add_theme_font_size_override("font_size", 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.text = display
		server_list.add_child(btn)
		btn.pressed.connect(func():
			main.get_node("%IPInput").text = ip
			save_last_ip(ip)
			main.state_manager.load_host_state(ip)
			main.current_host_id = h.id
			show_welcome_screen("welcome")
		)

func clear_saved_servers():
	var _cm = main.stream_backend.get_config_manager() if main.stream_backend else null
	if _cm:
		_cm.clear_hosts()
		main._log("[PAIR] Cleared all saved server pairings")
	populate_server_list()
	var screens = main.welcome_viewport.get_node_or_null("WelcomeRoot/Screens")
	if screens:
		var ws = screens.get_node_or_null("WelcomeScreen")
		if ws:
			var connect_btn = ws.get_node_or_null("WelcomeConnect")
			if connect_btn:
				connect_btn.text = "Connect"
				connect_btn.disabled = false

func start_pair(ip: String):
	main.get_node("%IPInput").text = ip
	main._log("[PAIR] Starting pair with %s:47989..." % ip)
	var pin = main.stream_backend.start_pair(ip, 47989)
	main._log("[PAIR] start_pair returned: %s" % str(pin))
	if str(pin) == "" or str(pin) == "0":
		main._log("[PAIR] FAILED - no pin returned")
		return
	main._pair_pin = str(pin)
	show_welcome_screen("pin")

func cycle_app():
	if main._available_apps.is_empty():
		return
	main._selected_app_idx = (main._selected_app_idx + 1) % main._available_apps.size()
	main._selected_app_id = main._available_apps[main._selected_app_idx].get("id", 881448767)
	var app_name = main._available_apps[main._selected_app_idx].get("name", "Desktop")
	var screens = main.welcome_viewport.get_node_or_null("WelcomeRoot/Screens")
	if not screens:
		return
	var app_btn = screens.get_node_or_null("WelcomeScreen/WelcomeAppBtn")
	if app_btn:
		app_btn.text = "App: %s" % app_name

func query_app_list():
	if main.current_host_id < 0:
		return
	main.stream_backend.get_app_list(main.current_host_id, func(success: bool):
		if success:
			var _cm3 = main.stream_backend.get_config_manager() if main.stream_backend else null
			main._available_apps = _cm3.get_apps(main.current_host_id) if _cm3 else []
			if main._available_apps.is_empty():
				main._available_apps = [{"name": "Desktop", "id": 881448767}]
			main._selected_app_idx = 0
			main._selected_app_id = main._available_apps[0].get("id", 881448767)
			var app_name = main._available_apps[0].get("name", "Desktop")
			var screens = main.welcome_viewport.get_node_or_null("WelcomeRoot/Screens")
			if screens:
				var app_btn = screens.get_node_or_null("WelcomeScreen/WelcomeAppBtn")
				if app_btn:
					app_btn.text = "App: %s" % app_name
					app_btn.visible = true
	)

func _get_host_mac(ip: String) -> String:
	var _cm = main.stream_backend.get_config_manager() if main.stream_backend else null
	var hosts = _cm.get_hosts() if _cm else []
	for h in hosts:
		if h.has("localaddress") and h.localaddress == ip:
			var mac = h.get("mac", "")
			if not mac.is_empty() and mac != "00:00:00:00:00:00":
				return mac
	return ""
