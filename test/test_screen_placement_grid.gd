extends SceneTree

const Grid = preload("res://src/screen_placement_grid.gd")

class Comp extends RefCounted:
	var in_use := false
	func update_cylinder_params(): pass

class Interaction extends XRInteraction:
	func get_active_raycast() -> RayCast3D: return main.ray
	func _is_now_clicking() -> bool: return true

class Owner extends Node3D:
	var is_xr_active := true
	var grabbed_node: Node3D
	var ray := RayCast3D.new()
	var grab_start_hand_pos := Vector3.ZERO
	var grab_start_node_pos := Vector3.ZERO
	var grab_forward := Vector3.FORWARD
	var grab_start_hand_basis := Basis.IDENTITY
	var grab_start_node_euler := Vector3.ZERO
	var grab_group_start_transforms := {}
	var grab_start_primary_transform := Transform3D.IDENTITY
	var placement_grid: ScreenPlacementController
	func _debug_log_cyl(_label): pass
	var settings := AppSettings.new()
	var comp := Comp.new()
	var xr_camera := Node3D.new()
	var primary_screen: VRScreen
	var screens: Array = []

class Screen extends VRScreen:
	func _ready(): pass
	func update_corner_positions(): pass
	func update_bezel_size(): pass
	func apply_curvature(): pass

func _init():
	call_deferred("run")

