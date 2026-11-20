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
var _focus_initialized := false
var _focused_browser: RefCounted
var _browser_uploaders: Dictionary = {}
var switching_primary := false
var switching_tab := false
var _tab_stream_session := {}
var _adding_monitor := false
var virtual_sizes: Array[Vector2i] = []
var _virtual_sizes_host: Variant = null
var _browser_after_monitor_close: RefCounted

func preserves_browser_on_stream_close() -> bool:
	# Parking the desktop for a browser tab is not closing the workspace.
	# Welcome's single-output layout would otherwise discard retained monitor
	# tabs and recreate them as independent screens on reconnect.
	return _browser_after_monitor_close != null or (switching_tab and not _tab_stream_session.is_empty())

static func valid_virtual_size(size: Vector2i) -> bool:
	return size == Vector2i.ZERO or (size.x >= 320 and size.y >= 240 and size.x <= 8192 and size.y <= 8192 and size.x % 2 == 0 and size.y % 2 == 0 and size.x * size.y <= 35389440)

func virtual_modes_query(count: int) -> String:
	if _virtual_sizes_host != main.get("current_host_id"): return ""
	var values := PackedStringArray()
	var custom := false
	for index in count:
		var size := virtual_sizes[index] if index < virtual_sizes.size() else Vector2i.ZERO
		custom = custom or size != Vector2i.ZERO
		values.append("%dx%d" % [size.x, size.y])
	return ",".join(values) if custom else ""

func _virtual_index(screen: VRScreen) -> int:
	var layout = main.get("layout")
	if layout == null: return -1
	for monitor in layout.monitors:
		if monitor.id == screen.monitor_id and monitor.hint.get("virtual", false):
			var id := String(monitor.id)
			if id.begins_with("v") and id.substr(1).is_valid_int(): return int(id.substr(1)) - 1
	return -1

func monitor_change_pending() -> bool:
	var controller = main.get("settings_controller")
	return _adding_monitor or (controller != null and (controller.get("_restart_pending") == true or controller.get("_virtual_apply_active") == true))

func monitor_tab_count() -> int:
	var ids := {}
	for screen in main.screens:
		for tab in screen.content_tabs.tabs:
			if tab.kind == ScreenContentTab.STREAM: ids[str(tab.locator.get("monitor_id", ""))] = true
	return ids.size()

func monitor_tab_owner(id: StringName) -> VRScreen:
	for screen in main.screens:
		for tab in screen.content_tabs.tabs:
			if tab.kind == ScreenContentTab.STREAM and StringName(tab.locator.get("monitor_id", "")) == id: return screen
	return null

func can_add_monitor_tab(screen: VRScreen, virtual: bool = false) -> bool:
	if not browser_supported or screen == null or not main.screens.has(screen) or not main.is_streaming: return false
	if switching_tab or switching_primary or monitor_change_pending() or main.session_lifecycle.phase != SessionLifecycle.Phase.STREAMING: return false
	if not main.settings.host.is_polaris_host: return false
	if virtual: return main.settings.host.virtual_display_installed and monitor_size_available(true, Vector2i(320,240) if main.layout.virtual_modes_supported else Vector2i.ZERO)
	for monitor in main.layout.monitors:
		if monitor.capturable and not monitor.hint.get("virtual", false) and monitor_tab_owner(monitor.id) == null: return monitor_size_available(false, Vector2i.ZERO, screen)
	return false

func add_monitor_tab(screen: VRScreen, virtual: bool = false, size: Vector2i = Vector2i.ZERO, monitor_id: StringName = &"") -> bool:
	if not can_add_monitor_tab(screen, virtual) or not valid_virtual_size(size): return false
	if size != Vector2i.ZERO and (not virtual or not main.layout.virtual_modes_supported): return false
	var id: StringName
	var title := ""
	var virtual_count: int = main.settings.host.virtual_display_count
	if virtual:
		if virtual_count >= main.settings.host.virtual_display_max_count:
			main.ui_controller.set_status("The host cannot create another virtual display")
			return false
		id = StringName("v%d" % (virtual_count + 1))
		title = "Virtual %d" % (virtual_count + 1)
	else:
		for monitor in main.layout.monitors:
			if monitor.capturable and not monitor.hint.get("virtual", false) and monitor_tab_owner(monitor.id) == null \
					and (monitor_id == &"" or monitor.id == monitor_id):
				id = monitor.id
				title = monitor.label if not monitor.label.is_empty() else String(id)
				break
		if id == &"": return false
	if not await _admit_monitor_addition(virtual, size, id, screen): return false
	var provider = browser_for_screen(screen)
	if provider != null and provider.active:
		switching_tab = true
		_trace_tab_switch("Adding monitor: pausing local inference before source retirement")
		main.depth_estimator.set_enabled(false)
		if main.depth_estimator.has_method("begin_source_transition"): main.depth_estimator.begin_source_transition()
		main.xr_interaction.cancel_transient_interactions("monitor tab added")
		main.video_presentation.deactivate_native(false)
		await _wait_for_primary_drain()
		if main.depth_estimator.has_method("wait_for_source_transition") and not await main.depth_estimator.wait_for_source_transition():
			main.depth_estimator.end_source_transition()
			switching_tab = false
			main.ui_controller.set_status("Depth is still busy; please try adding the monitor again")
			main.settings_controller.apply_stereo()
			_trace_tab_switch("Adding monitor: cancelled because inference did not drain")
			return false
		_trace_tab_switch("Adding monitor: render and inference consumers drained")
		if not is_instance_valid(screen) or not main.screens.has(screen) or not main.is_streaming:
			if main.depth_estimator.has_method("end_source_transition"): main.depth_estimator.end_source_transition()
			switching_tab = false
			return false
		var suspended: bool = provider.suspend_for_tab()
		if main.depth_estimator.has_method("end_source_transition"): main.depth_estimator.end_source_transition()
		switching_tab = false
		if not suspended: return false
	var tab := ScreenContentTab.for_monitor(id)
	tab.title = title
	if not screen.content_tabs.add(tab): return false
	screen.monitor_id = id
	var controller = main.settings_controller
	controller.sync_staged_from_current_layout()
	if virtual:
		if _virtual_sizes_host != main.get("current_host_id"): virtual_sizes.clear()
		_virtual_sizes_host = main.get("current_host_id")
		virtual_sizes.resize(virtual_count + 1)
		virtual_sizes[virtual_count] = size
		controller.stage_virtual_count(virtual_count + 1)
	else:
		controller.stage_monitor_count(main._staged_physical_count + 1)
		var physical: Array[StringName] = []
		for monitor in main.layout.enabled_monitors():
			if not monitor.hint.get("virtual", false): physical.append(monitor.id)
		physical.append(id)
		controller._monitor_selection_override = physical
	controller.apply_staged_monitor_config(true)
	changed.emit()
	return true

