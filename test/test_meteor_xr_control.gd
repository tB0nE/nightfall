extends SceneTree
const ControlClient = preload("res://src/meteor_xr_control.gd")

class FakeProjection extends RefCounted:
	var stops := 0
	func request_stop() -> void: stops += 1

class Owner extends Node:
	var pcvr_test := FakeProjection.new()
	func _log(_message: String) -> void: pass

func _init() -> void:
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
