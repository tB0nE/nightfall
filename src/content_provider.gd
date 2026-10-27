class_name ContentProvider
extends RefCounted

# Common lifecycle policy, not a claim that an engine is already implemented.
# Concrete stream/browser/media providers must own their native resource handling.
enum Activity { VISIBLE, BACKGROUND_AUDIO, SUSPENDED, CLOSED }

signal frame_available(generation: int)
signal failed(message: String)

var activity: Activity = Activity.SUSPENDED
var generation: int = 0

static func activity_for(tab: ScreenContentTab, visible: bool) -> Activity:
	if visible:
		return Activity.VISIBLE
	if tab.keep_audio_playing and not tab.muted:
		return Activity.BACKGROUND_AUDIO
	return Activity.SUSPENDED

func set_activity(next: Activity) -> void:
	if activity == Activity.CLOSED:
		return
	activity = next

func close() -> void:
	activity = Activity.CLOSED
	generation += 1 # invalidate outstanding asynchronous callbacks

func can_infer_depth() -> bool:
	return activity == Activity.VISIBLE

func accepts_frame(frame_generation: int) -> bool:
	return activity != Activity.CLOSED and generation == frame_generation