func visible_manifest_monitors(layout: ScreenLayout) -> Array:
	# A new connection can have fewer host outputs than the previous session.
	# Retained tab metadata must never expose an output absent from this stream.
	var enabled := {}
	for monitor in layout.enabled_monitors(): enabled[monitor.id] = monitor
	for screen in main.screens:
		for tab in screen.content_tabs.tabs.duplicate():
			if tab.kind != ScreenContentTab.STREAM: continue
			var id := StringName(tab.locator.get("monitor_id", ""))
			if not enabled.has(id):
				screen.content_tabs.remove(tab.id)
			else:
				tab.title = monitor_tab_title(enabled[id])
		var selected: ScreenContentTab = screen.content_tabs.selected()
		if selected != null and selected.kind == ScreenContentTab.STREAM:
			screen.monitor_id = StringName(selected.locator.get("monitor_id", ""))
	var result := []
	for monitor in layout.enabled_monitors():
		var owner := monitor_tab_owner(monitor.id)
		if owner != null:
			var selected := owner.content_tabs.selected()
			if selected == null or selected.kind != ScreenContentTab.STREAM or StringName(selected.locator.get("monitor_id", "")) != monitor.id: continue
			var visible := ScreenLayout.MonitorSpec.from_dict(monitor.to_dict())
			visible.is_primary = owner == main.primary_screen
			result.append(visible)
		else:
			result.append(monitor)
	return result

static func monitor_tab_title(monitor: ScreenLayout.MonitorSpec) -> String:
	if monitor.hint.get("virtual", false):
		return "Virtual %s" % String(monitor.id).trim_prefix("v")
	if monitor.label.is_empty() or monitor.label == String(monitor.id): return "Desktop"
	return monitor.label

func select_monitor_content_tab(screen: VRScreen, id: StringName) -> bool:
	if not can_switch_content_tab(screen): return false
	var tab := screen.content_tabs.find_tab(id)
	if tab == null or tab.kind != ScreenContentTab.STREAM: return false
	var available := false
	for monitor in main.layout.enabled_monitors():
		if monitor.id == StringName(tab.locator.get("monitor_id", "")): available = true
	if main.is_streaming and not available: return false
	var previous := screen.content_tabs.selected()
	var monitor_only: bool = previous != null and previous.kind == ScreenContentTab.STREAM and not is_browser_screen(screen) and main.is_streaming
	screen.content_tabs.select(id)
	screen.monitor_id = StringName(tab.locator.get("monitor_id", ""))
	if monitor_only:
		_bind_monitor_geometry(screen)
		var native = main.get("native_xr_renderer")
		if native: native._force_redraw = true
		changed.emit()
		return true
	return await select_monitor_tab(screen)

func start_stream_tab(screen: VRScreen) -> void:
	if main.is_streaming or switching_tab or switching_primary or not main.screens.has(screen): return
	if screen != main.primary_screen:
		if not await make_primary(screen): return
	if monitor_tab(screen) == null: screen.content_tabs.add(ScreenContentTab.for_monitor(screen.monitor_id), false)
	await select_monitor_tab(screen)

static func monitor_removal_plan(layout: ScreenLayout, id: StringName) -> Dictionary:
	var physical: Array[StringName] = []
	var virtual_count := 0
	var removed: ScreenLayout.MonitorSpec
	for monitor in layout.monitors:
		if not monitor.enabled: continue
		if monitor.id == id:
			removed = monitor
			continue
		if monitor.hint.get("virtual", false): virtual_count += 1
		else: physical.append(monitor.id)
	if removed == null: return {}
	return {"physical": physical, "virtual": virtual_count, "removed_virtual": removed.hint.get("virtual", false)}

func _remaining_browser() -> RefCounted:
	var providers: Array = [main.browser_prototype]
	providers.append_array(_browsers.values())
	for provider in providers:
		if provider != null and not provider.closing and (provider.active or provider.suspended) and not provider.pages.is_empty(): return provider
	return null

func can_close_monitor_screen(screen: VRScreen) -> bool:
	return screen != null and browser_supported and main.screens.has(screen) and main.is_streaming \
		and (main.settings.host.is_polaris_host or main.layout.enabled_monitors().size() == 1) and main.session_lifecycle.phase == SessionLifecycle.Phase.STREAMING \
		and not switching_tab and not switching_primary and not monitor_change_pending() \
		and not is_browser_screen(screen) and monitor_tab(screen) != null \
		and not monitor_removal_plan(main.layout, screen.monitor_id).is_empty()

func close_monitor_screen(screen: VRScreen) -> bool:
	if not can_close_monitor_screen(screen): return false
	var plan := monitor_removal_plan(main.layout, screen.monitor_id)
	var closed_tab := monitor_tab(screen)
	var next_monitor: ScreenContentTab
	for tab in screen.content_tabs.tabs:
		if tab != closed_tab and tab.kind == ScreenContentTab.STREAM:
			next_monitor = tab
			break
	var provider = browser_for_screen(screen)
	var keep_monitor := next_monitor != null
	var keep_browser: bool = not keep_monitor and provider != null and provider.suspended and not provider.pages.is_empty()
	# Zero captured monitors is a disconnect, never a request to reopen one.
	# Browser content can outlive that connection, on this or another screen.
	if plan.physical.is_empty() and plan.virtual == 0:
		_tab_stream_session = {}
		virtual_sizes.clear()
		main.settings.host.virtual_display_count = 0
		main.settings.host.virtual_only = false
		main._staged_physical_count = 0
		main._staged_virtual_count = 0
		var state = main.get("state_manager")
		if state != null: state.save_host_state()
		var remaining := _remaining_browser()
		if remaining != null: _close_last_monitor_keep_browser(screen, remaining)
		else: _close_last_monitor_to_welcome()
		return true
	if keep_browser and not provider.resume_from_tab(): return false
	var index := _virtual_index(screen)
	if keep_monitor or keep_browser: screen.content_tabs.remove(closed_tab.id)
	if plan.removed_virtual and index >= 0:
		if _virtual_sizes_host != main.get("current_host_id"): virtual_sizes.clear()
		_virtual_sizes_host = main.get("current_host_id")
		if index < virtual_sizes.size(): virtual_sizes.remove_at(index)
		# The count-based host numbers the surviving virtuals from v1 again.
		# Move their view/tab identities along with their size profiles.
		_renumber_virtual_tabs(index)
	# A fresh manifest removes this view, including when it was primary.
	# Retiring its ID prevents it being reused for a renumbered survivor.
	if keep_monitor:
		screen.content_tabs.select(next_monitor.id)
		screen.monitor_id = StringName(next_monitor.locator.monitor_id)
	elif keep_browser:
		screen.content_tabs.select(StringName("browser:page:%d" % provider.selected_page))
		screen.monitor_id = StringName("browser-screen:%d" % provider.browser_id)
	else:
		screen.monitor_id = StringName("retiring:%s" % screen.monitor_id)
	if not keep_monitor and not keep_browser and provider != null and provider.suspended:
		provider.cancel_pointer()
		provider.release_keys()
		if provider.uploader: provider.uploader.close_browser_prototype()
		provider.suspended = false
		provider.pages = []
		_browsers.erase(screen.get_instance_id())
	if not keep_monitor and not keep_browser: screen.content_tabs = ScreenContentTabs.new()
	var controller = main.settings_controller
	controller.sync_staged_from_current_layout()
	if plan.physical.size() > 0:
		controller.stage_monitor_count(plan.physical.size())
		controller.stage_virtual_count(plan.virtual)
	else:
		controller.stage_virtual_count(plan.virtual)
		controller.stage_monitor_count(0)
	controller._monitor_selection_override = plan.physical
	controller.apply_staged_monitor_config(true)
	changed.emit()
	return true

