extends SceneTree

class FakeBackend extends RefCounted:
	var pending: Array[Callable] = []
	var stops := 0
	var max_pending := 0
	func stop_play_stream(): stops += 1
	func stop_host_session(_host, _port, callback):
		pending.append(callback)
		max_pending = maxi(max_pending, pending.size())
	func acknowledge(reply: String = '<root status_code="200"><cancel>1</cancel></root>'):
		var callback: Callable = pending.pop_front()
		callback.call(reply)

class FakeStream extends RefCounted:
	var owner: Node3D
	var launches := 0
	var launch_pending := false
	var monitor_first_frame_pending := false
	var statuses := [{"running":true,"instance":"old"},{"running":false,"instance":""},{"running":true,"instance":"new"}]
	var virtual_calls := []
	var virtual_callbacks: Array[Callable] = []
	func record_monitor_transition_stage(_stage): pass
	func meteor_https_port(): return 48984
	func host_restart_status(): return statuses.pop_front() if statuses.size() > 1 else statuses[0]
	func start_stream(_host, _app, _size, guard: Callable):
		if not guard.call(): return
		launches += 1
		owner.session_lifecycle.stream_started()
	func post_meteor_virtual(count, callback):
		virtual_calls.append(count)
		virtual_callbacks.append(callback)

class PlanBackend extends StreamBackend:
	var callback: Callable
	var query := ""
	func _init(): super(null)
	func fetch_display_manifest(_host: int, done: Callable, options: String = ""):
		callback = done
		query = options

class PlanOwner extends Node3D:
	var stream_backend := PlanBackend.new()
	var settings := AppSettings.new()
	func _log(_message): pass

class FakeState extends RefCounted:
	func save_host_state(): pass

class Owner extends Node3D:
	var session_lifecycle := SessionLifecycle.new()
	var current_host_id := 4
	var _selected_app_id := 1
	var video_presentation = null
	var stream_backend := FakeBackend.new()
	var stream_manager := FakeStream.new()
	var settings := AppSettings.new()
	var state_manager := FakeState.new()
	var _pending_monitor_apply := false
	var failure := ""
	var browser_prototype = null
	var layout := ScreenLayout.single(Vector2i(1920,1080))
	var _staged_physical_count := 1
	var _staged_virtual_count := 2
	var _ui_status_label = null
	var host_resolution := Vector2i(1920,1080)
	func compute_requested_resolution(): return host_resolution
	var is_streaming: bool:
		get: return session_lifecycle.media_active
	func _clear_comp_yuv_textures(): pass
	func _log(_message): pass
	func restore_after_failed_connect(message):
		failure = message
		session_lifecycle.fail()

class LayoutController extends SettingsController:
	var rebuilt := 0
	var placements := 0
	var restarts := 0
	func _init(owner): super(owner)
	func _build_staged_layout(_preserve_current: bool = false) -> ScreenLayout: return main.layout
	func apply_screen_layout(_layout: ScreenLayout): rebuilt += 1
	func _apply_preset_positions_to_screens(): placements += 1
	func _schedule_stream_restart(_debounce: float = 0.8, _delay: float = 0.0, _end: bool = false, _info: Dictionary = {}): restarts += 1

func _init(): _run.call_deferred()

func until(predicate: Callable):
	var deadline := Time.get_ticks_msec() + 3000
	while not predicate.call() and Time.get_ticks_msec() < deadline: await process_frame
	assert(predicate.call(), "Transition test timed out")

