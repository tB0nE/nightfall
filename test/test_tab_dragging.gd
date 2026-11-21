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
class Comp extends Stub:
	var in_use := true
	var updates := 0
	func update_cylinder_params(): updates += 1
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
	var comp := Comp.new()
	var session_lifecycle := SessionLifecycle.new()
	var is_streaming := true
	var layout := ScreenLayout.single(Vector2i(2560,1440))
	var settings := AppSettings.new()
	func grid_cell_transform(gx, gy, _anchor_x, _anchor_y) -> Transform3D:
		return Transform3D(Basis(), Vector3(gx, gy, -2))
	func add_screen(id):
		var screen := VRScreen.new()
		screen.monitor_id = id
		screens.append(screen)
		return screen
class Sources extends ScreenSources:
	var positions := 0
	var placed: Array = []
	func _place_new_screen(screen, entry): placed.append([screen, entry])
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
	func _place_dropped_screen(screen, spot):
		positions += 1
		screen.grid_mode = true
		screen.grid_pos = spot.cell

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
	# A dropped screen's controls layer follows it: the cached layer geometry must be
	# refreshed as it moves, not on its next grab.
	var placer := ScreenSources.new(owner,"Android")
	var updates := owner.comp.updates
	placer._place_dropped_screen(detached,{"cell": Vector2i(1,0)})
	assert(detached.transform.origin == Vector3(1,0,-2) and detached.grid_pos == Vector2i(1,0))
	assert(owner.comp.updates == updates + 1, "Placing a dropped screen must refresh its layer geometry")
	while owner.screens.size() < 4: owner.add_screen(&"unused")
	assert(not sources.can_move_content_tab(target,target.content_tabs.selected_id), "A fifth visible screen is forbidden")
	# + Add > screen: the outline is the primary's height at the new screen's aspect.
	owner.primary_screen = target
	owner.primary_screen.mesh_size = Vector2(2.24, 1.26)
	var wide: Vector2 = sources.placement_size({"kind": &"virtual", "size": Vector2i(2560, 1080)})
	assert(is_equal_approx(wide.y, 1.26) and is_equal_approx(wide.x, 1.26 * 2560.0 / 1080.0))
	var square: Vector2 = sources.placement_size({"kind": &"virtual", "size": Vector2i(1600, 1200)})
	assert(is_equal_approx(square.y, 1.26) and is_equal_approx(square.x, 1.68))
	var host_sized: Vector2 = sources.placement_size({"kind": &"virtual", "size": Vector2i.ZERO})
	assert(is_equal_approx(host_sized.x / host_sized.y, 2560.0 / 1440.0), "Default matches the host monitor")
	sources.begin_screen_placement({"kind": &"physical", "id": &"DP-2", "title": "Right"})
	assert(sources.placement_active())
	sources.cancel_screen_placement()
	assert(not sources.placement_active())
	# A monitor arriving after the host restart takes the spot clicked for it.
	var wanted := {"kind": &"physical", "id": &"DP-2", "spot": {"cell": Vector2i(1, 0)}, "size": wide, "pixels": Vector2i(2560, 1080)}
	var virtual_entry := {"kind": &"virtual", "id": &"", "spot": {"cell": Vector2i(2, 0)}, "size": square, "pixels": Vector2i(1600, 1200)}
	sources._pending_placements = [wanted, virtual_entry]
	var other := ScreenLayout.MonitorSpec.new()
	other.id = &"DP-3"
	sources.claim_pending_placement(target, other)
	assert(sources.placed.is_empty(), "Another physical monitor keeps the default spot")
	var arriving := ScreenLayout.MonitorSpec.new()
	arriving.id = &"DP-2"
	sources.claim_pending_placement(target, arriving)
	assert(sources.placed.size() == 1 and sources.placed[0][1] == wanted)
	var virtual_monitor := ScreenLayout.MonitorSpec.new()
	virtual_monitor.id = &"v1"
	virtual_monitor.hint = {"virtual": true}
	sources.claim_pending_placement(target, virtual_monitor)
	assert(sources.placed.size() == 2 and sources.placed[1][1] == virtual_entry and sources._pending_placements.is_empty())
	for screen in owner.screens: screen.free()
	owner.free()
	print("All tab drag gesture, monitor transfer and detachment tests passed")
	quit()
