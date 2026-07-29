class_name PointerTarget

static func resolve(collider: Node) -> Dictionary:
	if collider == null:
		return {"role": &"", "screen": null, "node": null, "corner_idx": -1}
	var node: Node = collider.get_parent()
	if node == null:
		return {"role": &"", "screen": null, "node": null, "corner_idx": -1}
	var screen: VRScreen = null
	var n: Node = node
	while n != null:
		if n is VRScreen:
			screen = n
			break
		n = n.get_parent()
	return {
		"role": node.get_meta(&"nf_role", &""),
		"screen": screen,
		"node": node,
		"corner_idx": node.get_meta(&"nf_corner_idx", -1),
	}