class_name VRScreen
extends MeshInstance3D

var main: Node3D
var monitor_id: StringName = &"m0"

var mesh_size: Vector2 = Vector2(2.24, 1.26)
var curvature: int = 2
var bezel_mesh: MeshInstance3D = null
var corner_handles: Array = []

var display_crop := Vector4(0, 0, 1, 1)

func display_content_uv(uv: Vector2) -> Vector2:
	return ScreenImageOptions.content_uv(uv, display_crop)

var uv_region: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)
var monitor: ScreenLayout.MonitorSpec = null
var content_tabs: ScreenContentTabs = ScreenContentTabs.new()

# Browser sessions own an RGBA image, not a crop of the primary stream.
func bind_independent_browser_texture(texture: Texture2D) -> void:
	uv_region = Vector4(0, 0, 1, 1)
	var mats: Array = [comp_shader_mat, comp_shader_mat_left, comp_shader_mat_right, _original_mat]
	if material_override is ShaderMaterial:
		mats.append(material_override)
	for mat in mats:
		if not mat is ShaderMaterial:
			continue
		mat.set_shader_parameter("main_texture", texture)
		mat.set_shader_parameter("uv_region", uv_region)
		mat.set_shader_parameter("yuv_mode", 0)
		mat.set_shader_parameter("stereo_mode", 0)
		mat.set_shader_parameter("depth_texture", null)
		mat.set_shader_parameter("tex_y", null)
		mat.set_shader_parameter("tex_u", null)
		mat.set_shader_parameter("tex_v", null)

# Client-side VR presentation grid state (see MonitorGrid/MonitorPresets).
# grid_pos is (-1,-1) until this screen has ever been placed by the grid
# system (preset apply or a grid-mode-on drag); grid_mode false means the
# screen was last placed freely and the grid system leaves it alone until
# it's grabbed again with grid mode on.
var placement_radius: float = 0.0
## The single grid surface this screen lies on (ScreenPlacementGrid.Shape).
## FLAT means none: the screen keeps its own curvature setting. On a cylinder or
## sphere grid the surface, not that setting, gives the screen its shape.
var surface: int = 0
## Set by the placement grid (ScreenPlacementGrid, a capsule surface):
## surface_y: the screen centre's grid height on the surface.
## surface_on_cap: the screen lies on the sphere part (the whole sphere grid,
## or the cylinder grid's rows above and below) rather than the cylinder
## grid's straight middle section.
## surface_straight: half-height of that straight section (0 on a sphere grid).
## surface_lat: the latitude of this node's own frame on the sphere.
## The patch's latitudes follow from these and the current size, so a resized
## screen keeps its proportions.
var surface_lat := 0.0
var surface_y := 0.0
var surface_straight := 0.0
var surface_on_cap := false

## Radius of the sphere part. Longitudes still step by arc metres at
## placement_radius, so columns line up with the straight section.
func sphere_r() -> float:
	return ScreenPlacementGrid.sphere_radius(placement_radius, surface_straight)

## Lock Screens is on and this is a secondary: its grab bar, shortcuts and
## corners are hidden and ignore the pointer, so the screen can be used even
## where another screen's controls would overlap it.
func controls_locked() -> bool:
	return main != null and main.get("settings") != null and main.settings.secondary_screens_locked \
		and self != main.primary_screen

var _controls_lock_applied := false

## Turn the pointer targets of the screen's controls off or on to match the lock.
func sync_controls_lock() -> void:
	var locked := controls_locked()
	if locked == _controls_lock_applied: return
	_controls_lock_applied = locked
	var areas: Array = shortcut_areas.values()
	var grab_area = grab_bar.get_node_or_null("Area3D")
	if grab_area: areas.append(grab_area)
	for handle in corner_handles:
		var handle_area = handle.get_node_or_null("Area3D")
		if handle_area: areas.append(handle_area)
	for area in areas:
		if not is_instance_valid(area): continue
		for child in area.get_children():
			if child is CollisionShape3D: child.set_deferred("disabled", locked)

## On a sphere cap of the grid (where it goes; see on_sphere() for its shape).
func on_cap() -> bool:
	return on_surface() and surface_on_cap

## Drawn as a patch of the grid sphere: a Curved screen on a cap. Flat and
## Slight Curve screens keep their own shape there.
func on_sphere() -> bool:
	return on_cap() and curvature >= 2

