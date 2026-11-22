class_name ScreenPlacementController
extends RefCounted

var main: Node3D
var _owner: VRScreen
var _snap := ScreenPlacementGrid.SlowSnap.new()
var _radius := 4.0
var _guide: MultiMeshInstance3D
var _guide_centre := Vector3(INF, INF, INF)
var _guide_shape := -1
var _guide_step := Vector3.ZERO
var _guide_offset := Vector3.ZERO
var _snap_corner := 0
## The snapped corner's offset at drag start, with the screen's own radius. Snapping
## changes placement_radius, which moves a curved screen's real corner; sampling that
## would read as fast motion and release the snap every other frame.
var _corner_local := Vector3.ZERO
var _guide_radius := 0.0

var _radius_key: Array = []

func _init(owner: Node3D):
	main = owner

func shape() -> int:
	return main.settings.placement_grid_shape if main.settings.grid_mode_enabled else ScreenPlacementGrid.Shape.ORIGINAL

## The surface's radius as a multiple of the primary's distance. Grid Curve
## 0% matches a "Slightly Curved" screen (VRScreen.get_cylinder_radius());
## 100% bends tighter than a surface centred on the viewer.
const LOOSEST_CURVE := 3.0
const TIGHTEST_CURVE := 0.76
const MAX_RADIUS := 12.0

## The surface radius per metre of viewing distance for a Grid Curve percentage.
## Curvature (1 / radius) changes evenly along the slider.
static func curve_factor(percent: float) -> float:
	return 1.0 / lerpf(1.0 / LOOSEST_CURVE, 1.0 / TIGHTEST_CURVE, clampf(percent / 100.0, 0.0, 1.0))

## Cylinder and sphere grids are one surface around the viewer, sized by the
## primary's distance (tighter with Grid Curve).
func radius() -> float:
	var primary: VRScreen = main.primary_screen
	if primary == null: return 4.0
	var current := shape()
	var key := [primary.get_instance_id(), primary.curvature, current]
	if key == _radius_key: return _radius
	_radius_key = key
	if ScreenPlacementGrid.single_surface(current):
		if primary.surface == current and primary.placement_radius > 0.0:
			_radius = primary.placement_radius # Keep the arrangement's own sphere.
		elif is_instance_valid(main.xr_camera):
			var distance := primary.global_position.distance_to(main.xr_camera.global_position)
			_radius = clampf(distance * curve_factor(main.settings.placement_grid_curve), 0.5, MAX_RADIUS)
		else:
			_radius = 2.0
		if primary.surface != current:
			_set_surface(primary, current, _radius, _band_state(0.0, primary.mesh_size.y, _radius, current))
			# The primary's panel stays where it is; the surface lies behind it.
			primary.surface_inset = primary.panel_inset_now()
	else:
		if primary.on_surface(): _leave_surface(primary)
		_radius = primary.get_cylinder_radius() if primary.curvature > 0 else (maxf(primary.global_position.distance_to(main.xr_camera.global_position), 1.0) if is_instance_valid(main.xr_camera) else 4.0)
	return _radius

## Half-height of the capsule's straight section: the primary's own height on
## a cylinder grid, so its row is a plain cylinder and the rows above and below
## lie on the caps. A sphere grid has none.
func straight() -> float:
	if main.settings.placement_grid_shape != ScreenPlacementGrid.Shape.CYLINDER or main.primary_screen == null: return 0.0
	return main.primary_screen.mesh_size.y * 0.5

## Surface coordinates of a point in the anchor frame, and back.
func to_grid(local: Vector3) -> Vector3:
	return ScreenPlacementGrid.coordinates(local, shape(), radius(), straight())

func from_grid(point: Vector3) -> Transform3D:
	return ScreenPlacementGrid.point_transform(point, shape(), radius(), straight())

