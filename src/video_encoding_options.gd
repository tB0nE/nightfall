class_name VideoEncodingOptions
extends RefCounted

# UI IDs preserve existing wire codec indexes. H.264+ is a bitrate profile only.
const H264 := 0
const HEVC := 1
const AV1 := 2
const H264_PLUS := 5
const CHOICES := [H264, H264_PLUS, HEVC, AV1]
static var extended_limits := false # App-wide policy, initialized by AppSettings.

static func label(choice: int) -> String:
	match choice:
		H264: return "H.264"
		H264_PLUS: return "H.264+"
		HEVC: return "HEVC"
		AV1: return "AV1"
	return "Unknown"

static func wire_index(choice: int) -> int:
	return H264 if choice == H264_PLUS else choice

static func wire_name(choice: int) -> String:
	match choice:
		H264, H264_PLUS: return "h264"
		HEVC: return "h265"
		AV1: return "av1"
	return ""

static func maximum_bitrate(choice: int) -> int:
	return base_maximum_bitrate(choice) * (2 if extended_limits else 1)

static func base_maximum_bitrate(choice: int) -> int:
	match choice:
		H264: return 150
		H264_PLUS: return 500
		HEVC, AV1: return 200
	return 500 # Preserve experimental legacy codec behavior.

static func clamp_bitrate(value: int, choice: int, minimum: int = 5) -> int:
	return 0 if value <= 0 else clampi(value, minimum, maximum_bitrate(choice))
