class_name ScreenRegistry
extends RefCounted

const MAX_SCREENS := 4

var screens: Array[VRScreen] = []
var primary: VRScreen = null

func initialize(initial_screen: VRScreen) -> void:
	screens.assign([initial_screen])
	primary = initial_screen

func can_add() -> bool:
	return screens.size() < MAX_SCREENS

func add(screen: VRScreen) -> bool:
	if screen == null or screens.has(screen) or not can_add():
		return false
	screens.append(screen)
	return true

func remove(screen: VRScreen) -> bool:
	if screen == null or screen == primary or not screens.has(screen):
		return false
	screens.erase(screen)
	return true

func set_primary(screen: VRScreen) -> bool:
	if screen == null or screen == primary or not screens.has(screen):
		return false
	primary = screen
	return true
