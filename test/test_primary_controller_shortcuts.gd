extends SceneTree
const HandPolicy = preload("res://src/controller_hand_policy.gd")
const Shortcuts = preload("res://src/primary_controller_shortcuts.gd")
class Hand extends RefCounted:
	var pressed := ""
	func is_button_pressed(action: String) -> bool: return pressed == action
class Actions extends ScreenShortcutBar:
	var invoked: Array[StringName] = []
	func invoke(action: StringName) -> void: invoked.append(action)
func _initialize() -> void:
	var hand := HandPolicy.new()
	assert(not hand.step(.5, false, true))
	assert(hand.step(.3, false, true))
	assert(hand.effective(0) == 1) # Saved Right becomes session-only Left.
	assert(not hand.step(2, false, false))
	assert(hand.effective(0) == 1) # Brief tracking loss must not flip the pointer.
	assert(not hand.step(2, true, true, true)) # Never switch mid-grab.
	assert(hand.step(.8, true, true))
	assert(hand.effective(0) == 0 and hand.effective(2) == 2)
	assert(hand.step(.8, true, false))
	assert(hand.effective(1) == 0)
	var keys := Shortcuts.new()
	assert(keys.poll("left", false, false, false, false).is_empty())
	assert(keys.poll("left", true, false, false, false) == [&"menu"])
	assert(keys.poll("left", true, false, false, false).is_empty())
	assert(keys.poll("left", false, false, false, false).is_empty())
	assert(keys.poll("left", false, true, false, false) == [&"keyboard"])
	assert(keys.poll("left", false, false, false, false).is_empty())
	assert(keys.poll("left", false, false, true, false) == [&"sbs"])
	keys.poll("left", false, false, false, false)
	assert(keys.poll("left", false, false, true, true).is_empty()) # Two-stick pad chord.
	keys.poll("left", false, false, false, false)
	assert(keys.poll("left", false, false, true, false, false, true).is_empty()) # Trackpad exit.
	assert(keys.poll("right", true, true, true, false).is_empty()) # Hand switch held buttons.
	assert(keys.poll("right", true, true, true, false).is_empty())
	assert(keys.poll("right", false, false, false, false).is_empty())
	assert(keys.poll("right", true, false, false, false) == [&"menu"])
	assert(keys.poll("right", true, false, false, false, true).is_empty())
	assert(keys.poll("right", true, false, false, false).is_empty()) # Gamepad mode release guard.
	keys.poll("right", false, false, false, false)
	assert(keys.poll("right", false, true, false, false) == [&"keyboard"])
	keys.reset()
	assert(keys.poll("right", true, false, false, false).is_empty()) # XR return guard.
	# Verify main.gd actually reads the selected controller, not just policy edges.
	var owner = load("res://main.gd").new()
	owner.is_xr_active = true
	owner._startup_reposition = -1
	owner.left_hand = Hand.new()
	owner.right_hand = Hand.new()
	owner.screen_shortcuts = Actions.new(owner)
	owner.xr_interaction = preload("res://src/xr_interaction.gd").new(owner)
	var mapper := ControllerMapper.new(owner)
	owner.controller_mapper = mapper
	mapper.hand_policy.single_hand = ControllerMapper.PrimaryHand.LEFT
	owner._process_button_input()
	for button in ["by_button", "ax_button", "primary_click"]:
		owner.left_hand.pressed = button
		owner._process_button_input()
		owner.left_hand.pressed = ""
		owner._process_button_input()
	assert(owner.screen_shortcuts.invoked == [&"menu", &"keyboard", &"sbs"])
	owner.right_hand.pressed = "by_button"
	owner._process_button_input()
	assert(owner.screen_shortcuts.invoked.size() == 3, "Secondary controller must not fire primary shortcuts")
	mapper.free()
	owner.free()
	print("All primary_controller_shortcuts tests passed")
	quit()
