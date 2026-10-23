class_name PCVRStreamSettings
extends RefCounted
## Separate user preferences: never overwrite host identity or desktop settings.
const PATH := "user://pcvr_stream.cfg"
const EYE_SIZES := [512, 1024, 2048, 2560]
const BITRATES := [0, 16, 32, 48, 64, 80, 100, 120, 160]
const QUEST3_EYE_SIZE := 2048 # Square per-eye view, not the physical panel dimensions.
const QUEST3_BITRATE_MBPS := 80 # Conservative H.264 baseline; not a network benchmark.
const QUEST3_STREAM_FPS := 72
var _default_eye_size := 0
var _default_bitrate_mbps := 0
var eye_size := 0 # Unset: retain the developer host profile's resolution.
var bitrate_mbps := 0 # Auto: preserve resolution-dependent encoder default.
var sharpen := 0 # Runtime settings apply live; never a learned upscaler.
var sampling := 0

func _init(quest3: bool = false) -> void:
	_default_eye_size = QUEST3_EYE_SIZE if quest3 else 0
	_default_bitrate_mbps = QUEST3_BITRATE_MBPS if quest3 else 0
	eye_size = _default_eye_size
	bitrate_mbps = _default_bitrate_mbps

func load_from(path: String = PATH) -> void:
	eye_size = _default_eye_size
	bitrate_mbps = _default_bitrate_mbps
	sharpen = 0
	sampling = 0
	var config := ConfigFile.new()
	if config.load(path) != OK: return
	var size := int(config.get_value("video", "eye_size", _default_eye_size))
	var bitrate := int(config.get_value("video", "bitrate_mbps", _default_bitrate_mbps))
	eye_size = size if size == 0 or size in EYE_SIZES else _default_eye_size
	bitrate_mbps = bitrate if bitrate in BITRATES else _default_bitrate_mbps
	sharpen = clampi(int(config.get_value("video", "sharpen", 0)), 0, 2)
	sampling = clampi(int(config.get_value("video", "sampling", 0)), 0, 2)

func save_to(path: String = PATH) -> Error:
	var config := ConfigFile.new()
	config.set_value("video", "eye_size", eye_size)
	config.set_value("video", "bitrate_mbps", bitrate_mbps)
	config.set_value("video", "sharpen", sharpen)
	config.set_value("video", "sampling", sampling)
	return config.save(path)

func effective_eye_size(profile_size: int) -> int:
	return eye_size if eye_size in EYE_SIZES else profile_size

func cycle_resolution(profile_size: int = 1024) -> void:
	var current := effective_eye_size(profile_size)
	eye_size = EYE_SIZES[(EYE_SIZES.find(current) + 1) % EYE_SIZES.size()]

func cycle_bitrate() -> void:
	bitrate_mbps = BITRATES[(BITRATES.find(bitrate_mbps) + 1) % BITRATES.size()]
