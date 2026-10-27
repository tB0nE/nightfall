extends SceneTree

func _init():
	var hosts := [
		{"id": 0, "server_unique_id": "AAA", "localaddress": "192.168.1.5", "usb_address": ""},
		{"id": 1, "server_unique_id": "BBB", "localaddress": "192.168.1.6", "usb_address": "fe80::1%usb0"},
	]
	# A PC paired over Wi-Fi learns its address on the cable.
	assert(SettingsController.usb_host_to_update(hosts, "fe80::2%usb0", "AAA") == 0)
	# Already known at this address: nothing to save.
	assert(SettingsController.usb_host_to_update(hosts, "fe80::1%usb0", "BBB") == -1)
	# Its address on the cable changed.
	assert(SettingsController.usb_host_to_update(hosts, "fe80::9%usb0", "BBB") == 1)
	# An unknown PC, or one that didn't say who it is.
	assert(SettingsController.usb_host_to_update(hosts, "fe80::3%usb0", "CCC") == -1)
	assert(SettingsController.usb_host_to_update(hosts, "fe80::3%usb0", "") == -1)

	assert(StreamManager.pair_failure_message("fe80::1", "Network Error").contains("address_family = both"))
	assert(StreamManager.pair_failure_message("192.168.1.5", "Timed out") == "Pairing failed: Timed out")
	print("All usb_link tests passed")
	quit()