func _close_last_monitor_keep_browser(screen: VRScreen, provider: RefCounted) -> void:
	# Closing a source is not switching away from it: do not park another
	# reconnect request, or let the disconnect's welcome reset replace this view.
	switching_tab = true
	_browser_after_monitor_close = provider
	_tab_stream_session = {}
	main.xr_interaction.cancel_transient_interactions("monitor tab closed")
	main.depth_estimator.set_enabled(false)
	main.video_presentation.deactivate_native(false)
	main.disconnect_stream()
	var deadline := Time.get_ticks_msec() + 10000
	while main.session_lifecycle.phase == SessionLifecycle.Phase.DISCONNECTING and Time.get_ticks_msec() < deadline:
		await main.get_tree().process_frame
	await _wait_for_primary_drain()
	var browser_screen: VRScreen = provider.screen
	var ready: bool = is_instance_valid(browser_screen) and main.screens.has(browser_screen) \
		and not provider.closing and not main.is_streaming and main.session_lifecycle.phase == SessionLifecycle.Phase.SERVER_SELECTION
	if ready and browser_screen != main.primary_screen:
		ready = await make_primary(browser_screen)
	if ready and (provider.active or provider.resume_from_tab()):
		if browser_screen == screen:
			for tab in browser_screen.content_tabs.tabs.duplicate():
				if tab.kind == ScreenContentTab.STREAM: browser_screen.content_tabs.remove(tab.id)
			browser_screen.monitor_id = StringName("browser-screen:%d" % provider.browser_id)
		browser_screen.content_tabs.select(StringName("browser:page:%d" % provider.selected_page))
		if provider.texture != null: provider.bind_texture()
		focus_browser(provider)
		if is_instance_valid(screen) and screen != browser_screen: main.remove_screen(screen.monitor_id)
	_browser_after_monitor_close = null
	switching_tab = false
	changed.emit()

func _close_last_monitor_to_welcome() -> void:
	switching_tab = true
	main.xr_interaction.cancel_transient_interactions("last monitor closed")
	main.depth_estimator.set_enabled(false)
	main.video_presentation.deactivate_native(false)
	main.disconnect_stream()
	var deadline := Time.get_ticks_msec() + 10000
	while main.session_lifecycle.phase == SessionLifecycle.Phase.DISCONNECTING and Time.get_ticks_msec() < deadline:
		await main.get_tree().process_frame
	await _wait_for_primary_drain()
	switching_tab = false
	changed.emit()

func _renumber_virtual_tabs(closed_index: int) -> void:
	for screen in main.screens:
		for tab in screen.content_tabs.tabs:
			if tab.kind != ScreenContentTab.STREAM: continue
			var old_id := String(tab.locator.get("monitor_id", ""))
			if not old_id.begins_with("v") or not old_id.substr(1).is_valid_int(): continue
			var index := int(old_id.substr(1)) - 1
			if index <= closed_index: continue
			var selected: bool = screen.content_tabs.selected_id == tab.id
			var id := StringName("v%d" % index)
			var replacement := ScreenContentTab.for_monitor(id)
			tab.id = replacement.id
			tab.locator = replacement.locator
			if tab.title.begins_with("Virtual "): tab.title = "Virtual %d" % index
			if selected: screen.content_tabs.selected_id = tab.id
			if String(screen.monitor_id) == old_id: screen.monitor_id = id

func adopt_monitor_primary(screen: VRScreen) -> void:
	if main.screen_tab_strip != null and is_instance_valid(main.screen_tab_strip._screen):
		_menus[main.screen_tab_strip._screen.get_instance_id()] = main.screen_tab_strip
	var provider = _browsers.get(screen.get_instance_id())
	if provider == null and _menus.has(screen.get_instance_id()): provider = _menus[screen.get_instance_id()].browser
	if provider == null: provider = preload("res://src/browser_prototype.gd").new(main, screen, -1)
	provider.screen = screen
	main.browser_prototype = provider
	if not _menus.has(screen.get_instance_id()): _menus[screen.get_instance_id()] = ScreenTabStrip.new(main, screen, provider)
	main.screen_tab_strip = _menus[screen.get_instance_id()]

func can_add_monitor_screen(virtual: bool = false) -> bool:
	if not browser_supported or switching_primary or switching_tab or _adding_monitor: return false
	if not main.is_streaming or main.session_lifecycle.phase != SessionLifecycle.Phase.STREAMING: return false
	if main.layout == null or main.browser_prototype.closing or main.screens.size() >= MAX_BROWSER_SCREENS: return false
	if not main.settings.host.is_polaris_host: return false
	var controller = main.settings_controller
	if controller.get("_restart_pending") == true or controller.get("_virtual_apply_active") == true: return false
	if controller._real_monitor_count() <= 0: return false
	var physical := 0
	var virtual_count := 0
	for monitor in main.layout.enabled_monitors():
		if monitor.hint.get("virtual", false): virtual_count += 1
		else: physical += 1
	if virtual:
		return main.settings.host.virtual_display_installed and virtual_count < main.settings.host.virtual_display_max_count and monitor_size_available(true, Vector2i(320,240) if main.layout.virtual_modes_supported else Vector2i.ZERO)
	return physical < controller._real_monitor_count() and monitor_size_available(false)

func add_monitor_screen(virtual: bool = false, size: Vector2i = Vector2i.ZERO, monitor_id: StringName = &"") -> bool:
	if not can_add_monitor_screen(virtual): return false
	if not valid_virtual_size(size) or (size != Vector2i.ZERO and (not virtual or not main.layout.virtual_modes_supported)): return false
	if not await _admit_monitor_addition(virtual, size, &"", main.primary_screen): return false
	_adding_monitor = true
	var controller = main.settings_controller
	# Request through the established host/layout lifecycle. A fabricated local
	# screen would duplicate a region without creating another captured output.
	controller.sync_staged_from_current_layout()
	if virtual:
		if _virtual_sizes_host != main.get("current_host_id"):
			virtual_sizes.clear()
		_virtual_sizes_host = main.get("current_host_id")
		virtual_sizes.resize(main._staged_virtual_count + 1)
		virtual_sizes[main._staged_virtual_count] = size
		controller.stage_virtual_count(main._staged_virtual_count + 1)
	else:
		controller.stage_monitor_count(main._staged_physical_count + 1)
		if monitor_id != &"":
			# That monitor, beside the ones already shown.
			var physical: Array[StringName] = []
			for monitor in main.layout.enabled_monitors():
				if not monitor.hint.get("virtual", false): physical.append(monitor.id)
			if not physical.has(monitor_id): physical.append(monitor_id)
			controller._monitor_selection_override = physical
	controller.apply_staged_monitor_config(true)
	_adding_monitor = false
	changed.emit()
	return true

func _trace_tab_switch(stage: String) -> void:
	if main.has_method("_log"): main._log("[TABS] " + stage)
	if main.has_method("_flush_log"): main._flush_log()