## How far the screen sits in front of its place on the surface (a Flat or
## Slight Curve panel; see ScreenPlacementGrid.panel_inset()). Set when it is
## placed, so the surface pose stays consistent until it is placed again.
var surface_inset := 0.0

## The pose of the screen's place on the grid surface, behind its panel.
func surface_pose() -> Transform3D:
	if surface_inset == 0.0: return global_transform
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(0, 0, -surface_inset))

## The inset for the screen's current size, curvature and place on the surface.
func panel_inset_now() -> float:
	if not on_surface(): return 0.0
	var info := {"on_cap": false}
	if surface_on_cap: info = {"on_cap": true, "lat": surface_lat, "half": band_half()}
	return ScreenPlacementGrid.panel_inset(curvature, mesh_size, placement_radius, surface_straight, info)

## A corner of the screen's footprint on the surface, in surface_pose() space.
func grid_corner_point(index: int) -> Vector3:
	var x_sign := -1.0 if index in [0, 2] else 1.0
	var y_sign := 1.0 if index < 2 else -1.0
	if on_cap():
		return ScreenPlacementGrid.sphere_local_point(x_sign * mesh_size.x * 0.5 / placement_radius,
			band_mid() + y_sign * band_half(), surface_lat, sphere_r())
	var angle := mesh_size.x / maxf(placement_radius, 0.001) * 0.5
	return Vector3(x_sign * sin(angle) * placement_radius, y_sign * mesh_size.y * 0.5, placement_radius * (1.0 - cos(angle)))

func _cap_lat(y: float) -> float:
	return ScreenPlacementGrid.cap_lat(y, ScreenPlacementGrid.side_of(surface_y), placement_radius, surface_straight)

## Middle latitude and half latitude span of a sphere screen's patch.
func band_mid() -> float:
	return (_cap_lat(surface_y + mesh_size.y * 0.5) + _cap_lat(surface_y - mesh_size.y * 0.5)) * 0.5

func band_half() -> float:
	return maxf((_cap_lat(surface_y + mesh_size.y * 0.5) - _cap_lat(surface_y - mesh_size.y * 0.5)) * 0.5, 0.0001)

## Latitude per metre of nominal screen height. Rows away from the middle are
## Mercator-squashed, so this is less than 1 / radius there.
func lat_scale() -> float:
	return band_half() * 2.0 / maxf(mesh_size.y, 0.001)

func on_surface() -> bool:
	return surface != ScreenPlacementGrid.Shape.ORIGINAL and placement_radius > 0.0

func is_flat() -> bool:
	return curvature == 0
var grid_mode: bool = true
var grid_pos: Vector2i = Vector2i(-1, -1)

func apply_monitor(m: ScreenLayout.MonitorSpec, frame_size: Vector2i):
	monitor = m
	# Mirror existing monitor content without changing rendering or host input.
	# Real source selection will be wired after the browser GPU feasibility gate.
	var tab := ScreenContentTab.for_monitor(m.id)
	tab.title = ScreenSources.monitor_tab_title(m)
	var existing := content_tabs.find_tab(tab.id)
	if existing != null: existing.title = tab.title
	if content_tabs.tabs.is_empty():
		content_tabs.add(tab)
	elif content_tabs.tabs.size() == 1 and content_tabs.selected().kind == ScreenContentTab.STREAM:
		# Existing layout changes reuse a physical screen for another monitor.
		# A refresh of the same monitor must retain its tab's presentation state.
		if content_tabs.selected_id != tab.id:
			content_tabs.tabs[0] = tab
			content_tabs.selected_id = tab.id
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

## Puts this screen back on its own region of the stream frame, after a
## welcome or browser surface showed something else on it.
func restore_monitor_region() -> void:
	if monitor == null or main == null or main.layout == null:
		return
	var frame: Vector2i = main.layout.frame_size
	if frame.x <= 0 or frame.y <= 0 or monitor.frame_rect.size.x <= 0:
		return
	uv_region = Vector4(
		float(monitor.frame_rect.position.x) / float(frame.x),
		float(monitor.frame_rect.position.y) / float(frame.y),
		float(monitor.frame_rect.size.x) / float(frame.x),
		float(monitor.frame_rect.size.y) / float(frame.y),
	)
	for mat in [material_override, comp_shader_mat, comp_shader_mat_left, comp_shader_mat_right]:
		if mat is ShaderMaterial:
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
var comp_loading_label: Control = null
var comp_loading_label_left: Control = null
var comp_loading_label_right: Control = null
var comp_loading_dots: Array = []
var comp_loading_dots_left: Array = []
var comp_loading_dots_right: Array = []
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

