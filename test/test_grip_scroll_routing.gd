extends SceneTree

class Recorder extends RefCounted:
	var amounts: Array = []
	func send_high_res_scroll_event(amount: int): amounts.append(amount)

class Browser extends RefCounted:
	var active := true
	var amounts: Array = []
	func scroll_high_res(amount: int, _uv: Vector2): amounts.append(amount)

class Sources extends RefCounted:
	var browser: RefCounted
	func browser_for_screen(_screen): return browser

class Mapper extends RefCounted:
	var active := false
	func is_active(): return active

class Owner extends Node3D:
	var settings := AppSettings.new()
	var _is_using_hands := false
	var ui_visible := false
	var grabbed_node: Node3D
	var grabbed_corner_idx := -1
	var was_clicking := false
	var was_right_clicking := false
	var controller_mapper := Mapper.new()
	var virtual_keyboard: RefCounted
	var pcvr_handover: RefCounted
	var screen_sources := Sources.new()
	var stream_backend := Recorder.new()
	var current_host_id := 7
	var is_streaming := true

class Interaction extends XRInteraction:
	var anchors := 0
	func _active_pointer_tracked() -> bool: return true
	func _position_stream_pointer(_ray: RayCast3D) -> bool:
		anchors += 1
		return true

func _init(): _run.call_deferred()

func _run():
	var owner := Owner.new()
	root.add_child(owner)
	owner.settings.grip_scroll_enabled = true
	var interaction := Interaction.new(owner)
	var screen = preload("res://src/vr_screen.tscn").instantiate()
	screen.main = owner
	screen.curvature = 0
	screen.position = Vector3.ZERO
	owner.add_child(screen)
	var ray := RayCast3D.new()
	ray.position.z = 1.0
	ray.target_position = Vector3(0, 0, -3)
	ray.collision_mask = 2
	ray.collide_with_areas = true
	ray.collide_with_bodies = false
	owner.add_child(ray)
	for _frame in 3: await physics_frame
	ray.force_raycast_update()
	assert(ray.is_colliding())
	assert(not interaction._process_grip_scroll(ray, false, false))
	assert(interaction._process_grip_scroll(ray, false, true))
	assert(interaction.anchors == 1)
	await _move(interaction, ray, 0.02)
	await _move(interaction, ray, 0.12)
	assert(not owner.stream_backend.amounts.is_empty(), "Actual pointer routing must emit high-resolution host scroll")
	assert(owner.stream_backend.amounts.back() < 0)
	assert(interaction.anchors == 1, "A held grip must not keep repositioning the host cursor")
	owner.ui_visible = true
	var count := owner.stream_backend.amounts.size()
	await _move(interaction, ray, 0.2)
	assert(owner.stream_backend.amounts.size() == count, "Opening a menu cancels remote scrolling")
	assert(not interaction._drag_scroll.active and interaction._drag_scroll.consuming)
	owner.ui_visible = false
	await _move(interaction, ray, 0.3)
	assert(not interaction._drag_scroll.active, "A cancelled gesture needs release")
	interaction._process_grip_scroll(ray, false, false)
	owner.controller_mapper.active = true
	assert(not interaction._process_grip_scroll(ray, false, true))
	assert(not interaction._drag_scroll.active, "Mappings own their buttons")
	owner.controller_mapper.active = false
	interaction._process_grip_scroll(ray, false, false)
	var browser := Browser.new()
	owner.screen_sources.browser = browser
	owner.is_streaming = false
	assert(interaction._process_grip_scroll(ray, false, true))
	await _move(interaction, ray, 0.32)
	await _move(interaction, ray, 0.42)
	assert(not browser.amounts.is_empty(), "Browser scrolling works without a host stream")
	assert(owner.stream_backend.amounts.size() == count, "Browser scroll must never leak to GameStream")
	interaction._process_grip_scroll(ray, true, false)
	assert(interaction._pointer_rearm_required, "Releasing grip with trigger held must not invent a click")
	assert(not interaction._pointer_input_ready(true, true))
	assert(interaction._pointer_input_ready(true, false))
	assert(interaction._drag_scroll_browser == null, "Release must drop the captured browser reference")
	# A closed screen cannot be dereferenced on the next held frame.
	interaction._process_grip_scroll(ray, false, false)
	assert(interaction._process_grip_scroll(ray, false, true))
	screen.free()
	interaction._process_grip_scroll(ray, false, true)
	assert(not interaction._drag_scroll.active)
	owner.free()
	print("All grip scroll routing tests passed")
	quit()

func _move(interaction, ray: RayCast3D, y: float):
	ray.position.y = y
	ray.force_raycast_update()
	await physics_frame
	await create_timer(0.04).timeout
	interaction._process_grip_scroll(ray, false, true)
