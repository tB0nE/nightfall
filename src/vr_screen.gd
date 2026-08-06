class_name VRScreen
extends MeshInstance3D

var main: Node3D
var monitor_id: StringName = &"m0"

var mesh_size: Vector2 = Vector2(2.24, 1.26)
var curvature: int = 2
var bezel_mesh: MeshInstance3D = null
var corner_handles: Array = []

var uv_region: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)
var monitor: ScreenLayout.MonitorSpec = null

func apply_monitor(m: ScreenLayout.MonitorSpec, frame_size: Vector2i):
	monitor = m
	uv_region = Vector4(
		float(m.frame_rect.position.x) / float(frame_size.x),
		float(m.frame_rect.position.y) / float(frame_size.y),
		float(m.frame_rect.size.x) / float(frame_size.x),
		float(m.frame_rect.size.y) / float(frame_size.y),
	)
	comp_base_size = m.frame_rect.size
	if material_override is ShaderMaterial:
		material_override.set_shader_parameter("uv_region", uv_region)
	for mat in [comp_shader_mat, comp_shader_mat_left, comp_shader_mat_right]:
		if mat:
			mat.set_shader_parameter("uv_region", uv_region)

var comp_cylinder: Node3D = null
var comp_cylinder_left: Node3D = null
var comp_cylinder_right: Node3D = null
var comp_viewport: SubViewport = null
var comp_viewport_left: SubViewport = null
var comp_viewport_right: SubViewport = null
var comp_yuv_rect: ColorRect = null
var comp_yuv_rect_left: ColorRect = null
var comp_yuv_rect_right: ColorRect = null
var comp_loading_label: Label = null
var comp_loading_label_left: Label = null
var comp_loading_label_right: Label = null
var comp_bezel_rect: ColorRect = null
var comp_bezel_rect_left: ColorRect = null
var comp_bezel_rect_right: ColorRect = null
var comp_shader_mat: ShaderMaterial = null
var comp_shader_mat_left: ShaderMaterial = null
var comp_shader_mat_right: ShaderMaterial = null
var comp_stream_cursor: TextureRect = null
var comp_stream_cursor_circle: ColorRect = null
var comp_stream_cursor_left: TextureRect = null
var comp_stream_cursor_circle_left: ColorRect = null
var comp_stream_cursor_right: TextureRect = null
var comp_stream_cursor_circle_right: ColorRect = null
var comp_layer: Node3D = null
var comp_base_size: Vector2i = Vector2i(1920, 1080)
var _original_mat: Material = null

var _comp_cyl_center := Vector3.ZERO
var _comp_cyl_radius := 0.0
var _comp_cyl_central_angle := 0.0

@onready var grab_bar: MeshInstance3D = %ScreenGrabBar

static var _placeholder_tex: ImageTexture = null

static func placeholder_texture() -> ImageTexture:
	if _placeholder_tex == null:
		var img = Image.create(4, 4, false, Image.FORMAT_RGB8)
		img.fill(Color(0.45, 0.45, 0.45))
		_placeholder_tex = ImageTexture.create_from_image(img)
	return _placeholder_tex

func _ready() -> void:
	set_meta(&"nf_role", &"screen")
	grab_bar.set_meta(&"nf_role", &"grab_bar")
	if material_override:
		material_override = material_override.duplicate()
		if material_override is ShaderMaterial:
			material_override.set_shader_parameter("main_texture", VRScreen.placeholder_texture())

func setup(p_main: Node3D, p_monitor_id: StringName = &"m0") -> void:
	main = p_main
	monitor_id = p_monitor_id

func get_cylinder_radius() -> float:
	if main.comp and main.comp.in_use:
		var cam_to_screen = global_position - main.xr_camera.global_position
		var view_dist = cam_to_screen.length()
		if view_dist < 0.5:
			view_dist = 3.0
		if curvature == 1:
			return view_dist * 3.0
		elif curvature == 2:
			return view_dist * 2.0
		else:
			return view_dist * 100.0
	else:
		return 1000.0 if curvature == 0 else (10.0 if curvature == 1 else 4.0)

