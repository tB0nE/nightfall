extends SceneTree

# Connecting to an already-paired host must remember *which* host, not only its
# address: a bundled host (e.g. Meteor's) and the user's own can share one IP,
# and an address-only save made the next start pick the first of them.

class Config extends RefCounted:
	var hosts: Array = []
	func get_hosts() -> Array: return hosts
	func load_config() -> void: pass

class Welcome extends RefCounted:
	var saved: Array = []
	func save_last_ip(ip: String, unique_id: String = "") -> void: saved.append([ip, unique_id])

class Owner extends Node3D:
	var stream_backend: StreamBackend
	var welcome_screen := Welcome.new()
	var current_host_id := -1
	var _selected_app_id := 0
	var _ui_status_label := Label.new()
	func _log(_message: String) -> void: pass
	func parse_ip_port(text: String) -> Array: return [text, 47989]
	func host_matches_address(h: Dictionary, addr: String) -> bool: return h.get("localaddress", "") == addr

class Stream extends StreamManager:
	var started: Array = []
	func start_stream(host_id: int, app_id: int, _forced := Vector2i.ZERO, _is_current := Callable()):
		started.append([host_id, app_id])

func _init() -> void: call_deferred("run")

func _named(owner: Node, node: Node, name: String) -> void:
	node.name = name
	owner.add_child(node)
	node.owner = owner
	node.unique_name_in_owner = true

func run() -> void:
	var owner := Owner.new()
	get_root().add_child(owner)
	var ip_input := LineEdit.new()
	_named(owner, ip_input, "IPInput")
	_named(owner, Control.new(), "Numpad")
	var config := Config.new()
	config.hosts = [
		{"id": 1, "localaddress": "10.0.0.5", "server_unique_id": "bundled-host"},
		{"id": 2, "localaddress": "10.0.0.5", "server_unique_id": "own-host"},
	]
	owner.stream_backend = StreamBackend.new(null)
	owner.stream_backend.set_config_manager(config)
	var stream := Stream.new(owner)

	# The user picked the second host on the shared address, then pressed Connect.
	owner.current_host_id = 2
	ip_input.text = "10.0.0.5"
	await stream.on_pair_pressed()
	assert(stream.started == [[2, 0]], "Connect must use the selected host")
	assert(owner.welcome_screen.saved.back() == ["10.0.0.5", "own-host"],
		"The selected host's identity must be saved, not only the shared address")

	owner._ui_status_label.free()
	owner.queue_free()
	print("All last_server tests passed")
	quit()
