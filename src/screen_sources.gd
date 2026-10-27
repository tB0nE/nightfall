class_name ScreenSources
extends RefCounted

# Browser screens share the physical-screen budget with host outputs. Each
# browser slot owns its surface and tabs; only the primary runs local inference.
signal changed

const PRIMARY_BROWSER: StringName = &"browser:primary"
const MAX_BROWSER_SCREENS := ScreenRegistry.MAX_SCREENS
var main: Node3D
var browser_supported: bool
var _browsers: Dictionary = {}
var _menus: Dictionary = {}
var _focused_browser: RefCounted
var _browser_uploaders: Dictionary = {}
var switching_primary := false

func stream_screen() -> VRScreen:
	for screen in main.screens:
		var provider := browser_for_screen(screen)
		if provider == null or (not provider.active and not provider.closing):
			return screen
	return null

func can_add_stream_screen() -> bool:
	return can_offer_stream_screen() and main.screens.size() < MAX_BROWSER_SCREENS

func can_offer_stream_screen() -> bool:
	return browser_supported and not switching_primary and not main.is_streaming \
		and not main.browser_prototype.closing \
		and stream_screen() == null \
		and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT,
			SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED]

func add_stream_screen() -> void:
	if not can_add_stream_screen(): return
	var screen: VRScreen = main.add_screen(&"stream:welcome", INF, true)
	if screen != null:
		if await make_primary(screen):
			main.welcome_screen.show_welcome_screen("welcome")
			changed.emit()
		else:
			main.remove_screen(screen.monitor_id)

func can_make_primary(screen: VRScreen) -> bool:
	if switching_primary or main.browser_prototype.closing or screen == null or screen == main.primary_screen or not main.screens.has(screen): return false
	# The current PC renderer still owns primary for a connected session.
	if main.is_streaming or main.session_lifecycle.phase not in [SessionLifecycle.Phase.BOOT,
		SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED]: return false
	var provider := browser_for_screen(screen)
	return provider == null or (not provider.closing and (not provider.active or provider.texture != null))

func make_primary(screen: VRScreen, connecting: bool = false) -> bool:
	var restoring_connection: bool = connecting and not switching_primary and screen != null \
		and screen == stream_screen() and screen != main.primary_screen and not main.is_streaming
	if not restoring_connection and not can_make_primary(screen): return false
	switching_primary = true
	main.xr_interaction.cancel_transient_interactions("primary screen changed")
	main.depth_estimator.set_enabled(false)
	main.video_presentation.deactivate_native(false)
	var previous: VRScreen = main.primary_screen
	_menus[previous.get_instance_id()] = main.screen_tab_strip
	# Retire old stereo consumers before moving shared depth/native ownership.
	for layer in [previous.comp_cylinder_left, previous.comp_cylinder_right]:
		if layer: layer.visible = false
	for viewport in [previous.comp_viewport_left, previous.comp_viewport_right]:
		if viewport: viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	await _wait_for_primary_drain()
	if not is_instance_valid(screen) or not main.screens.has(screen):
		switching_primary = false
		main.settings_controller.apply_stereo()
		return false
	var provider := browser_for_screen(screen)
	if provider != null and provider.closing:
		switching_primary = false
		main.settings_controller.apply_stereo()
		return false
	if provider == null:
		provider = _menus[screen.get_instance_id()].browser if _menus.has(screen.get_instance_id()) else preload("res://src/browser_prototype.gd").new(main, screen, -1)
	provider.screen = screen
	main.set_primary_screen(screen)
	main.browser_prototype = provider
	if not _menus.has(screen.get_instance_id()):
		_menus[screen.get_instance_id()] = ScreenTabStrip.new(main, screen, provider)
	main.screen_tab_strip = _menus[screen.get_instance_id()]
	if screen.comp_corner_viewport:
		main.screen_tab_strip.attach(screen, screen.comp_corner_viewport)
	main.comp.ensure_stereo_layers(screen)
	if provider.active:
		provider.bind_texture()
		focus_browser(provider)
	else:
		focus_browser(null)
		provider.bind_texture()
	switching_primary = false
	main.comp.invalidate_yuv_cache()
	main.settings_controller.apply_stereo()
	changed.emit()
	return true

func _wait_for_primary_drain() -> void:
	for _frame in range(3): await main.get_tree().process_frame
	await RenderingServer.frame_post_draw

func register_browser(screen: VRScreen, provider: RefCounted) -> void:
	for key in _browsers.keys():
		if _browsers[key] == provider and key != screen.get_instance_id(): _browsers.erase(key)
	_browsers[screen.get_instance_id()] = provider
	provider.screen = screen
	if provider.get("uploader") != null: _browser_uploaders[provider.browser_id] = provider.uploader
	screen.set_meta(&"nf_browser_screen", true)

