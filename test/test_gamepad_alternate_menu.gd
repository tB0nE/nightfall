extends SceneTree
class Toast extends RefCounted:
	var hidden := false
	func hide(): hidden = true
class Owner extends Node3D:
	var composition_toast := Toast.new()
	func _log(_text): pass
class Mapper extends ControllerMapper:
	var frame := false
	func frame_controllers() -> bool: return frame
func _init():
	assert(ControllerMapper.quest_menu_flags(false,true) == ControllerMapper.PAD_BACK)
	assert(ControllerMapper.quest_menu_flags(true,true) == ControllerMapper.PAD_START)
	assert(ControllerMapper.quest_menu_flags(true,false) == 0)
	assert(ControllerMapper.quest_menu_flags(false,false) == 0)
	var owner := Owner.new()
	var mapper := Mapper.new(owner)
	mapper.btn_toggle = ControllerMapper.BtnToggle.TILT
	var hint := mapper.gamepad_help_text()
	assert(hint.contains("Tilt") and hint.contains("Left Menu: Select") and hint.contains("Select (Back)"))
	assert(hint.contains("Left X/Y: Left/Right") and hint.contains("alternate: X/Y"))
	mapper.ctrl_type = ControllerMapper.CtrlType.PAD_ABXY
	assert(mapper.gamepad_help_text().contains("alternate: Right/Left"))
	mapper.btn_toggle = ControllerMapper.BtnToggle.HEAD
	assert(mapper.gamepad_help_text().contains("near your head"))
	mapper.btn_toggle = ControllerMapper.BtnToggle.NONE
	assert(not mapper.gamepad_help_text().contains("alternate:"))
	mapper.frame = true
	hint = mapper.gamepad_help_text()
	assert(hint.contains("Left View: Select (Back)") and hint.contains("Right Menu: Start"))
	assert(hint.contains("Squeeze both grips") and not hint.contains("Tilt"))
	mapper._guide_waiting = true
	assert(mapper._advance_gamepad_guide(true)) # Opening button held: do not dismiss.
	assert(mapper._guide_waiting and not owner.composition_toast.hidden)
	assert(mapper._advance_gamepad_guide(false)) # Arm after release.
	assert(mapper._advance_gamepad_guide(true))
	assert(owner.composition_toast.hidden and not mapper._guide_waiting)
	assert(mapper._advance_gamepad_guide(true)) # Consume held dismissal.
	assert(mapper._advance_gamepad_guide(false))
	assert(not mapper._advance_gamepad_guide(false))
	mapper.free()
	owner.free()
	print("Gamepad alternate menu and mode-specific help passed")
	quit()