## The grid's origin frame: the primary's place at height 0. A primary resized
## on the surface may sit off the middle; the surface itself does not move.
func anchor() -> Transform3D:
	var primary: VRScreen = main.primary_screen
	if not primary.on_surface():
		return primary.global_transform
	var pose := primary.surface_pose()
	var basis := pose.basis.orthonormalized()
	if primary.on_cap():
		var frame := ScreenPlacementGrid.sphere_frame(pose, primary.surface_lat, primary.sphere_r())
		return Transform3D(frame.basis, frame.origin - frame.basis.z * primary.placement_radius)
	return Transform3D(basis, pose.origin - basis.y * primary.surface_y)

## Surface coordinates of a screen's centre. A sphere screen's node sits at its
## patch's middle latitude, which is not quite its middle grid height.
func screen_centre(screen: VRScreen) -> Vector3:
	var centre := to_grid(anchor().affine_inverse() * screen.surface_pose().origin)
	if screen.on_cap():
		centre.y += screen.surface_y - ScreenPlacementGrid.cap_y(screen.surface_lat,
			ScreenPlacementGrid.side_of(screen.surface_y), screen.placement_radius, screen.surface_straight)
	centre.z = 0.0
	return centre

## The lattice runs through the primary's corners, with a whole number of steps
## across its width and height, so all four corners lie on grid points.
func lattice() -> Dictionary:
	var primary: VRScreen = main.primary_screen
	var current := shape()
	var r := radius()
	var inverse := anchor().affine_inverse() * primary.surface_pose()
	var corner := primary.grid_corner_point if primary.on_surface() else primary.corner_surface_point
	var top_right := ScreenPlacementGrid.coordinates(inverse * corner.call(1), current, r, straight())
	var bottom_left := ScreenPlacementGrid.coordinates(inverse * corner.call(2), current, r, straight())
	var nominal: float = main.settings.placement_grid_spacing
	var span := (top_right - bottom_left).abs()
	var nx := maxi(1, roundi(span.x / nominal))
	var ny := maxi(1, roundi(span.y / nominal))
	var steps := Vector3(maxf(span.x / nx, 0.001), maxf(span.y / ny, 0.001), nominal)
	var offset := Vector3(top_right.x, top_right.y, 0.0 if ScreenPlacementGrid.single_surface(current) else top_right.z)
	return {"steps": steps, "offset": offset}

static func corner_signs(index: int) -> Vector2:
	return Vector2(-1.0 if index in [0, 2] else 1.0, 1.0 if index < 2 else -1.0)

## Where a screen of this height centred at grid height y lies on the surface.
func _band_state(y: float, height: float, r: float, current: int) -> Dictionary:
	var h := straight() if current == ScreenPlacementGrid.Shape.CYLINDER else 0.0
	var info := ScreenPlacementGrid.band(y, height, r, h)
	return {"y": y, "on_cap": info.on_cap, "straight": h, "lat": info.lat, "info": info}

func _set_surface(screen: VRScreen, surface_shape: int, r: float, state: Dictionary) -> void:
	var changed: bool = screen.surface != surface_shape or absf(screen.placement_radius - r) > 0.0001 \
		or absf(screen.surface_lat - state.lat) > 0.0002 or screen.surface_on_cap != state.on_cap \
		or absf(screen.surface_y - state.y) > 0.0002 or absf(screen.surface_straight - state.straight) > 0.0002
	screen.surface = surface_shape
	screen.placement_radius = r
	screen.surface_lat = state.lat
	screen.surface_y = state.y
	screen.surface_straight = state.straight
	screen.surface_on_cap = state.on_cap
	if surface_shape == ScreenPlacementGrid.Shape.ORIGINAL: screen.surface_inset = 0.0
	if changed:
		screen.apply_curvature()

func _leave_surface(screen: VRScreen) -> void:
	_set_surface(screen, ScreenPlacementGrid.Shape.ORIGINAL, 0.0, {"y": 0.0, "on_cap": false, "straight": 0.0, "lat": 0.0})

