extends SceneTree
const Watch = preload("res://src/pcvr_wristwatch.gd")

class Backend extends RefCounted:
	var tracking := PackedFloat32Array()
	var state := PackedFloat32Array()
	var focused := false
	func get_wristwatch_tracking() -> PackedFloat32Array: return tracking
	func set_wristwatch(value: PackedFloat32Array) -> void: state = value
	func set_workspace_input_focus(value: bool) -> void: focused = value
class PCVR extends RefCounted:
	var backend := Backend.new()
class Owner extends RefCounted:
	var pcvr_test := PCVR.new()
class Handover extends RefCounted:
	var desktop_visible := false
	var menu_only := false
	var menus := 0
	func toggle_pcvr_menu() -> void:
		if menu_only: menu_only = false
		else: open_pcvr_menu()
	func open_pcvr_menu() -> void:
		menu_only = true
		menus += 1
	var toggles := 0
	func set_desktop_visible(value: bool) -> void:
		desktop_visible = value
		toggles += 1

func pack_pose(pose: Transform3D) -> PackedFloat32Array:
	var q := pose.basis.get_rotation_quaternion()
	return PackedFloat32Array([pose.origin.x,pose.origin.y,pose.origin.z,q.x,q.y,q.z,q.w])

func _init():
	var pose := Transform3D(Basis.IDENTITY, Vector3(0,0,-0.5))
	assert(Watch.facing(pose, Transform3D.IDENTITY))
	assert(not Watch.facing(Transform3D(Basis(Vector3.UP, PI),pose.origin), Transform3D.IDENTITY))
	assert(Watch.hit(pose, Transform3D.IDENTITY).is_equal_approx(Vector2(.5,.5)))
	assert(Watch.settings_hit(Vector2(.8,.7)))
	assert(not Watch.settings_hit(Vector2(.3,.7)))
	assert(Watch.hit(pose, Transform3D(Basis.IDENTITY,Vector3(1,0,0))).x < 0)
	assert(Watch.hit(pose, Transform3D(Basis(Vector3.UP,PI),Vector3.ZERO)).x < 0)
	var owner := Owner.new()
	var handover := Handover.new()
	var watch := Watch.new(owner)
	watch.calibration_markers = false
	var backend := owner.pcvr_test.backend
	var mount := Watch.mount_transform()
	assert((mount.origin + mount.basis.x * Watch.SIZE.x * .5).is_equal_approx(Vector3(-.07,0,.04))) # Right edge at marker 13.
	assert(mount.basis.z.is_equal_approx(Vector3.LEFT))
	assert(mount.basis.x.is_equal_approx(Vector3(0,-1,-1).normalized()))
	assert(mount.basis.y.is_equal_approx(Vector3(0,-1,1).normalized()))
	assert(is_equal_approx(mount.basis.determinant(),1.0))
	var grip := pose * mount.affine_inverse()
	backend.tracking = pack_pose(Transform3D.IDENTITY)
	backend.tracking.append_array(pack_pose(grip))
	backend.tracking.append_array(pack_pose(Transform3D(Basis.IDENTITY,Vector3(0,-.03,0))))
	backend.tracking.append(0)
	watch.process(.1,handover)
	assert(backend.state[13] == 0)
	watch.process(.1,handover)
	assert(backend.state[13] == 1 and handover.toggles == 0) # Gaze never clicks.
	backend.tracking[21] = 1
	watch.process(.01,handover)
	assert(handover.desktop_visible and handover.toggles == 1 and watch.interaction_blocked())
	watch.process(.1,handover)
	assert(handover.toggles == 1) # Held trigger cannot repeat.
	backend.tracking[21] = 0
	watch.process(.01,handover)
	assert(not watch.interaction_blocked())
	backend.tracking[21] = 1
	watch.process(.01,handover)
	assert(not handover.desktop_visible and handover.toggles == 2)
	backend.tracking[21] = 0
	watch.process(.01,handover)
	var gear_ray := pack_pose(Transform3D(Basis.IDENTITY,Vector3(.048,-.03,0)))
	for i in 7: backend.tracking[14+i] = gear_ray[i]
	watch.process(.01,handover)
	backend.tracking[21] = 1
	watch.process(.01,handover)
	assert(handover.menus == 1 and handover.menu_only and not handover.desktop_visible)
	assert(backend.focused and handover.toggles == 2)
	watch.process(.01,handover)
	assert(handover.menus == 1) # Held trigger does not reopen the menu.
	backend.tracking[21] = 0
	watch.process(.01,handover)
	backend.tracking[21] = 1
	watch.process(.01,handover)
	assert(not handover.menu_only and handover.menus == 1) # Second gear click closes.
	backend.tracking[21] = 0
	watch.process(.01,handover)
	backend.tracking = PackedFloat32Array()
	watch.process(.1,handover)
	assert(backend.state[13] == 0)
	# A normal game trigger press while looking away must not capture input.
	backend.tracking = pack_pose(Transform3D(Basis(Vector3.UP,PI),Vector3.ZERO))
	backend.tracking.append_array(pack_pose(grip))
	backend.tracking.append_array(pack_pose(Transform3D.IDENTITY))
	backend.tracking.append(1)
	watch.process(.1,handover)
	assert(not backend.focused and handover.toggles == 2)
	watch.calibration_markers = true
	watch.process(.01,handover)
	assert(backend.state[13] == 2 and not backend.focused)
	assert(handover.toggles == 2) # Placement markers never consume game clicks.
	watch.reset()
	assert(backend.state.is_empty() and not backend.focused)
	print("All pcvr_wristwatch tests passed")
	quit()
