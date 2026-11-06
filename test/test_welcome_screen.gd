extends SceneTree

class FakePCVR extends RefCounted:
	func standby_busy_reason() -> String: return ""
	func busy_reason() -> String: return "Desktop stream active"

class Owner extends Node3D:
	var pcvr_test := FakePCVR.new()
	var is_streaming := true

class ControlProbe extends RefCounted:
	signal changed
	var state := "idle"
	var message := ""
	var offers := 0
	var accepts := 0
	var stops_projection := false
	func cancel(stop_projection: bool = true) -> void:
		stops_projection = stop_projection
		state = "idle"
	func current_config() -> ConfigFile: return ConfigFile.new()
	func connect_offer() -> void: offers += 1
	func accept_offer() -> void: accepts += 1

class WelcomeProbe extends WelcomeScreen:
	var control := ControlProbe.new()
	var reason := ""
	func get_xr_control() -> RefCounted: return control
	func _xr_entry_busy_reason(_config: ConfigFile) -> String: return reason

func _init():
	_test_order_apps()
	_test_pair_address()
	_test_xr_entry()
	_test_xr_teardown_policy()
	_test_active_watch_skips_discovery()
	_test_merge_mdns_hosts()
	print("All welcome_screen tests passed")
	quit()

func _test_active_watch_skips_discovery() -> void:
	var owner := Owner.new()
	var welcome := WelcomeScreen.new(owner)
	var control := ControlProbe.new()
	welcome._xr_control = control
	# FakePCVR deliberately has no discovery API: an established watcher
	# must return before config IO, host enumeration or capability probes.
	for state in ["watching", "offered", "prepared"]:
		control.state = state
		welcome._auto_retry = 0
		welcome.process_auto_xr(1.0 / 120.0)
		assert(control.offers == 0)
	owner.free()

func _test_xr_teardown_policy() -> void:
	var owner := Owner.new()
	var welcome := WelcomeScreen.new(owner)
	var control := ControlProbe.new()
	welcome._xr_control = control
	control.state = "prepared"
	welcome.cancel_xr_control(false, false)
	assert(control.state == "idle" and not control.stops_projection)
	assert(not welcome._auto_suppressed and welcome._auto_retry >= 1.0)
	# Manual cancel remains deliberate; an ensuing native cleanup cannot
	# silently undo it. Normal resume explicitly re-enables automatic detection.
	welcome.cancel_xr_control()
	assert(welcome._auto_suppressed and control.stops_projection)
	welcome.cancel_xr_control(false, false)
	assert(welcome._auto_suppressed)
	welcome.resume_auto_xr()
	assert(not welcome._auto_suppressed)
	owner.free()

func _test_xr_entry() -> void:
	var owner := Owner.new()
	var welcome := WelcomeScreen.new(owner)
	assert(welcome.get_xr_control() == welcome.get_xr_control())
	var config := ConfigFile.new()
	assert(welcome._xr_entry_busy_reason(config) == "Desktop stream active")
	config.set_value("host", "standby_only", true)
	assert(welcome._xr_entry_busy_reason(config) == "Desktop stream active")
	config.set_value("host", "handover_on_ready", true)
	assert(welcome._xr_entry_busy_reason(config).is_empty())
	var probe := WelcomeProbe.new(owner)
	probe.request_xr_control()
	assert(probe.control.offers == 1 and probe.control.accepts == 0)
	probe.control.state = "offered"
	probe.reason = "Wait for connection"
	probe.request_xr_control()
	assert(probe.control.accepts == 0 and probe.control.state == "offered")
	assert(probe.control.message == "Wait for connection")
	probe.reason = ""
	probe.request_xr_control()
	assert(probe.control.accepts == 1)
	probe.control.state = "prepared"
	probe.request_xr_control()
	assert(probe.control.offers == 1 and probe.control.accepts == 1)
	owner.free()

func _names(apps: Array) -> Array:
	var names := []
	for app in apps:
		names.append(app["name"])
	return names

func _test_order_apps() -> void:
	var host_order := [
		{"name": "Photoshop", "id": 3},
		{"name": "Steam Big Picture", "id": 2},
		{"name": "Hades", "id": 4},
		{"name": "Desktop", "id": 1},
		{"name": "Celeste", "id": 5},
	]
	assert(_names(WelcomeScreen.order_apps(host_order)) == ["Desktop", "Steam Big Picture", "Photoshop", "Hades", "Celeste"])
	# Missing entries just fall through; case and whitespace don't matter.
	assert(_names(WelcomeScreen.order_apps([{"name": "Zed"}, {"name": " steam "}, {"name": "Alpha"}])) == [" steam ", "Zed", "Alpha"])
	assert(WelcomeScreen.order_apps([]).is_empty())

func _test_merge_mdns_hosts() -> void:
	var merge = preload("res://src/stream_manager.gd").merge_mdns_hosts
	var usb := [{"hostname": "pc.local", "ip": "fe80::1%usb0", "port": 47989}]
	var lan := [
		{"hostname": "PC.local", "ip": "192.168.1.20", "port": 47989},
		{"hostname": "pc.local", "ip": "192.168.1.20", "port": 49989},
	]
	var merged: Array = merge.call(usb, lan)
	# The cable wins for the same host; a second host on the PC stays listed.
	assert(merged.size() == 2)
	assert(merged[0]["ip"] == "fe80::1%usb0")
	assert(int(merged[1]["port"]) == 49989)

func _test_pair_address() -> void:
	# The default port stays implicit, so existing addresses are unchanged.
	assert(WelcomeScreen.pair_address("192.168.1.20", 47989) == "192.168.1.20")
	assert(WelcomeScreen.pair_address("192.168.1.20", 50000) == "192.168.1.20:50000")
	assert(WelcomeScreen.pair_address("fe80::1%usb0", 50000) == "[fe80::1%usb0]:50000")
	assert(WelcomeScreen.pair_address("fe80::1%usb0", 47989) == "fe80::1%usb0")
	assert(WelcomeScreen.pair_address("192.168.1.20", 0) == "192.168.1.20")