func create_corner_handles():
	var offsets = [
		Vector2(-0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(-0.5, -0.5),
		Vector2(0.5, -0.5),
	]
	var corner_ids = ["top-left", "top-right", "bottom-left", "bottom-right"]
	var ms = mesh_size
	var corner_size = ms.x * 0.027
	var col_size = ms.x * 0.067
	for i in range(4):
		var handle = MeshInstance3D.new()
		handle.name = "Corner%d" % i
		handle.set_meta(&"nf_role", &"corner")
		handle.set_meta(&"nf_corner_idx", i)
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1, 1, 1, 0)
		mat.albedo_texture = VRScreen._make_corner_texture(corner_ids[i])
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 127
		var corner_quad = QuadMesh.new()
		corner_quad.size = Vector2(corner_size, corner_size)
		corner_quad.orientation = PlaneMesh.FACE_Z
		handle.mesh = corner_quad
		handle.material_override = mat
		var area = Area3D.new()
		area.collision_layer = 2
		var shape = CollisionShape3D.new()
		var col = BoxShape3D.new()
		col.size = Vector3(col_size, col_size, 0.1)
		shape.shape = col
		shape.position = Vector3(offsets[i].x * col_size, offsets[i].y * col_size, 0)
		area.add_child(shape)
		handle.add_child(area)
		handle.position = Vector3(offsets[i].x * (ms.x + corner_size), offsets[i].y * (ms.y + corner_size), 0)
		add_child(handle)
		corner_handles.append(handle)

func update_corner_positions():
	var ms = mesh_size
	var radius = get_cylinder_radius()
	var half_angle = ms.x / radius * 0.5
	var edge_x = sin(half_angle) * radius
	var edge_z = -(cos(half_angle) * radius - radius)
	var offsets = [
		Vector2(-0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(-0.5, -0.5),
		Vector2(0.5, -0.5),
	]
	var corner_size = ms.x * 0.027
	var col_size = ms.x * 0.067
	var grab_bar_off = ms.y * 0.119
	for i in range(4):
		var handle = corner_handles[i]
		if handle.mesh is QuadMesh:
			handle.mesh.size = Vector2(corner_size, corner_size)
		for child in handle.get_children():
			if child is Area3D:
				for c in child.get_children():
					if c is CollisionShape3D and c.shape is BoxShape3D:
						c.shape.size = Vector3(col_size, col_size, 0.1)
						c.position = Vector3(offsets[i].x * col_size, offsets[i].y * col_size, 0)
		var cy = offsets[i].y * (ms.y + corner_size)
		var a = half_angle if offsets[i].x > 0 else -half_angle
		var cx = edge_x if offsets[i].x > 0 else -edge_x
		if offsets[i].x > 0:
			cx += corner_size * 0.5
		else:
			cx -= corner_size * 0.5
		handle.position = Vector3(cx, cy, edge_z)
		handle.rotation.y = -a
	grab_bar.position.y = -ms.y / 2.0 - grab_bar_off
	if grab_bar.mesh is CylinderMesh:
		var grab_r = ms.x * 0.0045
		var grab_h = ms.x * 0.134
		grab_bar.mesh.top_radius = grab_r
		grab_bar.mesh.bottom_radius = grab_r
		grab_bar.mesh.height = grab_h
	var grab_area = grab_bar.get_node_or_null("Area3D")
	if grab_area:
		var grab_shape = grab_area.get_node_or_null("CollisionShape3D")
		if grab_shape and grab_shape.shape is BoxShape3D:
			grab_shape.shape.size = Vector3(ms.x * 0.134, ms.y * 0.079, 0.1)

func create_bezel():
	bezel_mesh = MeshInstance3D.new()
	bezel_mesh.name = "Bezel"
	var bezel_quad = QuadMesh.new()
	bezel_mesh.mesh = bezel_quad
	var bezel_mat = StandardMaterial3D.new()
	bezel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bezel_mat.albedo_color = Color(0, 0, 0, 1)
	bezel_mesh.material_override = bezel_mat
	bezel_mesh.position = Vector3(0, 0, -0.005)
	add_child(bezel_mesh)
	update_bezel_size()

func update_bezel_size():
	if not bezel_mesh:
		return
	var ms = mesh_size
	var bezel_pad = 0.04
	var bezel_size = ms + Vector2(bezel_pad, bezel_pad)
	if curvature == 0:
		var bezel_quad = QuadMesh.new()
		bezel_quad.size = bezel_size
		bezel_mesh.mesh = bezel_quad
		bezel_mesh.position = Vector3(0, 0, -0.005)
	else:
		var radius = get_cylinder_radius()
		var subdivide = 32
		var v_subdivide = 16
		var angle = bezel_size.x / radius
		var verts = PackedVector3Array()
		var uvs = PackedVector2Array()
		var indices = PackedInt32Array()
		for j in range(subdivide + 1):
			for i in range(v_subdivide + 1):
				var t = float(j) / subdivide
				var u = float(i) / v_subdivide
				var a = -angle * 0.5 + angle * t
				var x = sin(a) * radius
				var z = -(cos(a) * radius - radius) - 0.005
				var y = (u - 0.5) * bezel_size.y
				verts.append(Vector3(x, y, z))
				uvs.append(Vector2(t, 1.0 - u))
		var cols = v_subdivide + 1
		for j in range(subdivide):
			for i in range(v_subdivide):
				var idx = j * cols + i
				indices.append(idx)
				indices.append(idx + 1)
				indices.append(idx + cols)
				indices.append(idx + 1)
				indices.append(idx + cols + 1)
				indices.append(idx + cols)
		var arr = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_TEX_UV] = uvs
		arr[Mesh.ARRAY_INDEX] = indices
		var arr_mesh = ArrayMesh.new()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		bezel_mesh.mesh = arr_mesh
		bezel_mesh.position = Vector3.ZERO

