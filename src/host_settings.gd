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
## 0=Off, 1=Stretch, 2=Crop.
var sbs_mode: int = 0
## Index into SettingsController.ai_3d_models.
var ai_3d_model: int = 0
## 0=Off, 1=Auto, 2=Fast, 3=Standard.
var ai_3d_speed: int = 0
## 0=Off, 1=DMap, 2=DMap-Raw, 3=DMap-Input.
var ai_3d_debug: int = 0
## Last active AI-3D mode, used when the display toggle is turned back on.
var ai_3d_last_mode: int = 1
## Matches DepthBridge's 1=CPU and 2=GPU values.
var ai_3d_backend_pref: int = 2
## Depth inference update-rate cap in Hz.
var ai_3d_hz_cap: int = 20
## Percentage multiplier over the renderer's tuned parallax baseline.
var ai_3d_separation_pct: int = 100
## Depth fraction that appears at the screen plane, expressed as a percentage.
var ai_3d_convergence_pct: int = 50
## Cursor correction over AI-warped video: -1=Left, 0=Default, 1=Right.
var ai_3d_cursor_position: int = 0
## Delay native Android video by the measured depth age so both represent the same frame.
var ai_3d_depth_sync: bool = false