## Put a screen's centre at surface coordinates of the grid.
func _place(screen: VRScreen, centre: Vector3, current: int, r: float, frame := Transform3D()) -> void:
	centre.y = ScreenPlacementGrid.clamp_sphere_centre_y(centre.y, screen.mesh_size.y * 0.5, r,
		straight() if current == ScreenPlacementGrid.Shape.CYLINDER else 0.0)
	# The primary is laid in the grid frame it defined before the change.
	if frame == Transform3D(): frame = anchor()
	var state := _band_state(centre.y, screen.mesh_size.y, r, current)
	var pose := frame * ScreenPlacementGrid.band_transform(centre.x, centre.y, state.info, r, state.straight)
	_set_surface(screen, current, r, state)
	screen.surface_inset = screen.panel_inset_now()
	screen.global_transform = pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, screen.surface_inset))

## Where a new screen of this size, put at `world` (a grid_cell_transform()),
## would appear once laid on the grid: its pose, and the composition layer
## shape that draws it there. Used for the tab-drop outline.
func preview(world: Transform3D, size: Vector2, curvature: int) -> Dictionary:
	var current := shape()
	if not ScreenPlacementGrid.single_surface(current):
		var view_distance := 2.0
		if is_instance_valid(main.xr_camera):
			view_distance = maxf(world.origin.distance_to(main.xr_camera.global_position), 0.5)
		var curve_radius: float = view_distance * ([100.0, 3.0, 2.0][clampi(curvature, 0, 2)])
		return {"kind": &"cylinder", "screen": world, "size": size, "radius": curve_radius}
	return surface_preview(to_grid(anchor().affine_inverse() * world.origin), size, curvature)

## As preview(), for a screen centred at surface coordinates `centre`.
func surface_preview(centre: Vector3, size: Vector2, curvature := -1) -> Dictionary:
	var current := shape()
	var r := radius()
	var h := straight() if current == ScreenPlacementGrid.Shape.CYLINDER else 0.0
	if curvature < 0: curvature = main.primary_screen.curvature if main.primary_screen else 2
	centre.y = ScreenPlacementGrid.clamp_sphere_centre_y(centre.y, size.y * 0.5, r, h)
	var state := _band_state(centre.y, size.y, r, current)
	var pose := anchor() * ScreenPlacementGrid.band_transform(centre.x, centre.y, state.info, r, state.straight)
	if curvature < 2:
		# A Flat or Slight Curve panel in front of its place (see _place()).
		var inset := ScreenPlacementGrid.panel_inset(curvature, size, r, state.straight, state.info)
		var panel_r := ScreenPlacementGrid.panel_radius(curvature, r)
		return {"kind": &"cylinder", "screen": pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, inset)), "size": size,
			"radius": r * 100.0 if is_inf(panel_r) else panel_r}
	if not state.on_cap:
		return {"kind": &"cylinder", "screen": pose, "size": size, "radius": r}
	var sphere := ScreenPlacementGrid.sphere_radius(r, state.straight)
	var side := ScreenPlacementGrid.side_of(centre.y)
	return {"kind": &"sphere", "screen": pose, "size": size, "radius": sphere,
		"frame": ScreenPlacementGrid.sphere_frame(pose, state.lat, sphere), "horizontal": size.x / r,
		"upper": ScreenPlacementGrid.cap_lat(centre.y + size.y * 0.5, side, r, state.straight),
		"lower": ScreenPlacementGrid.cap_lat(centre.y - size.y * 0.5, side, r, state.straight)}

