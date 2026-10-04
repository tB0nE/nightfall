class_name MeteorDepthReceiver
extends RefCounted

## Receives depth maps from Nightfall Meteor's depth port (see
## meteor/src/depth_server.rs). Each message is a 32-byte little-endian header
## then a zstd-compressed 8-bit map, tagged with the video frame number it was
## made from. poll() runs once per rendered frame and keeps only the newest
## map; older ones that arrived in the same poll are skipped undecoded.

const HEADER_LEN := 32
const MAGIC := 0x4D44464E # "NFDM", little-endian
const VERSION := 1
const COMPRESSION_ZSTD := 1
const MAX_MAP_PIXELS := 4096 * 4096
const RECONNECT_SEC := 2.0
## A connection gets this long to deliver its first map.
const FIRST_MAP_GRACE_SEC := 3.0
## After this long without a map, the client falls back to on-device depth.
const STALL_SEC := 1.0

var host := ""
var port := 0
var map := PackedByteArray()
var width := 0
var height := 0
var frame_number := 0
var epoch := 0
## Meteor's frame-in to map-out time for the newest map.
var host_latency_ms := 0.0
## Increments with each new map.
var revision := 0
var maps_received := 0
var maps_skipped := 0
var bytes_received := 0

var _peer: StreamPeerTCP
var _buf := PackedByteArray()
var _connected_at := 0.0
var _last_map_at := 0.0
var _retry_at := 0.0
var _was_connected := false

func start(address: String, depth_port: int) -> void:
	if address == host and depth_port == port:
		return
	stop()
	host = address
	port = depth_port
	_retry_at = 0.0

func stop() -> void:
	_drop_connection()
	host = ""
	port = 0
	map = PackedByteArray()
	width = 0
	height = 0

func is_active() -> bool:
	return not host.is_empty()

func is_connected_to_meteor() -> bool:
	return _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

## True while maps are arriving, or a fresh connection is still within its
## grace period for the first one.
func is_delivering() -> bool:
	if not is_connected_to_meteor():
		return false
	var now := _now()
	if _last_map_at > _connected_at:
		return now - _last_map_at < STALL_SEC
	return now - _connected_at < FIRST_MAP_GRACE_SEC

## Returns true when a new map is ready in `map`.
func poll() -> bool:
	if host.is_empty():
		return false
	var now := _now()
	if _peer == null:
		if now < _retry_at:
			return false
		_retry_at = now + RECONNECT_SEC
		_peer = StreamPeerTCP.new()
		if _peer.connect_to_host(host, port) != OK:
			_peer = null
			return false
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			return false
		StreamPeerTCP.STATUS_CONNECTED:
			if not _was_connected:
				_was_connected = true
				_connected_at = now
				_peer.set_no_delay(true)
		_:
			_drop_connection()
			return false
	var available := _peer.get_available_bytes()
	if available > 0:
		var result: Array = _peer.get_partial_data(available)
		if result[0] != OK:
			_drop_connection()
			return false
		var chunk: PackedByteArray = result[1]
		_buf.append_array(chunk)
		bytes_received += chunk.size()
	var parsed := parse_messages(_buf)
	if parsed.has("error"):
		push_warning("Meteor depth: %s; reconnecting" % parsed["error"])
		_drop_connection()
		return false
	var count: int = parsed["count"]
	if count == 0:
		return false
	var newest: Dictionary = parsed["newest"]
	maps_received += count
	maps_skipped += count - 1
	var pixels: int = newest["width"] * newest["height"]
	var payload := _buf.slice(newest["payload_start"], newest["payload_end"])
	_buf = _buf.slice(parsed["consumed"])
	var decoded := payload.decompress(pixels, FileAccess.COMPRESSION_ZSTD)
	if decoded.size() != pixels:
		push_warning("Meteor depth: map for frame %d didn't decompress" % newest["frame"])
		return false
	map = decoded
	width = newest["width"]
	height = newest["height"]
	frame_number = newest["frame"]
	epoch = newest["epoch"]
	host_latency_ms = newest["latency_us"] / 1000.0
	revision += 1
	_last_map_at = now
	return true

func _drop_connection() -> void:
	if _peer:
		_peer.disconnect_from_host()
	_peer = null
	_buf = PackedByteArray()
	_was_connected = false

## Splits the complete messages at the start of buf. Returns {count,
## consumed (bytes), newest: {frame, epoch, width, height, latency_us,
## payload_start, payload_end}}, or {error} for a stream that isn't Meteor's.
static func parse_messages(buf: PackedByteArray) -> Dictionary:
	var offset := 0
	var count := 0
	var newest := {}
	while buf.size() - offset >= HEADER_LEN:
		if buf.decode_u32(offset) != MAGIC:
			return {"error": "bad magic"}
		if buf.decode_u16(offset + 4) != VERSION:
			return {"error": "unsupported version %d" % buf.decode_u16(offset + 4)}
		var header_len := buf.decode_u16(offset + 6)
		var w := buf.decode_u16(offset + 16)
		var h := buf.decode_u16(offset + 18)
		var payload_len := buf.decode_u32(offset + 24)
		if header_len < HEADER_LEN or buf.decode_u8(offset + 20) != 0 or buf.decode_u8(offset + 21) != COMPRESSION_ZSTD:
			return {"error": "unsupported map format"}
		if w == 0 or h == 0 or w * h > MAX_MAP_PIXELS or payload_len > w * h + 65536:
			return {"error": "bad map size %dx%d (%d bytes)" % [w, h, payload_len]}
		var end := offset + header_len + payload_len
		if end > buf.size():
			break
		newest = {
			"epoch": buf.decode_u32(offset + 8),
			"frame": buf.decode_u32(offset + 12),
			"width": w,
			"height": h,
			"latency_us": buf.decode_u32(offset + 28),
			"payload_start": offset + header_len,
			"payload_end": end,
		}
		count += 1
		offset = end
	return {"count": count, "consumed": offset, "newest": newest}

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
