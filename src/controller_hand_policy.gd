class_name ControllerHandPolicy
extends RefCounted
## Temporary physical-controller override; never rewrite the saved preference.
const SETTLE_SECONDS := 0.75
var single_hand := -1 # -1 uses preference, 0 right, 1 left.
var _candidate := -2
var _elapsed := 0.0

func step(delta: float, right: bool, left: bool, interaction_busy: bool = false) -> bool:
	if interaction_busy or (not right and not left):
		_candidate = -2
		_elapsed = 0.0
		return false
	var candidate := -1 if right and left else (0 if right else 1)
	if candidate != _candidate:
		_candidate = candidate
		_elapsed = 0.0
	_elapsed += maxf(delta, 0.0)
	if _elapsed < SETTLE_SECONDS or single_hand == candidate: return false
	single_hand = candidate
	return true

func effective(preference: int) -> int:
	return preference if single_hand < 0 else single_hand
