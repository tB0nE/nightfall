extends SceneTree

class Idle extends RefCounted:
	func is_exclusive(): return false
	func blocks_workspace(): return false
class Browser extends RefCounted:
	var active := false
	var suspended := false
	var closing := false
	var browser_id := -1
	var pages: Array = []
	func suspend_for_tab():
		active = false
		suspended = true
		return true
class Depth extends RefCounted:
	var events: Array = []
	var idle := true
	func set_enabled(value): events.append(["enabled",value])
	func begin_source_transition(): events.append(["begin"])
	func wait_for_source_transition():
		events.append(["drained"])
		return idle
	func end_source_transition(): events.append(["end"])
class Presentation extends RefCounted:
	func deactivate_native(_restore): pass
class Interaction extends RefCounted:
	func cancel_transient_interactions(_reason): pass
class UI extends RefCounted:
	func set_status(_text): pass
class Controller extends RefCounted:
	var owner
	var _restart_pending := false
	var _virtual_apply_active := false
	var _monitor_selection_override: Variant
	var requests: Array = []
	var stereo_applies := 0
	func sync_staged_from_current_layout():
		owner._staged_physical_count = 0
		owner._staged_virtual_count = 0
		for monitor in owner.layout.enabled_monitors():
			if monitor.hint.get("virtual",false): owner._staged_virtual_count += 1
			else: owner._staged_physical_count += 1
	func stage_monitor_count(count): owner._staged_physical_count = count
	func stage_virtual_count(count): owner._staged_virtual_count = count
	func apply_staged_monitor_config(_preserve := false):
		requests.append([owner._staged_physical_count,owner._staged_virtual_count])
		_restart_pending = true
	func apply_stereo(): stereo_applies += 1
class Owner extends Node3D:
	const MAX_SCREENS := 4
	var settings := AppSettings.new()
	var layout := ScreenLayout.new()
	var screens: Array[VRScreen] = []
	var primary_screen: VRScreen
	var screen_sources: ScreenSources
	var settings_controller := Controller.new()
	var browser_prototype := Browser.new()
	var depth_estimator := Depth.new()
	var video_presentation := Presentation.new()
	var xr_interaction := Interaction.new()
	var session_lifecycle := SessionLifecycle.new()
	var pcvr_test := Idle.new()
	var pcvr_handover := Idle.new()
	var ui_controller := UI.new()
	var current_host_id := 7
	var is_streaming := true
	var _staged_physical_count := 1
	var _staged_virtual_count := 0
	var _staged_preset_id: StringName = &""
	func _log(_text): pass
class Sources extends ScreenSources:
	var bound: StringName
	func _restore_monitor_surface(screen): bound = screen.monitor_id
	func _bind_monitor_geometry(screen): bound = screen.monitor_id

