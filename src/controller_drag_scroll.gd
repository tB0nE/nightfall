class_name ControllerDragScroll
extends RefCounted

## Pure input policy. One press owns one target; cancellation requires release.
const DEAD_ZONE := 0.006
const TICKS_PER_HEIGHT := 1440.0 # Twelve wheel notches per screen height.
const EMIT_INTERVAL_MS := 16
var active := false
var consuming := false
var _held := false
var _owner: Variant
var _origin := 0.0
var _last := 0.0
var _pending := 0.0
var _moved := false
var _last_emit := 0

func is_new_press(held: bool) -> bool:
	return held and not _held

func cancel() -> void:
	active = false
	_pending = 0.0
	_owner = null
	# Do not rearm while the physical grip is still held.

func step(held: bool, coordinate: float, owner: Variant, permitted: bool, now_ms: int) -> int:
	var pressed := held and not _held
	_held = held
	if not held:
		cancel()
		consuming = false
		return 0
	if active and (not permitted or owner != _owner or not is_finite(coordinate)):
		cancel()
	if pressed and permitted and owner != null and is_finite(coordinate):
		active = true
		consuming = true
		_owner = owner
		_origin = coordinate
		_last = coordinate
		_moved = false
		_last_emit = now_ms
	if not active: return 0
	if not _moved:
		if absf(coordinate - _origin) < DEAD_ZONE: return 0
		_moved = true
		_last = coordinate
	# Drag content with the hand: moving down sends wheel-up.
	_pending = clampf(_pending + (_last - coordinate) * TICKS_PER_HEIGHT, -240.0, 240.0)
	_last = coordinate
	if now_ms - _last_emit < EMIT_INTERVAL_MS: return 0
	_last_emit = now_ms
	var amount := clampi(int(_pending), -240, 240)
	_pending -= amount
	return amount
