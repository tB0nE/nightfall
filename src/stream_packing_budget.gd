class_name StreamPackingBudget
extends RefCounted

# Match the existing Quest decode guards; H.264+ is the same spatial codec.
static func options(codec: int, quest2: bool, target := Vector2i.ZERO, percent := 100) -> Dictionary:
	var axis := 4032 if codec == 0 or codec == 5 else 8192
	var pixels := axis * axis if axis == 4032 else 21233664
	if quest2: pixels = mini(pixels, 1920 * 1080)
	return {"nf_budget": 1, "nf_max_axis": axis, "nf_max_pixels": pixels,
		"nf_physical_w": target.x, "nf_physical_h": target.y, "nf_physical_scale": percent}

static func query(options: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append("outputs=" + str(options.get("capture_outputs", "")).uri_encode())
	parts.append("virtual_displays=" + str(options.get("virtual_displays", 0)))
	for key in ["virtual_only", "virtual_modes", "nf_budget", "nf_max_axis", "nf_max_pixels", "nf_physical_w", "nf_physical_h", "nf_physical_scale", "nf_physical_modes"]:
		if options.has(key): parts.append(key + "=" + str(options[key]).uri_encode())
	return "&".join(parts)

static func full_size_fits(plan: Dictionary, budget: Dictionary) -> bool:
	if int(plan.get("packing_budget_version", 0)) != 1 or not plan.get("packing_fits", false): return false
	var size := StreamRestartPolicy.planned_size(plan)
	return size.x > 0 and size.y > 0 and size.x <= int(budget.nf_max_axis) and size.y <= int(budget.nf_max_axis) and size.x * size.y <= int(budget.nf_max_pixels)
