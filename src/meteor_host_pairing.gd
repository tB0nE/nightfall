class_name MeteorHostPairing
extends RefCounted

const CHANNEL := "nightfall-host-pair-v1"

static func supported(info: Dictionary) -> bool:
	var host = info.get("host", {})
	if not host is Dictionary or host.get("managed", false) != true or host.get("kind", "") != "meteor-vibepollo":
		return false
	var pairing = host.get("pairing", {})
	return pairing is Dictionary and pairing.get("path", "") == "/meteor/pair" \
		and pairing.get("protocol", 0) == 1 \
		and pairing.get("encryption", "") == MeteorClient.ENCRYPTION \
		and not MeteorClient.meteor_key(info).is_empty()

## The ordinary host PIN exchange remains in charge of pairing. Meteor only
## receives the encrypted PIN and offers local desktop approval.
static func request(owner: Node, address: String, http_port: int, pin: String, identity: String, still_pending: Callable) -> bool:
	if not ClassDB.class_exists("MeteorChannelCipher") or not ClassDB.class_exists("HttpRequester"):
		return false
	var info := await MeteorClient.probe(owner, address, http_port - MeteorClient.HTTPS_BELOW_BASE)
	if not still_pending.call() or not supported(info): return false
	var key := MeteorClient.meteor_key(info)
	var key_id := identity if not identity.is_empty() else "%s:%d" % [address, http_port]
	if MeteorClient.check_key(MeteorClient.remembered_key(key_id), key) == MeteorClient.KeyCheck.CHANGED:
		return false # Never send a PIN to a changed remembered Meteor key.
	MeteorClient.remember_key(key_id, key)
	var cipher = ClassDB.instantiate("MeteorChannelCipher")
	if not String(cipher.init(key, CHANNEL)).is_empty(): return false
	var plain := JSON.stringify({"pin": pin, "created": int(Time.get_unix_time_from_system())}).to_utf8_buffer()
	var encrypted: PackedByteArray = cipher.seal(0, CHANNEL.to_utf8_buffer(), plain)
	if encrypted.is_empty(): return false
	var payload := JSON.stringify({"public_key": cipher.get_public_key().hex_encode(), "payload": encrypted.hex_encode()}).to_utf8_buffer()
	var host := MeteorClient.zone_address(address).replace("%", "%25")
	if ":" in host: host = "[%s]" % host
	var url := "http://%s:%d/meteor/pair" % [host, http_port - MeteorClient.DISCOVERY_BELOW_BASE]
	var state := {"done": false, "code": 0}
	var requester = ClassDB.instantiate("HttpRequester")
	requester.request(url, "POST", payload, {"Content-Type": "application/json"}, {}, func(code: int, _body, _headers, _error) -> void:
		state.code = code
		state.done = true, 2500)
	var deadline := Time.get_ticks_msec() + 3000
	while not state.done and Time.get_ticks_msec() < deadline:
		await owner.get_tree().process_frame
	return state.code == 202