func apply_curvature():
	var ms = mesh_size
	if curvature == 0:
		var quad = QuadMesh.new()
		quad.size = ms
		mesh = quad
		update_shader_for_mesh()
		set_collision_flat()
		return
	var subdivide = 32
	var v_subdivide = 16
	var radius = get_cylinder_radius()
	var angle = ms.x / radius
	var verts = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	for j in range(subdivide + 1):
		for i in range(v_subdivide + 1):
			var t = float(j) / subdivide
			var u = float(i) / v_subdivide
			var a = -angle * 0.5 + angle * t
			var x = sin(a) * radius
			var z = -(cos(a) * radius - radius)
			var y = (u - 0.5) * ms.y
			verts.append(Vector3(x, y, z))
			uvs.append(Vector2(t, 1.0 - u))
	var cols = v_subdivide + 1
	for j in range(subdivide):
		for i in range(v_subdivide):
			var idx = j * cols + i
			indices.append(idx)
			indices.append(idx + 1)
			indices.append(idx + cols)
			indices.append(idx + 1)
			indices.append(idx + cols + 1)
			indices.append(idx + cols)
	var arr = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var arr_mesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh = arr_mesh
	update_shader_for_mesh()
	set_collision_curved(verts, indices)

func update_shader_for_mesh():
	set_collision_flat()
	update_corner_positions()
	if bezel_mesh:
		update_bezel_size()

func set_collision_flat():
	var col_shape = get_node_or_null("Area3D/CollisionShape3D")
	if not col_shape:
		return
	var box = BoxShape3D.new()
	box.size = Vector3(mesh_size.x, mesh_size.y, 0.01)
	col_shape.shape = box

func set_collision_curved(verts: PackedVector3Array, indices: PackedInt32Array):
	var col_shape = get_node_or_null("Area3D/CollisionShape3D")
	if not col_shape:
		return
	var faces = PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(verts[indices[i]])
		faces.append(verts[indices[i + 1]])
		faces.append(verts[indices[i + 2]])
	var concave = ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	col_shape.shape = concave

func resize_to_aspect(w: int, h: int):
	var aspect = float(w) / float(h)
	var new_w = mesh_size.x
	var new_h = new_w / aspect
	if new_h < 0.4:
		new_h = 0.4
		new_w = new_h * aspect
	mesh_size = Vector2(new_w, new_h)
	if curvature == 0:
		mesh.size = mesh_size
		set_collision_flat()
	else:
		apply_curvature()
	update_corner_positions()
	if bezel_mesh:
		update_bezel_size()

var _corner_resize_started: bool = false
var _corner_start_width: float = 0.0
var _corner_start_hit_x: float = 0.0

func begin_corner_resize():
	_corner_resize_started = false

func apply_corner_resize(ray_origin: Vector3, ray_dir: Vector3, corner_idx: int, tile_aspect: float) -> void:
	var plane_normal = -global_transform.basis.z
	var plane_point = global_position
	var denom = ray_dir.dot(plane_normal)
	if absf(denom) < 0.0001:
		return
	var t = (plane_point - ray_origin).dot(plane_normal) / denom
	if t < 0:
		return
	var hit_world = ray_origin + ray_dir * t
	var local_hit = to_local(hit_world)

	if not _corner_resize_started:
		_corner_resize_started = true
		_corner_start_width = mesh_size.x
		_corner_start_hit_x = local_hit.x
		return

	var sign = -1.0 if corner_idx in [0, 2] else 1.0
	var new_w: float
	if curvature == 0:
		var dx = local_hit.x - _corner_start_hit_x
		new_w = _corner_start_width + dx * sign * 2.0
	else:
		var radius = get_cylinder_radius()
		var start_a = asin(clampf(_corner_start_hit_x / radius, -1.0, 1.0))
		var cur_a = asin(clampf(local_hit.x / radius, -1.0, 1.0))
		var da = cur_a - start_a
		new_w = _corner_start_width + da * radius * sign * 2.0
	new_w = maxf(new_w, 0.6)
	var new_h = new_w / tile_aspect
	if new_h < 0.4:
		new_h = 0.4
		new_w = new_h * tile_aspect

	mesh_size = Vector2(new_w, new_h)
	if curvature == 0:
		mesh.size = mesh_size
		set_collision_flat()
	else:
		apply_curvature()

	update_corner_positions()
	update_bezel_size()

