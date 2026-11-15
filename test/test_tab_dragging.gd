extends SceneTree
const Drag = preload("res://src/tab_drag_state.gd")
class Idle extends RefCounted:
	func is_exclusive(): return false
	func blocks_workspace(): return false
class Browser extends RefCounted:
	var active := false
	var closing := false
class Depth extends RefCounted:
	func set_enabled(_value): pass
	func begin_source_transition(): pass
	func end_source_transition(): pass
	func wait_for_source_transition(): return true
class Stub extends RefCounted:
	var calls := 0
	func deactivate_native(_restore): pass
	func cancel_transient_interactions(_reason): pass
	func apply_stereo(): calls += 1
	func invalidate_yuv_cache(): pass
	func save_state(): calls += 1
class Owner extends Node3D:
	var screens: Array[VRScreen] = []
	var primary_screen: VRScreen
	var browser_prototype := Browser.new()
	var pcvr_test := Idle.new()
	var pcvr_handover := Idle.new()
	var depth_estimator := Depth.new()
	var video_presentation := Stub.new()
	var xr_interaction := Stub.new()
	var settings_controller := Stub.new()
	var state_manager := Stub.new()
	var comp := Stub.new()
	var session_lifecycle := SessionLifecycle.new()
	var is_streaming := true
	var layout := ScreenLayout.single(Vector2i(2560,1440))
	var settings := AppSettings.new()
	func add_screen(id):
		var screen := VRScreen.new()
		screen.monitor_id = id
		screens.append(screen)
		return screen
class Sources extends ScreenSources:
	var positions := 0
	func _wait_for_primary_drain(): pass
	func browser_for_screen(_screen): return null
	func _bind_monitor_geometry(_screen): pass
	func _activate_content(screen):
		var tab: ScreenContentTab = screen.content_tabs.selected()
		if tab != null: screen.monitor_id = StringName(tab.locator.monitor_id)
	func _retire_transferred_screen(screen):
		main.screens.erase(screen)
		screen.free()
	func _promote_primary(screen: VRScreen) -> bool:
		main.primary_screen = screen
		return true
	func _drop_cell(_point, _exclude = null): return Vector2i(0,1)
	func _place_dropped_screen(screen, cell):
		positions += 1
		screen.grid_mode = true
		screen.grid_pos = cell

func _init(): call_deferred("run")
func run():
	var owner := Owner.new()
	root.add_child(owner)
	owner.session_lifecycle.begin_connect()
	owner.session_lifecycle.stream_started()
	var source: VRScreen = owner.add_screen(&"m0")
	var target: VRScreen = owner.add_screen(&"m1")
	owner.primary_screen = source
	var first := ScreenContentTab.for_monitor(&"m0")
	first.resolution = Vector2i(2560,1440)
	first.crop_mode = 2
	source.content_tabs.add(first)
	source.content_tabs.add(ScreenContentTab.for_monitor(&"v1"))
	target.content_tabs.add(ScreenContentTab.for_monitor(&"m1"))
	var drag := Drag.new()
	drag.begin(source,first.id,&"monitor:m0",Vector3.ZERO,"right")
	assert(drag.step(true,Vector3(0.002,0,0),"right") == &"")
	assert(drag.step(false,Vector3(0.002,0,0),"right") == &"click")
	drag.begin(source,first.id,&"monitor:m0",Vector3.ZERO,"right")
	assert(drag.step(true,Vector3(0.1,0,0),"right") == &"" and drag.dragging)
	assert(drag.step(false,Vector3(0.1,0,0),"right") == &"drop")
	drag.begin(source,first.id,&"monitor:m0",Vector3.ZERO,"right")
	assert(drag.step(true,Vector3.ZERO,"left") == &"cancel" and not drag.active)
	var sources := Sources.new(owner,"Android")
	owner.is_streaming = false
	owner.session_lifecycle.phase = SessionLifecycle.Phase.SERVER_SELECTION
	assert(sources.can_switch_content_tab(target), "Secondary browser surfaces must work without a PC stream")
	owner.is_streaming = true
	owner.session_lifecycle.phase = SessionLifecycle.Phase.STREAMING
	assert(await sources.move_content_tab(source,first.id,target,Vector3.ZERO))
	assert(owner.screens.size() == 2 and source.content_tabs.tabs.size() == 1)
	assert(target.content_tabs.selected() == first and first.crop_mode == 2 and first.resolution == Vector2i(2560,1440))
	assert(owner.settings.host.virtual_display_count == 0, "Moving never creates host outputs")
	assert(not sources.can_move_content_tab(target,first.id,target))
	assert(await sources.move_content_tab(source,source.content_tabs.selected_id,target,Vector3.ZERO))
	assert(owner.screens.size() == 1 and owner.primary_screen == target)
	assert(target.content_tabs.tabs.size() == 3, "Last-tab merge must preserve all sources")
	assert(await sources.move_content_tab(target,first.id,null,Vector3(1,0,-2)))
	assert(owner.screens.size() == 2 and target.content_tabs.tabs.size() == 2)
	var detached: VRScreen = owner.screens[-1]
	assert(detached.content_tabs.selected() == first and detached.grid_mode)
	assert(await sources.move_content_tab(detached,first.id,null,Vector3(2,0,-2)))
	assert(owner.screens.size() == 2 and sources.positions == 2, "Dragging a lone tab repositions its existing screen")
	while owner.screens.size() < 4: owner.add_screen(&"unused")
	assert(not sources.can_move_content_tab(target,target.content_tabs.selected_id), "A fifth visible screen is forbidden")
	for screen in owner.screens: screen.free()
	owner.free()
	print("All tab drag gesture, monitor transfer and detachment tests passed")
	quit()
