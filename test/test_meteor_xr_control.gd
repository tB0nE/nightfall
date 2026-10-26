extends SceneTree
const ControlClient = preload("res://src/meteor_xr_control.gd")

class FakeProjection extends RefCounted:
	var stops := 0
	func request_stop() -> void: stops += 1

class Owner extends Node:
	var pcvr_test := FakeProjection.new()
	func _log(_message: String) -> void: pass

func _init() -> void:
	assert(ControlClient.valid_launch_notice({"generation":"a".repeat(32),"app_id":"438100"}))
	assert(not ControlClient.valid_launch_notice({"generation":"a".repeat(31),"app_id":"438100"}))
	assert(not ControlClient.valid_launch_notice({"generation":"g".repeat(32),"app_id":"438100"}))
	assert(not ControlClient.valid_launch_notice({"generation":"a".repeat(32),"app_id":"0"}))
	assert(not ControlClient.relay_preparation_failed("idle", true))
	assert(not ControlClient.relay_preparation_failed("starting", true))
	assert(ControlClient.relay_preparation_failed("failed", true))
	assert(ControlClient.relay_preparation_failed("stopping", true))
	assert(ControlClient.relay_preparation_failed("idle", false))
	assert(ControlClient.valid_pin("a1".repeat(32)))
	assert(ControlClient.valid_pin("AB".repeat(32)))
	assert(not ControlClient.valid_pin("0".repeat(64)))
	assert(not ControlClient.valid_pin("z".repeat(64)))
	assert(not ControlClient.valid_pin("a1"))
	var owner := Owner.new()
	root.add_child(owner)
	var client = ControlClient.new(owner)
	var key := "13be4feaeaf204c7fd3358fc9c00721881d174278128227ec674f37f7fe97b6d"
	client.set_discovered_host("10.0.0.13", {"key":key,"xr":{"port":47910,"backend":"linux-nvidia","authorization":"allowlist"}})
	assert(client.current_config().get_value("host", "address") == "10.0.0.13")
	assert(client.current_config().get_value("host", "handover_on_ready"))
	assert(ControlClient.approval_code(key) == "0F6D2553")
	assert(ControlClient.approval_code("invalid").is_empty())

	assert(not client.queue_bitrate(80))
	assert(not client.queue_foveation(true))
	assert(not client.request_library("list"))
	client.state = "watching"
	client.library_available = true
	assert(client.request_library("art", "steam:438100"))
	assert(client.request_library("list") and client._library_queue.size() == 1)
	assert(client._library_queue[0].action == "list")
	assert(not client.request_library("invalid"))
	client.state = "prepared"
	client.session = "a".repeat(32)
	assert(client.queue_foveation(true) and client._pending_foveation == 1)
	assert(client.queue_foveation(false) and client._pending_foveation == 0)
	assert(not client.queue_bitrate(161))
	assert(client.queue_bitrate(32))
	assert(client.queue_bitrate(80) and client._pending_bitrate == 80)
	client._update_bitrate_status({"state":"applied", "applied_bps":80000000})
	assert(client.bitrate_message == "Bitrate 80.0 Mbps applied")
	client._update_bitrate_status({"state":"rejected", "error":"test rejection"})
	assert(client.bitrate_message == "Bitrate unchanged: test rejection")
	client.state = "idle"
	client.session = ""
	assert(client._update_runtime({})) # Old hosts have no runtime field.
	var status := {"phase": "starting", "generation": "a".repeat(32), "event_sequence": 0, "active_sessions": 0}
	assert(ControlClient.valid_runtime_status({"phase":"ready_for_application", "generation":"a".repeat(32), "event_sequence":0, "active_sessions":0}))
	assert(client._update_runtime({"runtime": status}))
	assert(not client._update_runtime({})) # Cannot erase a known generation.
	status.phase = "session_active"
	status.event_sequence = 2.0 # JSON numbers decode as floats.
	status.active_sessions = 1.0
	assert(client._update_runtime({"runtime": status}))
	assert(client.state == "idle") # Runtime activity must not trigger projection.
	var stale := status.duplicate()
	stale.generation = "b".repeat(32)
	assert(not client._update_runtime({"runtime": stale}))
	stale = status.duplicate()
	stale.event_sequence = 1
	assert(not client._update_runtime({"runtime": stale}))
	stale.event_sequence = "2"
	assert(not ControlClient.valid_runtime_status(stale))
	stale = status.duplicate()
	stale.active_sessions = 0
	assert(not ControlClient.valid_runtime_status(stale))
	client.cancel()
	assert(client.runtime_status.is_empty())
	assert(client._library_queue.is_empty() and not client.library_available)
	assert(client._pending_foveation == -1 and client.foveation_message.is_empty())
	assert(client._update_runtime({}))
	assert(not ControlClient.valid_runtime_status({"phase": "starting"}))
	client.state = "offered"
	client.session = "stale"
	var generation: int = client._generation
	client.cancel()
	assert(client._generation > generation)
	assert(client.state == "idle" and client.session.is_empty())
	assert(client._peer == null and client._send == null and client._receive == null)
	client.state = "prepared"
	client.accept_offer()
	assert(client.state == "prepared") # No second acceptance and never presentation.
	client.cancel()
	client._owns_projection = true
	client._long_run = true
	client._relay_config = {"identity": PackedByteArray([1, 2, 3])}
	client.cancel()
	assert(owner.pcvr_test.stops == 1 and client._relay_config.is_empty())
	assert(not client._long_run)
	client._owns_projection = true
	client.cancel(false)
	assert(owner.pcvr_test.stops == 1) # Native stop path already owns GPU drain.
	owner.free()
	print("All meteor_xr_control tests passed")
	quit()
