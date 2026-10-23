class_name StartupHandFallback
extends RefCounted
## Session-only rescue for controller-free startup, never a saved preference.
const GRACE_SECONDS := 1.5
var elapsed := 0.0
var decided := false
var auto_enabled := false

static func physical_controller_available(tracker: XRPositionalTracker) -> bool:
	if tracker == null or tracker is XRHandTracker: return false
	var profile := tracker.get_tracker_profile().to_lower()
	# OpenXR also exposes hand aim as controller-shaped trackers. Their presence
	# must not be mistaken for a physical Touch/Pico/etc. controller.
	if profile.is_empty() or profile == "none" or "hand_interaction" in profile or "hand_tracking" in profile or "hand_aim" in profile:
		return false
	for name in [&"grip", &"aim", &"default"]:
		var pose := tracker.get_pose(name)
		if pose != null and pose.has_tracking_data: return true
	return false

func step(delta: float, mode: int, controller_present: bool, hands_tracked: bool) -> bool:
	if decided: return false
	if mode in [1, 3] or controller_present:
		decided = true
		return false
	elapsed += maxf(delta, 0.0)
	if elapsed < GRACE_SECONDS or not hands_tracked: return false
	decided = true
	auto_enabled = true
	return true

func explicit_choice() -> void:
	decided = true
	auto_enabled = false

func effective_mode(saved_mode: int) -> int:
	return 1 if auto_enabled and saved_mode not in [1, 3] else saved_mode
