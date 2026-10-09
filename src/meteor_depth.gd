class_name MeteorDepthReceiver
extends RefCounted

## Receives depth maps from Nightfall Meteor's depth port (see
## meteor/src/depth_server.rs). On connecting it sends a key made for this
## connection; each message is then a 32-byte little-endian header and a
## zstd-compressed 8-bit map, encrypted (nightfall-stream's
## MeteorChannelCipher), tagged with the Moonlight frame number it was made
## from.
##
## A worker thread connects, reads and decompresses, and keeps the newest
## RING_SIZE maps. The main thread only picks the map for the frame on screen
## (pick()), so no network or decompression work lands on the render loop.

const HEADER_LEN := 32
const MAGIC := 0x4D44464E # "NFDM", little-endian
const VERSION := 2
const HELLO_MAGIC := "NFDK"
const KDF_INFO := "nightfall-meteor depth v2"
const COMPRESSION_ZSTD := 1
const MAX_MAP_PIXELS := 4096 * 4096
## About 100 ms of maps at 120 Hz.
const RING_SIZE := 12
const RECONNECT_SEC := 2.0
## A connection gets this long to deliver its first map.
const FIRST_MAP_GRACE_SEC := 3.0
## After this long without a map, the client falls back to on-device depth.
const STALL_SEC := 1.0
## Worker sleep when no data is waiting.
const IDLE_USEC := 500

var host := ""
var port := 0
## Meteor's public key (MeteorClient.meteor_key()).
var key := ""
# Written by the worker; plain ints and bools, read without the lock.
var maps_received := 0
var bytes_received := 0
var newest_frame := 0
var host_latency_ms := 0.0

var _thread: Thread
var _mutex := Mutex.new()
var _running := false
var _connected := false
var _connected_at := 0.0
var _last_map_at := 0.0
# {frame, epoch, map, width, height, latency_us}, oldest first. Guarded by _mutex.
var _ring: Array[Dictionary] = []

## Whether this build can decrypt Meteor's maps.
static func is_supported() -> bool:
	return ClassDB.class_exists("MeteorChannelCipher")

func start(address: String, depth_port: int, meteor_key: String) -> void:
	if address == host and depth_port == port and meteor_key == key and _thread:
		return
	stop()
	host = address
	port = depth_port
	key = meteor_key
	_running = true
	_thread = Thread.new()
	_thread.start(_run)

func stop() -> void:
	_running = false
	if _thread:
		_thread.wait_to_finish()
	_thread = null
	host = ""
	port = 0
	_connected = false
	_last_map_at = 0.0
	newest_frame = 0
	_mutex.lock()
	_ring.clear()
	_mutex.unlock()

func is_active() -> bool:
	return _thread != null

func is_connected_to_meteor() -> bool:
	return _connected

## True while maps are arriving, or a fresh connection is still within its
## grace period for the first one.
func is_delivering() -> bool:
	if not _connected:
		return false
	var now := _now()
	if _last_map_at > _connected_at:
		return now - _last_map_at < STALL_SEC
	return now - _connected_at < FIRST_MAP_GRACE_SEC

## The map for `target` (a Moonlight frame number) if it has arrived, else the
## newest one before it. Never a map from a later frame, unless target is 0
## (frame numbers unknown), when the newest map is returned. {} if none.
func pick(target: int) -> Dictionary:
	_mutex.lock()
	var best := {}
	for i in range(_ring.size() - 1, -1, -1):
		var entry: Dictionary = _ring[i]
		if target <= 0 or entry["frame"] <= target:
			best = entry
			break
	_mutex.unlock()
	return best

# StreamPeerTCP, or nightfall-stream's NightfallTcpPeer for a zoned
# link-local address (USB Link), which StreamPeerTCP can't reach. Both offer
# the calls _run() makes, with the same status values.
static func _new_peer(address: String):
	if "%" in address and ClassDB.class_exists("NightfallTcpPeer"):
		return ClassDB.instantiate("NightfallTcpPeer")
	return StreamPeerTCP.new()

