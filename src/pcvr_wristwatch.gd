class_name PCVRWristwatch
extends RefCounted
## Local-only controller watch, composited into the existing XR projection.
const SIZE := Vector2(0.16, 0.10)
var calibration_markers := false # Retained for future DEV placement comparisons.
var main
var _reveal := 0.0
var _pressed := false
var _blocked_until_release := true
var _capture_click := false

func _init(owner): main = owner

func interaction_blocked() -> bool:
	return _pressed and _capture_click

static func mount_transform() -> Transform3D:
	# User-selected marker 13 anchors the right-edge midpoint, not the centre.
	# Face outwards (-X), with 45 degrees clockwise from the marker-13 baseline.
	var face := Basis(Vector3(0,-1,0), Vector3(0,0,1), Vector3(-1,0,0))
	face = face * Basis(Vector3.BACK, -PI / 4)
	return Transform3D(face, Vector3(-0.07,0,0.04) - face.x * SIZE.x * 0.5)

static func unpack_pose(values: PackedFloat32Array, offset: int) -> Transform3D:
	return Transform3D(Basis(Quaternion(values[offset+3], values[offset+4], values[offset+5], values[offset+6])), Vector3(values[offset], values[offset+1], values[offset+2]))

static func facing(pose: Transform3D, head: Transform3D) -> bool:
	var toward_head := head.origin - pose.origin
	var distance := toward_head.length()
	return distance > 0.15 and distance < 1.0 and pose.basis.z.dot(toward_head.normalized()) > 0.65 and (-head.basis.z).dot(-toward_head.normalized()) > 0.65

static func hit(pose: Transform3D, ray: Transform3D) -> Vector2:
	var inverse := pose.affine_inverse()
	var origin := inverse * ray.origin
	var direction := inverse.basis * -ray.basis.z
	if origin.z <= 0 or direction.z >= -0.001: return Vector2(-1, -1)
	var point := origin + direction * (-origin.z / direction.z)
	var uv := Vector2(point.x / SIZE.x + 0.5, 0.5 - point.y / SIZE.y)
	if uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1: return Vector2(-1, -1)
	return uv

func reset() -> void:
	_reveal = 0
	_pressed = false
	_blocked_until_release = true
	_capture_click = false
	var backend = main.pcvr_test.backend
	if backend and backend.has_method("set_wristwatch"):
		backend.set_wristwatch(PackedFloat32Array())
		backend.set_workspace_input_focus(false)

func process(delta: float, handover) -> void:
	var backend = main.pcvr_test.backend
	if not backend or not backend.has_method("set_wristwatch"): return
	# Use the exact Quest LOCAL poses sent to Meteor, not Godot's potentially
	# recentered/STAGE-relative scene transforms.
	var tracking: PackedFloat32Array = backend.get_wristwatch_tracking()
	var valid := tracking.size() == 22
	var pose := Transform3D.IDENTITY
	var uv := Vector2(-1, -1)
	var down := false
	if valid and calibration_markers:
		# Raw grip origin, not the guessed watch mount: compare positions around
		# the hand and progressively along the wrist/forearm without face gating.
		pose = unpack_pose(tracking, 7)
		var rotation := pose.basis.get_rotation_quaternion()
		backend.set_wristwatch(PackedFloat32Array([
			pose.origin.x,pose.origin.y,pose.origin.z,rotation.x,rotation.y,rotation.z,rotation.w,
			0,0,0,0,-1,-1,2,0]))
		backend.set_workspace_input_focus(handover.desktop_visible)
		return
	if valid:
		pose = unpack_pose(tracking, 7) * mount_transform()
		_reveal = minf(_reveal + delta, 0.2) if facing(pose, unpack_pose(tracking, 0)) else 0.0
		if _reveal >= 0.2: uv = hit(pose, unpack_pose(tracking, 14))
		down = tracking[21] > 0.65
	else: _reveal = 0
	# A trigger already held when the watch appears must never select it.
	if not down:
		_blocked_until_release = false
		_capture_click = false
	if _reveal < 0.2: _blocked_until_release = down
	var hovered := uv.x >= 0 and uv.y >= 0.55
	if hovered and down and not _pressed and not _blocked_until_release:
		handover.set_desktop_visible(not handover.desktop_visible)
		_blocked_until_release = true
		_capture_click = true
	_pressed = down
	backend.set_workspace_input_focus(handover.desktop_visible or hovered or _capture_click)
	var q := pose.basis.get_rotation_quaternion()
	var time := Time.get_time_dict_from_system()
	backend.set_wristwatch(PackedFloat32Array([
		pose.origin.x, pose.origin.y, pose.origin.z, q.x, q.y, q.z, q.w,
		int(time.hour) / 10, int(time.hour) % 10, int(time.minute) / 10, int(time.minute) % 10,
		uv.x, uv.y, 1.0 if _reveal >= 0.2 else 0.0, 1.0 if handover.desktop_visible else 0.0]))
