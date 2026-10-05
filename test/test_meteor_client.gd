extends SceneTree

const INFO := '{"service":"nightfall-meteor","version":"0.1.0","protocol":1,"mode":"proxy",' \
	+ '"sunshine":{"http":47989,"https":47984,"rtsp":48010},' \
	+ '"ports":{"http":48989,"https":48984,"rtsp":49010,"video":48998}}'

func _init():
	_test_parse_info()
	_test_route_rtsp_url()
	_test_depth_info()
	_test_parse_depth_messages()
	_test_pick_depth_map()
	if not _failures.is_empty():
		for failure in _failures:
			printerr("FAIL: " + failure)
		quit(1)
		return
	print("All meteor_client tests passed")
	quit()

# Failed asserts stop in Godot's debugger instead of exiting, so the newer
# checks collect failures and exit non-zero.
var _failures: Array[String] = []

func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)

func _test_parse_info() -> void:
	var info := MeteorClient.parse_info(INFO, 47984)
	assert(int(info["ports"]["https"]) == 48984)
	# A Meteor in front of a different Sunshine instance on the same PC.
	assert(MeteorClient.parse_info(INFO, 57984).is_empty())
	assert(MeteorClient.parse_info(INFO.replace('"protocol":1', '"protocol":2'), 47984).is_empty())
	assert(MeteorClient.parse_info('{"service":"other"}', 47984).is_empty())
	assert(MeteorClient.parse_info("not json", 47984).is_empty())

func _test_route_rtsp_url() -> void:
	var info := MeteorClient.parse_info(INFO, 47984)
	assert(MeteorClient.route_rtsp_url("rtsp://127.0.0.1:48010", info) == "rtsp://127.0.0.1:49010")
	assert(MeteorClient.route_rtsp_url("rtspenc://[::1]:48010/", info) == "rtspenc://[::1]:49010/")
	assert(MeteorClient.route_rtsp_url("rtsp://127.0.0.1:48010", {}) == "rtsp://127.0.0.1:48010")
	assert(MeteorClient.route_rtsp_url("", info) == "")

func _test_depth_info() -> void:
	var with_depth := INFO.substr(0, INFO.length() - 1) \
		+ ',"depth":{"port":47901,"formats":["L8"],"compression":"zstd","width":384,"height":384,"model":"zipdepth_base_384","max_hz":0}}'
	var info := MeteorClient.parse_info(with_depth, 47984)
	var depth := MeteorClient.depth_info(info)
	_check(int(depth.get("port", 0)) == 47901, "depth offer is read")
	_check(MeteorClient.depth_info(MeteorClient.parse_info(INFO, 47984)).is_empty(), "no depth key means no offer")
	_check(MeteorClient.depth_info(MeteorClient.parse_info(with_depth.replace('"zstd"', '"lz4"'), 47984)).is_empty(), "unknown compression is ignored")
	_check(MeteorClient.depth_info(MeteorClient.parse_info(with_depth.replace('["L8"]', '["F16"]'), 47984)).is_empty(), "unknown format is ignored")

static func _message(frame: int, w: int, h: int, map: PackedByteArray) -> PackedByteArray:
	var payload := map.compress(FileAccess.COMPRESSION_ZSTD)
	var header := PackedByteArray()
	header.resize(MeteorDepthReceiver.HEADER_LEN)
	header.encode_u32(0, MeteorDepthReceiver.MAGIC)
	header.encode_u16(4, 1)
	header.encode_u16(6, MeteorDepthReceiver.HEADER_LEN)
	header.encode_u32(8, 3)
	header.encode_u32(12, frame)
	header.encode_u16(16, w)
	header.encode_u16(18, h)
	header.encode_u8(20, 0)
	header.encode_u8(21, 1)
	header.encode_u32(24, payload.size())
	header.encode_u32(28, 1800)
	return header + payload

func _test_parse_depth_messages() -> void:
	var map := PackedByteArray()
	map.resize(16)
	for i in 16:
		map[i] = i * 10
	var stream := _message(41, 4, 4, map) + _message(42, 4, 4, map)
	var parsed := MeteorDepthReceiver.parse_messages(stream.slice(0, stream.size() - 5))
	_check(parsed.size() == 1 and parsed[0]["frame"] == 41, "a partial second message waits")
	parsed = MeteorDepthReceiver.parse_messages(stream)
	_check(parsed.size() == 2 and parsed[1]["payload_end"] == stream.size(), "both messages parse")
	var newest: Dictionary = parsed[1]
	_check(newest["frame"] == 42 and newest["epoch"] == 3 and newest["latency_us"] == 1800, "header fields")
	var payload := stream.slice(newest["payload_start"], newest["payload_end"])
	_check(payload.decompress(16, FileAccess.COMPRESSION_ZSTD) == map, "payload decompresses")
	var bad := stream.duplicate()
	bad[0] = 0
	parsed = MeteorDepthReceiver.parse_messages(bad)
	_check(parsed.size() == 1 and parsed[0].has("error"), "bad magic is rejected")
	_check(MeteorDepthReceiver.parse_messages(PackedByteArray()).is_empty(), "empty buffer")

func _test_pick_depth_map() -> void:
	var receiver := MeteorDepthReceiver.new()
	for frame in [10, 11, 13]:
		receiver._store({"frame": frame, "epoch": 1, "map": PackedByteArray(), "width": 1, "height": 1, "latency_us": 0})
	_check(receiver.pick(11)["frame"] == 11, "exact frame")
	_check(receiver.pick(12)["frame"] == 11, "newest before a missing frame")
	_check(receiver.pick(20)["frame"] == 13, "newest when the frame hasn't arrived")
	_check(receiver.pick(9).is_empty(), "never a map from a later frame")
	_check(receiver.pick(0)["frame"] == 13, "unknown frame number takes the newest")
	receiver._store({"frame": 2, "epoch": 2, "map": PackedByteArray(), "width": 1, "height": 1, "latency_us": 0})
	_check(receiver.pick(5)["frame"] == 2 and receiver.pick(12)["frame"] == 2, "a new epoch drops old maps")
	for frame in range(3, 30):
		receiver._store({"frame": frame, "epoch": 2, "map": PackedByteArray(), "width": 1, "height": 1, "latency_us": 0})
	_check(receiver.pick(17).is_empty(), "only the newest maps are kept")