## Where the ray from `from` through `point` meets the grid surface, in
## surface coordinates; null if it doesn't (or the grid isn't a surface).
func ray_grid_point(from: Vector3, point: Vector3) -> Variant:
	var current := shape()
	if not ScreenPlacementGrid.single_surface(current) or main.primary_screen == null: return null
	var direction := point - from
	if direction.length() < 0.0001: return null
	direction = direction.normalized()
	var r := radius()
	var h := straight()
	var inverse := anchor().affine_inverse()
	# Depth in front of the surface falls along a ray leaving the viewer.
	var near := 0.0
	var far := r * 4.0
	if ScreenPlacementGrid.coordinates(inverse * from, current, r, h).z <= 0.0: return null
	if ScreenPlacementGrid.coordinates(inverse * (from + direction * far), current, r, h).z > 0.0: return null
	for i in range(40):
		var middle := (near + far) * 0.5
		if ScreenPlacementGrid.coordinates(inverse * (from + direction * middle), current, r, h).z > 0.0:
			near = middle
		else:
			far = middle
	var hit := ScreenPlacementGrid.coordinates(inverse * (from + direction * far), current, r, h)
	hit.z = 0.0
	return hit

## Where a new screen of this size dropped along the pointer ray goes on the
## surface (its centre, in surface coordinates): centred on the pointer, its
## corner nearest the primary on the lattice, as a dragged screen snaps. If
## that overlaps a screen, the nearest spot edge to edge with one instead.
## null if the ray misses the surface.
func drop_centre(from: Vector3, point: Vector3, size: Vector2, exclude: VRScreen = null) -> Variant:
	var hit = ray_grid_point(from, point)
	if hit == null: return null
	var grid := lattice()
	var steps: Vector3 = grid.steps
	var offset: Vector3 = grid.offset
	var primary_centre := screen_centre(main.primary_screen)
	var half := Vector3(size.x * 0.5, size.y * 0.5, 0.0)
	var signs := Vector2(signf(primary_centre.x - hit.x), signf(primary_centre.y - hit.y))
	if signs.x == 0.0: signs.x = 1.0
	if signs.y == 0.0: signs.y = 1.0
	var corner := Vector3(hit.x + signs.x * half.x, hit.y + signs.y * half.y, 0.0)
	corner = Vector3(offset.x + roundf((corner.x - offset.x) / steps.x) * steps.x,
		offset.y + roundf((corner.y - offset.y) / steps.y) * steps.y, 0.0)
	var base := corner - Vector3(signs.x * half.x, signs.y * half.y, 0.0)
	var others: Array = []
	for screen in main.screens:
		if screen == exclude or not is_instance_valid(screen) or not screen.visible: continue
		if screen != main.primary_screen and not screen.on_surface(): continue
		others.append({"centre": screen_centre(screen), "half": Vector2(screen.mesh_size) * 0.5})
	if _drop_free(base, half, others): return base
	var candidates: Array = []
	for other in others:
		var c: Vector3 = other.centre
		var oh: Vector2 = other.half
		# Beside it at the snapped row, or above/below it at the snapped column.
		candidates.append(Vector3(c.x + oh.x + half.x, base.y, 0))
		candidates.append(Vector3(c.x - oh.x - half.x, base.y, 0))
		candidates.append(Vector3(base.x, c.y + oh.y + half.y, 0))
		candidates.append(Vector3(base.x, c.y - oh.y - half.y, 0))
		# Its neighbours' slots: straight beside, above or below it.
		candidates.append(Vector3(c.x + oh.x + half.x, c.y, 0))
		candidates.append(Vector3(c.x - oh.x - half.x, c.y, 0))
		candidates.append(Vector3(c.x, c.y + oh.y + half.y, 0))
		candidates.append(Vector3(c.x, c.y - oh.y - half.y, 0))
	var best = null
	var best_distance := INF
	for candidate in candidates:
		var distance := Vector2(candidate.x - hit.x, candidate.y - hit.y).length_squared()
		if distance < best_distance and _drop_free(candidate, half, others):
			best = candidate
			best_distance = distance
	return best if best != null else base

static func _drop_free(centre: Vector3, half: Vector3, others: Array) -> bool:
	const EDGE := 0.005 # Screens meeting edge to edge don't overlap.
	for other in others:
		var c: Vector3 = other.centre
		var oh: Vector2 = other.half
		if absf(centre.x - c.x) < half.x + oh.x - EDGE and absf(centre.y - c.y) < half.y + oh.y - EDGE:
			return false
	return true

