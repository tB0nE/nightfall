class_name PCVRStreamTelemetry
extends RefCounted
## Actual decoder counters, not pending UI preferences. Payload bitrate excludes
## transport overhead; decoded output FPS is not unique application-render FPS.
var _time := -1
var _frames := 0
var _bytes := 0
var fps := -1.0
var mbps := -1.0

func sample(status: Dictionary, now_ms: int) -> void:
	var counts: Dictionary = status.get("meteor_device_counts", {})
	var frames := int(counts.get("codec_outputs", 0))
	var bytes := int(status.get("video_bytes", 0))
	if _time < 0 or now_ms - _time > 2000 or frames < _frames or bytes < _bytes:
		_time = now_ms
		_frames = frames
		_bytes = bytes
		fps = -1
		mbps = -1
	elif now_ms - _time >= 500:
		var seconds := float(now_ms - _time) / 1000.0
		fps = (frames - _frames) / seconds
		mbps = float(bytes - _bytes) * 8.0 / seconds / 1000000.0
		_time = now_ms
		_frames = frames
		_bytes = bytes

func describe(status: Dictionary, display_hz: float, app_fps: float) -> String:
	var width := int(status.get("video_width", 0))
	var height := int(status.get("video_height", 0))
	if width == 0 or height == 0: return "Waiting for decoded XR video…"
	var projection := int(status.get("projection_eye_size", 0))
	var projection_height := int(status.get("projection_eye_height", projection))
	var codec := "HEVC" if int(status.get("video_codec", 0)) == 2 else "H.264"
	var measured := "—" if fps < 0 else "%.1f" % fps
	var rate := "—" if mbps < 0 else "%.1f Mbps" % mbps
	return "Rx %d×%d/eye → XR %d×%d/eye • %s\nVideo %s/%d fps • Display %.0f Hz • Rx %s • App %.0f fps" % [
		width / 2, height, projection, projection_height, codec, measured,
		int(status.get("video_fps", 0)), display_hz, rate, app_fps]
