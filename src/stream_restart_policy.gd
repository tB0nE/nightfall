class_name StreamRestartPolicy
extends RefCounted

# /cancel's HTTP 200 is not enough: permission/busy errors live in its XML.
static func cancel_acknowledged(reply: String) -> bool:
	return cancel_outcome(reply) == 1

# 1 = teardown acknowledged, 0 = transient/unavailable, -1 = rejected.
static func cancel_outcome(reply: String) -> int:
	if reply.is_empty() or reply.length() > 65536: return 0
	var xml := XMLParser.new()
	if xml.open_buffer(reply.to_utf8_buffer()) != OK: return 0
	var status := 0
	var cancel := false
	while xml.read() == OK:
		if xml.get_node_type() != XMLParser.NODE_ELEMENT: continue
		if xml.get_node_name() == "root":
			status = int(xml.get_named_attribute_value_safe("status_code"))
		elif xml.get_node_name() == "cancel":
			if xml.read() == OK and xml.get_node_type() == XMLParser.NODE_TEXT:
				cancel = xml.get_node_data().strip_edges() == "1"
	if status == 200 and cancel: return 1
	if status >= 400 and status < 500 and status != 409: return -1
	return 0

static func replacement_ready(status: Dictionary, previous_instance: String) -> bool:
	var instance: String = str(status.get("instance", ""))
	return status.get("running", false) == true and not instance.is_empty() and instance != previous_instance

static func planned_size(plan: Dictionary) -> Vector2i:
	var size = plan.get("frame_size", [])
	if not size is Array or size.size() != 2: return Vector2i.ZERO
	for n in size:
		if (not n is int and not n is float) or not is_finite(float(n)) or n < 2 or n > 32768 or n != floor(n): return Vector2i.ZERO
	return Vector2i(int(size[0]), int(size[1]))
