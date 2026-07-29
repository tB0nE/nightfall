class_name VRPanelBase
extends Node3D

var main: Node3D
var viewport: SubViewport
var mesh_instance: MeshInstance3D
var area: Area3D
var collision_shape: CollisionShape3D
var mesh_size: Vector2
var viewport_size: Vector2i

var _saved_offset: Vector3 = Vector3.ZERO
var _saved_rot_y: float = 0.0
var _saved_rot_x: float = 0.0
var _has_saved_offset: bool = false

func _init(owner: Node3D):
	main = owner

func _setup_viewport(vp_name: String):
	viewport = SubViewport.new()
	viewport.name = vp_name
	viewport.size = viewport_size
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

func _setup_mesh(mesh_name: String):
	var quad = QuadMesh.new()
	quad.size = mesh_size
	quad.flip_faces = true
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = mesh_name
	mesh_instance.mesh = quad
	var tex_mat = StandardMaterial3D.new()
	tex_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tex_mat.albedo_color = Color(1, 1, 1, 0.85)
	tex_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tex_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	tex_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tex_mat.albedo_texture = viewport.get_texture()
	mesh_instance.set_surface_override_material(0, tex_mat)
	mesh_instance.extra_cull_margin = 10.0
	mesh_instance.set_meta(&"nf_role", &"panel")
	add_child(mesh_instance)

func _setup_collision():
	area = Area3D.new()
	area.name = "Area3D"
	area.collision_layer = 2
	mesh_instance.add_child(area)
	var shape = BoxShape3D.new()
	shape.size = Vector3(mesh_size.x, mesh_size.y, 0.02)
	collision_shape = CollisionShape3D.new()
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 0, 0.01)
	area.add_child(collision_shape)

func _set_collision_active(active: bool):
	if not area:
		return
	area.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	area.monitorable = active
	area.monitoring = active

func _hide_initially():
	visible = false
	_set_collision_active(false)

func _setup_grab_bar(parent_vp: SubViewport, bar_height: int = 38, offset_top: int = -79, offset_bottom: int = -37, radius: int = 19):
	var bottom_box = HBoxContainer.new()
	bottom_box.anchor_left = 0.0
	bottom_box.anchor_right = 1.0
	bottom_box.anchor_top = 1.0
	bottom_box.anchor_bottom = 1.0
	bottom_box.offset_top = offset_top
	bottom_box.offset_bottom = offset_bottom
	bottom_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_box.add_theme_constant_override("separation", 0)
	parent_vp.add_child(bottom_box)

	var left_spacer = Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_box.add_child(left_spacer)

	var grab = PanelContainer.new()
	grab.name = "CompGrabBar"
	grab.custom_minimum_size = Vector2(0, bar_height)
	grab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grab_style = StyleBoxFlat.new()
	grab_style.bg_color = Color(1, 1, 1, 0.08)
	grab_style.set_corner_radius_all(radius)
	grab.add_theme_stylebox_override("panel", grab_style)
	bottom_box.add_child(grab)

	var right_spacer = Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_box.add_child(right_spacer)

func _make_simple_btn_style(bg: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.set_bg_color(bg)
	s.set_border_width_all(0)
	s.set_corner_radius_all(8)
	s.set_content_margin_all(4)
	return s

func _apply_border_active(border_panel: PanelContainer, active: bool, base_color: Color, active_color: Color):
	if not border_panel:
		return
	var style = border_panel.get_theme_stylebox("panel")
	if style and style is StyleBoxFlat:
		style = style.duplicate()
		style.border_color = active_color if active else base_color
		border_panel.add_theme_stylebox_override("panel", style)

func _save_offset():
	var scr_basis = main.primary_screen.global_transform.basis.inverse()
	_saved_offset = scr_basis * (global_position - main.primary_screen.global_position)
	_saved_rot_y = rotation.y - main.primary_screen.global_rotation.y
	_saved_rot_x = rotation.x
	_has_saved_offset = true

func _place_default():
	pass

func toggle():
	var new_vis = not visible
	if new_vis:
		if _has_saved_offset:
			global_position = main.primary_screen.global_position + main.primary_screen.global_transform.basis * _saved_offset
			rotation.y = main.primary_screen.global_rotation.y + _saved_rot_y
			rotation.x = _saved_rot_x
		else:
			_place_default()
			_has_saved_offset = true
		_save_offset()
	visible = new_vis
	_set_collision_active(new_vis)
	if not new_vis:
		_on_hide()

func _on_hide():
	pass

func reset_position():
	_has_saved_offset = false
