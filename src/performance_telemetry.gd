class_name PerformanceTelemetry
extends RefCounted

var app_fps: float = 0.0
var video_update_fps: float = 0.0

var _sample_elapsed: float = 0.0
var _app_frames: int = 0
var _video_updates: int = 0
var _status_elapsed: float = 0.0
var _overlay_elapsed: float = 0.0
var _previous_performance_window: Dictionary = {}

func reset_session() -> void:
	app_fps = 0.0
	video_update_fps = 0.0
	_sample_elapsed = 0.0
	_app_frames = 0
	_video_updates = 0
	_status_elapsed = 0.0
	reset_overlay()

func record_frame(delta: float, video_updated: bool) -> Dictionary:
	_app_frames += 1
	if video_updated:
		_video_updates += 1
	_sample_elapsed += delta
	if _sample_elapsed < 1.0:
		return {}
	app_fps = float(_app_frames) / _sample_elapsed
	video_update_fps = float(_video_updates) / _sample_elapsed
	var sample := {
		"app_fps": app_fps,
		"video_update_fps": video_update_fps,
		"app_frames": _app_frames,
		"video_updates": _video_updates,
	}
	_sample_elapsed = 0.0
	_app_frames = 0
	_video_updates = 0
	return sample

func status_update_due(delta: float, interval: float = 0.1) -> bool:
	_status_elapsed += delta
	if _status_elapsed < interval:
		return false
	_status_elapsed = 0.0
	return true

func reset_overlay() -> void:
	_overlay_elapsed = 0.0
	_previous_performance_window.clear()

func overlay_update_due(delta: float, interval: float = 1.0) -> bool:
	_overlay_elapsed += delta
	if _overlay_elapsed < interval:
		return false
	_overlay_elapsed = 0.0
	return true

func combine_performance_window(current: Dictionary) -> Dictionary:
	var combined := combine_windows(_previous_performance_window, current)
	_previous_performance_window = current.duplicate()
	return combined

static func combine_windows(previous: Dictionary, current: Dictionary) -> Dictionary:
	if previous.is_empty():
		return current.duplicate()
	var combined := current.duplicate()
	for key in ["elapsed_us", "total_frames", "received_frames", "rendered_frames", "network_lost_frames", "decode_time_us", "host_latency_tenths_total", "host_latency_samples"]:
		combined[key] = int(previous.get(key, 0)) + int(current.get(key, 0))
	var previous_min := int(previous.get("host_latency_tenths_min", 0))
	var current_min := int(current.get("host_latency_tenths_min", 0))
	combined["host_latency_tenths_min"] = current_min if previous_min == 0 else previous_min if current_min == 0 else mini(previous_min, current_min)
	combined["host_latency_tenths_max"] = maxi(int(previous.get("host_latency_tenths_max", 0)), int(current.get("host_latency_tenths_max", 0)))
	return combined
