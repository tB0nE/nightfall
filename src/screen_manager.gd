class_name ScreenManager
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func create_corner_handles():
	main.primary_screen.create_corner_handles()

func create_corner_handles_for(s: VRScreen):
	s.create_corner_handles()

func update_corner_positions():
	main.primary_screen.update_corner_positions()

func create_bezel():
	main.primary_screen.create_bezel()

func create_bezel_for(s: VRScreen):
	s.create_bezel()

func update_bezel_size():
	for s in main.screens:
		s.update_bezel_size()

func toggle_bezel():
	main.bezel_enabled = not main.bezel_enabled
	for s in main.screens:
		if s.bezel_mesh:
			s.bezel_mesh.visible = main.bezel_enabled if not main.comp.in_use else false
	main.ui_controller.update_option_btn(main._ui_bezel_btn, "On" if main.bezel_enabled else "Off")
	main.comp.update_bezel()
	main.state_manager.save_state()

# GitHub issue #17 (2026-08-20): used to prefer s.monitor.frame_rect.size
# over the real stream_w/stream_h whenever a monitor spec existed - correct
# for genuine multi-monitor manifests (Polaris hosts report each monitor's
# real per-output resolution there), but WRONG for any single-screen/non-
# manifest host (Sunshine et al.): s.monitor there is just whatever the
# welcome screen's fixed 16:9 placeholder last set, never updated again, so
# the mesh stayed 16:9 forever regardless of the actual stream's real aspect
# (a 21:9 source got squeezed into a 16:9-shaped quad). A shader-side
# letterbox/pillarbox fix was tried first and worked, but the better fix is
# this: always resize the mesh itself to the REAL decoded content's aspect -
# resize_to_aspect() below already keeps WIDTH anchored to mesh_size.x (i.e.
# whatever this screen's current grid-cell footprint width already is) and
# only adjusts height, so a 21:9 screen ends up shorter (fits the same grid
# column, less vertical space) and a 4:3 screen taller - the actual visible
# mesh shape now matches reality instead of hiding the mismatch behind black
# bars. s.uv_region encodes what fraction of the (possibly multi-monitor
# composite) stream_w/stream_h this particular screen shows - use just its
# own slice, not the whole composite, or a genuine future multi-monitor
# layout would misjudge every screen's fit against the WRONG total. Height
# growing past a single grid row (e.g. a 4:3 source) can currently overlap a
# vertical neighbor - a real but deliberately deferred gap, not something
# this fix attempts to solve yet (see MULTI_MONITOR grid work).
func resize_screen_to_aspect(stream_w: int, stream_h: int):
	for s in main.screens:
		var content_w = int(float(stream_w) * s.uv_region.z)
		var content_h = int(float(stream_h) * s.uv_region.w)
		s.resize_to_aspect(content_w, content_h)
	if main.comp_layer and main.comp_layer is OpenXRCompositionLayerQuad:
		main.comp_layer.set_quad_size(main._mesh_size)

func cycle_curvature():
	main.curvature = (main.curvature + 1) % 3
	for s in main.screens:
		s.curvature = main.curvature
		s.apply_curvature()
	main.settings_controller.reflow_grid_screens()
	if main.comp.in_use:
		main.comp.switch_to_comp_layer()
	main.ui_controller.update_option_btn(main._ui_curve_btn, main.curvature_labels[main.curvature])
	main.state_manager.save_state()

func apply_curvature():
	for s in main.screens:
		s.apply_curvature()

func _get_cylinder_radius() -> float:
	return main.primary_screen.get_cylinder_radius()