func browser_for_screen(screen: VRScreen) -> RefCounted:
	if screen == null: return null
	if _browsers.has(screen.get_instance_id()): return _browsers[screen.get_instance_id()]
	return main.browser_prototype if screen == main.primary_screen else null

func is_browser_screen(screen: VRScreen) -> bool:
	var provider := browser_for_screen(screen)
	return provider != null and provider.active

func menu_for_screen(screen: VRScreen) -> ScreenTabStrip:
	if screen == main.primary_screen: return main.screen_tab_strip
	if _menus.has(screen.get_instance_id()): return _menus[screen.get_instance_id()]
	var provider := browser_for_screen(screen)
	if provider == null: return null
	if not _menus.has(screen.get_instance_id()):
		_menus[screen.get_instance_id()] = ScreenTabStrip.new(main, screen, provider)
	return _menus[screen.get_instance_id()]

func focused_browser() -> RefCounted:
	return _focused_browser if _focused_browser != null and _focused_browser.active else main.browser_prototype

func focus_browser(provider: RefCounted) -> void:
	if provider == _focused_browser: return
	if _focused_browser != null:
		_focused_browser.cancel_pointer()
		_focused_browser.clear_gamepad()
		_focused_browser.release_keys()
	if provider != null and main.is_streaming and main.get("input_handler") != null:
		main.input_handler.neutral_host_gamepads()
	_focused_browser = provider
	if main.has_method("_reset_steady_filter"): main._reset_steady_filter()
	if provider != null:
		var bridge = provider._gamepad_bridge()
		if bridge: bridge.browserFocus(provider.browser_id)
	elif main.browser_prototype != null:
		var bridge = main.browser_prototype._gamepad_bridge()
		if bridge: bridge.browserFocus(-1)

func begin_pointer_frame() -> void:
	main.screen_tab_strip.begin_pointer_frame()
	for menu in _menus.values():
		if menu != main.screen_tab_strip: menu.begin_pointer_frame()

func cancel_browser_pointers_except(screen: VRScreen = null) -> void:
	for provider in _browsers.values():
		if provider.screen != screen: provider.cancel_pointer()

func can_add_browser_screen() -> bool:
	return browser_supported and not switching_primary and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT,
		SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED, SessionLifecycle.Phase.STREAMING] \
		and not main.browser_prototype.closing and main.screens.size() < MAX_BROWSER_SCREENS \
		and _free_browser_slot() >= 0

func _free_browser_slot() -> int:
	var used := {}
	if main.browser_prototype.browser_id >= 0: used[main.browser_prototype.browser_id] = true
	for provider in _browsers.values(): used[provider.browser_id] = true
	for id in range(0, MAX_BROWSER_SCREENS):
		if not used.has(id): return id
	return -1

func allocate_primary_browser_slot(provider: RefCounted) -> bool:
	if provider.browser_id >= 0: return true
	var id := _free_browser_slot()
	if id < 0: return false
	provider.browser_id = id
	provider.uploader = _browser_uploaders.get(id)
	return true

static func browser_grid_offset(id: int) -> Vector2i:
	match id:
		1: return Vector2i(MonitorGrid.SPAN, 0)
		2: return Vector2i(-MonitorGrid.SPAN, 0)
		3: return Vector2i(0, -MonitorGrid.SPAN)
	return Vector2i.ZERO

func add_browser_screen() -> bool:
	if not can_add_browser_screen(): return false
	var id := _free_browser_slot()
	var provider: RefCounted = preload("res://src/browser_prototype.gd").new(main, null, id)
	provider.uploader = _browser_uploaders.get(id)
	var screen: VRScreen = main.add_screen(StringName("browser-screen:%d" % provider.browser_id), INF, false, provider)
	if screen == null: return false
	if main.primary_screen.grid_pos != Vector2i(-1, -1):
		var cell := Vector2i(-1, -1)
		for offset in [browser_grid_offset(id), Vector2i(MonitorGrid.SPAN, 0),
			Vector2i(-MonitorGrid.SPAN, 0), Vector2i(0, -MonitorGrid.SPAN), Vector2i(0, MonitorGrid.SPAN)]:
			var candidate: Vector2i = main.primary_screen.grid_pos + offset
			if offset == Vector2i.ZERO or not MonitorGrid.cell_in_bounds(candidate.x, candidate.y): continue
			var occupied := false
			for existing in main.screens:
				if existing != screen and existing.grid_pos == candidate: occupied = true
			if not occupied:
				cell = candidate
				break
		if cell != Vector2i(-1, -1):
			screen.grid_pos = cell
			screen.grid_mode = main.primary_screen.grid_mode
			screen.global_transform = main.grid_cell_transform(cell.x, cell.y,
				main.primary_screen.grid_pos.x, main.primary_screen.grid_pos.y)
		else:
			# add_screen already placed it beside/above its neighbours. Keep
			# that free placement instead of recording an invalid grid cell.
			screen.grid_mode = false
			screen.grid_pos = Vector2i(-1, -1)
	provider.start()
	_browser_uploaders[id] = provider.uploader
	focus_browser(provider)
	changed.emit()
	return provider.active

