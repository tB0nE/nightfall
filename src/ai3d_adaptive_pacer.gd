class_name Ai3dAdaptivePacer
extends RefCounted

# "Adaptive" AI 3D GPU priority. The OpenCL priority hint only has two useful
# states: LOW (AI 3D gets leftover GPU time, which is almost none while a
# 1440p90 stream and passthrough are running) and default (each inference
# competes head-on with frame rendering, and the stream drops frames).
# Adaptive runs inference at default priority but paces it: the inference rate
# backs off whenever the stream can't hold its frame rate and creeps back up
# while it can, so AI 3D gets whatever share the stream can spare.
# Additive-increase / multiplicative-decrease, one step per 1s telemetry sample.

const FLOOR_HZ := 10.0
const DECREASE_FACTOR := 0.75
const INCREASE_STEP_HZ := 2.0
const HEALTHY_SAMPLES_BEFORE_INCREASE := 3
# Fractions of target rate that still count as healthy - absorbs sampling jitter.
const APP_FPS_TOLERANCE := 0.97
const VIDEO_FPS_TOLERANCE := 0.95

var current_hz: float = 0.0
var _healthy_streak: int = 0

func reset(max_hz: int) -> void:
	current_hz = float(max_hz)
	_healthy_streak = 0

# Returns the inference rate to apply, or -1 if it didn't change.
func on_sample(app_fps: float, video_fps: float, display_hz: float, stream_fps: float, max_hz: int) -> int:
	if current_hz <= 0.0:
		reset(max_hz)
	var previous := int(current_hz)
	var app_ok := display_hz <= 0.0 or app_fps >= display_hz * APP_FPS_TOLERANCE
	var expected_video := minf(stream_fps, display_hz) if display_hz > 0.0 else stream_fps
	var video_ok := expected_video <= 0.0 or video_fps >= expected_video * VIDEO_FPS_TOLERANCE
	if app_ok and video_ok:
		_healthy_streak += 1
		if _healthy_streak >= HEALTHY_SAMPLES_BEFORE_INCREASE:
			_healthy_streak = 0
			current_hz = minf(float(max_hz), current_hz + INCREASE_STEP_HZ)
	else:
		_healthy_streak = 0
		current_hz = maxf(minf(FLOOR_HZ, float(max_hz)), current_hz * DECREASE_FACTOR)
	current_hz = minf(current_hz, float(max_hz))
	var now := int(current_hz)
	return now if now != previous else -1