func end_corner_resize():
	_corner_resize_started = false

static func _make_corner_texture(corner: String, size: int = 128, thickness: int = 20, opacity: float = 0.08) -> ImageTexture:
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var color = Color(1, 1, 1, opacity)
	var s = size
	var t = thickness
	var pad = 16
	match corner:
		"top-left":
			img.fill_rect(Rect2i(pad, pad, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(pad, pad + t, t, s - 2 * pad - t), color)
		"top-right":
			img.fill_rect(Rect2i(pad, pad, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(s - pad - t, pad + t, t, s - 2 * pad - t), color)
		"bottom-left":
			img.fill_rect(Rect2i(pad, s - pad - t, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(pad, pad, t, s - 2 * pad - t), color)
		"bottom-right":
			img.fill_rect(Rect2i(pad, s - pad - t, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(s - pad - t, pad, t, s - 2 * pad - t), color)
	return ImageTexture.create_from_image(img)

func get_cylinder_normal_at(hit_point: Vector3) -> Vector3:
	if curvature == 0 or not comp_layer:
		return -global_transform.basis.z
	var screen_forward = -global_transform.basis.z
	if _comp_cyl_radius < 0.01:
		return screen_forward
	var cyl_center = global_position - screen_forward * _comp_cyl_radius
	var to_hit = hit_point - cyl_center
	to_hit.y = 0.0
	if to_hit.length() < 0.001:
		return screen_forward
	return to_hit.normalized()

func hit_point_to_uv(hit_point: Vector3) -> Vector2:
	var ms = mesh_size
	var local_pos = to_local(hit_point)
	var uv_x = 0.0
	var uv_y = clampf((ms.y * 0.5 - local_pos.y) / ms.y, 0.0, 1.0)
	if curvature == 0:
		uv_x = clampf((local_pos.x + ms.x * 0.5) / ms.x, 0.0, 1.0)
	elif main.comp and main.comp.in_use and _comp_cyl_radius > 0.01 and _comp_cyl_central_angle > 0.001:
		var cam_pos = main.xr_camera.global_position
		var ray_dir = (hit_point - cam_pos).normalized()
		var screen_right = global_transform.basis.x
		var screen_forward = -global_transform.basis.z
		var oc = cam_pos - _comp_cyl_center
		var oc_right = oc.dot(screen_right)
		var oc_fwd = oc.dot(screen_forward)
		var d_right = ray_dir.dot(screen_right)
		var d_fwd = ray_dir.dot(screen_forward)
		var a = d_right * d_right + d_fwd * d_fwd
		var b = 2.0 * (oc_right * d_right + oc_fwd * d_fwd)
		var c = oc_right * oc_right + oc_fwd * oc_fwd - _comp_cyl_radius * _comp_cyl_radius
		var disc = b * b - 4.0 * a * c
		if disc < 0.0:
			uv_x = 0.5
		else:
			var sqrt_disc = sqrt(disc)
			var t1 = (-b - sqrt_disc) / (2.0 * a)
			var t2 = (-b + sqrt_disc) / (2.0 * a)
			var t = t1 if t1 > 0.001 else t2
			if t > 0.0:
				var hit_world = cam_pos + ray_dir * t
				var hit_local = to_local(hit_world)
				uv_y = clampf((ms.y * 0.5 - hit_local.y) / ms.y, 0.0, 1.0)
				var hit_cyl = hit_world - _comp_cyl_center
				var hit_right = hit_cyl.dot(screen_right)
				var hit_fwd = hit_cyl.dot(screen_forward)
				var hit_angle = atan2(hit_right, hit_fwd)
				uv_x = clampf((hit_angle + _comp_cyl_central_angle * 0.5) / _comp_cyl_central_angle, 0.0, 1.0)
			else:
				uv_x = 0.5
	else:
		var radius = 10.0 if curvature == 1 else 4.0
		var total_angle = ms.x / radius
		var chord = clampf(local_pos.x / radius, -1.0, 1.0)
		uv_x = clampf((asin(chord) + total_angle * 0.5) / total_angle, 0.0, 1.0)
	return Vector2(uv_x, uv_y)