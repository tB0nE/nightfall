class_name AppSettings
extends RefCounted

## Typed, side-effect-free application settings.
##
## Runtime controllers may react to these values, but this object deliberately
## owns no UI nodes, renderer objects, persistence paths, or platform checks.
## Runtime code reads this store directly; main.gd does not mirror these values.

const APP_STATE_VERSION := 1

var host: HostSettings = HostSettings.new()

const DEFAULT_BEZEL_ENABLED := true
const DEFAULT_PASSTHROUGH_ENABLED := false
const DEFAULT_BACKGROUND_MODE := 0
const DEFAULT_SHARPEN_MODE := 0
const DEFAULT_BRIGHTNESS_PCT := 0
const DEFAULT_CONTRAST_PCT := 100
const DEFAULT_GAMMA_PCT := 100
const DEFAULT_AMBIENT_MODE := 0
const DEFAULT_AMBIENT_COLOR := 0
const DEFAULT_CURSOR_MODE := 1
const DEFAULT_POINTER_STEADY := 1
const DEFAULT_DOUBLE_CLICK_MODE := 0
const DEFAULT_TRACKING_MODE := 0
const DEFAULT_CODEC_PREFERENCE := 1
const DEFAULT_GRID_MODE_ENABLED := true
const DEFAULT_PERFORMANCE_OVERLAY_ENABLED := false
const DEFAULT_AI_3D_GPU_PRIORITY := 0
const DEFAULT_AUTO_RECONNECT_ENABLED := true
const DEFAULT_QUICK_START_ENABLED := false
const DEFAULT_IDLE_TIMEOUT_MIN := 0
const DEFAULT_PIPEWIRE_RESTORE_TOKEN := ""

var bezel_enabled: bool = DEFAULT_BEZEL_ENABLED
var passthrough_enabled: bool = DEFAULT_PASSTHROUGH_ENABLED
var background_mode: int = DEFAULT_BACKGROUND_MODE
var sharpen_mode: int = DEFAULT_SHARPEN_MODE
var brightness_pct: int = DEFAULT_BRIGHTNESS_PCT
var contrast_pct: int = DEFAULT_CONTRAST_PCT
var gamma_pct: int = DEFAULT_GAMMA_PCT
var ambient_mode: int = DEFAULT_AMBIENT_MODE
var ambient_color: int = DEFAULT_AMBIENT_COLOR
var cursor_mode: int = DEFAULT_CURSOR_MODE
var pointer_steady: int = DEFAULT_POINTER_STEADY
var double_click_mode: int = DEFAULT_DOUBLE_CLICK_MODE
var tracking_mode: int = DEFAULT_TRACKING_MODE
var codec_preference: int = DEFAULT_CODEC_PREFERENCE
var grid_mode_enabled: bool = DEFAULT_GRID_MODE_ENABLED
var performance_overlay_enabled: bool = DEFAULT_PERFORMANCE_OVERLAY_ENABLED
var ai_3d_gpu_priority: int = DEFAULT_AI_3D_GPU_PRIORITY
var auto_reconnect_enabled: bool = DEFAULT_AUTO_RECONNECT_ENABLED
var quick_start_enabled: bool = DEFAULT_QUICK_START_ENABLED
var idle_timeout_min: int = DEFAULT_IDLE_TIMEOUT_MIN
var pipewire_restore_token: String = DEFAULT_PIPEWIRE_RESTORE_TOKEN

func reset_display() -> void:
	bezel_enabled = DEFAULT_BEZEL_ENABLED
	passthrough_enabled = DEFAULT_PASSTHROUGH_ENABLED
	background_mode = DEFAULT_BACKGROUND_MODE
	sharpen_mode = DEFAULT_SHARPEN_MODE
	brightness_pct = DEFAULT_BRIGHTNESS_PCT
	contrast_pct = DEFAULT_CONTRAST_PCT
	gamma_pct = DEFAULT_GAMMA_PCT
	ambient_mode = DEFAULT_AMBIENT_MODE
	ambient_color = DEFAULT_AMBIENT_COLOR

func reset_general() -> void:
	cursor_mode = DEFAULT_CURSOR_MODE
	pointer_steady = DEFAULT_POINTER_STEADY
	double_click_mode = DEFAULT_DOUBLE_CLICK_MODE
	tracking_mode = DEFAULT_TRACKING_MODE
	codec_preference = DEFAULT_CODEC_PREFERENCE
	grid_mode_enabled = DEFAULT_GRID_MODE_ENABLED
	performance_overlay_enabled = DEFAULT_PERFORMANCE_OVERLAY_ENABLED
	ai_3d_gpu_priority = DEFAULT_AI_3D_GPU_PRIORITY
	auto_reconnect_enabled = DEFAULT_AUTO_RECONNECT_ENABLED
	quick_start_enabled = DEFAULT_QUICK_START_ENABLED
	idle_timeout_min = DEFAULT_IDLE_TIMEOUT_MIN
	pipewire_restore_token = DEFAULT_PIPEWIRE_RESTORE_TOKEN
