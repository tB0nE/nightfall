extends SceneTree

class RestOwner extends Node3D:
	var right_hand_resting := false
	var left_hand_resting := false

func _init():
	var main_script = load("res://main.gd")
	if not main_script or not main_script.can_instantiate():
		quit(1)
		return
	var script = load("res://src/xr_interaction.gd")
	if not script or not script.can_instantiate():
		quit(1)
		return
	var interaction = script.new(null)
	# Invalid tracking and application suspension must not turn a held trigger
	# into a fresh click on the last raycast target after resume.
	assert(not interaction._pointer_input_ready(false, false))
	assert(not interaction._pointer_input_ready(true, true))
	assert(interaction._pointer_input_ready(true, false))
	assert(interaction._pointer_input_ready(true, true))
	interaction._pointer_suspended = true
	assert(not interaction._pointer_input_ready(true, false))
	interaction._pointer_suspended = false
	assert(not interaction._pointer_input_ready(true, true))
	assert(interaction._pointer_input_ready(true, false))
	var untracked := XRController3D.new()
	assert(not script.controller_pose_valid(untracked))
	untracked.free()
	var activity_owner = main_script.new()
	activity_owner.xr_interaction = script.new(activity_owner)
	var resting_controller := XRController3D.new()
	activity_owner.right_hand_resting = true
	resting_controller.position = Vector3(0.3, 1.0, -0.4)
	assert(not activity_owner._hand_has_activity(resting_controller, "right"))
	resting_controller.position.x += 0.003
	assert(not activity_owner._hand_has_activity(resting_controller, "right"))
	resting_controller.position.x += 0.009
	assert(activity_owner._hand_has_activity(resting_controller, "right"))
	assert(not activity_owner._hand_has_activity(resting_controller, "right"))
	resting_controller.free()
	activity_owner.free()
	var owner := RestOwner.new()
	var controller_interaction = script.new(owner)
	controller_interaction._auto_primary = "right"
	owner.right_hand_resting = true
	assert(controller_interaction._get_auto_primary() == "left")
	owner.right_hand_resting = false
	owner.left_hand_resting = true
	assert(controller_interaction._get_auto_primary() == "right")
	owner.free()
	interaction._active_hand = "left"
	assert(interaction._select_tracked_hand(ControllerMapper.PrimaryHand.RIGHT, true, true, 0.0, 0.9, false, true) == "right")
	assert(interaction._select_tracked_hand(ControllerMapper.PrimaryHand.LEFT, true, true, 0.9, 0.0, true, false) == "left")
	assert(interaction._select_tracked_hand(ControllerMapper.PrimaryHand.AUTO, true, true, 0.0, 0.0, true, false) == "right")
	assert(interaction._select_tracked_hand(ControllerMapper.PrimaryHand.AUTO, true, true, 0.0, 0.0, false, true) == "left")
	assert(interaction._select_tracked_hand(ControllerMapper.PrimaryHand.AUTO, true, true, 0.9, 0.0, false, true) == "right")
	assert(interaction._select_tracked_hand(ControllerMapper.PrimaryHand.AUTO, true, false, 0.0, 0.0, false, false) == "right")
	var tracker := XRPositionalTracker.new()
	tracker.name = &"/user/fbhandaim/right"
	tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(tracker)
	assert(interaction.hand_aim_available())
	tracker.set_pose("default", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	tracker.set_input("system_gesture", false)
	# The real plugin publishes menu_gesture only on LEFT, not RIGHT.
	tracker.set_input("index_pinch_strength", 0.9)
	tracker.set_input("index_pinch", true)
	assert(interaction.hand_aim_valid("right"))
	assert(is_equal_approx(interaction._get_hand_pinch_strength("/user/hand_tracker/right"), 0.9))
	tracker.set_input("system_gesture", true)
	assert(not interaction.hand_aim_valid("right"))
	assert(interaction._get_hand_pinch_strength("/user/hand_tracker/right") == 0.0)
	tracker.set_input("system_gesture", false)
	tracker.set_pose("default", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_NONE)
	assert(not interaction.hand_aim_valid("right"))
	XRServer.remove_tracker(tracker)
	var left := XRControllerTracker.new()
	left.name = &"/user/fbhandaim/left"
	XRServer.add_tracker(left)
	left.set_pose("default", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	# Left has no system_gesture input; menu gesture still suppresses it.
	left.set_input("menu_gesture", false)
	assert(interaction.hand_aim_valid("left"))
	left.set_input("menu_gesture", true)
	assert(not interaction.hand_aim_valid("left"))
	XRServer.remove_tracker(left)
	print("All hand_aim tests passed")
	quit()
