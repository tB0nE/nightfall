class_name CompositionToast
extends RefCounted

## Timed notifications sampled into the primary screen's existing overlay.
## This owns no viewport, swapchain or OpenXR composition layer.
var _main: Node
var _hide_at_msec := 0
var _persistent := false

func setup(scene_root: Node, _xr_origin: Node3D) -> void:
	_main = scene_root

func show(text: String, _camera: Node3D, seconds: float = 4.0) -> void:
	if not _main or not _main.comp: return
	_main.comp.set_screen_message(text)
	_persistent = seconds < 0.0
	_hide_at_msec = 0 if _persistent else Time.get_ticks_msec() + int(maxf(seconds, 0.0) * 1000.0)

func hide() -> void:
	_persistent = false
	_hide_at_msec = 0
	if _main and _main.comp: _main.comp.set_screen_message("")

func process() -> void:
	if not _main or not _main.comp: return
	if _hide_at_msec > 0 and Time.get_ticks_msec() >= _hide_at_msec:
		_hide_at_msec = 0
		_main.comp.set_screen_message("")
	if _persistent or _hide_at_msec > 0:
		_main.comp.update_stats_transform()
