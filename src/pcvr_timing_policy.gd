class_name PCVRTimingPolicy
extends RefCounted
## Transient session policy. Saved desktop preferences are never mutated.
var active := false
var stream_fps := 0
var display_hz := 0.0

func begin(fps: int, current_display_hz: float) -> bool:
	if active or fps not in [20, 60, 72] or not is_finite(current_display_hz) or current_display_hz <= 0:
		return false
	stream_fps = fps
	# Match the new 72 FPS profile to 72 Hz. Legacy 20/60 diagnostic profiles
	# retain the existing hardware rate, not an unsupported 60 Hz panel request.
	display_hz = 72.0 if fps == 72 else current_display_hz
	active = true
	return true

func effective_fps(desktop_preference: int) -> int:
	return stream_fps if active else desktop_preference

func end() -> void:
	active = false
	stream_fps = 0
	display_hz = 0.0