## Lay a dropped screen on the surface, centred at surface coordinates.
func place_dropped(screen: VRScreen, centre: Vector3) -> void:
	_place(screen, centre, shape(), radius())
	screen.set_meta(&"placement_grid_owned", true)
	screen.grid_pos = Vector2i(-1, -1)

var _keeping := false

## Run `change` (a resize, a curvature switch) without anything leaving the
## grid: every screen's grid position is noted first and the screens are laid
## back there on the surface afterwards. A cylinder grid's middle row follows
## the primary's height, so a resize anywhere can move the surface itself.
## The primary is laid back too unless `change` placed it (a pinned resize).
func keep_grid(change: Callable, place_primary := true) -> void:
	var current := shape()
	var primary: VRScreen = main.primary_screen
	if _keeping or primary == null or not ScreenPlacementGrid.single_surface(current) or primary.surface != current:
		change.call()
		return
	_keeping = true
	var r := primary.placement_radius
	var frame := anchor()
	var centres := {}
	for screen in main.screens:
		if is_instance_valid(screen) and screen.surface == current: centres[screen] = screen_centre(screen)
	change.call()
	_radius_key = []
	if place_primary and centres.has(primary):
		_place(primary, centres[primary], current, r, frame)
		primary.apply_curvature()
	for screen in centres:
		if screen != primary and is_instance_valid(screen) and main.screens.has(screen): _place(screen, centres[screen], current, r)
	_keeping = false
	if main.comp and main.comp.in_use: main.comp.update_cylinder_params()

## Grid Curve changed: the surface bends tighter or looser around the primary,
## which stays where it is. Every screen keeps its grid position (arc metres).
func set_curve(percent: int) -> void:
	var old: int = main.settings.placement_grid_curve
	main.settings.placement_grid_curve = clampi(percent, 0, 100)
	var current := shape()
	var primary: VRScreen = main.primary_screen
	if primary == null or not ScreenPlacementGrid.single_surface(current) or primary.surface != current: return
	finish()
	var centres := {}
	for screen in main.screens:
		if screen != primary and is_instance_valid(screen) and screen.surface == current: centres[screen] = screen_centre(screen)
	primary.placement_radius = clampf(primary.placement_radius * curve_factor(main.settings.placement_grid_curve) / curve_factor(old), 0.5, MAX_RADIUS)
	_radius_key = []
	var r := radius()
	primary.surface_inset = primary.panel_inset_now()
	primary.apply_curvature()
	for screen in centres: _place(screen, centres[screen], current, r)
	if main.comp and main.comp.in_use: main.comp.update_cylinder_params()

## Put a screen onto the current grid surface where it already is, or take it
## off a surface it no longer belongs to.
func adhere(screen: VRScreen) -> void:
	if main.primary_screen == null: return
	var current := shape()
	var r := radius()
	if screen == main.primary_screen: return
	if not ScreenPlacementGrid.single_surface(current):
		if screen.on_surface(): _leave_surface(screen)
		return
	_place(screen, screen_centre(screen) if screen.surface == current else to_grid(anchor().affine_inverse() * screen.global_position), current, r)

## The grid shape or grid mode changed: move every grid screen onto the new surface.
func reshape() -> void:
	finish()
	_radius_key = []
	if main.primary_screen == null: return
	radius()
	for screen in main.screens:
		if screen != main.primary_screen and (screen.has_meta(&"placement_grid_owned") or screen.on_surface()):
			adhere(screen)
	if main.comp and main.comp.in_use: main.comp.update_cylinder_params()

