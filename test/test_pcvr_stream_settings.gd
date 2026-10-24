extends SceneTree
const Video = preload("res://src/pcvr_stream_settings.gd")

class RuntimeRecommendation extends RefCounted:
	func get_pcvr_recommended_eye_size() -> Vector2i: return Vector2i(1680,1760)

class Device extends RefCounted:
	var codename := "eureka"
	func get_device_model() -> String: return codename

func _init() -> void:
	_test_quest3_defaults()
	var runtime := RuntimeRecommendation.new()
	var device := Device.new()
	assert(Video.reference_eye_dimensions(runtime, device) == Vector2i(2064,2208))
	for codename in ["hollywood", "panther"]:
		device.codename = codename
		assert(Video.reference_eye_dimensions(runtime, device) == Vector2i(1832,1920))
	device.codename = "unknown"
	assert(Video.reference_eye_dimensions(runtime, device) == Vector2i(1680,1760))
	assert(Video.reference_eye_dimensions(runtime) == Vector2i(1680,1760))
	var settings := Video.new()
	assert(settings.effective_eye_size(512) == 512)
	assert(settings.effective_eye_size(1024) == 1024)
	settings.cycle_resolution(2560)
	assert(settings.resolution_percent == 105)
	settings.cycle_resolution()
	assert(settings.resolution_percent == 110)
	settings.resolution_percent = 120
	assert(settings.effective_eye_size(512, 2208) == 2656)
	assert(settings.effective_eye_size(512, 1920) == 2304)
	settings.resolution_percent = 150
	assert(settings.effective_eye_size(512, 2208) == 3312)
	settings.cycle_resolution()
	assert(settings.resolution_percent == 75)
	settings.resolution_percent = 100
	assert(settings.effective_eye_size(512, 2208) == 2208)
	assert(settings.effective_eye_size(512, 4096) == 4096)
	assert(settings.effective_eye_dimensions(512, Vector2i(2064,2208)) == Vector2i(2064,2208))
	assert(settings.effective_eye_dimensions(512, Vector2i(1832,1920)) == Vector2i(1840,1920))
	settings.resolution_percent = 120
	assert(settings.effective_eye_dimensions(512, Vector2i(2064,2208)) == Vector2i(2480,2656))
	settings.resolution_percent = 150
	assert(settings.effective_eye_dimensions(512, Vector2i(4000,3200)) == Vector2i(4096,3280))
	settings.resolution_percent = 100
	for size in [256, 1920, 2208, 2656, 3312, 4096]: assert(Video.valid_eye_size(size))
	for size in [0, 255, 2209, 4112]: assert(not Video.valid_eye_size(size))
	settings.cycle_bitrate()
	assert(settings.bitrate_mbps == 16)
	settings.sharpen = 2
	settings.sampling = 1
	var path := "user://pcvr-video-unit-test.cfg"
	assert(settings.save_to(path) == OK)
	var loaded := Video.new()
	loaded.load_from(path)
	assert(loaded.resolution_percent == 100 and loaded.bitrate_mbps == 16)
	assert(loaded.sharpen == 2 and loaded.sampling == 1)
	# Extended mode changes choices without silently changing the target.
	settings.resolution_percent = 105
	settings.extended_resolution_range = true
	settings.foveated_encoding = true
	assert(settings.save_to(path) == OK)
	loaded.load_from(path)
	assert(loaded.extended_resolution_range and loaded.resolution_percent == 105 and loaded.foveated_encoding)
	loaded.cycle_resolution()
	assert(loaded.resolution_percent == 110)
	loaded.resolution_percent = 150
	loaded.cycle_resolution()
	assert(loaded.resolution_percent == 50)
	loaded.extended_resolution_range = false
	loaded.cycle_resolution()
	assert(loaded.resolution_percent == 75)
	loaded.resolution_percent = 135
	loaded.cycle_resolution()
	assert(loaded.resolution_percent == 75)
	loaded.resolution_percent = 0
	loaded.cycle_resolution()
	assert(loaded.resolution_percent == 100)
	var bad := ConfigFile.new()
	bad.set_value("video", "eye_size", 99999)
	bad.set_value("video", "bitrate_mbps", -1)
	assert(bad.save(path) == OK)
	loaded.load_from(path)
	assert(loaded.eye_size == 0 and loaded.bitrate_mbps == 0)
	assert(DirAccess.remove_absolute(path) == OK)
	for _i in Video.BITRATES.size() - 1: settings.cycle_bitrate()
	assert(settings.bitrate_mbps == 0)
	print("All pcvr_stream_settings tests passed")
	quit()

func _test_quest3_defaults() -> void:
	var settings := Video.new(true)
	assert(settings.eye_size == 2048 and settings.bitrate_mbps == 80)
	assert(Video.QUEST3_STREAM_FPS == 72)
	var path := "user://pcvr-quest3-defaults-unit-test.cfg"
	settings.load_from(path)
	assert(settings.eye_size == 2048 and settings.bitrate_mbps == 80)
	var explicit := ConfigFile.new()
	explicit.set_value("video", "eye_size", 512)
	explicit.set_value("video", "bitrate_mbps", 32)
	assert(explicit.save(path) == OK)
	settings.load_from(path)
	assert(settings.eye_size == 512 and settings.bitrate_mbps == 32)
	# Explicit Auto/host-profile selections are preferences, not missing values.
	explicit.set_value("video", "eye_size", 0)
	explicit.set_value("video", "bitrate_mbps", 0)
	assert(explicit.save(path) == OK)
	settings.load_from(path)
	assert(settings.eye_size == 0 and settings.bitrate_mbps == 0)
	explicit.set_value("video", "eye_size", 9999)
	explicit.set_value("video", "bitrate_mbps", -1)
	assert(explicit.save(path) == OK)
	settings.load_from(path)
	assert(settings.eye_size == 2048 and settings.bitrate_mbps == 80)
	assert(DirAccess.remove_absolute(path) == OK)