func _run():
	assert(StreamRestartPolicy.cancel_acknowledged('<root status_code="200"><cancel>1</cancel></root>'))
	for reply in ["", "not xml", '<root status_code="403"><cancel>1</cancel></root>', '<root status_code="503"><cancel>0</cancel></root>', '<root><cancel>1</cancel></root>']:
		assert(not StreamRestartPolicy.cancel_acknowledged(reply))
	assert(not StreamRestartPolicy.replacement_ready({"running":true,"instance":"old"}, "old"))
	assert(not StreamRestartPolicy.replacement_ready({"running":false,"instance":""}, "old"))
	assert(StreamRestartPolicy.replacement_ready({"running":true,"instance":"new"}, "old"))
	assert(StreamRestartPolicy.planned_size({"frame_size":[7680,2160]}) == Vector2i(7680,2160))
	for size in [[0,0],[-1,1080],[1920.5,1080],["1920",1080],[1920], [INF,1080]]:
		assert(StreamRestartPolicy.planned_size({"frame_size":size}) == Vector2i.ZERO)
	var owner := Owner.new()
	root.add_child(owner)
	owner.stream_manager.owner = owner
	owner.session_lifecycle.stream_started()
	var controller := SettingsController.new(owner)
	controller.note_virtual_count_launched(2)
	assert(controller._last_applied_virtual_count == 2, "Saved/loaded virtual count must not trigger a false first Apply")
	# Host readiness is the real ACK: never reconnect while cancel is in flight.
	controller._schedule_stream_restart(0, 0, true)
	await until(func(): return owner.stream_backend.pending.size() == 1)
	assert(owner.stream_manager.launches == 0)
	# Superseding requests serialize, and only the latest reconnects.
	controller._schedule_stream_restart(0, 0, true)
	await process_frame
	assert(owner.stream_backend.pending.size() == 1)
	owner.stream_backend.acknowledge()
	await until(func(): return owner.stream_backend.pending.size() == 1)
	owner.stream_backend.acknowledge()
	await until(func(): return not controller._restart_pending)
	assert(owner.stream_manager.launches == 1 and owner.stream_backend.max_pending == 1)
	# The old host process is not a replacement; wait through stopped/new.
	controller._schedule_stream_restart(0,0,true,{"host_restarting":true,"restart_status":1,"previous_instance":"old"})
	await until(func(): return owner.stream_backend.pending.size() == 1)
	assert(owner.stream_manager.statuses.size() == 1)
	owner.stream_backend.acknowledge()
	await until(func(): return not controller._restart_pending)
	assert(owner.stream_manager.launches == 2)
	# Disconnect while waiting: an acknowledged old request cannot resurrect it.
	controller._schedule_stream_restart(0,0,true)
	await until(func(): return owner.stream_backend.pending.size() == 1)
	owner.session_lifecycle.request_disconnect()
	owner.stream_backend.acknowledge()
	await until(func(): return not controller._restart_pending)
	assert(owner.stream_manager.launches == 2)
	# Reject an explicit permission error without launching or waiting 16 seconds.
	owner.session_lifecycle.stream_started()
	controller._schedule_stream_restart(0,0,true)
	await until(func(): return owner.stream_backend.pending.size() == 1)
	owner.stream_backend.acknowledge('<root status_code="403"><cancel>0</cancel></root>')
	await until(func(): return not controller._restart_pending)
	assert(owner.stream_manager.launches == 2 and not owner.failure.is_empty())
	# Coalesce POSTs while one is outstanding, without parallel writes.
	controller._monitor_apply_seq = 1
	controller._queue_virtual_apply({"seq":1,"count":1,"host_id":4,"restart":false,"real_changed":false})
	controller._monitor_apply_seq = 2
	controller._queue_virtual_apply({"seq":2,"count":2,"host_id":4,"restart":false,"real_changed":false})
	controller._monitor_apply_seq = 3
	controller._queue_virtual_apply({"seq":3,"count":3,"host_id":4,"restart":false,"real_changed":false})
	assert(owner.stream_manager.virtual_calls == [1])
	owner.stream_manager.virtual_callbacks.pop_front().call(true,{})
	await until(func(): return owner.stream_manager.virtual_calls.size() == 2)
	assert(owner.stream_manager.virtual_calls == [1,3])
	owner.stream_manager.virtual_callbacks.pop_front().call(true,{})
	await until(func(): return not controller._virtual_apply_active)
	assert(controller._last_applied_virtual_count == 3)
	# A layout-only Apply must preserve actual virtual entries and never POST/restart.
	var layout_owner := Owner.new()
	root.add_child(layout_owner)
	layout_owner.stream_manager.owner = layout_owner
	layout_owner.session_lifecycle.stream_started()
	layout_owner.settings.host.virtual_display_installed = true
	layout_owner.settings.host.virtual_display_count = 2
	for id in ["virtual:a", "virtual:b"]:
		var monitor := ScreenLayout.MonitorSpec.new()
		monitor.id = StringName(id)
		monitor.hint = {"virtual":true}
		monitor.enabled = true
		layout_owner.layout.monitors.append(monitor)
	var layout_controller := LayoutController.new(layout_owner)
	layout_controller.note_virtual_count_launched(2)
	layout_controller.apply_staged_monitor_config()
	assert(layout_controller.rebuilt == 0 and layout_controller.placements == 1)
	assert(layout_controller.restarts == 0 and layout_owner.stream_manager.virtual_calls.is_empty())
	assert(layout_owner.layout.monitors.size() == 3)
	layout_owner.free()
	# An FPS/codec request cannot bypass a still-required monitor relaunch.
	owner.session_lifecycle.stream_started()
	controller._monitor_relaunch_required = true
	controller._virtual_apply_active = true
	var stopped_before: int = owner.stream_backend.stops
	controller._schedule_stream_restart(0,0)
	await process_frame
	await process_frame
	assert(owner.stream_backend.stops == stopped_before)
	controller._virtual_apply_active = false
	await until(func(): return owner.stream_backend.pending.size() == 1)
	owner.stream_backend.acknowledge()
	await until(func(): return not controller._restart_pending)
	assert(owner.stream_manager.launches == 3)
	# A stale plan reply must not overwrite the next selection's size.
	var plan_owner := PlanOwner.new()
	root.add_child(plan_owner)
	var planner := StreamManager.new(plan_owner)
	var before := plan_owner.settings.host.native_resolution
	var active := {"value": true}
	planner._adopt_launch_plan(4,{"capture_outputs":"DP-0,DP-2","virtual_displays":2},func(): return active.value)
	assert(plan_owner.stream_backend.query == "outputs=DP-0%2CDP-2&virtual_displays=2")
	active.value = false
	plan_owner.stream_backend.callback.call({"frame_size":[7680,2160]})
	await process_frame
	await process_frame
	assert(plan_owner.settings.host.native_resolution == before)
	planner._adopt_launch_plan(4,{"virtual_only":1,"virtual_displays":2})
	plan_owner.stream_backend.callback.call({"frame_size":[3840,1080]})
	await process_frame
	await process_frame
	assert(plan_owner.settings.host.native_resolution == Vector2i(3840,1080))
	planner.begin_monitor_transition(1)
	assert(not planner.monitor_first_frame_pending, "Frames from the old stream must not complete new transition timings")
	planner.record_monitor_transition_stage("launch_request")
	planner.record_monitor_transition_stage("stream_started")
	assert(planner.monitor_first_frame_pending)
	planner.record_monitor_transition_stage("first_frame_submitted")
	assert(planner.monitor_transition.complete and not planner.monitor_first_frame_pending)
	plan_owner.free()
	owner.free()
	print("All stream restart readiness, coalescing and cancellation tests passed")
	quit()