func can_switch_content_tab(screen: VRScreen) -> bool:
	if screen == null or switching_tab or switching_primary or monitor_change_pending(): return false
	if screen != main.primary_screen:
		var provider = browser_for_screen(screen)
		return browser_supported and main.screens.has(screen) and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT, SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED, SessionLifecycle.Phase.STREAMING] and not main.pcvr_test.is_exclusive() and not main.pcvr_handover.blocks_workspace() and (provider == null or not provider.closing)
	if main.browser_prototype.closing: return false
	if main.pcvr_test.is_exclusive() or main.pcvr_handover.blocks_workspace(): return false
	if main.session_lifecycle.phase not in [SessionLifecycle.Phase.BOOT, SessionLifecycle.Phase.SERVER_SELECTION,
		SessionLifecycle.Phase.FAILED, SessionLifecycle.Phase.STREAMING]: return false
	return browser_supported

func _other_stream_screen(screen: VRScreen) -> bool:
	for other in main.screens:
		if other != screen and monitor_tab(other) != null and not is_browser_screen(other): return true
	return false

func monitor_tab(screen: VRScreen) -> ScreenContentTab:
	if screen == null: return null
	var selected := screen.content_tabs.selected()
	if selected != null and selected.kind == ScreenContentTab.STREAM: return selected
	for tab in screen.content_tabs.tabs:
		if tab.kind == ScreenContentTab.STREAM: return tab
	return null

func can_edit_monitor_tab_resolution(screen: VRScreen) -> bool:
	if screen != null and _virtual_index(screen) >= 0 and main.layout.virtual_modes_supported:
		return can_switch_content_tab(screen) and screen.content_tabs.selected() != null and screen.content_tabs.selected().kind == ScreenContentTab.STREAM
	return can_switch_content_tab(screen) and screen.content_tabs.selected() != null \
		and screen == main.primary_screen \
		and screen.content_tabs.selected().kind == ScreenContentTab.STREAM

func set_monitor_tab_resolution(screen: VRScreen, size: Vector2i) -> bool:
	if not can_edit_monitor_tab_resolution(screen): return false
	var tab := screen.content_tabs.selected()
	if tab == null or tab.kind != ScreenContentTab.STREAM: return false
	if _virtual_index(screen) >= 0:
		if not valid_virtual_size(size): return false
	elif size != Vector2i.ZERO and size not in main.resolutions: return false
	if tab.resolution == size: return true
	tab.resolution = size
	var virtual_index := _virtual_index(screen)
	if virtual_index >= 0:
		if _virtual_sizes_host != main.get("current_host_id"): virtual_sizes.clear()
		_virtual_sizes_host = main.get("current_host_id")
		if virtual_sizes.size() <= virtual_index: virtual_sizes.resize(virtual_index + 1)
		virtual_sizes[virtual_index] = size
		main.settings_controller._monitor_relaunch_required = true
	# A tab override is session-local. Do not replace the saved Default Res.
	if main.is_streaming: main.settings_controller._schedule_stream_restart()
	changed.emit()
	return true

func can_edit_browser_tab_resolution(screen: VRScreen) -> bool:
	if not can_switch_content_tab(screen): return false
	var provider = browser_for_screen(screen)
	return provider != null and provider.active and provider.uploader != null \
		and provider.uploader.has_method("resize_browser_prototype") \
		and screen.content_tabs.selected() != null and screen.content_tabs.selected().kind == ScreenContentTab.BROWSER

func set_browser_tab_resolution(screen: VRScreen, size: Vector2i) -> bool:
	if not can_edit_browser_tab_resolution(screen): return false
	var provider = browser_for_screen(screen)
	if size != Vector2i.ZERO and size not in provider.RESOLUTIONS: return false
	var tab := screen.content_tabs.selected()
	tab.resolution = size
	return await resize_browser_tab(screen, provider.desired_render_size())

func resize_browser_tab(screen: VRScreen, target: Vector2i) -> bool:
	if not can_edit_browser_tab_resolution(screen): return false
	var provider = browser_for_screen(screen)
	if target not in provider.RESOLUTIONS: return false
	if provider.render_size == target: return true
	var tab := screen.content_tabs.selected()
	switching_tab = true
	main.xr_interaction.cancel_transient_interactions("browser resolution changed")
	main.depth_estimator.set_enabled(false)
	main.video_presentation.deactivate_native(false)
	await _wait_for_primary_drain()
	var complete := false
	if is_instance_valid(screen) and main.screens.has(screen) and provider.active \
		and provider.uploader.resize_browser_prototype(target.x, target.y):
		var deadline := Time.get_ticks_msec() + 2500
		while Time.get_ticks_msec() < deadline and provider.active:
			provider._poll_pages()
			if provider.uploader.get_browser_surface_size() == target and provider.reported_render_size == target:
				provider.render_size = target
				provider.texture = null # Rebind from the first frame at the new size.
				provider._opening_at = Time.get_ticks_msec()
				complete = true
				break
			await main.get_tree().process_frame
	if not complete:
		# A producer acknowledgement can arrive after a pause or UI-thread
		# stall. Restore both halves before allowing pointer coordinates again.
		if provider.active and provider.uploader.get_browser_surface_size() != provider.render_size:
			provider.uploader.resize_browser_prototype(provider.render_size.x, provider.render_size.y)
			var deadline := Time.get_ticks_msec() + 1000
			while provider.active and Time.get_ticks_msec() < deadline:
				provider._pages_poll_at = 0
				provider._poll_pages()
				if provider.uploader.get_browser_surface_size() == provider.render_size and provider.reported_render_size == provider.render_size: break
				await main.get_tree().process_frame
			if provider.active and (provider.uploader.get_browser_surface_size() != provider.render_size or provider.reported_render_size != provider.render_size):
				provider.stop()
		# Do not retry a failed allocation on every rendered frame.
		if tab != null: tab.resolution = provider.render_size
		_trace_tab_switch("Browser resolution: resize not acknowledged")
	switching_tab = false
	if provider.active: main.settings_controller.apply_stereo()
	changed.emit()
	return complete

func select_browser_tab(screen: VRScreen, page_id: int = 0, new_page: bool = false) -> bool:
	if not can_switch_content_tab(screen): return false
	if screen != main.primary_screen:
		var provider = menu_for_screen(screen).browser
		if provider.closing: return false
		var retained: bool = provider.active or provider.suspended
		var selected: int = page_id if page_id > 0 else provider.selected_page
		if selected > 0: screen.content_tabs.select(StringName("browser:page:%d" % selected))
		provider.start()
		if not provider.active: return false
		if new_page and retained: provider.tab_action("new")
		elif page_id > 0: provider.tab_action("select", page_id)
		focus_browser(provider)
		changed.emit()
		return true
	switching_tab = true
	_trace_tab_switch("Browser source: releasing input and inference")
	main.xr_interaction.cancel_transient_interactions("content tab changed")
	main.depth_estimator.set_enabled(false)
	# Keep the host session, its virtual desktops and decoder alive while a
	# browser owns this surface. Only presentation/input changes on tab switch.
	main.video_presentation.deactivate_native(false)
	await _wait_for_primary_drain()
	if not is_instance_valid(screen) or screen != main.primary_screen:
		switching_tab = false
		return false
	var provider = main.browser_prototype
	var was_retained: bool = provider.active or provider.suspended
	if provider.suspended and page_id <= 0: page_id = provider.selected_page
	if page_id > 0: screen.content_tabs.select(StringName("browser:page:%d" % page_id))
	if not provider.active: provider.start()
	if not provider.active:
		switching_tab = false
		return false
	if new_page and was_retained:
		provider.tab_action("new")
	elif page_id > 0:
		provider.tab_action("select", page_id)
	main.screen_sources.focus_browser(provider)
	changed.emit()
	switching_tab = false
	_trace_tab_switch("Browser source: selected")
	if provider.texture != null: main.settings_controller.apply_stereo()
	return true