# Composition-space grab-bar indicator (2026-08-24, GLES projectionless
# polish) - the real grab_bar (a MeshInstance3D, see @onready above) is
# invisible under projectionless mode for the same reason the laser/cursor
# were (plain 3D scene nodes never reach the compositor when
# submit_projection_layer=false). Its Area3D grab interaction is unaffected
# (physics doesn't depend on rendering) - this only adds the missing
# visual. See CompositionScreenControls.
# Compatibility aliases: grab bar, shortcuts, corners and browser chrome now
# share comp_corner_layer/comp_corner_viewport (one controls layer per screen).
var comp_grab_bar: Node3D = null
var comp_grab_bar_viewport: SubViewport = null
var shortcut_buttons: Dictionary = {}
var shortcut_areas: Dictionary = {}
var comp_shortcut_icons: Dictionary = {}
var shortcut_backdrop: MeshInstance3D = null

# Composition-space corner-handle indicators (2026-08-24) - same rationale
# as comp_grab_bar: corner_handles are plain 3D scene nodes (MeshInstance3D
# with an L-bracket texture, see create_corner_handles()), invisible under
# projectionless mode. One curved visual layer holds four independent bracket
# controls, indexed like corner_handles (top-left/top-right/bottom-left/bottom-right).
# CompositionScreenControls mirrors hover/click alpha onto comp_corner_rects.
var comp_corner_layer: Node3D = null
var comp_corner_viewport: SubViewport = null
var comp_corner_rects: Array = []
var comp_layer: Node3D = null
var comp_base_size: Vector2i = Vector2i(1920, 1080)
# Fraction of comp_base_size the composition viewports are rendered at
# (EyeResolution lowers it while the screen covers fewer headset pixels).
var comp_render_scale: float = 1.0

## The size the composition viewports render the picture at (without bezel).
func comp_render_size() -> Vector2i:
	if comp_render_scale >= 0.999:
		return comp_base_size
	return Vector2i(maxi(1, roundi(comp_base_size.x * comp_render_scale)),
		maxi(1, roundi(comp_base_size.y * comp_render_scale)))
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
	# ScreenGrabBar's material isn't resource_local_to_scene, so without this
	# every screen instance shares one material resource - invisible while
	# every bar is always driven to the same color, but breaks the moment
	# primary/secondary bars need genuinely different base colors.
	if grab_bar.material_override:
		grab_bar.material_override = grab_bar.material_override.duplicate()

func setup(p_main: Node3D, p_monitor_id: StringName = &"m0") -> void:
	main = p_main
	monitor_id = p_monitor_id

func get_cylinder_radius() -> float:
	if on_surface() and curvature > 0: return ScreenPlacementGrid.panel_radius(curvature, placement_radius)
	if placement_radius > 0.0 and curvature > 0: return placement_radius
	if main.comp and main.comp.in_use:
		var cam_to_screen = global_position - main.xr_camera.global_position
		# Same clamp as the composition cylinder it has to match.
		var view_dist = maxf(cam_to_screen.length(), 0.5)
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

## The grab bar's offset below the screen centre along the screen's surface.
## Equal to grab_bar.position.y except on a sphere, where the bar follows the curve.
var grab_bar_surface_y := 0.0

func grab_bar_arc_y() -> float:
	return grab_bar_surface_y if on_sphere() else grab_bar.position.y

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
		if on_sphere():
			handle.position = corner_surface_point(i) + Vector3(signf(offsets[i].x), signf(offsets[i].y), 0) * corner_size * 0.5
			handle.rotation = Vector3.ZERO
	# Halved (2026-08-24, was the full grab_bar_off gap) - moves the real
	# grab_bar (and its Area3D hitbox) closer to the screen edge, not just
	# its composition-space visual (CompositionScreenControls
	# mirrors this position directly) - keeping both in sync was the point;
	# an earlier attempt that only offset the visual left the hitbox
	# behind, making it hard to find/grab.
	grab_bar.position.y = -ms.y / 2.0 - grab_bar_off * 0.5
	grab_bar.position.z = 0.0
	grab_bar_surface_y = grab_bar.position.y
	if on_sphere():
		# The bar's arc distance below the centre stays the same; it follows the sphere.
		var bar := ScreenPlacementGrid.sphere_local_point(0.0, band_mid() + grab_bar.position.y * lat_scale(), surface_lat, sphere_r())
		grab_bar.position = Vector3(0, bar.y, bar.z)
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
			# ScreenGrabBar is rotated 90 degrees in the scene so its CylinderMesh
			# local Y axis runs horizontally. Match that transform here: local Y
			# is the visible bar width and local X is its vertical hit height.
			grab_shape.shape.size = Vector3(ms.y * 0.079, ms.x * 0.134, 0.1)
	update_shortcut_positions()

