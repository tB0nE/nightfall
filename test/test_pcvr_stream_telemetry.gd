extends SceneTree
const Telemetry = preload("res://src/pcvr_stream_telemetry.gd")
func _init() -> void:
	var telemetry := Telemetry.new()
	assert(telemetry.describe({},72,72).contains("Waiting"))
	var status := {"video_width":5120,"video_height":2560,"video_codec":2,"video_fps":72,
		"projection_eye_size":2560,"video_bytes":0,"meteor_device_counts":{"codec_outputs":0}}
	telemetry.sample(status,0)
	status.video_bytes = 5000000
	status.meteor_device_counts.codec_outputs = 36
	telemetry.sample(status,500)
	assert(telemetry.fps == 72 and telemetry.mbps == 80)
	var text := telemetry.describe(status,72,72)
	assert(text.contains("2560×2560/eye → XR 2560×2560/eye"))
	assert(text.contains("HEVC") and text.contains("72.0/72 fps") and text.contains("80.0 Mbps"))
	status.projection_eye_size = 1024
	assert(telemetry.describe(status,72,72).contains("XR 1024×1024")) # Never hide a downscale.
	status.projection_eye_size = 2064
	status.projection_eye_height = 2208
	status.video_width = 4128
	status.video_height = 2208
	assert(telemetry.describe(status,72,72).contains("2064×2208/eye → XR 2064×2208/eye"))
	telemetry.sample(status,4000)
	assert(telemetry.fps < 0) # Do not display a stale rate on reopening the menu.
	status.video_bytes = 0
	status.meteor_device_counts.codec_outputs = 0
	telemetry.sample(status,4500)
	assert(telemetry.mbps < 0) # New stream counters reset safely.
	print("All pcvr_stream_telemetry tests passed")
	quit()