## The primary was moved. With nothing else on the surface yet, re-centre the
## surface on the viewer at the primary's new distance.
func primary_released() -> void:
	var primary: VRScreen = main.primary_screen
	if primary == null or not primary.on_surface(): return
	for screen in main.screens:
		if screen != primary and screen.on_surface(): return
	var keep := primary.surface
	primary.surface = ScreenPlacementGrid.Shape.ORIGINAL
	primary.placement_radius = 0.0
	primary.surface_lat = 0.0
	primary.surface_y = 0.0
	primary.surface_straight = 0.0
	primary.surface_on_cap = false
	_radius_key = []
	radius()
	if primary.surface != keep: primary.apply_curvature()

## Resizing on a surface: keep the pinned corner at its surface coordinates.
func place_pinned(screen: VRScreen, pinned_corner: int, pinned_world: Vector3) -> void:
	var current := screen.surface
	var r := screen.placement_radius
	var signs := corner_signs(pinned_corner)
	var corner := to_grid(anchor().affine_inverse() * pinned_world)
	var centre := corner - Vector3(signs.x * screen.mesh_size.x * 0.5, signs.y * screen.mesh_size.y * 0.5, 0)
	centre.z = 0.0
	# The primary defines the anchor, but _place reads it before moving the primary.
	_place(screen, centre, current, r)
	screen.apply_curvature()

func drag(screen: VRScreen, delta: float) -> void:
	if screen == main.primary_screen:
		finish()
		return
	if not ScreenPlacementGrid.single_surface(shape()):
		# Original layout, or grid mode off: XRInteraction places the screen
		# (slot snapping or free placement); it keeps its own curvature.
		if screen.on_surface(): _leave_surface(screen)
		finish()
		return
	_drag_on_surface(screen, delta)

## Cylinder/sphere: the screen slides over the one surface. Its corner nearest
## the primary snaps to the lattice in surface coordinates (arc metres), so
## same-sized screens meet edge to edge, row above row.
func _drag_on_surface(screen: VRScreen, delta: float) -> void:
	var current := shape()
	var r := radius()
	var frame := anchor()
	var centre := screen_centre(screen) if screen.surface == current else to_grid(frame.affine_inverse() * screen.global_position)
	centre.z = 0.0
	if screen != _owner:
		_owner = screen
		_snap = ScreenPlacementGrid.SlowSnap.new()
		var primary_centre := screen_centre(main.primary_screen)
		var nearest := INF
		for index in range(4):
			var signs := corner_signs(index)
			var corner := centre + Vector3(signs.x * screen.mesh_size.x * 0.5, signs.y * screen.mesh_size.y * 0.5, 0)
			var distance := Vector2(corner.x - primary_centre.x, corner.y - primary_centre.y).length_squared()
			if distance < nearest:
				nearest = distance
				_snap_corner = index
	var signs := corner_signs(_snap_corner)
	var half := Vector3(signs.x * screen.mesh_size.x * 0.5, signs.y * screen.mesh_size.y * 0.5, 0)
	var raw := centre + half
	var grid := lattice()
	var point := _snap.sample_grid(raw, delta, Vector3(grid.steps.x, grid.steps.y, 1.0), grid.offset)
	_place(screen, (point if _snap.engaged else raw) - half, current, r)
	screen.set_meta(&"placement_grid_owned", true)
	screen.grid_pos = Vector2i(-1, -1)
	show_guide(raw, screen)

