class_name HostSettings
extends RefCounted

## Settings associated with the currently selected streaming host.
## Screen layout and physical placements remain owned by their typed layout
## objects; this class holds only scalar stream and AI-3D preferences.

const HOST_STATE_VERSION := 1

var stream_fps: int = 60
var resolution_scale_pct: int = 100
var native_resolution: Vector2i = Vector2i(1920, 1080)
var is_polaris_host: bool = false
var resolution_idx: int = 1
var bitrate_idx: int = -1
var double_h: bool = false
var sbs_mode: int = 0
var ai_3d_model: int = 0
var ai_3d_speed: int = 0
var ai_3d_debug: int = 0
var ai_3d_last_mode: int = 1
var ai_3d_backend_pref: int = 2
var ai_3d_hz_cap: int = 20
var ai_3d_separation_pct: int = 100
var ai_3d_convergence_pct: int = 50
var ai_3d_cursor_position: int = 0
