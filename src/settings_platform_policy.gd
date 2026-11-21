class_name SettingsPlatformPolicy
extends RefCounted

## Platform-specific availability rules for settings.
##
## Keeping these decisions side-effect-free makes UI state, persisted-state
## normalization, and runtime controllers consume the same policy.

static func ai3d_options_locked(platform_name: String = OS.get_name()) -> bool:
	return platform_name == "Android"

## The Screens tab (several PC monitors / virtual monitors, tabs). Linux builds run
## on standalone headsets such as the Steam Frame, where it works as on Quest.
static func multi_screen_available(platform_name: String = OS.get_name()) -> bool:
	return platform_name == "Android" or platform_name == "Linux"

static func depth_gpu_priority_available(platform_name: String = OS.get_name()) -> bool:
	return platform_name == "Android"

static func sharpen_choices(
		platform_name: String,
		runtime_normal: int,
		runtime_quality: int,
		label_count: int) -> Array:
	if platform_name == "Android":
		return [0, runtime_normal, runtime_quality]
	return range(label_count)

static func sharpen_label(
		platform_name: String,
		mode: int,
		runtime_normal: int,
		runtime_quality: int,
		labels: Array) -> String:
	if platform_name == "Android":
		match mode:
			runtime_normal:
				return "Runtime"
			runtime_quality:
				return "Runtime Quality"
			_:
				return "Off"
	return labels[clampi(mode, 0, labels.size() - 1)]