func run():
	for shape in range(3):
		for point in [Vector3.ZERO, Vector3(1.3, 0.7, 0.2), Vector3(-2.1, -0.6, -0.4)]:
			var surface := Grid.point_transform(point, shape, 4.0)
			assert(Grid.coordinates(surface.origin, shape, 4.0).is_equal_approx(point), "All radial shells must round-trip")
			assert(is_equal_approx(surface.basis.determinant(), 1.0))
			var anchor := Transform3D(Basis.from_euler(Vector3(0.2, 2.5, 0.1)), Vector3(3, 2, -4))
			var world := anchor * surface
			assert(Grid.coordinates(anchor.affine_inverse() * world.origin, shape, 4.0).is_equal_approx(point))
	assert(Grid.point_transform(Vector3.ZERO, Grid.Shape.SPHERE, 4).is_equal_approx(Transform3D.IDENTITY))
	var sphere := Grid.point_transform(Vector3(0.8, 0.9, 0.2), Grid.Shape.SPHERE, 4)
	assert(sphere.basis.z.is_equal_approx((Vector3(0,0,4) - sphere.origin).normalized()), "Spherical panels follow the shell tangent")
	var cylinder := Grid.point_transform(Vector3(0.8, 0.9, 0.2), Grid.Shape.CYLINDER, 4)
	assert(cylinder.basis.y == Vector3.UP, "Cylindrical rows stay upright")
	for position in [Vector3(0,3,-2),Vector3(-4,0,-2),Vector3(3,-2,-1)]:
		for step in [0.0,0.05,0.1,0.2]:
			var basis := Grid.viewer_facing_basis(position,Vector3.ZERO,step,Basis.from_euler(Vector3(.2,1.1,0)))
			assert(basis.z.dot(-position.normalized()) > 0.998, "Raised/side panels must face the viewer, including snapped orientation")
			assert(is_equal_approx(basis.determinant(),1.0))
	var snap := Grid.SlowSnap.new()
	var raw := Vector3(0.13, 0.23, 0.31)
	assert(snap.sample(raw, 0.016, 0.1) == raw)
	for frame in range(8): snap.sample(raw, 0.016, 0.1)
	assert(snap.engaged and snap.cell.is_equal_approx(Vector3(0.1,0.2,0.3)))
	assert(snap.sample(Vector3(0.151,0.23,0.31), 0.1, 0.1).x == snap.cell.x)
	for frame in range(12): snap.sample(Vector3(0.151,0.23,0.31), 0.016, 0.1)
	var held := snap.cell
	assert(snap.sample(Vector3(0.154,0.23,0.31), 0.016, 0.1) == held, "Small jitter must not chatter between cells")
	var fast := Vector3(1.0, 2.0, 3.0)
	assert(snap.sample(fast, 0.016, 0.1) == fast and not snap.engaged, "Fast motion immediately escapes snapping")
	# Exact ratio wins over arbitrary independent x/y rounding.
	for aspect in [4.0/3.0, 16.0/9.0, 21.0/9.0]:
		var diagonal := Vector2(1, 1/aspect)
		var width := snappedf(2.37 * diagonal.length(), 0.1) / diagonal.length()
		assert(is_equal_approx(width / (width / aspect), aspect))
	var owner := Owner.new()
	root.add_child(owner)
	owner.add_child(owner.xr_camera)
	var screen := Screen.new()
	screen.main = owner
	screen.mesh = QuadMesh.new()
	var bar := MeshInstance3D.new()
	bar.name = "ScreenGrabBar"
	screen.add_child(bar)
	bar.owner = screen
	bar.unique_name_in_owner = true
	owner.add_child(screen)
	owner.primary_screen = screen
	for curve in range(3):
		screen.curvature = curve
		for corner in range(4):
			for aspect in [4.0/3, 16.0/9, 21.0/9]:
				screen.global_transform = Transform3D(Basis.from_euler(Vector3(0.2,1.1,0.1)), Vector3(2,1,-3))
				screen.mesh_size = Vector2(2.0,2.0/aspect)
				var pinned := screen.to_global(screen.corner_surface_point(corner))
				screen.set_pinned_size(2.7, aspect, corner, pinned)
				assert(screen.to_global(screen.corner_surface_point(corner)).distance_to(pinned) < 0.0001, "Opposite corner must stay pinned on flat AND curved surfaces")
				assert(is_equal_approx(screen.mesh_size.x/screen.mesh_size.y, aspect))
	owner.comp.in_use = true
	screen.curvature = 2
	var pinned := screen.to_global(screen.corner_surface_point(3))
	screen.set_pinned_size(3.1, 16.0/9, 3, pinned)
	assert(screen.to_global(screen.corner_surface_point(3)).distance_to(pinned) < 0.0001, "Pinned corner must account for distance-dependent cylinder radius")
	var config := ConfigFile.new()
	owner.settings.placement_grid_shape = 2
	owner.settings.placement_grid_spacing = 0.05
	SettingsPersistence.write_app(config, owner.settings)
	var restored := AppSettings.new()
	SettingsPersistence.read_app(config, restored, true, [0, 1, 2])
	assert(restored.placement_grid_shape == 2 and restored.placement_grid_spacing == 0.05)
	var secondary := Screen.new()
	secondary.main = owner
	var secondary_bar := MeshInstance3D.new()
	secondary_bar.name = "ScreenGrabBar"
	secondary.add_child(secondary_bar)
	secondary_bar.owner = secondary
	secondary_bar.unique_name_in_owner = true
	owner.add_child(secondary)
	secondary.curvature = 2
	var controller := ScreenPlacementController.new(owner)
	owner.settings.grid_mode_enabled = true
	owner.settings.placement_grid_shape = 2
	var primary_before := screen.global_transform
	var raw_point := Vector3(1.13,0.23,-0.12)
	var raw_transform := screen.global_transform * Grid.point_transform(raw_point,2,controller.radius())
	for frame in range(10):
		secondary.global_transform = raw_transform
		controller.drag(secondary,0.016)
	var snapped_point := Grid.coordinates(controller.anchor().affine_inverse() * secondary.to_global(secondary.corner_surface_point(controller._snap_corner)),2,controller.radius())
	assert(controller._snap.engaged, "A held screen engages snapping")
	assert(snapped_point.distance_to(controller._snap.cell) < 0.001, "The real secondary corner must align with the grid, not just its centre")
	assert(absf(snapped_point.z) < 0.001, "Sphere screens lie on the one surface, not on nested shells")
	assert(screen.global_transform == primary_before, "Secondary editing must not move primary")
	var sphere_centre := controller.anchor() * Vector3(0, 0, controller.radius())
	for corner in range(4):
		assert(is_equal_approx(secondary.to_global(secondary.corner_surface_point(corner)).distance_to(sphere_centre), controller.radius()), "Every corner of a sphere screen lies on the sphere")
	assert(secondary.global_basis.z.dot((sphere_centre-secondary.global_position).normalized()) > .9999, "A sphere screen faces the sphere's centre")
	assert(secondary.has_meta(&"placement_grid_owned") and secondary.grid_pos == Vector2i(-1,-1))
	assert(secondary.on_sphere() and is_equal_approx(secondary.placement_radius,controller.radius()))
	assert(controller._guide.visible and controller._guide.multimesh.visible_instance_count == 165, "One surface shows one layer of guide points")
	secondary.comp_corner_viewport = SubViewport.new()
	owner.add_child(secondary.comp_corner_viewport)
	secondary.comp_corner_viewport.size = Vector2i(1536,900)
	controller.update_composition_guide(secondary,Vector2(3,2))
	var guide: Control = secondary.comp_corner_viewport.get_node("PlacementGridGuide")
	assert(guide.visible and guide.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	assert(guide.points.size() == 165, "Projectionless guide must reuse the controls viewport")
	controller.finish()
	assert(not guide.visible)
	assert(not controller._guide.visible)
	for curve in range(3):
		screen.curvature = curve
		screen.placement_radius = 0.0
		for shape in range(3):
			owner.settings.placement_grid_shape = shape
			var r := controller.radius()
			var grid := controller.lattice()
			for corner in range(4):
				var corner_point: Vector3 = screen.grid_corner_point(corner) if screen.on_surface() else screen.corner_surface_point(corner)
				var coordinate := Grid.coordinates(controller.anchor().affine_inverse() * (screen.surface_pose() * corner_point),shape,r)
				assert(Grid.snap_point(coordinate,grid.steps,grid.offset).distance_to(coordinate) < 0.0001, "All four primary corners must lie on lattice points for every shape/curvature")
	# Exercise the actual grab path: primary height is unconstrained and
	# controller pitch still tilts the whole workspace (lying-down use).
	owner.add_child(owner.ray)
	owner.placement_grid = controller
	owner.grabbed_node = screen
	owner.grab_start_hand_pos = Vector3.ZERO
	owner.grab_start_node_pos = screen.global_position
	owner.grab_start_node_euler = screen.rotation
	owner.grab_start_hand_basis = Basis.from_euler(Vector3(.2,.1,0))
	owner.ray.global_basis = Basis.from_euler(Vector3(.6,.1,0))
	owner.ray.global_position = Vector3(0,.1,0)
	owner.grab_start_primary_transform = screen.global_transform
	owner.grab_group_start_transforms[secondary] = secondary.global_transform
	var start_y := screen.global_position.y
	var initial_secondary := secondary.global_transform
	var grab := Interaction.new(owner)
	grab.handle_grab()
	assert(is_equal_approx(screen.global_position.y,start_y+.6), "Primary must still move up/down freely")
	assert(is_equal_approx(screen.rotation.x,owner.grab_start_node_euler.x+.264), "Primary must retain manual controller tilt")
	assert(secondary.global_transform.is_equal_approx(screen.global_transform*owner.grab_start_primary_transform.affine_inverse()*initial_secondary), "The grid/workspace must tilt and move with primary")
	primary_before = screen.global_transform
	var secondary_before := secondary.global_transform
	owner.primary_screen = secondary
	controller.radius()
	assert(screen.global_transform == primary_before and secondary.global_transform == secondary_before, "Changing anchor must preserve both poses")
	_test_sphere_patches(owner, controller)
	owner.free()
	print("All screen placement grid tests passed")
	quit()

func _test_sphere_patches(owner, controller: ScreenPlacementController) -> void:
	# The patch model: points lie on the sphere and the angles round-trip.
	for lat_c in [0.0, 0.4, -0.7]:
		for dlon in [-0.3, 0.0, 0.25]:
			for lat in [lat_c - 0.2, lat_c, lat_c + 0.15]:
				var local := Grid.sphere_local_point(dlon, lat, lat_c, 1.7)
				assert(is_equal_approx(local.distance_to(Vector3(0, 0, 1.7)), 1.7))
				assert(Grid.sphere_angles(local, lat_c, 1.7).is_equal_approx(Vector2(dlon, lat)))
		assert(Grid.sphere_local_point(0, lat_c, lat_c, 1.7).is_zero_approx())
	# Two screens one width apart in longitude, and one a height below, share edges exactly.
	owner.primary_screen.global_transform = Transform3D(Basis.from_euler(Vector3(0.3, -0.4, 0.05)), Vector3(0.5, 1.2, -2))
	owner.primary_screen.surface = Grid.Shape.ORIGINAL
	owner.primary_screen.placement_radius = 0.0
	owner.settings.placement_grid_shape = Grid.Shape.SPHERE
	controller._radius_key = []
	var r := controller.radius()
	assert(owner.primary_screen.on_sphere() and is_equal_approx(r, owner.primary_screen.placement_radius))
	var size := Vector2(0.9, 0.5)
	var screens := []
	for centre in [Vector3(0.9, 0.5, 0), Vector3(1.8, 0.5, 0), Vector3(0.9, 0.0, 0)]:
		var other := Screen.new()
		other.main = owner
		var bar := MeshInstance3D.new()
		bar.name = "ScreenGrabBar"
		other.add_child(bar)
		bar.owner = other
		bar.unique_name_in_owner = true
		owner.add_child(other)
		other.mesh_size = size
		controller._place(other, centre, Grid.Shape.SPHERE, r)
		screens.append(other)
	var corner := func(screen, index): return screen.to_global(screen.corner_surface_point(index))
	assert(corner.call(screens[0], 1).distance_to(corner.call(screens[1], 0)) < 0.0001, "Side by side: top corners meet")
	assert(corner.call(screens[0], 3).distance_to(corner.call(screens[1], 2)) < 0.0001, "Side by side: bottom corners meet")
	assert(corner.call(screens[0], 2).distance_to(corner.call(screens[2], 0)) < 0.0001, "Row below: left corners meet")
	assert(corner.call(screens[0], 3).distance_to(corner.call(screens[2], 1)) < 0.0001, "Row below: right corners meet")
	var top_width: float = corner.call(screens[0], 0).distance_to(corner.call(screens[0], 1))
	var bottom_width: float = corner.call(screens[0], 2).distance_to(corner.call(screens[0], 3))
	assert(top_width < bottom_width, "Above the equator a sphere screen narrows towards the top")
	# The pointer maps the sphere surface to the picture.
	var middle: VRScreen = screens[0]
	var hit := middle.to_global(Grid.sphere_local_point(size.x * 0.25 / r, middle.band_mid() - middle.band_half() * 0.5, middle.surface_lat, r))
	assert(middle.hit_point_to_uv(hit).is_equal_approx(Vector2(0.75, 0.75)))
	# The equirect pose: centred on the sphere, -Z through the screen's longitude.
	var frame := Grid.sphere_frame(middle.global_transform, middle.surface_lat, r)
	assert(frame.origin.is_equal_approx(controller.anchor() * Vector3(0, 0, r)))
	assert(frame.basis.is_equal_approx(controller.anchor().basis * Basis(Vector3.UP, -0.9 / r)))
	# Rows away from the middle are squashed a little, never stretched.
	controller._place(screens[2], Vector3(0.0, r * 0.9, 0), Grid.Shape.SPHERE, r)
	var high: VRScreen = screens[2]
	var mid_width: float = (corner.call(high, 0).distance_to(corner.call(high, 1)) + corner.call(high, 2).distance_to(corner.call(high, 3))) * 0.5
	var mid_height: float = (corner.call(high, 0).distance_to(corner.call(high, 2)) + corner.call(high, 1).distance_to(corner.call(high, 3))) * 0.5
	assert(mid_width / mid_height > size.x / size.y * 1.1, "High sphere screens are squashed vertically")
	assert(mid_width < size.x * 0.85, "High sphere screens also get smaller")
	assert(high.global_basis.z.dot((controller.anchor() * Vector3(0, 0, r) - high.global_position).normalized()) > 0.999, "Sphere screens face the viewer")
	# Round trips through the surface, including the rows above and below a cylinder grid.
	for straight in [0.0, 0.3]:
		for point in [Vector3(0.4, 0.1, 0), Vector3(-0.7, 0.9, 0), Vector3(0.2, -1.4, 0)]:
			var surface := Grid.point_transform(point, Grid.Shape.CYLINDER, 2.0, straight)
			assert(Grid.coordinates(surface.origin, Grid.Shape.CYLINDER, 2.0, straight).is_equal_approx(point))
	# A cylinder grid: the primary's row is a straight cylinder.
	owner.settings.placement_grid_shape = Grid.Shape.CYLINDER
	controller._radius_key = []
	r = controller.radius()
	var primary: VRScreen = owner.primary_screen
	assert(primary.on_surface() and not primary.on_sphere() and is_equal_approx(controller.straight(), primary.mesh_size.y * 0.5))
	var row := controller.screen_centre(primary)
	controller._place(screens[1], Vector3(1.0, row.y + 0.05, 0), Grid.Shape.CYLINDER, r)
	assert(screens[1].surface == Grid.Shape.CYLINDER and not screens[1].is_flat() and not screens[1].on_sphere())
	var axis := controller.anchor() * Vector3(0, 0, r)
	var offset: Vector3 = screens[1].global_position - axis
	var up := controller.anchor().basis.y.normalized()
	assert(is_equal_approx((offset - up * offset.dot(up)).length(), r), "Cylinder screens sit on the same cylinder")
	assert(screens[1].global_basis.y.is_equal_approx(up), "Cylinder screens in the middle row stay upright")
	# Rows above and below face the viewer, and meet the middle row's edge.
	var half_height := primary.mesh_size.y * 0.5
	for side in [1.0, -1.0]:
		controller._place(screens[1], Vector3(0.0, side * (half_height + size.y * 0.5), 0), Grid.Shape.CYLINDER, r)
		assert(screens[1].on_sphere() and is_equal_approx(screens[1].surface_straight, half_height))
		var to_viewer: Vector3 = (axis - screens[1].global_position).normalized()
		assert(screens[1].global_basis.z.dot(to_viewer) > 0.999, "Rows above and below tilt to face the viewer")
		var join := controller.anchor() * Grid.point_transform(Vector3(-size.x * 0.5, side * half_height, 0), Grid.Shape.CYLINDER, r, half_height).origin
		assert(corner.call(screens[1], 2 if side > 0 else 0).distance_to(join) < 0.0001, "The row meets the middle row's edge")
	assert(corner.call(primary, 0).distance_to(controller.anchor() * Grid.point_transform(Vector3(-primary.mesh_size.x * 0.5, half_height, 0), Grid.Shape.CYLINDER, r, half_height).origin) < 0.0001)
	# The tab-drop outline matches where adhere() puts a screen.
	owner.settings.placement_grid_shape = Grid.Shape.SPHERE
	controller._radius_key = []
	r = controller.radius()
	var drop_at := controller.anchor() * Transform3D(Basis.IDENTITY, Vector3(0.3, 0.8, 0.1))
	var outline := controller.preview(drop_at, size, 2)
	screens[1].global_transform = drop_at
	controller.adhere(screens[1])
	assert(outline.kind == &"sphere" and outline.screen.is_equal_approx(screens[1].global_transform))
	assert(is_equal_approx(outline.upper, screens[1].band_mid() + screens[1].band_half()) and is_equal_approx(outline.lower, screens[1].band_mid() - screens[1].band_half()))
	var drag_preview := TabDragPreview.new(owner)
	drag_preview.update("Desktop", drop_at.origin, outline)
	assert(drag_preview._outline_mesh.visible and drag_preview._label_mesh.visible and drag_preview._label.text == "Desktop")
	drag_preview.update("Desktop", drop_at.origin, {})
	assert(not drag_preview._outline_mesh.visible)
	drag_preview.hide()
	assert(not drag_preview._label_mesh.visible)
	# With composition layers the label rides on the cursor layer, dot on the point.
	var origin := Node3D.new()
	owner.add_child(origin)
	var pointers := CompositionPointerLayers.new()
	pointers.setup(owner, origin)
	var rest_size := pointers.cursor_viewport.size
	assert(pointers.show_drag(Vector3(0, 1, -2), Vector3(0, 1, 0), "Desktop"), "The drag label shows on every renderer, GLES included")
	assert(pointers.cursor_layer.visible and pointers._drag_label.text == "Desktop" and pointers._drag_root.visible)
	assert(pointers.cursor_viewport.size == CompositionPointerLayers.DRAG_SIZE)
	var dot_px := Vector2(CompositionPointerLayers.DRAG_SIZE.x * 0.5, CompositionPointerLayers.DRAG_DOT_PX * 0.5)
	var quad: Vector2 = pointers.cursor_layer.get_quad_size()
	var per_px := quad.x / CompositionPointerLayers.DRAG_SIZE.x
	var basis: Basis = pointers.cursor_layer.global_transform.basis.orthonormalized()
	var dot: Vector3 = pointers.cursor_layer.global_position + basis.y * (CompositionPointerLayers.DRAG_SIZE.y * 0.5 - dot_px.y) * per_px
	assert(dot.distance_to(Vector3(0, 1, -2)) < 0.003, "The dot sits on the drag point")
	pointers.show_drag(Vector3(0.2, 1, -2), Vector3(0, 1, 0), "Desktop")
	assert(pointers.cursor_viewport.size == CompositionPointerLayers.DRAG_SIZE)
	pointers.end_drag()
	assert(not pointers._drag_root.visible and pointers.cursor_viewport.size == rest_size, "The ordinary cursor returns after a drag")
	pointers.end_drag()
	assert(pointers.cursor_viewport.size == rest_size)
	# Dropping a tab on a surface grid: the pointer ray laid on the fine lattice.
	owner.screens = [primary] + screens
	var viewer := controller.anchor() * Vector3(0, 0, r)
	var aim := Vector3(-2.0, -0.35, 0) # Clear of the primary's left edge.
	var aim_world := controller.anchor() * Grid.point_transform(aim, Grid.Shape.SPHERE, r, 0.0).origin
	var on_surface = controller.ray_grid_point(viewer, viewer.lerp(aim_world, 0.4))
	assert(on_surface != null and on_surface.distance_to(aim) < 0.001, "The pointer ray meets the surface where it aims")
	var lat := controller.lattice()
	var dropped = controller.drop_centre(viewer, aim_world, size)
	assert(dropped != null and Vector2(dropped.x - aim.x, dropped.y - aim.y).length() <= Vector2(lat.steps.x, lat.steps.y).length())
	var near_corner: Vector3 = dropped + Vector3(size.x * 0.5, size.y * 0.5, 0) # Up and right, towards the primary.
	var on_lattice: Vector3 = (near_corner - lat.offset) / lat.steps
	assert(absf(on_lattice.x - roundf(on_lattice.x)) < 0.001 and absf(on_lattice.y - roundf(on_lattice.y)) < 0.001, "The corner nearest the primary is on the lattice")
	var primary_world := controller.anchor() * Grid.point_transform(controller.screen_centre(primary), Grid.Shape.SPHERE, r, 0.0).origin
	var beside = controller.drop_centre(viewer, primary_world, size)
	var others := []
	for screen in [primary] + screens:
		others.append({"centre": controller.screen_centre(screen), "half": Vector2(screen.mesh_size) * 0.5})
	assert(beside != null and ScreenPlacementController._drop_free(beside, Vector3(size.x, size.y, 0) * 0.5, others), "A drop on a screen goes beside it instead")
	var drop_outline := controller.surface_preview(dropped, size)
	controller.place_dropped(screens[1], dropped)
	assert(drop_outline.screen.is_equal_approx(screens[1].global_transform), "The outline is where the drop puts the screen")
	assert(controller.screen_centre(screens[1]).distance_to(dropped) < 0.001)
	# Grid Curve bends the surface tighter round the primary, which stays put;
	# every screen keeps its grid position.
	owner.settings.placement_grid_shape = Grid.Shape.CYLINDER
	controller.reshape()
	assert(screens[0].surface == Grid.Shape.CYLINDER)
	var loose := controller.radius()
	var primary_pose: Transform3D = primary.global_transform
	var kept := controller.screen_centre(screens[0])
	controller.set_curve(100)
	var tight := controller.radius()
	assert(is_equal_approx(tight, loose * ScreenPlacementController.TIGHTEST_CURVE / ScreenPlacementController.LOOSEST_CURVE) and is_equal_approx(primary.placement_radius, tight))
	assert(primary.global_transform.origin.is_equal_approx(primary_pose.origin), "The primary stays where it is")
	assert(controller.screen_centre(screens[0]).distance_to(kept) < 0.001, "Screens keep their grid position: %s vs %s" % [controller.screen_centre(screens[0]), kept])
	assert(screens[0].placement_radius == tight)
	controller.set_curve(0)
	assert(is_equal_approx(controller.radius(), loose) and controller.screen_centre(screens[0]).distance_to(kept) < 0.001)
	# A resize keeps every screen on the one grid. On a cylinder grid the
	# primary's height is the middle row, so the rows above and below move
	# with it and still meet its edge.
	controller._place(screens[1], Vector3(0.0, primary.mesh_size.y * 0.5 + size.y * 0.5, 0), Grid.Shape.CYLINDER, controller.radius())
	var side_before := controller.screen_centre(screens[0])
	var above_before := controller.screen_centre(screens[1])
	primary.resize_to_aspect(1920, 1200) # Taller: 16:10.
	assert(is_equal_approx(controller.straight(), primary.mesh_size.y * 0.5))
	assert(controller.screen_centre(screens[0]).distance_to(side_before) < 0.001, "Screens keep their grid position through a primary resize")
	assert(controller.screen_centre(screens[1]).distance_to(above_before) < 0.001)
	assert(screens[1].on_sphere() and is_equal_approx(screens[1].surface_straight, controller.straight()), "The row above moves onto the new cap")
	assert(screens[1].placement_radius == primary.placement_radius, "One grid: one radius")
	screens[1].resize_to_aspect(2560, 1080)
	assert(controller.screen_centre(screens[1]).distance_to(above_before) < 0.001, "A secondary's own resize keeps its centre")
	# A curvature switch on a surface grid leaves the grid alone.
	var radius_before := primary.placement_radius
	controller.keep_grid(func():
		for screen in [primary] + screens: screen.curvature = 0)
	assert(primary.placement_radius == radius_before and screens[0].placement_radius == radius_before)
	assert(controller.screen_centre(screens[0]).distance_to(side_before) < 0.001)
	# Flat and Slight Curve screens are panels in front of the surface, angled
	# so side-by-side panels meet edge to edge on the same ray from its axis.
	owner.settings.placement_grid_shape = Grid.Shape.CYLINDER
	controller.reshape()
	for curve in [0, 1]:
		controller.keep_grid(func():
			for screen in [primary] + screens: screen.curvature = curve)
		var surface_r := controller.radius()
		var next_to := Vector3(primary.mesh_size.x * 0.5 + screens[0].mesh_size.x * 0.5, 0, 0)
		controller._place(screens[0], next_to, Grid.Shape.CYLINDER, surface_r)
		assert(controller.screen_centre(screens[0]).distance_to(next_to) < 0.001, "A panel keeps its place on the grid")
		assert(screens[0].surface_inset > 0.0 and primary.surface_inset > 0.0, "Panels sit in front of the surface")
		var inverse := controller.anchor().affine_inverse()
		var angle := func(local: Vector3) -> float: return atan2(local.x, surface_r - local.z)
		var primary_edge: Vector3 = inverse * primary.to_global(primary.corner_surface_point(1))
		var side_edge: Vector3 = inverse * screens[0].to_global(screens[0].corner_surface_point(0))
		assert(absf(angle.call(primary_edge) - angle.call(side_edge)) < 0.0005, "Curve %d: neighbouring panels meet edge to edge" % curve)
		assert(absf(angle.call(primary_edge) - primary.mesh_size.x * 0.5 / surface_r) < 0.0005, "A panel spans its footprint's angle")
		assert(not screens[0].on_sphere() and screens[0].is_flat() == (curve == 0))
	controller.keep_grid(func():
		for screen in [primary] + screens: screen.curvature = 2)
	assert(primary.surface_inset == 0.0, "Curved screens lie on the surface")
	# Lock Screens: only secondaries lose their controls.
	owner.settings.secondary_screens_locked = true
	assert(screens[1].controls_locked() and not primary.controls_locked())
	owner.settings.secondary_screens_locked = false
	assert(not screens[1].controls_locked())