func process_secondary_browsers() -> void:
	for provider in _browsers.values().duplicate():
		if provider != main.browser_prototype: provider.process()

func stop_secondary_browsers() -> void:
	for provider in _browsers.values().duplicate():
		if provider != main.browser_prototype: provider.stop()

func remove_browser_screen(screen: VRScreen) -> void:
	var provider := browser_for_screen(screen)
	if _focused_browser == provider: focus_browser(main.browser_prototype)
	_browsers.erase(screen.get_instance_id())
	_menus.erase(screen.get_instance_id())
	main.remove_screen(screen.monitor_id)
	# Retain the small uploader object so its deferred render-thread cleanup
	# cannot target a destroyed RefCounted. Reuse it rather than leaking one
	# full-resolution surface for every new/closed browser screen.
	var uploader: RefCounted = _browser_uploaders.get(provider.browser_id) if provider != null else null
	if uploader: uploader.cleanup()
	changed.emit()

func _init(owner: Node3D, platform: String = "") -> void:
	main = owner
	browser_supported = (OS.get_name() if platform.is_empty() else platform) == "Android"

func can_open_browser() -> bool:
	return browser_supported and not switching_primary and not main.browser_prototype.closing and not main.is_streaming \
		and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT,
			SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED]

func choose_source(kind: StringName) -> bool:
	if kind == ScreenContentTab.BROWSER:
		if not can_open_browser():
			return false
		main.browser_prototype.start()
		return main.browser_prototype.active
	if kind == ScreenContentTab.STREAM:
		# Returning to the PC/welcome source closes the browser tab. This is
		# explicitly not hidden-tab suspension or a PC reconnect operation.
		main.browser_prototype.stop()
		return true
	return false

func browser_opened(provider: RefCounted = null) -> void:
	var screen: VRScreen = provider.screen if provider != null else main.primary_screen
	if screen == null:
		return
	var tabs := screen.content_tabs
	if tabs.tabs.is_empty() and screen == main.primary_screen:
		tabs.add(ScreenContentTab.for_monitor(screen.monitor_id))
	if tabs.find_tab(PRIMARY_BROWSER) == null:
		var tab := ScreenContentTab.new()
		tab.id = PRIMARY_BROWSER
		tab.kind = ScreenContentTab.BROWSER
		tab.title = "Browser"
		# Session-only identity. Do not copy navigation URLs or credentials
		# into diagnostics/workspace persistence as part of this milestone.
		tab.locator = {"url": "about:blank"}
		tabs.add(tab)
	else:
		tabs.select(PRIMARY_BROWSER)
	changed.emit()

func browser_closed() -> void:
	if main.primary_screen:
		var tabs: ScreenContentTabs = main.primary_screen.content_tabs
		for tab in tabs.tabs.duplicate():
			if tab.kind == ScreenContentTab.BROWSER:
				tabs.remove(tab.id)
	changed.emit()

func sync_browser_pages(pages: Array, selected: int, screen: VRScreen = null) -> void:
	if screen == null: screen = main.primary_screen
	if screen == null or pages.is_empty():
		return
	var tabs: ScreenContentTabs = screen.content_tabs
	var keep := {}
	for page in pages:
		if not page is Dictionary or int(page.get("id", 0)) <= 0:
			continue
		var id := StringName("browser:page:%d" % int(page.id))
		keep[id] = true
		var tab: ScreenContentTab = tabs.find_tab(id)
		if tab == null:
			tab = ScreenContentTab.new()
			tab.id = id
			tab.kind = ScreenContentTab.BROWSER
			tab.locator = {"url": "about:blank"}
			tabs.add(tab, false)
		tab.title = str(page.get("title", "Browser"))
	for tab in tabs.tabs.duplicate():
		if tab.kind == ScreenContentTab.BROWSER and not keep.has(tab.id):
			tabs.remove(tab.id)
	tabs.select(StringName("browser:page:%d" % selected))
	changed.emit()
