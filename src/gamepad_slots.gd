class_name GamepadSlots
extends RefCounted

# Host controller numbers for every gamepad source in a stream: each physical
# pad (keyed by its Godot device ID) and the Quest-controller PAD mode (keyed
# by QUEST_PAD). Before this, both sent as controller 0 / Godot device ID and
# each packet's active mask held only its own bit, so a physical pad and PAD
# mode fought over controller 0, or the host saw a second pad appear
# ("Multiple controllers connected", GitHub #37).

const QUEST_PAD := -1
# Sunshine accepts 16 gamepads; activeGamepadMask is 16 bits.
const MAX_SLOTS := 16

var _slots: Dictionary = {}

func has(key: int) -> bool:
	return _slots.has(key)

func slot_of(key: int) -> int:
	return _slots.get(key, -1)

# Assigns the lowest free slot to a new source; -1 when all are taken.
func acquire(key: int) -> int:
	if _slots.has(key):
		return _slots[key]
	var used := _slots.values()
	for slot in MAX_SLOTS:
		if not used.has(slot):
			_slots[key] = slot
			return slot
	return -1

# Frees a source's slot and returns it, or -1 if it had none.
func release(key: int) -> int:
	var slot: int = _slots.get(key, -1)
	_slots.erase(key)
	return slot

func active_mask() -> int:
	var mask := 0
	for slot in _slots.values():
		mask |= 1 << slot
	return mask

func clear() -> void:
	_slots.clear()