func show_guide(point: Vector3, screen: VRScreen = null) -> void:
	_guide_screen = screen if screen != null else main.primary_screen
	if not ScreenPlacementGrid.single_surface(shape()): return
	if not is_instance_valid(_guide):
		_guide = MultiMeshInstance3D.new()
		_guide.name = "ScreenPlacementGuide"
		_guide.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var dots := MultiMesh.new()
		dots.transform_format = MultiMesh.TRANSFORM_3D
		var dot := SphereMesh.new()
		dot.radius = 0.003
		dot.height = 0.006
		dot.radial_segments = 4
		dot.rings = 2
		dots.mesh = dot
		dots.instance_count = 15 * 11 * 3
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.35, 0.7, 1.0, 0.45)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_guide.material_override = material
		_guide.multimesh = dots
		main.add_child(_guide)
	_guide.global_transform = anchor()
	_guide.visible = true
	var current: int = main.settings.placement_grid_shape
	var grid := lattice()
	var centre := ScreenPlacementGrid.snap_point(point, grid.steps, grid.offset)
	var r := radius()
	if centre == _guide_centre and current == _guide_shape and grid.steps == _guide_step and grid.offset == _guide_offset and r == _guide_radius: return
	_guide_centre = centre
	_guide_shape = current
	_guide_step = grid.steps
	_guide_offset = grid.offset
	_guide_radius = r
	var i := 0
	# One surface has one layer of points; flat grids also show the depth shells.
	var shells := [0] if ScreenPlacementGrid.single_surface(current) else [-1, 0, 1]
	for z in shells:
		for y in range(-5, 6):
			for x in range(-7, 8):
				var t := ScreenPlacementGrid.point_transform(centre + Vector3(x, y, z) * _guide_step, current, r, straight())
				_guide.multimesh.set_instance_transform(i, t)
				i += 1
	_guide.multimesh.visible_instance_count = i

func finish() -> void:
	_owner = null
	_guide_screen = null
	if is_instance_valid(_guide): _guide.hide()
	for canvas in _composition_guides.values():
		if is_instance_valid(canvas): canvas.hide()

## Projectionless Quest rendering reuses the existing screen-controls atlas.
## The dots are a surface-projected guide; placement itself remains fully 3D.
class GuideCanvas extends Control:
	var points := PackedVector2Array()
	var snapped := false
	func _draw() -> void:
		var color := Color(0.3, 0.9, 0.65, 0.65) if snapped else Color(0.4, 0.7, 1.0, 0.45)
		for point in points:
			draw_circle(point, 2.0, color)

var _guide_screen: VRScreen
var _composition_guides := {}

func update_composition_guide(screen: VRScreen, surface_size: Vector2) -> void:
	var id := screen.get_instance_id()
	var canvas: GuideCanvas = _composition_guides.get(id)
	if screen != _guide_screen or not is_instance_valid(_guide) or not _guide.visible:
		if is_instance_valid(canvas): canvas.hide()
		return
	if not screen.comp_corner_viewport: return
	if not is_instance_valid(canvas):
		canvas = GuideCanvas.new()
		canvas.name = "PlacementGridGuide"
		canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
		canvas.z_index = -1
		canvas.clip_contents = true
		screen.comp_corner_viewport.add_child(canvas)
		_composition_guides[id] = canvas
	canvas.size = screen.comp_corner_viewport.size
	canvas.show()
	var pixels := float(screen.comp_corner_viewport.size.x) / surface_size.x
	var anchor_to_screen: Transform3D = screen.global_transform.affine_inverse() * anchor()
	var points := PackedVector2Array()
	# The middle radial shell keeps the on-screen aid readable. The 3D scene
	# guide additionally shows the neighbouring shells where scene rendering exists.
	for y in range(-5, 6):
		for x in range(-7, 8):
			var point := _guide_centre + Vector3(x, y, 0) * _guide_step
			var local: Vector3 = anchor_to_screen * ScreenPlacementGrid.point_transform(point, _guide_shape, _guide_radius, straight()).origin
			var u: float = local.x
			var v: float = local.y
			if screen.on_sphere():
				var angles := ScreenPlacementGrid.sphere_angles(local, screen.surface_lat, screen.placement_radius)
				u = angles.x * screen.placement_radius
				v = (angles.y - screen.band_mid()) / screen.lat_scale()
			elif not screen.is_flat():
				var r := screen.get_cylinder_radius()
				u = atan2(local.x, r - local.z) * r
			points.append(canvas.size * 0.5 + Vector2(u, -v) * pixels)
	canvas.points = points
	canvas.snapped = _snap.engaged if _owner == screen else screen._corner_snap.engaged
	canvas.queue_redraw()
