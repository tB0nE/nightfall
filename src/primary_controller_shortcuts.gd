class_name PrimaryControllerShortcuts
extends RefCounted
## Edges follow pointer ownership; switching hands never invents a press.
var _side := ""
var _wait_release := true
var _previous := [false, false, false]

func reset() -> void:
	_side = ""
	_wait_release = true
	_previous = [false, false, false]

func poll(side: String, menu: bool, keyboard: bool, stick: bool,
		other_stick: bool, blocked: bool = false, trackpad_blocked: bool = false) -> Array[StringName]:
	var values := [menu, keyboard, stick]
	var result: Array[StringName] = []
	if blocked or side != _side:
		_side = side
		_wait_release = true
	if _wait_release:
		_wait_release = blocked or menu or keyboard or stick or other_stick
		_previous = values
		return result
	if menu and not _previous[0]: result.append(&"menu")
	if keyboard and not _previous[1]: result.append(&"keyboard")
	if stick and not _previous[2] and not other_stick and not trackpad_blocked: result.append(&"sbs")
	_previous = values
	return result
