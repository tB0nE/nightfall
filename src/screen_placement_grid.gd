class_name ScreenPlacementGrid
extends RefCounted

## Grid coordinates: x is arc metres around the axis, y is height on the
## surface (see below), z is radial depth. The primary is the origin and
## tangent frame; nothing depends on head rotation.
## ORIGINAL is the slot layout from before the placement grid (main.gd
## grid_cell_transform); CYLINDER and SPHERE are one surface each.
enum Shape { ORIGINAL, CYLINDER, SPHERE }
const LABELS := ["Original", "Cylinder", "Sphere"]
const SPACINGS := [0.05, 0.1, 0.2]

## Cylinder and sphere grids are one surface around the viewer: a straight
## cylinder section of half-height `straight` (the primary's row on a cylinder
## grid; none on a sphere grid), with the rows above and below on a sphere
## centred on the viewer's point of the axis. That sphere passes through the
## straight section's top and bottom edges, so rows still meet edge to edge,
## and every screen on it faces the viewer.
## Rows on the sphere get less latitude the further they are from the middle:
## dy/d(lat) grows as a blend of sec(lat)^2 (a flat wall seen from its centre)
## and sec(lat)^3. Width falls as cos(lat), so a screen there is smaller and
## squashed vertically: by 20% at 30 degrees with SQUASH_BLEND (headset
## feedback: sec^2 alone, 15%, still looked tall; sec^3, 25%, was too much).
const SQUASH_BLEND := 0.4667
const OPEN := -1.0

static func default_straight(shape: int) -> float:
	return INF if shape == Shape.CYLINDER else 0.0

static func sphere_radius(radius: float, straight: float) -> float:
	return sqrt(radius * radius + straight * straight)

## Latitude on the sphere of grid height y, on the given side (+1 above the
## middle, -1 below), and back.
static func cap_lat(y: float, side: float, radius: float, straight: float) -> float:
	radius = maxf(radius, 0.001)
	var join := atan(straight / radius)
	var scale := _row_scale(radius, straight)
	var target := _row_integral(join) + (side * y - straight) / scale
	# Newton's method on the integral (its derivative is always >= 1).
	var lat := clampf(atan(target), -PI * 0.49, PI * 0.49)
	for i in range(12):
		var step := (_row_integral(lat) - target) / _row_density(lat)
		lat = clampf(lat - step, -PI * 0.499, PI * 0.499)
		if absf(step) < 0.0000001: break
	return side * lat

static func cap_y(lat: float, side: float, radius: float, straight: float) -> float:
	radius = maxf(radius, 0.001)
	var join := atan(straight / radius)
	var l := clampf(side * lat, -PI * 0.499, PI * 0.499)
	return side * (straight + (_row_integral(l) - _row_integral(join)) * _row_scale(radius, straight))

## Grid metres per unit of the row integral, so a row at the join is its true size.
static func _row_scale(radius: float, straight: float) -> float:
	return sphere_radius(radius, straight) / _row_density(atan(straight / radius))

## The blend of sec^2 and sec^3, and its integral from 0
## (tan, and (sec*tan + ln(sec + tan)) / 2).
static func _row_density(lat: float) -> float:
	var sec := 1.0 / cos(lat)
	return SQUASH_BLEND * sec * sec + (1.0 - SQUASH_BLEND) * sec * sec * sec

static func _row_integral(lat: float) -> float:
	var sec := 1.0 / cos(lat)
	var t := tan(lat)
	return SQUASH_BLEND * t + (1.0 - SQUASH_BLEND) * 0.5 * (sec * t + log(sec + t))

static func side_of(y: float) -> float:
	return -1.0 if y < 0.0 else 1.0

static func in_straight(y: float, straight: float) -> bool:
	return straight > 0.0 and absf(y) <= straight

static func point_transform(point: Vector3, shape: int, radius: float, straight: float = OPEN) -> Transform3D:
	if shape == Shape.ORIGINAL:
		return Transform3D(Basis.IDENTITY, point)
	if straight < 0.0: straight = default_straight(shape)
	radius = maxf(radius, 0.5)
	var yaw := point.x / radius
	if in_straight(point.y, straight):
		var basis := Basis(Vector3.UP, -yaw)
		var origin := Vector3(0, 0, radius) - basis.z * maxf(radius - point.z, 0.2)
		origin.y = point.y
		return Transform3D(basis, origin)
	var lat := clampf(cap_lat(point.y, side_of(point.y), radius, straight), -MAX_LATITUDE, MAX_LATITUDE)
	var cap_basis := Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, lat)
	return Transform3D(cap_basis, Vector3(0, 0, radius) - cap_basis.z * maxf(sphere_radius(radius, straight) - point.z, 0.2))