func close_browser_tab(screen: VRScreen, page_id: int) -> void:
	if await select_browser_tab(screen, page_id): main.browser_prototype.tab_action("close", page_id)

func select_monitor_tab(screen: VRScreen) -> bool:
	if not can_switch_content_tab(screen): return false
	var tab := monitor_tab(screen)
	if tab == null: return false
	if screen != main.primary_screen:
		var provider = browser_for_screen(screen)
		if provider != null and provider.active:
			provider.cancel_pointer()
			if not provider.suspend_for_tab(): return false
		_restore_monitor_surface(screen)
		screen.content_tabs.select(tab.id)
		focus_browser(null)
		changed.emit()
		return true
	if not main.browser_prototype.active:
		screen.content_tabs.select(tab.id)
		if main.is_streaming: _restore_monitor_surface(screen)
		changed.emit()
		return true
	switching_tab = true
	_trace_tab_switch("Desktop source: releasing input and inference")
	main.xr_interaction.cancel_transient_interactions("content tab changed")
	main.depth_estimator.set_enabled(false)
	main.video_presentation.deactivate_native(false)
	_trace_tab_switch("Desktop source: native consumer disabled")
	await _wait_for_primary_drain()
	_trace_tab_switch("Desktop source: consumer drain finished")
	if not is_instance_valid(screen) or screen != main.primary_screen:
		switching_tab = false
		return false
	if not main.browser_prototype.suspend_for_tab():
		switching_tab = false
		main.settings_controller.apply_stereo()
		return false
	screen.content_tabs.select(tab.id)
	_trace_tab_switch("Desktop source: browser suspended with retained tabs")
	focus_browser(null)
	if main.is_streaming:
		_tab_stream_session = {}
		_restore_monitor_surface(screen)
	elif not _tab_stream_session.is_empty():
		var retained := _tab_stream_session
		_tab_stream_session = {}
		await main.stream_manager.start_stream(int(retained.host), int(retained.app))
	else:
		main.welcome_screen.show_welcome_screen("welcome")
		main.settings_controller.apply_stereo()
	switching_tab = false
	changed.emit()
	_trace_tab_switch("Desktop source: selected")
	return true

func _restore_monitor_surface(screen: VRScreen) -> void:
	_bind_monitor_geometry(screen)
	main.settings_controller.apply_stereo()

func _bind_monitor_geometry(screen: VRScreen) -> void:
	for monitor in main.layout.monitors:
		if monitor.id == screen.monitor_id:
			screen.apply_monitor(monitor, main.layout.frame_size)
			if monitor.frame_rect.size.x > 0 and monitor.frame_rect.size.y > 0:
				screen.resize_to_aspect(monitor.frame_rect.size.x, monitor.frame_rect.size.y)
			break
	# Source changes can leave RGB browser pixels in this same material, while
	# a static desktop reuses its decoder texture IDs. Rebind immediately.
	if main.is_streaming and main.comp:
		main.comp.invalidate_yuv_cache()
		main.comp.bind_yuv_textures()

func secondary_browser_closed(screen: VRScreen) -> bool:
	if monitor_tab(screen) == null: return false
	for tab in screen.content_tabs.tabs.duplicate():
		if tab.kind == ScreenContentTab.BROWSER: screen.content_tabs.remove(tab.id)
	var monitor := monitor_tab(screen)
	screen.content_tabs.select(monitor.id)
	_restore_monitor_surface(screen)
	changed.emit()
	return true

func stream_screen() -> VRScreen:
	# The primary carries the stream (and the welcome surface between streams)
	# whenever no browser owns it. Picking the first screen in creation order
	# instead made a secondary stream screen the "welcome" surface during each
	# restart, and that reset its region to the whole multi-screen frame.
	if main.primary_screen and main.screens.has(main.primary_screen):
		var primary_provider := browser_for_screen(main.primary_screen)
		if primary_provider == null or (not primary_provider.active and not primary_provider.closing):
			return main.primary_screen
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
	return await _promote_primary(screen)

func _promote_primary(screen: VRScreen) -> bool:
	if not is_instance_valid(screen) or not main.screens.has(screen) or screen == main.primary_screen: return false
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
	# Native composition can keep presenting without a Godot viewport draw.
	# Observe a draw when available, but never wait forever for one after the
	# last native source was disabled. Several process frames retire its layers.
	var observed := {"drawn": false}
	var on_draw := func(): observed.drawn = true
	RenderingServer.frame_post_draw.connect(on_draw, CONNECT_ONE_SHOT)
	for _frame in range(3): await main.get_tree().process_frame
	for _frame in range(3):
		if observed.drawn: break
		await main.get_tree().process_frame
	if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)

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
	# A captured physical/virtual monitor needs the same toolbar atlas even
	# though it has no Android browser surface. Keep this inactive provider
	# local to the menu; do not register it as a live browser or allocate one.
	if provider == null:
		provider = preload("res://src/browser_prototype.gd").new(main, screen, -1)
	if not _menus.has(screen.get_instance_id()):
		_menus[screen.get_instance_id()] = ScreenTabStrip.new(main, screen, provider)
	return _menus[screen.get_instance_id()]

func focused_browser() -> RefCounted:
	if _focus_initialized: return _focused_browser if _focused_browser != null and _focused_browser.active else null
	return main.browser_prototype

func focus_browser(provider: RefCounted) -> void:
	_focus_initialized = true
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
	return browser_supported and not switching_primary and not switching_tab and not monitor_change_pending() and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT,
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

static func free_browser_cell(origin: Vector2i, id: int, occupied: Array[Vector2i]) -> Vector2i:
	for offset in [browser_grid_offset(id), Vector2i(MonitorGrid.SPAN, 0),
			Vector2i(-MonitorGrid.SPAN, 0), Vector2i(0, -MonitorGrid.SPAN), Vector2i(0, MonitorGrid.SPAN)]:
		var candidate: Vector2i = origin + offset
		if offset == Vector2i.ZERO or not MonitorGrid.cell_in_bounds(candidate.x, candidate.y): continue
		var overlaps := false
		for cell in occupied:
			if MonitorGrid.cells_overlap(candidate, cell): overlaps = true
		if not overlaps: return candidate
	return Vector2i(-1, -1)

