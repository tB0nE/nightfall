class_name WorkspaceStability
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

## OpenXR gives the NEW natural origin in the OLD coordinate system.
## Convert scene poses in the opposite direction, preserving their physical location.
static func correction(previous_from_new: Transform3D, world_from_tracking: Transform3D) -> Transform3D:
	return world_from_tracking * previous_from_new.affine_inverse() * world_from_tracking.affine_inverse()

func process() -> void:
	if not main.is_xr_active or not main.native_xr_renderer:
		return
	var renderer = main.native_xr_renderer.renderer
	if renderer == null or not renderer.has_method("consume_reference_space_changes"):
		return
	var interface = XRServer.find_interface("OpenXR")
	var mode: int = interface.get_play_area_mode() if interface else -1
	var space := "stage" if mode == XRInterface.XR_PLAY_AREA_STAGE else "local" if mode == XRInterface.XR_PLAY_AREA_SITTING else "local_floor"
	for change in renderer.consume_reference_space_changes():
		if main._startup_reposition >= 0: continue
		if change.get("space", "") != space:
			continue
		if not change.get("valid", false):
			main._log("[PLACEMENT] Runtime lost the old tracking origin; exact room placement cannot be restored (space=%s)" % space)
			continue
		var previous_from_new: Transform3D = change["previous_from_new"]
		if not previous_from_new.is_finite():
			main._log("[PLACEMENT] Ignored non-finite runtime origin change")
			continue
		previous_from_new.origin *= XRServer.world_scale
		var frame: Transform3D = main.xr_origin.global_transform * XRServer.get_reference_frame()
		var delta := correction(previous_from_new, frame)
		var nodes: Array = main.screens.duplicate()
		for panel in [main.ui_panel_3d, main.virtual_keyboard]:
			if is_instance_valid(panel): nodes.append(panel)
		# Skip descendants of moved nodes: they inherit the same correction.
		for node in nodes:
			if not is_instance_valid(node): continue
			var inherited := false
			for other in nodes:
				if other != node and is_instance_valid(other) and other.is_ancestor_of(node):
					inherited = true
			if not inherited: node.global_transform = delta * node.global_transform
		for screen in main.screens:
			screen.apply_curvature()
		if main.comp.in_use: main.comp.update_cylinder_params()
		# Placements for temporarily absent monitors use the same scene frame.
		if main.state_manager:
			var local_delta: Transform3D = main.global_transform.affine_inverse() * delta * main.global_transform
			for placement in main.state_manager.remembered_placements.values():
				var p: Array = placement.get("pos", [0, 0, 0])
				var r: Array = placement.get("rot", [0, 0, 0])
				var t := local_delta * Transform3D(Basis.from_euler(Vector3(r[0], r[1], r[2])), Vector3(p[0], p[1], p[2]))
				placement["pos"] = [t.origin.x, t.origin.y, t.origin.z]
				var angles := t.basis.get_euler()
				placement["rot"] = [angles.x, angles.y, angles.z]
			main.state_manager.save_state()
		if main.xr_interaction: main.xr_interaction.cancel_transient_interactions("tracking origin changed")
		main._sync_composition_panels()
		main._log("[PLACEMENT] Preserved workspace across tracking-origin change: %s" % previous_from_new)
