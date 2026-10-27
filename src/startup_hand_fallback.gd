class_name StartupHandFallback
extends RefCounted
## Session-only rescue for controller-free startup, never a saved preference.
const GRACE_SECONDS := 1.5
const STARTUP_WINDOW_SECONDS := 5.0
var elapsed := 0.0
var decided := false
var auto_enabled := false

static func physical_controller_available(tracker: XRPositionalTracker) -> bool:
	if tracker == null or tracker is XRHandTracker: return false
	var profile := tracker.get_tracker_profile().to_lower()
	# OpenXR also exposes hand aim as controller-shaped trackers. Their presence
	# must not be mistaken for a physical Touch/Pico/etc. controller.
	if profile.is_empty() or profile == "none" or "hand_interaction" in profile or "hand_tracking" in profile or "hand_aim" in profile or profile.ends_with("/khr/simple_controller"):
		return false
	# Quest also exposes emulated hands as khr/simple_controller; that profile
	# alone cannot establish that a physical Touch controller exists.
	# An untracked/resting controller is still a controller. Requiring a live
	# pose here made startup with controllers put down look controller-free.
	return true

func step(delta: float, mode: int, controller_present: bool, hands_tracked: bool) -> bool:
	if controller_present:
		var changed := auto_enabled
		auto_enabled = false
		decided = true
		return changed
	if decided: return false
	if mode in [1, 3]:
		decided = true
		return false
	elapsed += maxf(delta, 0.0)
	if elapsed >= STARTUP_WINDOW_SECONDS:
		decided = true # Do not turn this startup rescue into a runtime auto-switch.
		return false
	if elapsed < GRACE_SECONDS or not hands_tracked: return false
	decided = true
	auto_enabled = true
	return true

func explicit_choice() -> void:
	decided = true
	auto_enabled = false

func effective_mode(saved_mode: int) -> int:
	return 1 if auto_enabled and saved_mode not in [1, 3] else saved_mode