func update_shortcut_positions() -> void:
	if shortcut_buttons.is_empty():
		return
	var icon_size = mesh_size.x * ScreenShortcutBar.ICON_SIZE_RATIO
	var hit_size = mesh_size.x * ScreenShortcutBar.HIT_SIZE_RATIO
	if shortcut_backdrop:
		var backdrop_size = ScreenShortcutBar.backdrop_size_ratio() * mesh_size.x
		shortcut_backdrop.position = Vector3(0.0, grab_bar.position.y, 0.0015)
		if shortcut_backdrop.mesh is QuadMesh:
			shortcut_backdrop.mesh.size = backdrop_size
		var material = shortcut_backdrop.material_override as ShaderMaterial
		if material:
			material.set_shader_parameter("aspect", backdrop_size.x / backdrop_size.y)
	for action in ScreenShortcutBar.VISIBLE_ACTIONS:
		var icon = shortcut_buttons.get(action) as MeshInstance3D
		if not icon:
			continue
		var show = self == main.primary_screen
		icon.visible = show
		icon.position = Vector3(
			mesh_size.x * ScreenShortcutBar._action_x_ratio(action),
			grab_bar.position.y,
			0.002,
		)
		if icon.mesh is QuadMesh:
			icon.mesh.size = Vector2(icon_size, icon_size)
		var dot = icon.get_node_or_null("LiveDot") as MeshInstance3D
		if dot and dot.mesh is QuadMesh:
			var dot_size = icon_size * ScreenShortcutBar.LIVE_DOT_SIZE
			dot.mesh.size = Vector2(dot_size, dot_size)
			dot.position = Vector3(icon_size * ScreenShortcutBar.LIVE_DOT_OFFSET, icon_size * ScreenShortcutBar.LIVE_DOT_OFFSET, 0.001)
		var area = shortcut_areas.get(action) as Area3D
		if not area:
			continue
		area.position = icon.position
		var collision = area.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if collision and collision.shape is BoxShape3D:
			collision.shape.size = Vector3(hit_size, hit_size, 0.1)
			collision.set_deferred("disabled", not show)
		area.monitoring = show
		area.monitorable = show

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
	if on_sphere():
		var patch := _sphere_patch(bezel_size, 0.005, 32, 16)
		var arr = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = patch.verts
		arr[Mesh.ARRAY_TEX_UV] = patch.uvs
		arr[Mesh.ARRAY_INDEX] = _grid_indices(32, 16)
		var sphere_mesh = ArrayMesh.new()
		sphere_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		bezel_mesh.mesh = sphere_mesh
		bezel_mesh.position = Vector3.ZERO
		return
	if is_flat():
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

## The radius the curved mesh and its collision shape were last built with.
## The composition layer re-fits its cylinder whenever the screen moves; the
## pointer hits this mesh, so it must be rebuilt to match (see
## CompositionLayerManager._update_cylinder_params_for()).
var built_radius := 0.0

## Vertices and UVs of a sphere screen's lat/long patch, in its own frame.
func _sphere_patch(size: Vector2, depth: float, columns: int, rows: int) -> Dictionary:
	var radius := placement_radius
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var mid := band_mid()
	var scale := lat_scale()
	var sphere := sphere_r()
	for j in range(columns + 1):
		for i in range(rows + 1):
			var t := float(j) / columns
			var u := float(i) / rows
			var point := ScreenPlacementGrid.sphere_local_point((t - 0.5) * size.x / radius,
				mid + (u - 0.5) * size.y * scale, surface_lat, sphere)
			verts.append(point + (point - Vector3(0, 0, sphere)).normalized() * depth)
			uvs.append(Vector2(t, 1.0 - u))
	return {"verts": verts, "uvs": uvs}

