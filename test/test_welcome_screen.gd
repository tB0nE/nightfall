extends SceneTree

func _init():
	_test_order_apps()
	_test_pair_address()
	_test_merge_mdns_hosts()
	print("All welcome_screen tests passed")
	quit()

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
