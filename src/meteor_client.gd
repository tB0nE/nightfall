class_name MeteorClient
extends RefCounted

## Nightfall Meteor (meteor/) is an optional companion app on the Sunshine PC.
## Before each launch the client asks it, on DISCOVERY_PORT, which ports to
## use. When it answers, the launch, RTSP, and stream traffic go through
## Meteor's ports instead of Sunshine's; Meteor forwards them to Sunshine.

## Keep in sync with DEFAULT_DISCOVERY_PORT in meteor/src/config.rs.
const DISCOVERY_PORT := 47900
const PROTOCOL_VERSION := 1
const PROBE_TIMEOUT_SEC := 0.8
## Read by NightfallComputerManager::establish_stream() in place of the host's
## saved HTTPS port.
const HTTPS_PORT_OPTION := "meteor_https_port"

## Meteor's port map for this host, or {} when Meteor isn't running there.
## sunshine_https_port guards against a Meteor that fronts a different
## Sunshine instance on the same PC.
static func probe(owner: Node, ip: String, sunshine_https_port: int) -> Dictionary:
	# Godot's HTTP client can't reach a zoned link-local address (USB Link).
	if ip.is_empty() or ip.to_lower().begins_with("fe80:"):
		return {}
	var request := HTTPRequest.new()
	request.timeout = PROBE_TIMEOUT_SEC
	owner.add_child(request)
	var host := "[%s]" % ip if ":" in ip else ip
	var err := request.request("http://%s:%d/meteor" % [host, DISCOVERY_PORT])
	if err != OK:
		request.queue_free()
		return {}
	var result: Array = await request.request_completed
	request.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		return {}
	return parse_info(PackedByteArray(result[3]).get_string_from_utf8(), sunshine_https_port)

static func parse_info(body: String, sunshine_https_port: int) -> Dictionary:
	# Something else may answer on the port; JSON.parse_string() would log an error.
	var json := JSON.new()
	if json.parse(body) != OK:
		return {}
	var info = json.data
	if not info is Dictionary or info.get("service", "") != "nightfall-meteor":
		return {}
	if int(info.get("protocol", 0)) != PROTOCOL_VERSION:
		push_warning("Nightfall Meteor speaks protocol %d, expected %d" % [int(info.get("protocol", 0)), PROTOCOL_VERSION])
		return {}
	var ports = info.get("ports", {})
	var sunshine = info.get("sunshine", {})
	if not ports is Dictionary or not sunshine is Dictionary:
		return {}
	if int(sunshine.get("https", 0)) != sunshine_https_port:
		return {}
	if int(ports.get("https", 0)) <= 0 or int(ports.get("rtsp", 0)) <= 0:
		return {}
	return info

## Points Sunshine's RTSP session URL at Meteor's RTSP port. moonlight-common-c
## only takes the port from this URL; it connects to the host it was given.
static func route_rtsp_url(session_url: String, info: Dictionary) -> String:
	if info.is_empty() or session_url.is_empty():
		return session_url
	var port_re := RegEx.create_from_string(":(\\d+)/?$")
	var found := port_re.search(session_url)
	if found == null:
		return session_url
	return session_url.substr(0, found.get_start(1)) + str(int(info["ports"]["rtsp"])) + session_url.substr(found.get_end(1))

## Keep in sync with FORMAT_PCM_S16LE_48K_MONO in meteor/src/mic.rs.
const MIC_FORMAT := "pcm_s16le_48k_mono"

## Meteor's microphone offer ({port, formats}), or {} when it has no
## microphone device or none in a format this client sends.
static func mic_info(info: Dictionary) -> Dictionary:
	var mic = info.get("mic", {})
	if not mic is Dictionary or int(mic.get("port", 0)) <= 0:
		return {}
	var formats = mic.get("formats", [])
	if not formats is Array or not formats.has(MIC_FORMAT):
		return {}
	return mic

## Meteor's host depth offer ({port, width, height, model, ...}), or {} when
## it isn't offering depth in a format this client reads.
static func depth_info(info: Dictionary) -> Dictionary:
	var depth = info.get("depth", {})
	if not depth is Dictionary or depth.is_empty():
		return {}
	var formats = depth.get("formats", [])
	if not formats is Array or not formats.has("L8") or depth.get("compression", "") != "zstd":
		return {}
	if int(depth.get("port", 0)) <= 0 or int(depth.get("width", 0)) <= 0 or int(depth.get("height", 0)) <= 0:
		return {}
	return depth