static func coordinates(point: Vector3, shape: int, radius: float, straight: float = OPEN) -> Vector3:
	if shape == Shape.ORIGINAL:
		return point
	if straight < 0.0: straight = default_straight(shape)
	radius = maxf(radius, 0.5)
	var offset := point - Vector3(0, 0, radius)
	var yaw := atan2(offset.x, -offset.z)
	if in_straight(offset.y, straight):
		return Vector3(yaw * radius, offset.y, radius - Vector2(offset.x, offset.z).length())
	var r := offset.length()
	var lat := asin(clampf(offset.y / maxf(r, 0.001), -1.0, 1.0))
	return Vector3(yaw * radius, cap_y(lat, side_of(offset.y), radius, straight), sphere_radius(radius, straight) - r)

## Where a screen of nominal height `height` centred at grid height y sits:
## {"on_cap": on the sphere rather than the straight section, "lat": middle
## latitude, "half": half its latitude span}.
static func band(y: float, height: float, radius: float, straight: float) -> Dictionary:
	if in_straight(y, straight): return {"on_cap": false, "lat": 0.0, "half": 0.0}
	var side := side_of(y)
	var top := cap_lat(y + height * 0.5, side, radius, straight)
	var bottom := cap_lat(y - height * 0.5, side, radius, straight)
	return {"on_cap": true, "lat": (top + bottom) * 0.5, "half": maxf((top - bottom) * 0.5, 0.0001)}

## The pose of a screen whose band is given: its frame at the patch middle,
## facing the sphere centre (which lies at local (0, 0, sphere radius)).
static func band_transform(x: float, y: float, info: Dictionary, radius: float, straight: float) -> Transform3D:
	radius = maxf(radius, 0.5)
	if not info.on_cap:
		return point_transform(Vector3(x, y, 0), Shape.CYLINDER, radius, INF)
	var basis := Basis(Vector3.UP, -x / radius) * Basis(Vector3.RIGHT, info.lat)
	return Transform3D(basis, Vector3(0, 0, radius) - basis.z * sphere_radius(radius, straight))

## Flat and Slight Curve screens on a cylinder or sphere grid keep their own
## shape: the surface only says where they go and which way they face. A
## Slight Curve panel bends at twice the surface's radius.
const SLIGHT_PANEL_FACTOR := 2.0

## The radius a screen of this curvature bends at on a surface of this radius
## (INF: flat). Curved screens take the surface's own shape.
static func panel_radius(curvature: int, radius: float) -> float:
	if curvature >= 2: return radius
	return INF if curvature <= 0 else radius * SLIGHT_PANEL_FACTOR

## How far a panel sits in front of the surface (towards its centre; negative:
## behind it), so its
## left and right edges lie on the same rays from the surface's axis as the
## edges of its footprint: side-by-side panels then meet edge to edge, angled.
## On the sphere caps a flat rectangle can't match its lat/long patch, so it
## sits far enough in to fit inside it both ways (leaving small gaps).
## info: band() for the screen's grid height. 0 for a Curved screen.
static func panel_inset(curvature: int, size: Vector2, radius: float, straight: float, info: Dictionary) -> float:
	if curvature >= 2 or radius <= 0.0: return 0.0
	var surface_r := radius
	var half_h := size.x * 0.5 / radius
	var half_v := 0.0
	if info.get("on_cap", false):
		surface_r = sphere_radius(radius, straight)
		var lat: float = info.lat
		half_h = acos(clampf(sin(lat) * sin(lat) + cos(lat) * cos(lat) * cos(size.x * 0.5 / radius), -1.0, 1.0))
		half_v = info.half
	half_h = clampf(half_h, 0.0001, 1.4)
	var rho := panel_radius(curvature, radius)
	var edge_x := size.x * 0.5
	var edge_z := 0.0
	if not is_inf(rho):
		edge_x = rho * sin(size.x * 0.5 / rho)
		edge_z = rho * (1.0 - cos(size.x * 0.5 / rho))
	var distance := edge_x / tan(half_h) + edge_z
	if half_v > 0.0:
		distance = maxf(distance, size.y * 0.5 / tan(clampf(half_v, 0.0001, 1.4)))
	# Squashed cap rows can put a panel behind the surface; that is fine.
	return clampf(surface_r - distance, -surface_r * 0.5, surface_r * 0.8)

## Cylinder and sphere grids are one surface each: screens lie on it rather
## than on nested shells, so neighbouring screens meet edge to edge.
static func single_surface(shape: int) -> bool:
	return shape != Shape.ORIGINAL

## Sphere screens are latitude/longitude patches of the grid sphere, so they
## warp like the surface itself and tile without gaps. A screen's own frame has
## its origin at the patch centre (longitude 0, latitude lat_c) facing the
## sphere centre, which lies at local (0, 0, radius).
static func sphere_local_point(dlon: float, lat: float, lat_c: float, radius: float) -> Vector3:
	var on_sphere := Vector3(0, 0, radius) - (Basis(Vector3.UP, -dlon) * Basis(Vector3.RIGHT, lat)).z * radius
	var centre := Vector3(0, 0, radius) - Basis(Vector3.RIGHT, lat_c).z * radius
	return Basis(Vector3.RIGHT, lat_c).inverse() * (on_sphere - centre)