func add_browser_screen() -> bool:
	if not can_add_browser_screen(): return false
	var id := _free_browser_slot()
	var provider: RefCounted = preload("res://src/browser_prototype.gd").new(main, null, id)
	provider.uploader = _browser_uploaders.get(id)
	var screen: VRScreen = main.add_screen(StringName("browser-screen:%d" % provider.browser_id), INF, false, provider)
	if screen == null: return false
	if main.primary_screen.grid_mode and main.primary_screen.grid_pos != Vector2i(-1, -1):
		var occupied: Array[Vector2i] = []
		for existing in main.screens:
			if existing != screen and existing.grid_pos != Vector2i(-1, -1): occupied.append(existing.grid_pos)
		var cell := free_browser_cell(main.primary_screen.grid_pos, id, occupied)
		if cell != Vector2i(-1, -1):
			screen.grid_pos = cell
			screen.grid_mode = main.primary_screen.grid_mode
			screen.global_transform = main.grid_cell_transform(cell.x, cell.y,
				main.primary_screen.grid_pos.x, main.primary_screen.grid_pos.y)
			if main.get("placement_grid") != null: main.placement_grid.adhere(screen)
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
	return browser_supported and not switching_primary and not main.browser_prototype.closing and (not main.is_streaming or switching_tab or _other_stream_screen(main.primary_screen)) \
		and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT,
			SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED, SessionLifecycle.Phase.STREAMING]

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

func restore_stream_after_browser_close(screen: VRScreen) -> bool:
	# Only a browser-originated close may resume the connection parked by a
	# tab switch. Explicit disconnects and new connections own their lifecycle.
	if screen == null or screen != main.primary_screen or monitor_tab(screen) == null: return false
	if switching_tab or switching_primary: return false
	if main.is_streaming and main.session_lifecycle.phase == SessionLifecycle.Phase.STREAMING:
		_tab_stream_session = {}
		screen.content_tabs.select(monitor_tab(screen).id)
		_restore_monitor_surface(screen)
		changed.emit()
		return true
	if _tab_stream_session.is_empty() or main.is_streaming: return false
	if main.session_lifecycle.phase not in [SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED]: return false
	if main.pcvr_test.is_exclusive() or main.pcvr_handover.blocks_workspace(): return false
	switching_tab = true
	screen.content_tabs.select(monitor_tab(screen).id)
	focus_browser(null)
	_trace_tab_switch("Last browser closed: restoring retained desktop stream")
	var retained := _tab_stream_session
	_tab_stream_session = {}
	await main.stream_manager.start_stream(int(retained.host), int(retained.app))
	switching_tab = false
	changed.emit()
	return true

func sync_browser_pages(pages: Array, selected: int, screen: VRScreen = null) -> void:
	if screen == null: screen = main.primary_screen
	if screen == null or pages.is_empty():
		return
	screen.content_tabs.sync_browser_pages(pages, selected)
	changed.emit()

func _monitor_addition_proposal(virtual: bool, size: Vector2i, id: StringName = &"") -> Dictionary:
	var target := ScreenLayout.from_dict(main.layout.to_dict())
	if not virtual:
		for monitor in target.monitors:
			if monitor.capturable and not monitor.hint.get("virtual", false) and (monitor.id == id or (id == &"" and not monitor.enabled)):
				monitor.enabled = true
				break
	var count: int = main.settings.host.virtual_display_count + (1 if virtual else 0)
	var modes := virtual_modes_query(count)
	if virtual and size != Vector2i.ZERO:
		var values := modes.split(",") if not modes.is_empty() else PackedStringArray()
		while values.size() < count: values.append("0x0")
		values[count-1] = "%dx%d" % [size.x,size.y]
		modes = ",".join(values)
	return {"layout": target, "count": count, "modes": modes}

func _admit_monitor_addition(virtual: bool, size: Vector2i, id: StringName, screen: VRScreen) -> bool:
	var manager = main.get("stream_manager")
	if manager == null or not manager.has_method("admit_monitor_set"): return true
	var proposal := _monitor_addition_proposal(virtual, size, id)
	return await manager.admit_monitor_set(proposal.layout, proposal.count, proposal.modes, screen)

var _capacity_views := {}

func monitor_size_available(virtual: bool, size := Vector2i.ZERO, screen: VRScreen = null) -> bool:
	var manager = main.get("stream_manager")
	if manager == null or not manager.has_method("monitor_proposal_available"): return true
	var key := str([virtual,size,screen.get_instance_id() if screen != null else 0])
	var now := Time.get_ticks_msec()
	var revision: int = manager.capacity_revision
	var cached: Dictionary = _capacity_views.get(key,{})
	if not cached.is_empty() and cached.until > now and cached.revision == revision: return cached.value
	var id: StringName = &""
	if not virtual:
		for monitor in main.layout.monitors:
			if monitor.capturable and not monitor.hint.get("virtual", false) and (monitor_tab_owner(monitor.id) == null if screen != null else not monitor.enabled):
				id = monitor.id
				break
	var proposal := _monitor_addition_proposal(virtual, size, id)
	var available: bool = manager.monitor_proposal_available(proposal.layout, proposal.count, proposal.modes)
	_capacity_views[key] = {"value":available,"until":now+200,"revision":revision}
	return available

var moving_tab := false
var dragged_tab_id: StringName = &""
var dragged_tab_source: VRScreen

func can_move_content_tab(source: VRScreen, id: StringName, destination: VRScreen = null) -> bool:
	if moving_tab or not can_switch_content_tab(source): return false
	var tab := source.content_tabs.find_tab(id)
	if tab == null or tab.kind not in [ScreenContentTab.STREAM, ScreenContentTab.BROWSER]: return false
	if destination == null: return source.content_tabs.tabs.size() == 1 or main.screens.size() < MAX_BROWSER_SCREENS
	if destination == source: return false
	if not can_switch_content_tab(destination) or destination.content_tabs.tabs.size() >= 8: return false
	if tab.kind == ScreenContentTab.STREAM and destination.content_tabs.find_tab(tab.id) != null: return false
	var provider := browser_for_screen(destination)
	return tab.kind != ScreenContentTab.BROWSER or provider == null or provider.pages.size() < 8

func _drop_cell(point: Vector3, exclude: VRScreen = null) -> Vector2i:
	var occupied: Array = []
	for screen in main.screens:
		if screen != exclude and screen.grid_mode: occupied.append(screen.grid_pos)
	var anchor: Vector2i = main.primary_screen.grid_pos
	if anchor == Vector2i(-1,-1): anchor = Vector2i(3,1)
	return main.nearest_free_grid_cell(point, occupied, anchor.x, anchor.y)

## Where a screen dropped at `point` goes: {"centre": surface coordinates}
## on a cylinder or sphere grid (the pointer ray from `from` laid on the
## surface's fine lattice), {"cell": slot} on the Original grid; empty if none.
func _drop_spot(point: Vector3, from: Vector3, size: Vector2, exclude: VRScreen = null) -> Dictionary:
	var grid = main.get("placement_grid")
	if grid != null and ScreenPlacementGrid.single_surface(grid.shape()):
		if from == Vector3.INF:
			from = main.xr_camera.global_position if is_instance_valid(main.xr_camera) else Vector3.ZERO
		var centre = grid.drop_centre(from, point, size, exclude)
		return {} if centre == null else {"centre": centre}
	var cell := _drop_cell(point, exclude)
	return {} if cell == Vector2i(-1, -1) else {"cell": cell}

