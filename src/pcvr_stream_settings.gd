class_name PCVRStreamSettings
extends RefCounted
## Separate user preferences: never overwrite host identity or desktop settings.
const PATH := "user://pcvr_stream.cfg"
const EYE_SIZES := [512, 1024, 2048, 2560]
const RESOLUTION_PERCENTAGES := [75, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135]
const EXTENDED_RESOLUTION_PERCENTAGES := [50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150]
const BITRATES := [0, 16, 32, 48, 64, 80, 100, 120, 160]
const QUEST3_EYE_SIZE := 2048 # Square per-eye view, not the physical panel dimensions.
const QUEST3_BITRATE_MBPS := 80 # Conservative H.264 baseline; not a network benchmark.
const QUEST3_STREAM_FPS := 72
var _default_eye_size := 0
var _default_bitrate_mbps := 0
var eye_size := 0 # Unset: retain the developer host profile's resolution.
var resolution_percent := 100 # 0 preserves a pre-percentage custom/host selection.
var extended_resolution_range := false
var bitrate_mbps := 0 # Auto: preserve resolution-dependent encoder default.
var sharpen := 0 # Runtime settings apply live; never a learned upscaler.
var sampling := 0
var foveated_encoding := false

func _init(quest3: bool = false) -> void:
	_default_eye_size = QUEST3_EYE_SIZE if quest3 else 0
	_default_bitrate_mbps = QUEST3_BITRATE_MBPS if quest3 else 0
	eye_size = _default_eye_size
	bitrate_mbps = _default_bitrate_mbps

func load_from(path: String = PATH) -> void:
	eye_size = _default_eye_size
	resolution_percent = 100
	extended_resolution_range = false
	bitrate_mbps = _default_bitrate_mbps
	sharpen = 0
	sampling = 0
	foveated_encoding = false
	var config := ConfigFile.new()
	if config.load(path) != OK: return
	extended_resolution_range = bool(config.get_value("video", "extended_resolution_range", false))
	foveated_encoding = bool(config.get_value("video", "foveated_encoding", false))
	var size := int(config.get_value("video", "eye_size", _default_eye_size))
	var bitrate := int(config.get_value("video", "bitrate_mbps", _default_bitrate_mbps))
	eye_size = size if size == 0 or size in EYE_SIZES else _default_eye_size
	if config.has_section_key("video", "resolution_percent"):
		var percent := int(config.get_value("video", "resolution_percent", 100))
		resolution_percent = percent if percent in RESOLUTION_PERCENTAGES or percent in EXTENDED_RESOLUTION_PERCENTAGES or percent == 0 else 100
	elif config.has_section_key("video", "eye_size") and (size == 0 or size in EYE_SIZES):
		resolution_percent = 0 # Preserve the user's existing explicit resolution.
	bitrate_mbps = bitrate if bitrate in BITRATES else _default_bitrate_mbps
	sharpen = clampi(int(config.get_value("video", "sharpen", 0)), 0, 2)
	sampling = clampi(int(config.get_value("video", "sampling", 0)), 0, 2)

func save_to(path: String = PATH) -> Error:
	var config := ConfigFile.new()
	config.set_value("video", "eye_size", eye_size)
	config.set_value("video", "resolution_percent", resolution_percent)
	config.set_value("video", "extended_resolution_range", extended_resolution_range)
	config.set_value("video", "bitrate_mbps", bitrate_mbps)
	config.set_value("video", "sharpen", sharpen)
	config.set_value("video", "sampling", sampling)
	config.set_value("video", "foveated_encoding", foveated_encoding)
	return config.save(path)

static func valid_eye_size(size: int) -> bool:
	return size >= 256 and size <= 4096 and size % 16 == 0

static func recommended_eye_size(backend) -> int:
	if backend == null or not backend.has_method("get_pcvr_recommended_eye_size"): return 0
	var recommended: Vector2i = backend.get_pcvr_recommended_eye_size()
	# The current transport is square per eye: cover both recommended axes.
	return maxi(recommended.x, recommended.y)

static func recommended_eye_dimensions(backend) -> Vector2i:
	if backend == null or not backend.has_method("get_pcvr_recommended_eye_size"): return Vector2i.ZERO
	return backend.get_pcvr_recommended_eye_size()

static func panel_eye_dimensions(device: String) -> Vector2i:
	match device.strip_edges().to_lower():
		"eureka": return Vector2i(2064,2208) # Quest 3
		"hollywood", "panther": return Vector2i(1832,1920) # Quest 2 / 3S
	return Vector2i.ZERO

static func reference_eye_dimensions(backend, stream_backend = null) -> Vector2i:
	if stream_backend != null and stream_backend.has_method("get_device_model"):
		var panel := panel_eye_dimensions(stream_backend.get_device_model())
		if panel != Vector2i.ZERO: return panel
	return recommended_eye_dimensions(backend)

func effective_eye_dimensions(profile_size: int, recommended: Vector2i) -> Vector2i:
	if resolution_percent > 0 and recommended.x > 0 and recommended.y > 0:
		# One common scale preserves the reference ratio even at the size cap.
		var scale := minf(resolution_percent / 100.0, 4096.0 / maxi(recommended.x, recommended.y))
		return Vector2i(clampi(int(ceil(recommended.x * scale / 16.0)) * 16, 256, 4096),
			clampi(int(ceil(recommended.y * scale / 16.0)) * 16, 256, 4096))
	var legacy := effective_eye_size(profile_size)
	return Vector2i(legacy, legacy)

func effective_eye_size(profile_size: int, recommended_size: int = 0) -> int:
	if resolution_percent > 0 and recommended_size > 0:
		# Encoder-friendly dimensions; bounded to 8192 x 4096 packed stereo.
		return clampi(int(ceil(float(recommended_size) * resolution_percent / 1600.0)) * 16, 256, 4096)
	return eye_size if eye_size in EYE_SIZES else profile_size

func cycle_resolution(_profile_size: int = 1024) -> void:
	if resolution_percent == 0:
		resolution_percent = 100
		return
	var choices: Array = EXTENDED_RESOLUTION_PERCENTAGES if extended_resolution_range else RESOLUTION_PERCENTAGES
	# Preserve the current value when ranges change; the next click advances
	# to the next available choice, even if the old value is off this grid.
	for percent in choices:
		if percent > resolution_percent:
			resolution_percent = percent
			return
	resolution_percent = choices[0]

func cycle_bitrate() -> void:
	bitrate_mbps = BITRATES[(BITRATES.find(bitrate_mbps) + 1) % BITRATES.size()]