## Longitude (from the patch centre) and latitude of a local point of a sphere screen.
static func sphere_angles(local: Vector3, lat_c: float, radius: float) -> Vector2:
	var v := Basis(Vector3.RIGHT, lat_c) * (local - Vector3(0, 0, radius))
	var length := maxf(v.length(), 0.0001)
	return Vector2(atan2(v.x, -v.z), asin(clampf(v.y / length, -1.0, 1.0)))

## The sphere frame of a sphere screen: centred on the sphere, with -Z through
## the screen's longitude at latitude 0. OpenXR equirect layers use this pose.
static func sphere_frame(screen_transform: Transform3D, lat_c: float, radius: float) -> Transform3D:
	var basis := screen_transform.basis.orthonormalized() * Basis(Vector3.RIGHT, lat_c).inverse()
	return Transform3D(basis, screen_transform.origin + screen_transform.basis.orthonormalized().z * radius)

## Keep a patch of this half-height clear of the poles.
const MAX_LATITUDE := PI * 0.42

static func clamp_sphere_centre_y(y: float, half_height: float, radius: float, straight: float = 0.0) -> float:
	var limit := maxf(cap_y(MAX_LATITUDE, 1.0, radius, straight) - half_height, 0.0)
	return clampf(y, -limit, limit)

## Per gesture: sample RAW motion, never the previously snapped output.
class SlowSnap extends RefCounted:
	var initialized := false
	var previous := Vector3.ZERO
	var cell := Vector3.ZERO
	var speed := 0.0
	var slow_seconds := 0.0
	var engaged := false

	func sample(raw: Vector3, delta: float, step: float) -> Vector3:
		return sample_grid(raw, delta, Vector3.ONE * maxf(step, 0.001), Vector3.ZERO)

	func sample_grid(raw: Vector3, delta: float, steps: Vector3, offset: Vector3) -> Vector3:
		if not initialized:
			initialized = true
			previous = raw
			cell = ScreenPlacementGrid.snap_point(raw, steps, offset)
			return raw
		delta = clampf(delta, 0.0001, 0.1)
		var instantaneous := raw.distance_to(previous) / delta
		previous = raw
		speed = lerpf(speed, instantaneous, 1.0 - exp(-delta / 0.035))
		if speed > 0.45:
			engaged = false
			slow_seconds = 0.0
		elif speed < 0.25:
			slow_seconds += delta
			if not engaged and slow_seconds >= 0.08:
				engaged = true
				cell = ScreenPlacementGrid.snap_point(raw, steps, offset)
		else:
			slow_seconds = 0.0
		if not engaged:
			return raw
		for axis in range(3):
			if absf(raw[axis] - cell[axis]) > steps[axis] * 0.65:
				cell[axis] = snappedf(raw[axis] - offset[axis], steps[axis]) + offset[axis]
		return cell

## Fit integral half-width/half-height subdivisions to the primary's actual
## corner in grid coordinates. The radial phase includes its curved edge bow.
## All four symmetric corners lie on points without changing the primary size.
static func lattice(corner: Vector3, nominal: float) -> Dictionary:
	var nx := maxi(1, roundi(absf(corner.x) / nominal))
	var ny := maxi(1, roundi(absf(corner.y) / nominal))
	return {"steps": Vector3(maxf(absf(corner.x) / nx, 0.001), maxf(absf(corner.y) / ny, 0.001), nominal),
		"offset": Vector3(0, 0, corner.z)}

static func snap_point(point: Vector3, steps: Vector3, offset: Vector3) -> Vector3:
	return (point - offset).snapped(steps) + offset

## Panels face the viewer, not the centre of the mathematical grid shell.
## Quantize yaw/pitch in the grid anchor's frame without shifting the position.
static func viewer_facing_basis(position: Vector3, viewer: Vector3, step: float = 0.0, reference: Basis = Basis.IDENTITY) -> Basis:
	var direction := reference.orthonormalized().inverse() * (viewer - position)
	var distance := direction.length()
	if distance < 0.001: return reference.orthonormalized()
	var yaw := atan2(direction.x, direction.z)
	var pitch := -asin(clampf(direction.y / distance, -1.0, 1.0))
	if step > 0.0:
		var angle_step := clampf(atan2(step, distance), deg_to_rad(1.0), deg_to_rad(5.0))
		yaw = snappedf(yaw, angle_step)
		pitch = snappedf(pitch, angle_step)
	pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
	return reference.orthonormalized() * Basis.from_euler(Vector3(pitch, yaw, 0))