## Where dropping this tab at `point` (in empty space) would put its screen,
## as ScreenPlacementController.preview(); empty if it can't be dropped there.
func drop_preview(source: VRScreen, id: StringName, point: Vector3, from: Vector3 = Vector3.INF) -> Dictionary:
	if main.primary_screen == null or not can_move_content_tab(source, id, null): return {}
	var single := source.content_tabs.tabs.size() == 1
	var model: VRScreen = source if single else main.primary_screen
	var spot := _drop_spot(point, from, model.mesh_size, source if single else null)
	if spot.is_empty(): return {}
	if spot.has("centre"): return main.placement_grid.surface_preview(spot.centre, model.mesh_size)
	var anchor: Vector2i = main.primary_screen.grid_pos
	if anchor == Vector2i(-1, -1): anchor = Vector2i(3, 1)
	return main.placement_grid.preview(main.grid_cell_transform(spot.cell.x, spot.cell.y, anchor.x, anchor.y), model.mesh_size, model.curvature)

## The label of a content tab, as its tab strip shows it.
func content_tab_title(source: VRScreen, id: StringName) -> String:
	var tab := source.content_tabs.find_tab(id) if is_instance_valid(source) else null
	if tab == null: return ""
	if not tab.title.is_empty(): return tab.title
	return "Desktop" if tab.kind == ScreenContentTab.STREAM else "Browser"

func _place_dropped_screen(screen: VRScreen, spot: Dictionary) -> void:
	if spot.has("centre"):
		main.placement_grid.place_dropped(screen, spot.centre)
		screen.grid_mode = true
	else:
		var cell: Vector2i = spot.cell
		var anchor: Vector2i = main.primary_screen.grid_pos
		if anchor == Vector2i(-1,-1): anchor = Vector2i(3,1)
		screen.global_transform = main.grid_cell_transform(cell.x, cell.y, anchor.x, anchor.y)
		if main.get("placement_grid") != null: main.placement_grid.adhere(screen)
		screen.grid_mode = true
		screen.grid_pos = cell
	# The controls layer (tab strip, toolbar) is placed from the cylinder centre cached by
	# update_cylinder_params(), not from the screen's transform: without this it stayed where
	# the screen was created until the screen was next grabbed.
	if main.comp.in_use: main.comp.update_cylinder_params()

func _activate_content(screen: VRScreen) -> void:
	var tab := screen.content_tabs.selected()
	if tab == null: return
	if tab.kind == ScreenContentTab.STREAM:
		await select_monitor_content_tab(screen,tab.id)
	else:
		await select_browser_tab(screen,int(String(tab.id).trim_prefix("browser:page:")))

func _retire_transferred_screen(screen: VRScreen) -> void:
	_browsers.erase(screen.get_instance_id())
	_menus.erase(screen.get_instance_id())
	main.remove_screen(screen.monitor_id, screen)

func move_content_tab(source: VRScreen, id: StringName, destination: VRScreen, point: Vector3, from: Vector3 = Vector3.INF) -> bool:
	if destination == source: return false
	if not can_move_content_tab(source,id,destination): return false
	var spot := {}
	var created := destination == null
	if created:
		var single := source.content_tabs.tabs.size() == 1
		spot = _drop_spot(point, from, (source if single else main.primary_screen).mesh_size, source if single else null)
		if spot.is_empty(): return false
		if single:
			_place_dropped_screen(source,spot)
			main.state_manager.save_state()
			return true
	moving_tab = true
	switching_tab = true
	var tab := source.content_tabs.find_tab(id)
	var source_provider := browser_for_screen(source)
	# Retire shared consumers before moving ownership of an inferred surface.
	main.depth_estimator.set_enabled(false)
	main.video_presentation.deactivate_native(false)
	main.xr_interaction.cancel_transient_interactions("tab move")
	if main.depth_estimator.has_method("begin_source_transition"): main.depth_estimator.begin_source_transition()
	await _wait_for_primary_drain()
	if main.depth_estimator.has_method("wait_for_source_transition") and not await main.depth_estimator.wait_for_source_transition():
		main.depth_estimator.end_source_transition()
		switching_tab = false
		moving_tab = false
		main.settings_controller.apply_stereo()
		return false
	if main.depth_estimator.has_method("end_source_transition"): main.depth_estimator.end_source_transition()
	if not is_instance_valid(source) or not main.screens.has(source) or source.content_tabs.find_tab(id) != tab:
		switching_tab = false
		moving_tab = false
		main.settings_controller.apply_stereo()
		return false
	if created:
		destination = main.add_screen(StringName("detached:%d" % Time.get_ticks_msec()))
		if destination != null: _place_dropped_screen(destination,spot)
	if not is_instance_valid(destination) or not main.screens.has(destination):
		switching_tab = false
		moving_tab = false
		main.settings_controller.apply_stereo()
		return false
	var destination_provider := browser_for_screen(destination)
	var fresh_browser := false
	var new_id := id
	if tab.kind == ScreenContentTab.BROWSER:
		if destination_provider == null: destination_provider = menu_for_screen(destination).browser
		fresh_browser = not destination_provider.active and not destination_provider.suspended
		destination_provider.start()
		var deadline := Time.get_ticks_msec() + 5000
		while destination_provider.uploader != null and destination_provider.uploader.poll_browser_prototype() == 1 and Time.get_ticks_msec() < deadline:
			await main.get_tree().process_frame
		var bridge = source_provider._gamepad_bridge() if source_provider != null else null
		var result := {}
		if bridge != null and destination_provider.active and destination_provider.uploader.poll_browser_prototype() == 2:
			var page := int(String(id).trim_prefix("browser:page:"))
			var ticket: int = bridge.browserTransferTab(source_provider.browser_id,destination_provider.browser_id,page,fresh_browser)
			deadline = Time.get_ticks_msec() + 15000
			while true:
				var value = JSON.parse_string(str(bridge.browserTransferResult(ticket)))
				if value is Dictionary and value.get("done",false):
					result = value
					break
				if Time.get_ticks_msec() >= deadline:
					bridge.browserCancelTransfer(ticket)
					break
				await main.get_tree().process_frame
		if int(result.get("page",0)) <= 0:
			if fresh_browser:
				destination_provider.retire_after_transfer()
				for placeholder in destination.content_tabs.tabs.duplicate():
					if placeholder.kind == ScreenContentTab.BROWSER: destination.content_tabs.remove(placeholder.id)
			if created: _retire_transferred_screen(destination)
			switching_tab = false
			moving_tab = false
			await _activate_content(source)
			if not created: await _activate_content(destination)
			main.settings_controller.apply_stereo()
			main.ui_controller.set_status("Tab could not be moved; original page kept")
			return false
		new_id = StringName("browser:page:%d" % int(result.page))
		if fresh_browser:
			for placeholder in destination.content_tabs.tabs.duplicate():
				if placeholder.kind == ScreenContentTab.BROWSER: destination.content_tabs.remove(placeholder.id)
	if not is_instance_valid(source) or not is_instance_valid(destination) or not main.screens.has(source) or not main.screens.has(destination):
		switching_tab = false
		moving_tab = false
		main.settings_controller.apply_stereo()
		return false
	# Both model mutations happen without yielding. Nothing closes the host or
	# edits its selected outputs: a move changes surface ownership only.
	source.content_tabs.remove(id)
	tab.id = new_id
	destination.content_tabs.add(tab)
	if tab.kind == ScreenContentTab.BROWSER:
		source_provider._pages_snapshot = ""
		source_provider._pages_poll_at = 0
		source_provider._poll_pages(true)
		destination_provider._pages_snapshot = ""
		destination_provider._pages_poll_at = 0
		destination_provider._poll_pages(true)
	if tab.kind == ScreenContentTab.STREAM:
		if destination_provider != null and destination_provider.active: destination_provider.suspend_for_tab()
		destination.monitor_id = StringName(tab.locator.monitor_id)
		_bind_monitor_geometry(destination)
	switching_tab = false
	if source.content_tabs.tabs.is_empty():
		if source == main.primary_screen: await _promote_primary(destination)
		if source == main.primary_screen:
			moving_tab = false
			return false # Never delete the active primary surface.
		# Detach compositor consumers first, then retire their Android producer.
		# Closing the SurfaceTexture before layer detachment can reset the GPU.
		_retire_transferred_screen(source)
		await _wait_for_primary_drain()
		if source_provider != null: source_provider.retire_after_transfer()
	else:
		var has_browser := false
		for remaining in source.content_tabs.tabs:
			if remaining.kind == ScreenContentTab.BROWSER: has_browser = true
		await _activate_content(source)
		if not has_browser and source_provider != null:
			await _wait_for_primary_drain()
			source_provider.retire_after_transfer()
	await _activate_content(destination)
	moving_tab = false
	main.comp.invalidate_yuv_cache()
	main.settings_controller.apply_stereo()
	main.state_manager.save_state()
	changed.emit()
	return true