func _init(): _run.call_deferred()
func _run():
	var owner := Owner.new()
	root.add_child(owner)
	owner.settings_controller.owner = owner
	owner.settings.host.is_polaris_host = true
	owner.settings.host.virtual_display_installed = true
	owner.settings.host.virtual_display_max_count = 64
	owner.layout.frame_size = Vector2i(3840,1080)
	owner.layout.desktop_bounds = Rect2i(0,0,3840,1080)
	for index in 2:
		var monitor := ScreenLayout.MonitorSpec.new()
		monitor.id = StringName("m%d" % index)
		monitor.enabled = index == 0
		monitor.is_primary = index == 0
		monitor.desktop_rect = Rect2i(index*1920,0,1920,1080)
		monitor.frame_rect = monitor.desktop_rect
		owner.layout.monitors.append(monitor)
	for index in 4:
		var screen := VRScreen.new()
		owner.screens.append(screen)
	owner.primary_screen = owner.screens[0]
	owner.primary_screen.content_tabs.add(ScreenContentTab.for_monitor(&"m0"))
	owner.primary_screen.monitor_id = &"m0"
	owner.screen_sources = Sources.new(owner,"Android")
	owner.session_lifecycle.begin_connect()
	owner.session_lifecycle.stream_started()
	var sources: Sources = owner.screen_sources
	assert(not sources.can_add_monitor_screen(false), "Four visible surfaces must prevent another screen")
	assert(sources.can_add_monitor_tab(owner.primary_screen,false), "The screen limit must not prevent another tab")
	owner.browser_prototype.active = true
	owner.depth_estimator.idle = false
	assert(not await sources.add_monitor_tab(owner.primary_screen,false))
	assert(owner.primary_screen.content_tabs.tabs.size() == 1 and owner.settings_controller.requests.is_empty())
	assert(owner.browser_prototype.active and not sources.switching_tab)
	owner.depth_estimator.idle = true
	owner.depth_estimator.events.clear()
	assert(await sources.add_monitor_tab(owner.primary_screen,false))
	assert(owner.depth_estimator.events == [["enabled",false],["begin"],["drained"],["end"]])
	assert(owner.browser_prototype.suspended and not sources.switching_tab)
	assert(owner.screens.size() == 4 and owner.primary_screen.content_tabs.tabs.size() == 2)
	assert(owner.settings_controller._monitor_selection_override == [&"m0",&"m1"])
	owner.layout.monitors[1].enabled = true
	owner.settings_controller._restart_pending = false
	assert(not sources.can_add_monitor_tab(owner.primary_screen,false), "Both physical outputs are now reserved")
	for index in 5:
		assert(await sources.add_monitor_tab(owner.primary_screen,true))
		owner.settings.host.virtual_display_count = index+1
		var monitor := ScreenLayout.MonitorSpec.new()
		monitor.id = StringName("v%d" % (index+1))
		monitor.hint = {"virtual":true}
		monitor.frame_rect = Rect2i(0,0,1920,1080)
		monitor.desktop_rect = monitor.frame_rect
		owner.layout.monitors.append(monitor)
		owner.settings_controller._restart_pending = false
	assert(owner.screens.size() == 4 and sources.monitor_tab_count() == 7)
	assert(sources.can_add_monitor_tab(owner.primary_screen,true), "Virtual tabs must remain available beyond four displays")
	var visible := sources.visible_manifest_monitors(owner.layout)
	assert(visible.size() == 1 and visible[0].id == &"v5", "Hidden monitor tabs must not create VR screens")
	var real_controller := SettingsController.new(owner)
	var staged := real_controller._build_staged_layout(true)
	assert(staged.enabled_monitors().size() == 7, "Count staging must preserve monitor tabs beyond the visible-screen cap")
	var stereo_before: int = owner.settings_controller.stereo_applies
	assert(await sources.select_monitor_content_tab(owner.primary_screen,&"monitor:m0"))
	assert(owner.settings_controller.stereo_applies == stereo_before, "Monitor-only switching must not reconfigure stereo or inference")
	assert(sources.bound == &"m0" and owner.primary_screen.monitor_id == &"m0")
	assert(await sources.select_monitor_content_tab(owner.primary_screen,&"monitor:v3"))
	assert(sources.bound == &"v3")
	assert(sources.close_monitor_screen(owner.primary_screen))
	assert(owner.screens.size() == 4 and owner.primary_screen.content_tabs.tabs.size() == 6)
	assert(owner.primary_screen.monitor_id == &"m0", "Closing a monitor tab must select its sibling, not retire its screen")
	assert(owner.settings_controller.requests[-1] == [2,4])
	# A fresh physical-only connection must discard the previous session's
	# virtual tabs, including an accidentally selected stale output.
	owner.primary_screen.content_tabs.select(&"monitor:v1")
	for monitor in owner.layout.monitors:
		monitor.enabled = monitor.id == &"m0"
	visible = sources.visible_manifest_monitors(owner.layout)
	assert(owner.primary_screen.content_tabs.tabs.size() == 1)
	assert(owner.primary_screen.monitor_id == &"m0")
	assert(owner.primary_screen.content_tabs.selected().title != "m0")
	assert(not await sources.select_monitor_content_tab(owner.primary_screen,&"monitor:v1"))
	for screen in owner.screens: screen.free()
	owner.free()
	print("All monitor content tab tests passed")
	quit()
