extends SceneTree

func _init() -> void:
	var info := {"key": "ab".repeat(32), "host": {"kind": "meteor-vibepollo", "managed": true,
		"pairing": {"path": "/meteor/pair", "protocol": 1, "encryption": MeteorClient.ENCRYPTION}}}
	assert(MeteorHostPairing.supported(info))
	assert(not MeteorHostPairing.supported({}))
	for invalid in ["host", "key"]:
		var changed := info.duplicate(true)
		changed.erase(invalid)
		assert(not MeteorHostPairing.supported(changed))
	for field in ["path", "protocol", "encryption"]:
		var changed := info.duplicate(true)
		changed.host.pairing.erase(field)
		assert(not MeteorHostPairing.supported(changed))
	var external := info.duplicate(true)
	external.host.managed = false
	assert(not MeteorHostPairing.supported(external))
	var changed := info.duplicate(true)
	changed.host.pairing.path = "http://other-host/api/pin"
	assert(not MeteorHostPairing.supported(changed))
	print("All Meteor host pairing discovery tests passed")
	quit()
