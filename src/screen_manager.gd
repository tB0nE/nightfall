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

func resize_screen_to_aspect(stream_w: int, stream_h: int):
	for s in main.screens:
		if s.monitor and s.monitor.frame_rect.size.y > 0:
			s.resize_to_aspect(s.monitor.frame_rect.size.x, s.monitor.frame_rect.size.y)
		else:
			s.resize_to_aspect(stream_w, stream_h)
	if main.comp_layer and main.comp_layer is OpenXRCompositionLayerQuad:
		main.comp_layer.set_quad_size(main._mesh_size)

func cycle_curvature():
	main.curvature = (main.curvature + 1) % 3
	for s in main.screens:
		s.curvature = main.curvature
		s.apply_curvature()
	if main.comp.in_use:
		main.comp.switch_to_comp_layer()
	main.ui_controller.update_option_btn(main._ui_curve_btn, main.curvature_labels[main.curvature])
	main.state_manager.save_state()

func apply_curvature():
	for s in main.screens:
		s.apply_curvature()

func _get_cylinder_radius() -> float:
	return main.primary_screen.get_cylinder_radius()