static func _grid_indices(columns: int, rows: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	var cols := rows + 1
	for j in range(columns):
		for i in range(rows):
			var idx := j * cols + i
			indices.append_array([idx, idx + 1, idx + cols, idx + 1, idx + cols + 1, idx + cols])
	return indices

func _apply_sphere_mesh() -> void:
	built_radius = placement_radius
	var patch := _sphere_patch(mesh_size, 0.0, 32, 16)
	var indices := _grid_indices(32, 16)
	var arr = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = patch.verts
	arr[Mesh.ARRAY_TEX_UV] = patch.uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var arr_mesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh = arr_mesh
	update_shader_for_mesh()
	set_collision_curved(patch.verts, indices)

func apply_curvature():
	var ms = mesh_size
	if on_sphere():
		_apply_sphere_mesh()
		return
	if is_flat():
		var quad = QuadMesh.new()
		quad.size = ms
		mesh = quad
		update_shader_for_mesh()
		set_collision_flat()
		return
	var subdivide = 32
	var v_subdivide = 16
	var radius = get_cylinder_radius()
	built_radius = radius
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
	if on_surface() and main != null and main.get("placement_grid") != null:
		# A new aspect changes the screen's height: it, and on a cylinder grid
		# every screen when it is the primary, stays at its grid position.
		main.placement_grid.keep_grid(func(): _resize_to_aspect(w, h))
		return
	_resize_to_aspect(w, h)

func _resize_to_aspect(w: int, h: int):
	var aspect = float(w) / float(h)
	var new_w = mesh_size.x / maxf(display_crop.z, 0.001)
	var new_h = new_w / aspect
	if new_h < 0.4:
		new_h = 0.4
		new_w = new_h * aspect
	mesh_size = Vector2(new_w * display_crop.z, new_h * display_crop.w)
	if is_flat() and mesh is QuadMesh:
		mesh.size = mesh_size
		set_collision_flat()
	else:
		apply_curvature()
	update_corner_positions()
	if bezel_mesh:
		update_bezel_size()

var _corner_resize_started: bool = false
var _corner_start_width := 0.0
var _corner_start_hit := Vector3.ZERO
var _corner_start_transform := Transform3D.IDENTITY
var _corner_pinned_world := Vector3.ZERO
var _corner_snap := ScreenPlacementGrid.SlowSnap.new()

func begin_corner_resize():
	_corner_resize_started = false
	_corner_snap = ScreenPlacementGrid.SlowSnap.new()

func corner_surface_point(index: int) -> Vector3:
	var x_sign := -1.0 if index in [0, 2] else 1.0
	var y_sign := 1.0 if index < 2 else -1.0
	if on_sphere():
		return ScreenPlacementGrid.sphere_local_point(x_sign * mesh_size.x * 0.5 / placement_radius,
			band_mid() + y_sign * band_half(), surface_lat, sphere_r())
	if is_flat():
		return Vector3(x_sign * mesh_size.x * 0.5, y_sign * mesh_size.y * 0.5, 0)
	var radius := get_cylinder_radius()
	var angle := mesh_size.x / radius * 0.5
	return Vector3(x_sign * sin(angle) * radius, y_sign * mesh_size.y * 0.5, radius * (1.0 - cos(angle)))

func apply_corner_resize(ray_origin: Vector3, ray_dir: Vector3, corner_idx: int, tile_aspect: float) -> void:
	if not _corner_resize_started:
		_corner_start_transform = global_transform
	var plane_normal := _corner_start_transform.basis.z
	var denom := ray_dir.dot(plane_normal)
	if absf(denom) < 0.0001: return
	var t := (_corner_start_transform.origin - ray_origin).dot(plane_normal) / denom
	if t < 0: return
	var hit := _corner_start_transform.affine_inverse() * (ray_origin + ray_dir * t)
	if not _corner_resize_started:
		_corner_resize_started = true
		_corner_start_width = mesh_size.x
		_corner_start_hit = hit
		# On a grid surface the footprint's corner stays put, not the panel's.
		_corner_pinned_world = surface_pose() * grid_corner_point(3 - corner_idx) if on_surface() \
			else to_global(corner_surface_point(3 - corner_idx))
		return
	var aspect := maxf(tile_aspect, 0.01)
	var x_sign := -1.0 if corner_idx in [0, 2] else 1.0
	var y_sign := 1.0 if corner_idx < 2 else -1.0
	var diagonal := Vector2(x_sign, y_sign / aspect)
	var delta_hit := Vector2(hit.x - _corner_start_hit.x, hit.y - _corner_start_hit.y)
	var width := _corner_start_width + delta_hit.dot(diagonal) / diagonal.length_squared()
	if main.get("placement_grid") != null and ScreenPlacementGrid.single_surface(main.placement_grid.shape()):
		# Quantize distance along the aspect-constrained diagonal, not x/y
		# independently (which would stretch the content).
		var diagonal_size := _corner_snap.sample(Vector3(width * diagonal.length(), 0, 0), get_process_delta_time(), main.settings.placement_grid_spacing)
		width = diagonal_size.x / diagonal.length()
	set_pinned_size(maxf(width, maxf(0.6, 0.4 * aspect)), aspect, 3 - corner_idx, _corner_pinned_world)
	set_meta(&"placement_grid_owned", true)
	grid_pos = Vector2i(-1, -1)

func set_pinned_size(width: float, aspect: float, pinned_corner: int, pinned_world: Vector3) -> void:
	if on_surface() and main.get("placement_grid") != null:
		# On a grid surface the pinned corner stays put in surface coordinates.
		# The primary's height shapes a cylinder grid's middle row, so the
		# other screens are laid back on the grid as it changes.
		var resize := func():
			mesh_size = Vector2(width, width / aspect)
			main.placement_grid.place_pinned(self, pinned_corner, pinned_world)
		if self == main.primary_screen: main.placement_grid.keep_grid(resize, false)
		else: resize.call()
		update_corner_positions()
		update_bezel_size()
		return
	mesh_size = Vector2(width, width / aspect)
	# The composition cylinder radius depends on screen distance. Resolve its
	# small feedback as the centre shifts, so the actual curved corner stays put.
	for iteration in range(8):
		var correction := pinned_world - to_global(corner_surface_point(pinned_corner))
		global_position += correction
		if correction.length_squared() < 0.0000000001: break
	if is_flat() and mesh is QuadMesh:
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
	if on_sphere():
		var to_hit := hit_point - to_global(Vector3(0, 0, sphere_r()))
		return to_hit.normalized() if to_hit.length() > 0.001 else -global_transform.basis.z
	if is_flat() or not comp_layer:
		return -global_transform.basis.z
	var screen_forward = -global_transform.basis.z
	if _comp_cyl_radius < 0.01:
		return screen_forward
	var cyl_center = global_position - screen_forward * _comp_cyl_radius
	var to_hit = hit_point - cyl_center
	# Cylinder curvature is horizontal in the screen's own basis. Removing the
	# screen-up component keeps the tangent correct when a screen is pitched or
	# rolled; clearing world Y produced a skewed normal away from screen centre.
	var screen_up := global_transform.basis.y.normalized()
	to_hit -= screen_up * to_hit.dot(screen_up)
	if to_hit.length() < 0.001:
		return screen_forward
	return to_hit.normalized()

func hit_point_to_uv(hit_point: Vector3) -> Vector2:
	var ms = mesh_size
	var local_pos = to_local(hit_point)
	var uv_x = 0.0
	var uv_y = clampf((ms.y * 0.5 - local_pos.y) / ms.y, 0.0, 1.0)
	if on_sphere():
		var angles := ScreenPlacementGrid.sphere_angles(local_pos, surface_lat, sphere_r())
		return Vector2(clampf(angles.x * placement_radius / ms.x + 0.5, 0.0, 1.0),
			clampf(0.5 - (angles.y - band_mid()) / (2.0 * band_half()), 0.0, 1.0))
	if is_flat():
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
				# uv_y is deliberately NOT reprojected here (unlike uv_x) -
				# curvature only bends the screen horizontally, so the
				# mesh's vertical extent is exactly mesh_size.y regardless
				# of cylinder radius. Re-deriving Y from the ray-cylinder
				# intersection walks the ray out to a DIFFERENT point along
				# its direction using _comp_cyl_radius (maintained on its
				# own update schedule via update_cylinder_params(), not
				# necessarily in sync with the radius the collision mesh
				# was actually built with in apply_curvature()) - any drift
				# between those two radii pushed the reprojected Y away
				# from the raw raycast hit, growing worse toward the edges
				# (confirmed live, 2026-08-21: the in-VR pointer reticle,
				# anchored to the raw hit_point/local_pos.y computed at the
				# top of this function, renders in the visually correct
				# spot; only the value SENT to the host was wrong). The uv_y
				# computed at the top of this function from the real,
				# visually-correct raycast hit is used as-is.
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