# ---------------------------------------------------------------------------
# Adding a screen from the + Add menu: the yellow outline follows the pointer
# at the new screen's size (the primary's height, the new screen's aspect),
# and a click places it there. Monitors only appear once the host session
# restarts, so their spot is kept until their screen arrives.
# ---------------------------------------------------------------------------

## The screen being placed: {"kind": &"browser"|&"virtual"|&"physical",
## "size": Vector2i pixels (virtual: ZERO matches the host), "id": monitor id
## (physical), "title"}. Empty when nothing is being placed.
var placement := {}
var _pending_placements: Array = []

## The physical monitors that can be added as a screen (screen == null) or
## as a tab of `screen`: [{"id", "label", "enabled"}], by desktop position.
func physical_choices(screen: VRScreen = null) -> Array:
	var result: Array = []
	if main.layout == null: return result
	var shown := {}
	for monitor in main.layout.enabled_monitors(): shown[monitor.id] = true
	var monitors: Array = main.layout.monitors.duplicate()
	monitors.sort_custom(func(a, b): return a.desktop_rect.position.x < b.desktop_rect.position.x)
	for monitor in monitors:
		if not monitor.capturable or monitor.hint.get("virtual", false): continue
		if monitor_tab_owner(monitor.id) != null: continue
		if screen == null and shown.has(monitor.id): continue
		var enabled: bool = can_add_monitor_tab(screen, false) if screen != null else can_add_monitor_screen(false)
		result.append({"id": monitor.id, "label": monitor_tab_title(monitor), "enabled": enabled})
	return result

func placement_active() -> bool:
	return not placement.is_empty()

func begin_screen_placement(request: Dictionary) -> void:
	placement = request.duplicate()
	if main.get("xr_interaction") != null: main.xr_interaction.cancel_transient_interactions("screen placement")
	changed.emit()

func cancel_screen_placement() -> void:
	placement = {}
	changed.emit()

## The new screen's pixel aspect.
func _placement_pixels(request: Dictionary) -> Vector2i:
	var pixels: Vector2i = request.get("size", Vector2i.ZERO)
	match request.get("kind", &""):
		&"browser":
			pixels = preload("res://src/browser_prototype.gd").RESOLUTIONS[clampi(main.settings.browser_resolution, 0, 1)]
		&"physical":
			for monitor in main.layout.monitors:
				if monitor.id == request.get("id", &""): pixels = monitor.desktop_rect.size
	if pixels.x <= 0 or pixels.y <= 0: pixels = host_monitor_size()
	return pixels

## The size a "Default" virtual monitor gets: the host's primary monitor.
func host_monitor_size() -> Vector2i:
	var host = main.layout.get_primary() if main.layout != null else null
	return host.frame_rect.size if host != null and host.frame_rect.size.x > 0 and host.frame_rect.size.y > 0 else Vector2i(1920, 1080)

## The new screen's size in metres: the primary's height at its aspect.
func placement_size(request: Dictionary = placement) -> Vector2:
	var pixels := _placement_pixels(request)
	var height: float = main.primary_screen.mesh_size.y if main.primary_screen != null else 1.26
	return Vector2(height * pixels.x / float(pixels.y), height)

## The outline for placing the screen at the pointer, as drop_preview().
func placement_preview(point: Vector3, from: Vector3) -> Dictionary:
	if placement.is_empty() or main.primary_screen == null: return {}
	var size := placement_size()
	var spot := _drop_spot(point, from, size)
	if spot.is_empty(): return {}
	if spot.has("centre"): return main.placement_grid.surface_preview(spot.centre, size)
	var anchor: Vector2i = main.primary_screen.grid_pos
	if anchor == Vector2i(-1, -1): anchor = Vector2i(3, 1)
	return main.placement_grid.preview(main.grid_cell_transform(spot.cell.x, spot.cell.y, anchor.x, anchor.y), size, main.primary_screen.curvature)

## Place the screen at the pointer: a browser now, a monitor when it arrives.
func commit_screen_placement(point: Vector3, from: Vector3) -> bool:
	if placement.is_empty() or main.primary_screen == null: return false
	var request := placement
	var size := placement_size(request)
	var spot := _drop_spot(point, from, size)
	if spot.is_empty(): return false
	placement = {}
	var entry := {"kind": request.kind, "id": request.get("id", &""), "spot": spot,
		"size": size, "pixels": _placement_pixels(request)}
	match request.kind:
		&"browser":
			var before: Array = main.screens.duplicate()
			if not add_browser_screen(): return false
			for screen in main.screens:
				if not before.has(screen): _place_new_screen(screen, entry)
		&"virtual":
			_pending_placements.append(entry)
			if not await add_monitor_screen(true, request.get("size", Vector2i.ZERO)): _pending_placements.erase(entry)
		&"physical":
			_pending_placements.append(entry)
			if not await add_monitor_screen(false, Vector2i.ZERO, request.get("id", &"")): _pending_placements.erase(entry)
	changed.emit()
	return true

## A monitor screen just appeared: put it where its placement was clicked.
func claim_pending_placement(screen: VRScreen, monitor) -> void:
	var virtual: bool = monitor.hint.get("virtual", false)
	for entry in _pending_placements:
		if (virtual and entry.kind == &"virtual") or (not virtual and entry.kind == &"physical" and entry.id == monitor.id):
			_pending_placements.erase(entry)
			_place_new_screen(screen, entry)
			return

func _place_new_screen(screen: VRScreen, entry: Dictionary) -> void:
	var pixels: Vector2i = entry.pixels
	screen.mesh_size = entry.size
	screen.resize_to_aspect(pixels.x, pixels.y)
	_place_dropped_screen(screen, entry.spot)
	main.state_manager.save_state()