func _run() -> void:
	var peer = null
	var cipher = null
	var counter := 0
	var buf := PackedByteArray()
	var retry_at := 0.0
	var stats_at := Time.get_ticks_usec()
	var last_loop_at := stats_at
	var max_loop_gap_us := 0
	var max_read_us := 0
	var max_parse_us := 0
	var max_open_us := 0
	var max_decompress_us := 0
	var max_store_us := 0
	var measured_maps := 0
	while _running:
		var loop_at := Time.get_ticks_usec()
		max_loop_gap_us = maxi(max_loop_gap_us, loop_at - last_loop_at)
		last_loop_at = loop_at
		if loop_at - stats_at >= 1000000:
			if _connected:
				print("[METEOR-DEPTH-TIMING] maps=%d max_loop=%.1f max_read=%.1f max_parse=%.1f max_decrypt=%.1f max_zstd=%.1f max_store=%.1f ms buffered=%d" % [
					measured_maps, max_loop_gap_us / 1000.0, max_read_us / 1000.0,
					max_parse_us / 1000.0, max_open_us / 1000.0,
					max_decompress_us / 1000.0, max_store_us / 1000.0, buf.size()])
			stats_at = loop_at
			max_loop_gap_us = 0
			max_read_us = 0
			max_parse_us = 0
			max_open_us = 0
			max_decompress_us = 0
			max_store_us = 0
			measured_maps = 0
		var now := _now()
		if peer == null:
			if now < retry_at:
				OS.delay_msec(50)
				continue
			retry_at = now + RECONNECT_SEC
			peer = _new_peer(host)
			if peer.connect_to_host(host, port) != OK:
				peer = null
				continue
		peer.poll()
		var status: int = peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTING:
			OS.delay_msec(5)
			continue
		if status != StreamPeerTCP.STATUS_CONNECTED:
			peer = null
			buf = PackedByteArray()
			_connected = false
			continue
		if not _connected:
			peer.set_no_delay(true)
			cipher = ClassDB.instantiate("MeteorChannelCipher")
			var err: String = cipher.init(key, KDF_INFO)
			var hello := HELLO_MAGIC.to_ascii_buffer()
			hello.append_array(cipher.get_public_key())
			if not err.is_empty() or peer.put_data(hello) != OK:
				push_warning("Meteor depth: can't start the encrypted connection (%s)" % err)
				peer.disconnect_from_host()
				peer = null
				continue
			counter = 0
			_connected_at = now
			_connected = true
		var available: int = peer.get_available_bytes()
		if available <= 0:
			OS.delay_usec(IDLE_USEC)
			continue
		var read_at := Time.get_ticks_usec()
		var result: Array = peer.get_partial_data(available)
		max_read_us = maxi(max_read_us, Time.get_ticks_usec() - read_at)
		if result[0] != OK:
			peer.disconnect_from_host()
			peer = null
			buf = PackedByteArray()
			_connected = false
			continue
		var chunk: PackedByteArray = result[1]
		buf.append_array(chunk)
		bytes_received += chunk.size()
		var parse_at := Time.get_ticks_usec()
		var messages := parse_messages(buf)
		max_parse_us = maxi(max_parse_us, Time.get_ticks_usec() - parse_at)
		if messages.size() == 1 and messages[0].has("error"):
			push_warning("Meteor depth: %s; reconnecting" % messages[0]["error"])
			peer.disconnect_from_host()
			peer = null
			buf = PackedByteArray()
			_connected = false
			continue
		var consumed := 0
		var forged := false
		for message: Dictionary in messages:
			consumed = message["payload_end"]
			var pixels: int = message["width"] * message["height"]
			var header := buf.slice(message["header_start"], message["payload_start"])
			var open_at := Time.get_ticks_usec()
			var plain: PackedByteArray = cipher.open(counter, header, buf.slice(message["payload_start"], message["payload_end"]))
			max_open_us = maxi(max_open_us, Time.get_ticks_usec() - open_at)
			counter += 1
			if plain.is_empty():
				forged = true
				break
			var decompress_at := Time.get_ticks_usec()
			var map := plain.decompress(pixels, FileAccess.COMPRESSION_ZSTD)
			max_decompress_us = maxi(max_decompress_us, Time.get_ticks_usec() - decompress_at)
			if map.size() != pixels:
				push_warning("Meteor depth: map for frame %d didn't decompress" % message["frame"])
				continue
			var store_at := Time.get_ticks_usec()
			_store({
				"frame": message["frame"],
				"epoch": message["epoch"],
				"map": map,
				"width": message["width"],
				"height": message["height"],
				"latency_us": message["latency_us"],
			})
			max_store_us = maxi(max_store_us, Time.get_ticks_usec() - store_at)
			measured_maps += 1
		if forged:
			push_warning("Meteor depth: a map didn't decrypt; reconnecting")
			peer.disconnect_from_host()
			peer = null
			buf = PackedByteArray()
			_connected = false
			continue
		if consumed > 0:
			buf = buf.slice(consumed)
	if peer:
		peer.disconnect_from_host()
	_connected = false

func _store(entry: Dictionary) -> void:
	var now := _now()
	if _last_map_at > 0.0 and now - _last_map_at >= 0.1:
		push_warning("[METEOR-DEPTH] Receive gap %.0f ms before frame %d (previous %d)" % [
			(now - _last_map_at) * 1000.0, entry["frame"], newest_frame])
	_mutex.lock()
	# A new stream epoch starts its frame numbers again.
	if not _ring.is_empty() and (entry["epoch"] != _ring[-1]["epoch"] or entry["frame"] < _ring[-1]["frame"]):
		_ring.clear()
	_ring.append(entry)
	while _ring.size() > RING_SIZE:
		_ring.pop_front()
	_mutex.unlock()
	maps_received += 1
	newest_frame = entry["frame"]
	host_latency_ms = entry["latency_us"] / 1000.0
	_last_map_at = now

## The complete messages at the start of buf, each {frame, epoch, width,
## height, latency_us, header_start, payload_start, payload_end} (the payload
## still encrypted); or a single {error} for a stream that isn't Meteor's.
static func parse_messages(buf: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var offset := 0
	while buf.size() - offset >= HEADER_LEN:
		if buf.decode_u32(offset) != MAGIC:
			return [{"error": "bad magic"}]
		if buf.decode_u16(offset + 4) != VERSION:
			return [{"error": "unsupported version %d" % buf.decode_u16(offset + 4)}]
		var header_len := buf.decode_u16(offset + 6)
		var w := buf.decode_u16(offset + 16)
		var h := buf.decode_u16(offset + 18)
		var payload_len := buf.decode_u32(offset + 24)
		if header_len < HEADER_LEN or buf.decode_u8(offset + 20) != 0 or buf.decode_u8(offset + 21) != COMPRESSION_ZSTD:
			return [{"error": "unsupported map format"}]
		if w == 0 or h == 0 or w * h > MAX_MAP_PIXELS or payload_len > w * h + 65536 + 16:
			return [{"error": "bad map size %dx%d (%d bytes)" % [w, h, payload_len]}]
		var end := offset + header_len + payload_len
		if end > buf.size():
			break
		out.append({
			"epoch": buf.decode_u32(offset + 8),
			"frame": buf.decode_u32(offset + 12),
			"width": w,
			"height": h,
			"latency_us": buf.decode_u32(offset + 28),
			"header_start": offset,
			"payload_start": offset + header_len,
			"payload_end": end,
		})
		offset = end
	return out

static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
