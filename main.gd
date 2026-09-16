extends Node3D

var settings: AppSettings = AppSettings.new()
var session_lifecycle: SessionLifecycle = SessionLifecycle.new()
var telemetry: PerformanceTelemetry = PerformanceTelemetry.new()

@onready var screen_mesh = $MeshInstance3D
@onready var ui_panel_3d = %UIPanel3D
@onready var ui_viewport = %UIViewport
@onready var stream_viewport = %StreamViewport
@onready var stream_target = %StreamTarget
@onready var detection_viewport = %DetectionViewport
@onready var detection_target = %DetectionTarget
@onready var welcome_viewport = %WelcomeViewport
@onready var config_mgr = ClassDB.instantiate("NightfallConfigManager") if ClassDB.class_exists("NightfallConfigManager") else null
@onready var comp_mgr = ClassDB.instantiate("NightfallComputerManager") if ClassDB.class_exists("NightfallComputerManager") else null
var mdns
var stream_backend: StreamBackend

func _get_mdns():
	if not mdns and ClassDB.class_exists("MdnsBrowser"):
		mdns = ClassDB.instantiate("MdnsBrowser")
	return mdns

func get_is_hand_tracking() -> bool:
	if settings.tracking_mode != 1:
		return false
	for tracker_name in ["/user/hand_tracker/right", "/user/hand_tracker/left"]:
		var tracker = XRServer.get_tracker(tracker_name)
		if tracker and tracker is XRHandTracker:
			return true
	return false

func get_hand_tracking_has_data() -> bool:
	if settings.tracking_mode != 1:
		return false
	for tracker_name in ["/user/hand_tracker/right", "/user/hand_tracker/left"]:
		var tracker = XRServer.get_tracker(tracker_name)
		if tracker and tracker is XRHandTracker:
			if tracker.get_has_tracking_data():
				return true
	return false
@onready var xr_origin = $XROrigin3D
@onready var xr_camera = $XROrigin3D/XRCamera3D
@onready var mouse_raycast = %RayCast3D
@onready var hand_raycast = %HandRayCast
@onready var right_hand = %RightHand
@onready var left_hand = %LeftHand
@onready var audio_player = %StreamAudioPlayer
@onready var world_env = $WorldEnvironment

var current_host_id: int = -1
var _last_hostname: String = ""
var _selected_app_id: int = 881448767
var _selected_app_idx: int = 0
var _available_apps: Array = []
var _welcome_screen: String = "welcome"
var _pair_pin: String = ""
var _connecting_ip: String = ""
# Whether the host is drawing its own cursor into the captured frame (Polaris-only:
# a POST /polaris/v1/session/cursor endpoint neither Sunshine nor Apollo expose today).
# Support is detected per-connection from the launch response, not guessed up front,
# since a version-string heuristic already burned us once for microphone detection.
var host_cursor_visible: bool = false
var _host_cursor_toggle_supported: bool = false
var _did_initial_monitor_trim: bool = false
var _stream_start_seq: int = 0
var is_streaming: bool:
	get: return session_lifecycle.media_active
var is_xr_active: bool = false
var was_clicking: bool = false
var was_right_clicking: bool = false
var right_click_cooldown: float = 0.0
var _was_b_pressed: bool = false
var _was_a_pressed: bool = false
var _was_r_stick_click: bool = false
var _startup_reposition: int = 0  # 0=waiting for tracking, 1=centered, 2=positioning
var _startup_cover: MeshInstance3D
var _startup_ready: bool = false

var _is_using_hands: bool = false
var tracking_labels: Array = ["Off", "Hands"]

# OS/runtime controller render models (2026-08-25, see the archived
# docs/archive/plans/gles-quest-projectionless.md plan's
# "Controller and hand experiment" section) - OpenXRFbRenderModel wraps
# XR_FB_render_model, letting the runtime hand us its own real controller
# mesh instead of the bundled MetaQuestTouchPlus FBX (_load_controller_models()
# below, which stays as the fallback, and is no longer even bundled in the
# Android export - see export_presets.cfg). Default OFF. Tried routing it
# through a composition-space 3D capture (2026-08-27, same technique as the
# hand-skeleton indicator that used to live below) - pulled back out along
# with that whole approach: rendering a real 3D scene into an offscreen
# viewport every frame was too expensive even throttled to 14fps (see the
# composite-only hand indicator that replaced it), and there's every reason
# to expect the same cost for controllers. Back to its original scope:
# normal (mesh) projection mode only - projectionless/composition mode
# would need a genuinely cheap 3D-in-composition-layer renderer, which this
# isn't, so it stays out of scope until one exists.
const DEBUG_RENDER_MODEL_CONTROLLERS := false
var right_render_model: Node3D = null
var left_render_model: Node3D = null
var _right_render_model_ready: bool = false
var _left_render_model_ready: bool = false
var left_hand_raycast: RayCast3D = null
var mouse_captured_by_stream: bool = false
var suppress_input_frames: int = 0
var auto_detect_enabled: bool = false
var auto_detect_timer: float = 0.0
var auto_detect_running: bool = false
var detection_history: Array = []
var mouse_sensitivity: float = 0.002
var grabbed_node: Node3D = null
var grab_distance: float = 0.0
var grab_offset: Vector3 = Vector3.ZERO
var grabbed_bar: MeshInstance3D = null
var grab_start_hand_pos: Vector3 = Vector3.ZERO
var grab_start_node_pos: Vector3 = Vector3.ZERO
var grab_forward: Vector3 = Vector3.FORWARD
var grab_start_hand_basis: Basis = Basis()
var grab_start_node_basis: Basis = Basis()
var grab_start_node_euler: Vector3 = Vector3.ZERO
var grab_start_primary_transform: Transform3D = Transform3D.IDENTITY
var grab_group_start_transforms: Dictionary = {}
var grab_snap_candidate: Vector2i = Vector2i(-1, -1)
# Passthrough is real extra GPU cost (native OpenXR alpha-blend, composited
# by the system compositor, confirmed via on-device benchmark 2026-08-25) -
# no in-app UI disclaimer for this by design; settings_controller.gd's
# AUTO_TABLE already accounts for it directly in its tier/model picks.
var passthrough_supported: bool = false
var background_labels: Array = ["Black", "Ash", "Snow", "Data"]
var bg_names: Array = ["Ash", "Snow", "Data"]
var bg_offsets: Array = [Vector3.ZERO, Vector3(0, 10, 0), Vector3(0, -3, 0)]
var ui_visible: bool = false
var bezel_mesh: MeshInstance3D:
	get: return primary_screen.bezel_mesh if primary_screen else null
	set(v):
		if primary_screen: primary_screen.bezel_mesh = v
var curvature: int:
	get: return primary_screen.curvature if primary_screen else 2
	set(v):
		if primary_screen: primary_screen.curvature = v
var curvature_labels: Array = ["Flat", "Slight Curve", "Curved"]
const SHARPEN_RUNTIME_NORMAL := 6
const SHARPEN_RUNTIME_QUALITY := 7
# Keep the existing shader modes in their original saved-state slots for a
# direct A/B comparison. The two runtime modes bypass those expensive video
# neighbourhood samples when the OpenXR extension is available.
var sharpen_labels: Array = ["0%", "10%", "20%", "30%", "40%", "50%", "Runtime", "Runtime Quality"]
# Picture tab (2026-08-31) - brightness/contrast/gamma grade applied as a
# final step after YUV->RGB conversion (and after HDR tonemap, on the HDR
# shader variant) - see settings_controller.gd's apply_filter() for the
# percent->shader-uniform mapping and each shader's apply_picture().
# Ambient screen lighting is a separate low-resolution composition layer,
# so it stays out of the main YUV/HDR/AI-3D shader path. Reactive modes use
# the already-rendered primary screen as their colour source.
var ambient_mode_labels: Array = ["Off", "Static", "Slow", "Live"]
var ambient_color_labels: Array = ["White", "Warm", "Red", "Green", "Blue", "Purple"]
var _xr_base_render_scale: float = 1.0
var _xr_render_width: int = 2064
var _mesh_size: Vector2:
	get: return primary_screen.mesh_size if primary_screen else Vector2(2.24, 1.26)
	set(v):
		if primary_screen: primary_screen.mesh_size = v
var _cached_sharpen: float = -1.0
var _cached_blur_scale: float = -1.0
# host_resolution is the actual WxH about to be (or last) requested from the
# host - computed from the selected host's native size and resolution scale,
# not set directly. It always matches whatever the host's real desktop/composite
# shape is (single monitor or multi-monitor composite alike), instead of a
# fixed target size that would force the host to letterbox/squeeze a
# mismatched-aspect composite to fit.
var host_resolution: Vector2i = Vector2i(1920, 1080)
# Last known real desktop/composite size for the currently selected host, as
# reported by its display manifest (or session_optimization's negotiated
# width/height for hosts without one). Cached per-host in host_state.cfg so a
# repeat connection can request the correctly-scaled resolution on the first
# try instead of needing the mismatch-triggered reconnect every time.
const RESOLUTION_PRESETS: Array = [100, 90, 80, 70, 60, 50]
# Kept around for state_manager.gd's old-save-file validation fallback; the UI
# itself now uses compute_resolution_options() instead of this static list -
# see that function for why (this doesn't know about the per-codec/per-native-
# resolution caps below, so a preset here can silently be unreachable).
var resolution_scale_options: Array = RESOLUTION_PRESETS
# True once SettingsController.detect_polaris_host() confirms this host answers
# the Polaris-only /polaris/v1/display/manifest probe. Polaris is host-driven -
# it reports its real (possibly multi-monitor) desktop size, so the
# percentage-of-native-resolution system above gives an accurate result. Every
# other GameStream-compatible host (Sunshine, GFE, etc.) is client-driven -
# there is no equivalent "ask the host its resolution" mechanism at all, the
# client is expected to just request what it wants and the host adapts to
# match. The cached native resolution has nothing real to hold for them, so the
# percentage system's "MAX"/percent labels would just describe the wrong
# thing (confirmed: reported "1080p" against a real 2560x1440 Sunshine
# display, because the cached value never left its 1920x1080 fallback).
# Defaults false (the old fixed-list picker) so a host that hasn't been probed
# yet - or a probe that's still in flight - never shows a percentage of a
# guess as if it meant something.
# Detected once at startup via stream_backend.get_device_model() (Android's
# Build.MODEL, read through DepthBridge's JNI bridge - see GodotApp.java's
# getDeviceModel()). Quest 2's Snapdragon XR2 Gen 1 GPU benchmarks at
# roughly 2-2.5x slower than Quest 3/3s's XR2 Gen 2 (Meta's own published
# figures), and our AI-3D depth inference runs on the GLES GPU delegate -
# the same GPU used for rendering, not the (much bigger, but NNAPI-gated
# and unavailable to us) NPU gap - so the existing AUTO_TABLE (hand-tuned
# entirely on Quest 3/3s) is a poor fit there. Added 2026-08-27 after a
# Quest 2 user reported AI-3D tanking performance; see settings_controller.
# gd's QUEST2_AUTO_TABLE and main.gd's QUEST2_MAX_RESOLUTION.
var device_is_quest2: bool = false
var device_is_quest3: bool = false
# See device_is_quest2's comment. Quest 2's own per-eye display resolution
# (~1832x1920) is already below Quest 3's, so there's no real benefit
# requesting more than this regardless of AI-3D state - applied in
# compute_requested_resolution() as a hard ceiling before any other cap.
const QUEST2_MAX_RESOLUTION := Vector2i(1920, 1080)

# The pre-percentage fixed-resolution picker, used for any non-Polaris host
# (see the Polaris detection comment above) - the user picks what they actually want
# instead of the client trying to detect anything, matching how Sunshine
# itself expects to be driven. Untouched by the H264/HEVC dimension/pixel
# caps in compute_max_resolution_pct() below - every entry here is well
# under all of those caps on its own (largest is 3840x2160), so there's
# nothing to filter for the single-screen case this picker is used for.
var resolutions: Array = [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(1600, 1200), Vector2i(2560, 1080), Vector2i(3440, 1440)]
# 21:9 split into two tiers (2026-08-20, GitHub issue #17) - was a single
# 3440x1440 entry, which meant there was no way to request a 21:9 source at a
# more modest pixel budget (matching the HD/2K split every other aspect
# already gets). 2560x1080 (UWFHD, 64:27) and 3440x1440 (UWQHD, 43:18) are
# the two real, common ultrawide monitor resolutions - not arbitrary picks.
var resolution_labels: Array = ["720", "HD", "2K", "4K", "4:3", "21:9 HD", "21:9 2K"]
var bitrates: Array = [5, 10, 15, 20, 30, 40, 50, 60, 80, 100, 120]
var bitrate_labels: Array = ["Auto", "5", "10", "15", "20", "30", "40", "50", "60", "80", "100", "120"]
var display_refresh_rate: float = 72.0

var cursor_labels: Array = ["Circle", "Pointer"]
var pointer_steady_labels: Array = ["Off", "Low", "High", "One Euro"]
# Touch-controller double-click gesture. Standard leaves host-side recognition
# untouched; Chord maps a near-simultaneous trigger+grip press to two left
# clicks. Hand tracking always retains its normal pinch-twice behaviour.
var double_click_mode_labels: Array = ["Standard", "Chord"]
var _steady_hit: Vector3 = Vector3.ZERO
var _steady_active: bool = false
var _steady_factor: float = 0.3
var _steady_dead_zone: float = 0.002
var _steady_velocity: Vector3 = Vector3.ZERO
var _steady_raw_hit: Vector3 = Vector3.ZERO
var _steady_last_usec: int = 0
var _steady_last_frame: int = -1
var codec_labels: Array = ["H.264", "HEVC", "AV1", "Raw"]
var _client_codec_support: Dictionary = {}
var _server_codec_support: Dictionary = {}
var corner_handles: Array:
	get: return primary_screen.corner_handles if primary_screen else []
	set(v):
		if primary_screen: primary_screen.corner_handles = v
var grabbed_corner_idx: int = -1
var grabbed_corner_screen: VRScreen = null
var corner_anchor_world: Vector3 = Vector3.ZERO
var screen_registry: ScreenRegistry = ScreenRegistry.new()
var screens: Array[VRScreen]:
	get: return screen_registry.screens
var primary_screen: VRScreen:
	get: return screen_registry.primary
var layout: ScreenLayout = null

# Staging state for the Monitors tab's Row1 (counts) + Row2 (preset) - Apply
# commits these together via SettingsController.apply_staged_monitor_config();
# nothing here touches the live layout/stream on its own.
var _staged_physical_count: int = 1
var _staged_virtual_count: int = 0
var _staged_preset_id: StringName = &""
# Set by apply_staged_monitor_config() when it restarted the stream to pick up
# a real monitor-selection change; cleared once stream_manager.gd's launch
# response finishes applying the fresh manifest that follows (see
# SettingsController.finish_pending_monitor_apply()).
var _pending_monitor_apply: bool = false

var stream_manager: StreamManager
var xr_interaction: XRInteraction
var input_handler: InputHandler
var ui_controller: UIController
var auto_detect: AutoDetect
var depth_estimator: DepthEstimatorModule
var native_xr_renderer: NativeXrRendererManager
var video_presentation: VideoPresentation
var virtual_keyboard: VirtualKeyboard
var welcome_screen: WelcomeScreen
var screen_manager: ScreenManager
var settings_controller: SettingsController
var state_manager: StateManager
var controller_mapper: ControllerMapper
var screen_shortcuts: ScreenShortcutBar
var comp: CompositionLayerManager
var bg_manager: BackgroundManager
var composition_panels: CompositionPanelLayers = CompositionPanelLayers.new()
var composition_environment: CompositionEnvironmentLayer = CompositionEnvironmentLayer.new()
var composition_pointers: CompositionPointerLayers = CompositionPointerLayers.new()
var composition_controller_rays: CompositionControllerRays = CompositionControllerRays.new()
var composition_controller_markers: CompositionControllerMarkers = CompositionControllerMarkers.new()
var composition_hand_indicators: CompositionHandIndicators = CompositionHandIndicators.new()
var composition_screen_controls: CompositionScreenControls = CompositionScreenControls.new()
var _xr_resume_refresh_attempts := 0
var _xr_resume_refresh_wait_frames := 0

# Temporary on-device A/B flags (2026-08-24) to isolate which of today's new
# composition-space additions (laser/grab-bar/corners/background-equirect,
# all added this session) is contending with the GLES GPU TFLite delegate
# for depth inference - MiDaS-256-GPU measured ~13-15Hz today vs. an
# earlier-session ~20Hz. Each gates both its composition layer's visibility
# AND its backing SubViewport's render_target_update_mode (UPDATE_ALWAYS
# viewports render every frame regardless of the layer's own visibility, so
# hiding alone doesn't stop the GPU cost) - see
# _update_laser_layers()/_update_grab_bar_layers()/_sync_comp_background().
# Toggle one at a time and rebuild; remove once the
# regression is isolated (see the diagnosis plan). Confirmed 2026-08-24 the
# regression was a debug-build-vs-release-build artifact, not caused by any
# of these - release build hits ~19.5-20.2Hz with all four enabled. Kept
# around (all true) in case it's needed again rather than deleting outright.
const DEBUG_COMP_BG_EQUIRECT := true
const DEBUG_COMP_LASER := true
const DEBUG_COMP_GRAB_BAR := true
const DEBUG_COMP_CORNERS := true
const DEBUG_COMP_MARKER := true
const DEBUG_COMP_HANDS := true

# Composition-space environment-background replacement (2026-08-24,
# GLES projectionless polish) - the ambient particle backgrounds
# (Ash/Snow/Data, background_manager.gd) are real GPUParticles3D
# in the normal 3D scene, invisible under projectionless mode like
# everything else plain-3D. Unlike the cursor/laser/grab-bar/corners (flat
# 2D UI content on a quad), this needs an actual 3D scene capture -
# comp_bg_capture_viewport (disable_3d=false, a real mini 3D scene, not
# just a Control tree) holding a wide-FOV camera and a standalone duplicate
# of whichever background is active (background_manager.create_capture_
# instance()), fed into comp_bg_equirect (OpenXRCompositionLayerEquirect,
# a real 360-capable OpenXR layer type - confirmed natively supported by
# WiVRn on this device). A single perspective camera can't capture a true
# full sphere without heavy edge distortion, so this deliberately covers a
# wide-but-partial angular range (BG_CAPTURE_FOV_DEG) rather than claiming
# full 360 coverage - turning far enough away may show black instead of
# the effect, unlike the original always-surrounding particle system.
var comp_bg_equirect: Node3D:
	get: return composition_environment.layer
var comp_bg_capture_viewport: SubViewport:
	get: return composition_environment.capture_viewport
var comp_bg_capture_camera: Camera3D:
	get: return composition_environment.capture_camera
var comp_bg_capture_instance: GPUParticles3D = null
var comp_bg_capture_index: int = -1
const BG_CAPTURE_FOV_DEG := 160.0
const BG_EQUIRECT_ANGLE_DEG := 150.0

var comp_cylinder: Node3D:
	get: return primary_screen.comp_cylinder if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_cylinder = v
var _comp_cyl_center: Vector3:
	get: return primary_screen._comp_cyl_center if primary_screen else Vector3.ZERO
	set(v):
		if primary_screen: primary_screen._comp_cyl_center = v
var _comp_cyl_radius: float:
	get: return primary_screen._comp_cyl_radius if primary_screen else 0.0
	set(v):
		if primary_screen: primary_screen._comp_cyl_radius = v
var _comp_cyl_central_angle: float:
	get: return primary_screen._comp_cyl_central_angle if primary_screen else 0.0
	set(v):
		if primary_screen: primary_screen._comp_cyl_central_angle = v
var comp_layer: Node3D:
	get: return primary_screen.comp_layer if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_layer = v
var comp_viewport: SubViewport:
	get: return primary_screen.comp_viewport if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_viewport = v
var comp_yuv_rect: ColorRect:
	get: return primary_screen.comp_yuv_rect if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_yuv_rect = v
var comp_bezel_rect: ColorRect:
	get: return primary_screen.comp_bezel_rect if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_bezel_rect = v
var comp_shader_mat: ShaderMaterial:
	get: return primary_screen.comp_shader_mat if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_shader_mat = v
var comp_cylinder_left: Node3D:
	get: return primary_screen.comp_cylinder_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_cylinder_left = v
var comp_cylinder_right: Node3D:
	get: return primary_screen.comp_cylinder_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_cylinder_right = v
var comp_viewport_left: SubViewport:
	get: return primary_screen.comp_viewport_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_viewport_left = v
var comp_viewport_right: SubViewport:
	get: return primary_screen.comp_viewport_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_viewport_right = v
var comp_yuv_rect_left: ColorRect:
	get: return primary_screen.comp_yuv_rect_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_yuv_rect_left = v
var comp_yuv_rect_right: ColorRect:
	get: return primary_screen.comp_yuv_rect_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_yuv_rect_right = v
var comp_bezel_rect_left: ColorRect:
	get: return primary_screen.comp_bezel_rect_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_bezel_rect_left = v
var comp_bezel_rect_right: ColorRect:
	get: return primary_screen.comp_bezel_rect_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_bezel_rect_right = v
var comp_shader_mat_left: ShaderMaterial:
	get: return primary_screen.comp_shader_mat_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_shader_mat_left = v
var comp_shader_mat_right: ShaderMaterial:
	get: return primary_screen.comp_shader_mat_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_shader_mat_right = v
var comp_stream_cursor: TextureRect:
	get: return primary_screen.comp_stream_cursor if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_stream_cursor = v
var comp_stream_cursor_circle: ColorRect:
	get: return primary_screen.comp_stream_cursor_circle if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_stream_cursor_circle = v
var comp_stream_cursor_left: TextureRect:
	get: return primary_screen.comp_stream_cursor_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_stream_cursor_left = v
var comp_stream_cursor_circle_left: ColorRect:
	get: return primary_screen.comp_stream_cursor_circle_left if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_stream_cursor_circle_left = v
var comp_stream_cursor_right: TextureRect:
	get: return primary_screen.comp_stream_cursor_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_stream_cursor_right = v
var comp_stream_cursor_circle_right: ColorRect:
	get: return primary_screen.comp_stream_cursor_circle_right if primary_screen else null
	set(v):
		if primary_screen: primary_screen.comp_stream_cursor_circle_right = v
var _screen_mesh_original_mat: Material:
	get: return primary_screen._original_mat if primary_screen else null
	set(v):
		if primary_screen: primary_screen._original_mat = v

const LOG_CURRENT_PATH := "user://nightfall-current.log"
const LOG_PREVIOUS_PATH := "user://nightfall-previous.log"
const LEGACY_LOG_PATH := "user://debug.log"
var _log_lines: PackedStringArray = []
var _log_file_initialized: bool = false
var _log_session_rotated: bool = false
var _log_flush_timer: float = 0.0
var _ui_viewport_size := Vector2i(1200, 580)
var _ui_mesh_size := Vector2(1.20, 0.58)
var _ui_status_label: Label
var _ui_pt_btn: Button
var _ui_bg_btn: Button
var _ui_curve_btn: Button
var _ui_bezel_btn: Button
var _ui_monitors_btn: Button
var _ui_virtual_monitors_btn: Button
var _ui_apply_preset_btn: Button
var _ui_save_preset_btn: Button
var _ui_remove_preset_btn: Button
var _ui_grid_mode_btn: Button
var _ui_hand_tracking_btn: Button
var _ui_sbs_btn: Button
var _ui_3d_speed_btn: Button
var _ui_3d_btn: Button
var _ui_3d_debug_btn: Button
var _ui_3d_priority_btn: Button
# AI 3D tab (2026-08-28) - see ui_controller.gd's build_ui() for layout.
var _ui_3d_mode_btn: Button
var _ui_3d_type_btn: Button
var _ui_3d_hz_cap_btn: Button
var _ui_3d_separation_btn: Button
var _ui_3d_convergence_btn: Button
var _ui_3d_cursor_position_btn: Button
var _ui_3d_depth_sync_btn: Button
var _ui_3d_reset_btn: Button
var _ui_res_btn: Button
var _ui_fps_btn: Button
var _ui_bitrate_btn: Button
var _ui_ctrl_type_btn: Button
var _ui_btn_toggle_btn: Button
var _ui_primary_btn: Button
var _ui_quick_start_btn: Button
var _ui_host_cursor_btn: Button
var _ui_sharpen_btn: Button
# Picture tab (2026-08-31) - see ui_controller.gd's build_ui() for layout.
var _ui_brightness_btn: Button
var _ui_contrast_btn: Button
var _ui_gamma_btn: Button
var _ui_ambient_btn: Button
var _ui_ambient_color_btn: Button
var _ui_ctrl_mode_btn: Button
var _ui_cursor_btn: Button
var _ui_steady_btn: Button
var _ui_double_click_btn: Button
var _ui_codec_btn: Button
var _last_activity_time: float = 0.0
var _ui_idle_btn: Button
var _ui_reconnect_btn: Button
var _ui_exit_btn: Button
var _ui_disconnect_btn: Button
var _ui_close_btn: Button
var _ui_center_btn: Button
var _ui_log_btn: Button
var _ui_stats_btn: Button

var _btn_style: StyleBoxFlat
var _btn_hover: StyleBoxFlat


# 2026-08-07: settled at 4032, this time with real evidence it's a genuine
# hardware/driver width ceiling, not a software bug we can fix. Two real,
# separate software bugs WERE found and fixed along the way (both worth
# keeping): (1) AndroidMediaCodec's input buffer was sized at width*height,
# too tight for a real H264 keyframe - widened to width*height*3
# (mediacodec_native.cpp); (2) that fix itself overshot a ~16MiB Android
# graphics-buffer-allocation ceiling at wide resolutions, so it's now clamped
# to 12MiB. But testing at 6912x1944 with both fixes in place still failed
# completely (zero frames ever decoded), and critically: CCodec's own log
# showed it silently overrode our 12MiB request UP to 13.27MB (its own
# platform-computed minimum for that resolution) and decode still never
# produced a single frame - proving buffer size was never the bottleneck at
# this width. That points to a real hardware/HAL line-buffer width limit
# around 4032px on this SoC's H264 decoder, independent of buffer sizing or
# total pixel count - the MediaCodec capability query's claimed 8192px
# support just doesn't hold up in practice (a known class of gap on
# Qualcomm HALs). HEVC has no equivalent cap; prefer it for wide layouts.
const H264_MAX_DIMENSION = 4032
# Confirmed via on-device MediaCodec capability query (getSupportedWidths/
# getSupportedHeights against real candidate resolutions - see
# docs/architecture/multi-monitor-encode-budget-and-layout.md): HEVC on this hardware is
# dual-limited, not just axis-limited - each dimension independently caps at
# 8192px, AND the total canvas is separately capped at ~138,240 macroblocks
# (16x16 each) regardless of aspect. A 4-monitor row can hit the axis cap
# (e.g. 8320px wide) while sitting nowhere near the total-pixel cap, so both
# constraints have to be checked - clamping only the axis would silently
# allow a request that's still invalid for the other reason, and vice versa.
const HEVC_MAX_DIMENSION = 8192
const HEVC_MAX_TOTAL_PIXELS = 35389440
# A SEPARATE, lower ceiling from the two above - those reflect what the decoder
# can technically decode at all; this reflects what the headset can actually
# sustain in real time while also running its own tracking/compositor/etc.
# Confirmed live testing 4x4K HEVC (2x2 grid, 7680x4320 base): 80% scale
# (21,233,664 total pixels) ran smoothly; 90% (26,873,856 pixels - still well
# under HEVC_MAX_TOTAL_PIXELS, so the decode-capability cap never caught it)
# caused the headset's own tracking-camera watchdog to report multi-second
# frame delays and visible corruption/freezing - a real-time throughput
# problem, not a decode failure. Set at exactly the confirmed-good boundary
# (80% of that specific 4-monitor test), not a round-number guess.
const HEVC_MAX_SUSTAINED_PIXELS = 21233664

# Extra resolution ceiling applied whenever MiDaS-Fast is the active stereo
# mode (2026-08-18, redesigned 2026-08-25) - unlike every knob AI-3D's own
# pipeline exposes (pre-pass resolution/throttle, Newton-refinement cadence,
# depth-capture throttle), none of which moved FPS at 4K when tested,
# capping the actual decoded/composited stream size directly attacks the
# real cost: general per-pixel video decode + compositing work, which
# scales with resolution regardless of AI-3D. MiDaS-Std is intentionally
# NOT capped here - it stays the uncapped/known-good reference. See
# compute_requested_resolution().
#
# 2026-08-25: replaced the old flat MIDAS_FAST_MAX_PIXELS/
# MIDAS_FASTEST_MAX_PIXELS constants (one budget per tier, applied
# regardless of resolution/passthrough) with settings_controller.gd's
# AUTO_TABLE, whose cap_px varies per (resolution-class, passthrough) combo
# from an on-device GPU-inference benchmark matrix - e.g. Fast is uncapped
# at HD-passthrough-on but capped to 2K's pixel budget at 4K-passthrough-on.
# Applies to MANUAL Fast selection too, not just Auto - see
# compute_requested_resolution()'s cap block below.
#
# History: capped both tiers, then MiDaS-Fast/-Fastest's 3D quality looked
# visibly worse than MiDaS-Std. [DEPTH]-tagged logging in depth_estimator.gd
# ruled out the depth pipeline itself (capture/submission/polling equally
# healthy across all tiers) and the bitrate cliff bug (fixed separately,
# stream_manager.gd's _auto_bitrate() now scales from the UNCAPPED
# resolution). Root cause found 2026-08-18: these caps were width/height
# pairs, aspect-scaled with min(target_w/w, target_h/h) - on a WIDE source
# (the native size here can be a 2.96:1 multi-monitor composite, not 16:9),
# the width dimension binds first, so "cap to 2560x1440" actually produced
# 2560x864 (2.21M px) instead of the 3.69M px the "1440p" label implied -
# confirmed directly: manually selecting 1440p and letting Fastest's cap
# reduce down to "1440p" were NOT delivering the same pixel count at all,
# despite looking like they should be equal. Fixed by capping to a total
# PIXEL BUDGET via sqrt(target_px/actual_px) instead of a width/height pair
# - same approach this file already uses for HEVC_MAX_TOTAL_PIXELS just
# below, which doesn't have this problem because it already works in pixels.
const MIDAS_RES_CAP_ENABLED := true

# The highest resolution scale that keeps compute_requested_resolution()'s
# result under every constraint that applies to the given codec at the
# current native size, i.e. the point past which compute_requested_resolution()
# would otherwise silently downscale further than the requested percentage
# implied. Used to build the UI's resolution option list (compute_resolution_options())
# so a user can never select a percentage compute_requested_resolution() would
# have quietly overridden anyway.
func compute_max_resolution_pct(codec: int) -> int:
	if settings.host.native_resolution.x <= 0 or settings.host.native_resolution.y <= 0:
		return 100
	var nw = float(settings.host.native_resolution.x)
	var nh = float(settings.host.native_resolution.y)
	var max_pct = 100.0
	if codec == 0:
		max_pct = minf(max_pct, 100.0 * H264_MAX_DIMENSION / maxf(nw, nh))
	elif codec == 1:
		max_pct = minf(max_pct, 100.0 * HEVC_MAX_DIMENSION / maxf(nw, nh))
		max_pct = minf(max_pct, 100.0 * sqrt(HEVC_MAX_TOTAL_PIXELS / (nw * nh)))
		max_pct = minf(max_pct, 100.0 * sqrt(HEVC_MAX_SUSTAINED_PIXELS / (nw * nh)))
	return clampi(int(floor(max_pct)), 10, 100)

# The dynamic option list for the resolution cycle button: RESOLUTION_PRESETS
# below the current max get kept as-is; the max itself always occupies the top
# slot (labeled "MAX" by the UI, not a number) instead of whatever presets
# would otherwise have sat above an unreachable ceiling - so there's never an
# option in the list that silently does something other than what its label says.
func compute_resolution_options() -> Array:
	var max_pct = compute_max_resolution_pct(settings.codec_preference)
	var opts: Array = [max_pct]
	for p in RESOLUTION_PRESETS:
		if p < max_pct:
			opts.append(p)
	return opts

func compute_requested_resolution(apply_midas_cap: bool = true) -> Vector2i:
	var w: int
	var h: int
	if settings.host.is_polaris_host:
		w = int(settings.host.native_resolution.x * settings.host.resolution_scale_pct / 100.0)
		h = int(settings.host.native_resolution.y * settings.host.resolution_scale_pct / 100.0)
	else:
		var res: Vector2i = resolutions[settings.host.resolution_idx]
		w = res.x
		h = res.y
	# H.264 hardware decoders on this class of mobile SoC commonly cap out at 4096px
	# per dimension (HEVC decoders on the same hardware typically go up to 8192) -
	# requesting wider/taller than that doesn't error, it just silently never produces
	# a decoded frame. Confirmed live: at 100% (4480x1440) H.264 decode stalls
	# completely right after connecting; at 90% (4032x1296, under the limit) it works
	# fine. Scale both dimensions down together to preserve aspect ratio rather than
	# only clamping the offending one, which would mismatch the server's capture
	# aspect and trigger its own letterbox/pillarbox scaling instead.
	if settings.codec_preference == 0 and (w > H264_MAX_DIMENSION or h > H264_MAX_DIMENSION):
		var scale = minf(float(H264_MAX_DIMENSION) / w, float(H264_MAX_DIMENSION) / h)
		w = int(w * scale)
		h = int(h * scale)
	elif settings.codec_preference == 1:
		var scale = 1.0
		if w > HEVC_MAX_DIMENSION or h > HEVC_MAX_DIMENSION:
			scale = minf(scale, minf(float(HEVC_MAX_DIMENSION) / w, float(HEVC_MAX_DIMENSION) / h))
		if w * h > HEVC_MAX_TOTAL_PIXELS:
			scale = minf(scale, sqrt(float(HEVC_MAX_TOTAL_PIXELS) / float(w * h)))
		if w * h > HEVC_MAX_SUSTAINED_PIXELS:
			scale = minf(scale, sqrt(float(HEVC_MAX_SUSTAINED_PIXELS) / float(w * h)))
		if scale < 1.0:
			w = int(w * scale)
			h = int(h * scale)
	# Quest 2 hard resolution ceiling (2026-08-27, see device_is_quest2's own
	# comment) - unconditional (not gated on apply_midas_cap, unlike the
	# AI-3D cap_px block below) since this reflects real hardware/display
	# limits, not an AI-3D-specific tradeoff: Quest 2's own per-eye panel
	# resolution is already below Quest 3's, so there's no benefit
	# requesting more than this regardless of AI-3D state. Applied BEFORE
	# the AI-3D cap block, so get_auto_selection()'s own classification
	# (which reads this same function with apply_midas_cap=false) always
	# sees the already-1080p-capped value too.
	if device_is_quest2 and w * h > QUEST2_MAX_RESOLUTION.x * QUEST2_MAX_RESOLUTION.y:
		var quest2_scale = sqrt(float(QUEST2_MAX_RESOLUTION.x * QUEST2_MAX_RESOLUTION.y) / float(w * h))
		w = int(w * quest2_scale)
		h = int(h * quest2_scale)
	# MiDaS-Fast only - see MIDAS_RES_CAP_ENABLED's comment above. Keyed off
	# the actually-active stereo mode (accounts for settings.host.sbs_mode overriding
	# settings.host.ai_3d_speed/model/debug, same as settings_controller.get_stereo_mode()
	# itself), not those raw fields directly. Caps by total pixel budget
	# (like HEVC_MAX_TOTAL_PIXELS above), NOT a width/height pair scaled by
	# min(target_w/w, target_h/h) - that approach silently delivered far
	# fewer pixels than intended on a non-16:9 source (see history above).
	# apply_midas_cap=false lets a caller ask "what would this resolution be
	# WITHOUT the AI-3D cap" - see stream_manager.gd's start_stream(), which
	# uses that to pick Auto bitrate from the uncapped resolution instead of
	# the capped encode resolution (same bitrate, fewer pixels should mean
	# MORE bits per pixel, not fewer). get_auto_selection() always reads the
	# UNCAPPED resolution internally (apply_midas_cap=false), so this can't
	# recurse into itself.
	#
	# cap_px comes from settings_controller.gd's AUTO_TABLE UNCONDITIONALLY
	# whenever the resulting tier is Fast (stereo_mode 10) - not gated on
	# settings.host.ai_3d_speed==1 - so a MANUAL Fast selection gets the same per-combo cap
	# Auto's own Fast pick would use at that resolution/passthrough combo,
	# matching this cap's pre-2026-08-25 behavior of applying to manual Fast
	# too (it just used one flat constant then instead of a per-combo table).
	if apply_midas_cap and MIDAS_RES_CAP_ENABLED and settings_controller:
		var stereo_mode = settings_controller.get_stereo_mode()
		var max_pixels := 0
		if stereo_mode == 10:
			max_pixels = settings_controller.get_auto_selection().cap_px
		if max_pixels > 0 and w * h > max_pixels:
			var cap_scale = sqrt(float(max_pixels) / float(w * h))
			w = int(w * cap_scale)
			h = int(h * cap_scale)
	w = maxi(w - (w % 2), 320)
	h = maxi(h - (h % 2), 180)
	return Vector2i(w, h)

# %IPInput accepts an optional ":port" suffix now (2026-08-26, GitHub-reported
# need for a custom Apollo/Sunshine HTTP port) - splits on the LAST ":" so a
# bare IP with no port still works unchanged. Returns [ip: String, port: int],
# defaulting to DEFAULT_PAIR_PORT when no ":" is present or the suffix isn't a
# valid number. Callers that just DISPLAY the field text or use it as a
# per-host settings-persistence key (state_manager.gd's save_host_state())
# should keep using the raw text as-is - only callers that actually connect
# somewhere (pairing, host-record matching, Wake-on-LAN's host lookup) need
# the parsed ip/port.
const DEFAULT_PAIR_PORT := 47989
func parse_ip_port(text: String) -> Array:
	var colon = text.rfind(":")
	if colon == -1:
		return [text, DEFAULT_PAIR_PORT]
	var ip_part = text.substr(0, colon)
	var port_part = text.substr(colon + 1)
	if not port_part.is_valid_int():
		return [text, DEFAULT_PAIR_PORT]
	var port = port_part.to_int()
	if port <= 0 or port > 65535:
		return [text, DEFAULT_PAIR_PORT]
	return [ip_part, port]

func _log(msg: String):
	_log_lines.append("[%s] %s" % [Time.get_datetime_string_from_system(false, true), msg])
	push_warning("NF: %s" % msg)

func _rotate_session_log():
	if _log_session_rotated:
		return
	_log_session_rotated = true
	var current_path = ProjectSettings.globalize_path(LOG_CURRENT_PATH)
	var previous_path = ProjectSettings.globalize_path(LOG_PREVIOUS_PATH)
	if FileAccess.file_exists(previous_path):
		DirAccess.remove_absolute(previous_path)
	if FileAccess.file_exists(current_path):
		DirAccess.rename_absolute(current_path, previous_path)
	elif FileAccess.file_exists(LEGACY_LOG_PATH):
		# Preserve the final pre-rotation session once when upgrading.
		DirAccess.rename_absolute(ProjectSettings.globalize_path(LEGACY_LOG_PATH), previous_path)

func _flush_log():
	if _log_lines.is_empty():
		return
	_rotate_session_log()
	var mode = FileAccess.READ_WRITE if _log_file_initialized else FileAccess.WRITE
	var f = FileAccess.open(LOG_CURRENT_PATH, mode)
	if f:
		if _log_file_initialized:
			f.seek_end()
		for line in _log_lines:
			f.store_line(line)
		f.close()
		_log_lines.clear()
		_log_file_initialized = true

func export_diagnostics():
	var device_codename = stream_backend.get_device_model() if stream_backend else "unknown"
	_log("[DIAGNOSTICS] Export requested: phase=%s streaming=%s device=%s requested_resolution=%s fps=%d codec=%d ai3d_mode=%d model=%d backend=%d priority=%d hz_cap=%d" % [
		session_lifecycle.phase_name() if session_lifecycle else "unknown",
		str(is_streaming), device_codename, str(compute_requested_resolution(false)),
		settings.host.stream_fps, settings.codec_preference, settings.host.ai_3d_speed,
		settings.host.ai_3d_model, settings.host.ai_3d_backend_pref,
		settings.ai_3d_gpu_priority, settings.host.ai_3d_hz_cap])
	_flush_log()
	var result = stream_backend.export_diagnostics() if stream_backend else "ERROR: Streaming backend unavailable"
	if result.begins_with("ERROR:"):
		ui_controller.show_temporary_status("Log export failed", 1.0)
		_log("[DIAGNOSTICS] %s" % result)
	else:
		ui_controller.show_temporary_status("Log downloaded to %s" % result, 1.0)
		_log("[DIAGNOSTICS] Saved to %s" % result)

func _setup_comp_layer():
	comp = CompositionLayerManager.new(self)
	video_presentation.set_legacy_renderer(comp)
	comp.setup()

func _update_comp_bezel():
	comp.update_bezel()

func _update_cylinder_params():
	comp.update_cylinder_params()

func _make_screen_transparent():
	comp.make_screen_transparent()

func _make_ui_transparent():
	comp.make_ui_transparent()

func _make_kb_transparent():
	comp.make_kb_transparent()

func _restore_screen_material():
	comp.restore_screen_material()

func _restore_ui_material():
	comp.restore_ui_material()

func _restore_kb_material():
	comp.restore_kb_material()

var _comp_base_size: Vector2i:
	get: return primary_screen.comp_base_size if primary_screen else Vector2i(1920, 1080)
	set(v):
		if primary_screen: primary_screen.comp_base_size = v

func get_blur_scale(s: VRScreen) -> float:
	if _xr_render_width <= 0:
		return 1.0
	var source_size: Vector2i = stream_manager.get_current_stream_size() if stream_manager else stream_viewport.size
	return (s.uv_region.z * float(source_size.x)) / float(_xr_render_width)

func _reset_steady_filter():
	_steady_active = false
	_steady_velocity = Vector3.ZERO
	_steady_raw_hit = Vector3.ZERO
	_steady_last_usec = 0
	_steady_last_frame = -1

func _one_euro_alpha(cutoff_hz: float, delta: float) -> float:
	var tau := 1.0 / (TAU * maxf(cutoff_hz, 0.001))
	return 1.0 / (1.0 + tau / maxf(delta, 0.000001))

func _get_steady_hit(raw: Vector3) -> Vector3:
	if settings.pointer_steady == 0 or not is_xr_active:
		_reset_steady_filter()
		return raw
	var frame := Engine.get_process_frames()
	# Several interaction paths ask for the same ray hit in one frame. Advancing
	# a time-based filter for every caller would make its response depend on UI
	# state rather than elapsed time.
	if _steady_active and frame == _steady_last_frame:
		return _steady_hit
	var now_usec := Time.get_ticks_usec()
	if not _steady_active:
		_steady_hit = raw
		_steady_active = true
		_steady_velocity = Vector3.ZERO
		_steady_raw_hit = raw
		_steady_last_usec = now_usec
		_steady_last_frame = frame
		return raw
	if settings.pointer_steady == 3:
		var delta := float(now_usec - _steady_last_usec) / 1000000.0
		# A long gap means the ray left the screen or tracking was interrupted.
		# Reset rather than letting the old point pull the cursor back onscreen.
		if delta <= 0.0 or delta > 0.25:
			_steady_hit = raw
			_steady_velocity = Vector3.ZERO
			_steady_raw_hit = raw
		else:
			# The derivative must be measured between consecutive raw samples.
			# Measuring it against the filtered position makes accumulated filter
			# lag look like movement and defeats One Euro's stationary cutoff.
			var raw_velocity := (raw - _steady_raw_hit) / delta
			var derivative_alpha := _one_euro_alpha(1.0, delta)
			_steady_velocity = _steady_velocity.lerp(raw_velocity, derivative_alpha)
			# Low cutoff while stationary removes controller tremor; movement raises
			# it immediately so deliberate aiming does not inherit High's lag.
			var cutoff := 1.2 + 8.0 * _steady_velocity.length()
			_steady_hit = _steady_hit.lerp(raw, _one_euro_alpha(cutoff, delta))
			_steady_raw_hit = raw
		_steady_last_usec = now_usec
		_steady_last_frame = frame
		return _steady_hit
	var factor := 0.3 if settings.pointer_steady == 1 else 0.1
	var dead_zone := 0.002 if settings.pointer_steady == 1 else 0.005
	var delta = raw - _steady_hit
	if delta.length() < dead_zone:
		_steady_last_usec = now_usec
		_steady_last_frame = frame
		return _steady_hit
	_steady_hit = _steady_hit.lerp(raw, factor)
	_steady_last_usec = now_usec
	_steady_last_frame = frame
	return _steady_hit

func _get_cylinder_normal_at(hit_point: Vector3) -> Vector3:
	return primary_screen.get_cylinder_normal_at(hit_point)

func _hit_point_to_uv(hit_point: Vector3) -> Vector2:
	return primary_screen.hit_point_to_uv(hit_point)

func _update_cursor_layer():
	if not comp.in_use:
		composition_pointers.hide_primary()
		composition_pointers.hide_all_embedded(screens)
		return
	var active_raycast = xr_interaction.get_active_raycast() if xr_interaction else (hand_raycast if is_xr_active else mouse_raycast)
	var on_screen = false
	var pad_on_screen = controller_mapper and controller_mapper.is_active() and controller_mapper.is_gamepad_mode()
	var tp_capturing = virtual_keyboard and virtual_keyboard.visible and virtual_keyboard.trackpad_active
	var stereo = settings_controller.get_stereo_mode() if settings_controller else 0
	var use_embedded_cursor = on_screen and not pad_on_screen and not tp_capturing
	var hovered_screen: VRScreen = null
	if active_raycast.is_colliding():
		var hit_point = _get_steady_hit(active_raycast.get_collision_point())
		var col = active_raycast.get_collider()
		var t = PointerTarget.resolve(col) if col else {"role": &""}
		on_screen = (t.role == &"screen")
		hovered_screen = t.screen if on_screen else null
		# Keep the screen cursor in one composition layer across mono, SBS, and
		# native presentation. Switching between embedded eye-viewport cursors and
		# this layer made the pointer disappear after returning from SBS.
		var independent_cursor = VideoPresentation.uses_independent_screen_cursor(
			comp.in_use, video_presentation.is_native_active())
		use_embedded_cursor = on_screen and not pad_on_screen and not tp_capturing \
			and not independent_cursor
		if on_screen and (pad_on_screen or tp_capturing):
			composition_pointers.hide_primary()
			composition_pointers.hide_all_embedded(screens)
		elif use_embedded_cursor and on_screen:
			composition_pointers.hide_primary()
			if pointer_cursor:
				pointer_cursor.visible = false
			if contact_dot:
				contact_dot.visible = false
			composition_pointers.show_embedded(
				hovered_screen,
				screens,
				hit_point,
				settings.bezel_enabled,
				settings.cursor_mode,
				stereo,
				settings.host.ai_3d_cursor_position,
				depth_estimator._pass_parallax if depth_estimator else 0.0,
				primary_screen)
		elif composition_pointers.has_primary():
			composition_pointers.hide_all_embedded(screens)
			var surf_normal = hovered_screen.get_cylinder_normal_at(hit_point) \
				if on_screen and hovered_screen \
				else (xr_camera.global_position - hit_point).normalized()
			# The native renderer cannot embed the pointer into its video texture,
			# so apply the AI-3D cursor calibration to this independent composition
			# layer in world space. Convert the legacy branch's exact pixel offset
			# into screen metres so Left/Default/Right remain resolution-independent.
			var native_ai_cursor_offset := Vector3.ZERO
			if on_screen and stereo >= 3 and video_presentation.is_native_active() and hovered_screen:
				var base_w := maxf(float(hovered_screen.comp_base_size.x), 1.0)
				var base_h := maxf(float(hovered_screen.comp_base_size.y), 1.0)
				var correction_px := float(settings.host.ai_3d_cursor_position + 1) * 12.0 * base_h / 1080.0
				var screen_right := hovered_screen.global_transform.basis.x.normalized()
				native_ai_cursor_offset = screen_right * (correction_px / base_w) * hovered_screen.mesh_size.x
			composition_pointers.show_primary(
				hit_point,
				surf_normal,
				xr_camera.global_position,
				hovered_screen.global_position if hovered_screen else hit_point,
				on_screen,
				settings.cursor_mode,
				native_ai_cursor_offset)
	else:
		composition_pointers.hide_primary()
		composition_pointers.hide_all_embedded(screens)
	if composition_pointers.has_primary():
		if pointer_cursor:
			pointer_cursor.visible = false
		if contact_dot:
			contact_dot.visible = false

func _sync_composition_panels():
	if not comp.in_use:
		return
	if ui_controller:
		ui_controller.sync_tooltip_surface()
	var keyboard_action := composition_panels.sync_transforms(ui_panel_3d, virtual_keyboard)
	match keyboard_action:
		CompositionPanelLayers.KeyboardMaterialAction.MAKE_TRANSPARENT:
			_make_kb_transparent()
		CompositionPanelLayers.KeyboardMaterialAction.RESTORE:
			_restore_kb_material()

func _update_laser_layers():
	composition_controller_rays.update(
		DEBUG_COMP_LASER,
		comp.in_use and is_xr_active,
		xr_camera.global_position,
		hand_raycast,
		left_hand_raycast)

func _update_marker_layers(_delta: float):
	composition_controller_markers.update(
		DEBUG_COMP_MARKER and comp.in_use and is_xr_active,
		xr_camera.global_transform.basis,
		right_hand,
		left_hand,
		right_hand_resting,
		left_hand_resting,
		_is_using_hands)

func set_comp_grab_bar_color(viewport: SubViewport, color: Color):
	CompositionLayerManager.set_grab_bar_color(viewport, color)

func _update_grab_bar_layers():
	composition_screen_controls.update(
		screens,
		comp.in_use,
		DEBUG_COMP_GRAB_BAR,
		DEBUG_COMP_CORNERS,
		screen_shortcuts.revealed_screen if screen_shortcuts else null)

func exit_app():
	get_tree().quit()

func disconnect_stream():
	session_lifecycle.request_disconnect()
	if current_host_id >= 0:
		stream_backend.cancel_host_stream(current_host_id)
	stream_backend.stop_play_stream()

func start_connect_timeout():
	session_lifecycle.arm_connect_timeout()
	get_tree().create_timer(10.0).timeout.connect(_on_connect_timeout)

func _on_connect_timeout():
	if not session_lifecycle.connect_timeout_pending:
		return
	_log("[CONNECT] Connection timed out")
	stream_backend.stop_play_stream()
	restore_after_failed_connect("Failed to connect (timeout)")

func restore_after_failed_connect(status_msg: String, welcome_name: String = "server"):
	# start_stream() resizes the shared source/composition viewports before the
	# asynchronous launch request is sent. If that request fails, no decoder was
	# started and therefore no stream_terminated signal arrives to run the normal
	# disconnect cleanup. Leaving comp_base_size at the attempted stream size
	# makes the 1920x1080 welcome cursor use the wrong pixel coordinate space.
	# Treat this as a complete non-streaming transition, including cancelling the
	# still-armed Connect timeout and clearing restart state so the viewport reset
	# below cannot take the native-restart preserve path.
	session_lifecycle.fail()
	_full_disconnect_cleanup(status_msg, welcome_name)

func _bind_yuv_textures():
	comp.bind_yuv_textures()

func _retry_yuv_bind(seq: int):
	for i in range(6):
		await get_tree().create_timer(0.25).timeout
		if seq != _stream_start_seq or not is_streaming:
			return
		_bind_yuv_textures()

func _bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode: int, cmt, cr):
	comp.bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode, cmt, cr)

func _bind_comp_fallback_texture(stream_tex):
	comp.bind_fallback_texture(stream_tex)

func _on_stream_started():
	# The selected display rate was already applied and awaited by
	# StreamManager.start_stream() before decoder and native swapchain setup.
	# Do not request it again here: a display transition racing newly-created
	# GLES resources crashes the Quest GL thread.
	var was_restarting := session_lifecycle.stream_started()
	telemetry.reset_session()
	_last_activity_time = Time.get_ticks_msec() / 1000.0
	ui_controller.set_status("Connecting...")
	welcome_screen.reset_connect_button()
	ui_controller.set_disconnect_visible(true)
	_log("[STREAM] Connection started!")
	if not comp.in_use:
		stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	welcome_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	stream_manager.bind_texture()
	# bind_yuv_textures() skips rebinding the composition-layer cylinder's
	# shader when the decoder's texture RIDs "look unchanged" from the last
	# bind - a real optimization for the steady-state per-frame case, but
	# wrong right after a (re)connect: a restart's new decoder session can
	# end up with the exact same RIDs reused (resource pooling) even though
	# the actual texture is a fresh one, leaving the cylinder showing a
	# stale/blank frame while decode stats keep updating normally. A stream
	# genuinely (re)starting here should always force a real rebind.
	if comp.available:
		comp.invalidate_yuv_cache()
	_bind_yuv_textures()
	# The decoder's shader material is reused across a restart, not recreated -
	# right here, right at connection start, it can still be holding a
	# reference to the just-torn-down previous session's (now GPU-invalid)
	# texture, which bind_yuv_textures() now correctly refuses to bind (see its
	# RID validity check) rather than crashing the renderer on it. But nothing
	# else ever retries the real YUV path afterward (binding is purely
	# event-driven, no periodic re-check), so without this the stream would be
	# stuck on the SubViewport fallback for the rest of the session. Retry a
	# few times shortly after connecting, by which point the new session's
	# first real frame should have landed.
	_stream_start_seq += 1
	_retry_yuv_bind(_stream_start_seq)
	# Was an unconditional _switch_to_comp_layer() (plain/mono), which reset
	# AI-3D/SBS to 2D on EVERY (re)connect, silently, with nothing re-
	# applying the real mode afterward unless the user happened to touch a
	# mode button again post-restart - root cause of "3D effect stopped
	# working after a restart, only came back after manually cycling modes"
	# (2026-08-18, user diagnosed this from watching a MiDaS-Fast switch
	# visibly apply against the OLD pre-restart video, then get lost when
	# the restart landed). apply_stereo() re-derives and applies the actual
	# current stereo mode (2D/SBS/AI-3D) against the freshly (re)started
	# session instead of blindly resetting to 2D - settings_controller.gd's
	# _schedule_ai_3d_commit() now deliberately skips its own apply_stereo()
	# call when a restart is about to happen, relying on this one instead,
	# so the mode is only ever applied against a session that's actually live.
	settings_controller.apply_stereo()
	if not was_restarting:
		ui_visible = false
		_set_ui_visible(false)
		_ui_has_saved_offset = false
		composition_panels.hide_ui()
	if settings.passthrough_enabled:
		_hide_all_backgrounds()
	var all_btn_flags = 0x1000|0x2000|0x4000|0x8000|0x0001|0x0002|0x0004|0x0008|0x0100|0x0200|0x0010|0x0020|0x0040|0x0080|0x0400
	stream_backend.send_controller_arrival(0, 1, 1, all_btn_flags, 0x01|0x02)

	# The host's real desktop can be a very different shape than settings.host.native_resolution
	# assumed (first-ever connection to a host, or its desktop layout changed since
	# last time) - requesting the wrong aspect makes the host letterbox/squeeze its
	# real composite to fit. Reconnect once at the correctly-scaled size instead, so
	# the *next* launch requests the right shape from the start, and cache the real
	# size afterward so a repeat connection to this host doesn't need to. Only ever
	# retries once per session, so a host that free-scales regardless of requested
	# resolution can't loop us forever.
	#
	# Deliberately done AFTER the stream has genuinely started (not by aborting the
	# first launch response before ever calling start_stream_v2): a launch that's
	# never followed through to an actual RTSP/media connection leaves the host
	# waiting on a handshake that will never come, which held its session-launch
	# lock forever and made every subsequent connect attempt fail with "the active
	# session is stopping or changing" - the exact regression this replaces. Tearing
	# an ACTUALLY-STARTED stream down with stop_play_stream() (same pattern as
	# settings_controller.gd's _schedule_stream_restart()) gives the host a real,
	# clean teardown to work with instead of an abandoned half-launch.
	# Start every session on just the primary monitor - makes multi-monitor
	# testing much easier to reason about (add monitors one at a time from a
	# known-good baseline instead of whatever the host's own multi-monitor
	# default happens to be) and is simpler for real use too. Deliberately a
	# true one-shot for the whole app run (never reset), not per-host/per-
	# reconnect - once trimmed, later manual monitor changes this session are
	# left alone; relaunch the app to get the primary-only starting point again.
	if layout and not _did_initial_monitor_trim and layout.source == &"host_manifest":
		_did_initial_monitor_trim = true
		var enabled_at_connect = layout.enabled_monitors()
		if enabled_at_connect.size() > 1:
			var primary_m = layout.get_primary()
			for m in layout.monitors:
				if not m.is_primary:
					m.enabled = false
			settings_controller.apply_screen_layout(layout)
			if primary_m:
				settings.host.native_resolution = primary_m.frame_rect.size
			host_resolution = compute_requested_resolution()
			settings_controller.refresh_resolution_btn_label()
			stream_manager._resolution_retry_done = true
			var retry_host_id = current_host_id
			var retry_app_id = _selected_app_id
			var retry_resolution = host_resolution
			_log("[LAYOUT] Trimming to primary-only on first connect (host defaulted to %d monitors)" % enabled_at_connect.size())
			session_lifecycle.request_restart()
			_clear_comp_yuv_textures()
			await get_tree().process_frame
			await get_tree().process_frame
			stream_backend.stop_play_stream()
			await get_tree().create_timer(0.5).timeout
			stream_manager.start_stream(retry_host_id, retry_app_id, retry_resolution)
			return

	# Polaris-only: this whole comparison is "does the manifest-reported real
	# desktop size match what settings.host.native_resolution assumed" - meaningless (and,
	# confirmed live, actively harmful) for any host that never populates a
	# real manifest, since layout.frame_size then never reflects this actual
	# connection at all. Against a Sunshine host this fired repeatedly every
	# single connect, restarting over and over chasing a comparison that could
	# never converge - each restart also being a real cost (see
	# stream_connection.cpp's deferred-free GPU resource queue).
	if settings.host.is_polaris_host and layout and layout.frame_size != Vector2i.ZERO and layout.frame_size != settings.host.native_resolution:
		settings.host.native_resolution = layout.frame_size
		settings_controller.refresh_resolution_btn_label()
		# Deliberately NOT gated on "not was_restarting" (this used to be) - that
		# blocked the retry for exactly the case that needs it most: removing/
		# adding a monitor changes the server's real captured composite size,
		# triggering a genuine restart (settings_controller.gd's
		# _schedule_stream_restart()), which left the stream stuck requesting the
		# old (now mismatched) aspect for that whole session - the same
		# squished-with-black-bars server-side letterbox symptom this retry
		# exists to fix in the first place, just not caught because a restart
		# was already in flight. _resolution_retry_done alone already prevents
		# this from cascading (the retry's own reconnect passes a non-zero
		# forced_resolution, which does not reset it), so was_restarting was
		# never actually needed for that protection.
		if not stream_manager._resolution_retry_done:
			stream_manager._resolution_retry_done = true
			var retry_host_id = current_host_id
			var retry_app_id = _selected_app_id
			var retry_resolution = compute_requested_resolution()
			_log("[STREAM] Host's real desktop %s doesn't match cached size - reconnecting at %s (%d%%)" % [
				str(layout.frame_size), str(retry_resolution), settings.host.resolution_scale_pct])
			session_lifecycle.request_restart()
			# See settings_controller.gd's _schedule_stream_restart() for why this
			# has to happen (and yield a frame) before stop_play_stream(), not after.
			_clear_comp_yuv_textures()
			await get_tree().process_frame
			await get_tree().process_frame
			stream_backend.stop_play_stream()
			await get_tree().create_timer(0.5).timeout
			stream_manager.start_stream(retry_host_id, retry_app_id, retry_resolution)
			return
	state_manager.save_host_state()

func _switch_to_comp_layer():
	comp.switch_to_comp_layer()

func _switch_to_stereo_comp_layer():
	comp.switch_to_stereo_comp_layer()

func _switch_to_mesh_rendering():
	comp.switch_to_mesh_rendering()

func _update_comp_layer_size():
	comp.update_layer_size()

func _on_stream_terminated(msg: String, err_code: int = 0):
	_log("[NF] _on_stream_terminated: phase=" + session_lifecycle.phase_name() + " msg=" + str(msg) + " err=" + str(err_code))
	if video_presentation:
		video_presentation.deactivate_native(false)
	if session_lifecycle.is_restarting():
		session_lifecycle.stream_terminated(false, err_code)
		_server_codec_support = {}
		ui_controller.update_codec_btn()
		stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_clear_comp_yuv_textures()
		if not comp.in_use and screen_mesh.material_override is ShaderMaterial:
			screen_mesh.material_override.set_shader_parameter("yuv_mode", 0)
			screen_mesh.material_override.set_shader_parameter("tex_y", null)
			screen_mesh.material_override.set_shader_parameter("tex_u", null)
			screen_mesh.material_override.set_shader_parameter("tex_v", null)
		return
	if settings.auto_reconnect_enabled and err_code != 0:
		_log("[RECONNECT] Keeping stream alive for auto-reconnect")
		session_lifecycle.stream_terminated(true, err_code)
		ui_controller.set_status("Connection lost, reconnecting...")
		return
	session_lifecycle.stream_terminated(false, err_code)
	_full_disconnect_cleanup("Disconnected: " + str(msg))

func _full_disconnect_cleanup(status_msg: String, welcome_name: String = "welcome"):
	session_lifecycle.finish_cleanup()
	_server_codec_support = {}
	_host_cursor_toggle_supported = false
	ui_controller.update_codec_btn()
	ui_controller.update_host_cursor_btn_state()
	ui_controller.set_status(status_msg)
	ui_controller.set_disconnect_visible(false)
	_log("[STREAM] Full disconnect: %s" % status_msg)
	welcome_screen.show_welcome_screen(welcome_name)
	stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_clear_comp_yuv_textures()
	# _clear_comp_yuv_textures() shows the ". . ." loading indicator (meant
	# for mid-restart, waiting-on-real-decoder-frames), but a full disconnect
	# goes straight to the welcome screen instead of a fresh stream - hide it
	# again so it doesn't blink away on top of the welcome screen content.
	comp.hide_loading_dots()
	comp_shader_mat.set_shader_parameter("main_texture", welcome_viewport.get_texture())
	comp_shader_mat.set_shader_parameter("yuv_mode", 0)
	if comp_shader_mat_left:
		comp_shader_mat_left.set_shader_parameter("main_texture", welcome_viewport.get_texture())
		comp_shader_mat_left.set_shader_parameter("yuv_mode", 0)
	if comp_shader_mat_right:
		comp_shader_mat_right.set_shader_parameter("main_texture", welcome_viewport.get_texture())
		comp_shader_mat_right.set_shader_parameter("yuv_mode", 0)
	if not comp.in_use and screen_mesh.material_override is ShaderMaterial:
		screen_mesh.material_override.set_shader_parameter("yuv_mode", 0)
		screen_mesh.material_override.set_shader_parameter("tex_y", null)
		screen_mesh.material_override.set_shader_parameter("tex_u", null)
		screen_mesh.material_override.set_shader_parameter("tex_v", null)
	stream_manager.teardown_v2_yuv_rect()
	welcome_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if comp.available:
		_switch_to_comp_layer()
		comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	else:
		if not comp.in_use:
			screen_mesh.material_override.set_shader_parameter("main_texture", welcome_viewport.get_texture())
		_switch_to_mesh_rendering()
	if mouse_captured_by_stream:
		input_handler.release_stream_mouse()
	audio_player.stop()
	ui_visible = false
	_set_ui_visible(false)
	composition_panels.hide_ui()
	welcome_screen.reset_connect_button()
	settings_controller.apply_passthrough(settings.passthrough_enabled)
	welcome_screen.update_welcome_info()
	stream_manager.resize_stream_viewport(1920, 1080)

func _clear_comp_yuv_textures():
	comp.clear_yuv_textures()

func _ready():
	session_lifecycle.phase_changed.connect(_on_session_phase_changed)
	_log("=== Nightfall started ===")
	Engine.max_fps = 0

	_startup_cover = MeshInstance3D.new()
	_startup_cover.name = "StartupCover"
	var quad = QuadMesh.new()
	quad.size = Vector2(20.0, 20.0)
	_startup_cover.mesh = quad
	_startup_cover.position = Vector3(0, 0, -0.3)
	var cov_mat = StandardMaterial3D.new()
	cov_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cov_mat.albedo_color = Color(0, 0, 0, 1)
	cov_mat.render_priority = 127
	_startup_cover.material_override = cov_mat
	xr_camera.add_child(_startup_cover)
	_log("[COVER] Startup cover active")

	if OS.get_name() == "Android":
		OS.set_environment("CURL_CA_BUNDLE", "/system/etc/security/cacerts/")
		OS.set_environment("SSL_CERT_FILE", "/system/etc/security/cacerts/")
	else:
		OS.set_environment("CURL_CA_BUNDLE", "/etc/ssl/certs/ca-certificates.crt")
		OS.set_environment("SSL_CERT_FILE", "/etc/ssl/certs/")

	_init_modules()
	_init_android_setup()
	_init_ui()
	_init_stream_backend()

	var interface = XRServer.find_interface("OpenXR")
	if not interface or not interface.is_initialized():
		if "--nf-no-xr" in OS.get_cmdline_user_args():
			_log("[XR] --nf-no-xr set, continuing without OpenXR for desktop testing")
			return
		_log("[XR] OpenXR not available - cannot run without VR runtime")
		if not Engine.is_editor_hint():
			get_tree().quit()
		return

	if Engine.is_editor_hint():
		get_viewport().use_xr = false
		if interface:
			interface.uninitialize()
		return

	_init_xr(interface)
	video_presentation.setup_native()
	# Composition providers must be registered before the OpenXR session starts.
	# Only after registration may the refresh transition settle before layer and
	# stream swapchains are allocated.
	await settings_controller.apply_display_refresh_rate()
	_init_backgrounds_and_comp_layer()
	await get_tree().create_timer(0.5).timeout
	screen_mesh.extra_cull_margin = 10.0
	ui_panel_3d.extra_cull_margin = 10.0
	_init_post_xr()
	_init_textures_and_ui()

	if settings.quick_start_enabled:
		_try_auto_connect()

	Input.joy_connection_changed.connect(func(device, connected):
		_on_joy_changed(device, connected)
	)

	if right_hand:
		right_hand.pose = "aim"
	if left_hand:
		left_hand.pose = "aim"

	_post_ready_check.call_deferred()

func _on_session_phase_changed(previous: int, current: int) -> void:
	_log("[SESSION] %s -> %s" % [
		SessionLifecycle.Phase.keys()[previous].to_lower(),
		SessionLifecycle.Phase.keys()[current].to_lower(),
	])

func _init_modules():
	stream_manager = StreamManager.new(self)
	xr_interaction = XRInteraction.new(self)
	input_handler = InputHandler.new(self)
	ui_controller = UIController.new(self)
	auto_detect = AutoDetect.new(self)
	depth_estimator = DepthEstimatorModule.new(self)
	native_xr_renderer = NativeXrRendererManager.new(self)
	video_presentation = VideoPresentation.new(null, native_xr_renderer)
	welcome_screen = WelcomeScreen.new(self)
	screen_manager = ScreenManager.new(self)
	settings_controller = SettingsController.new(self)
	state_manager = StateManager.new(self)
	controller_mapper = ControllerMapper.new(self)
	add_child(controller_mapper)
	screen_shortcuts = ScreenShortcutBar.new(self)

func _init_android_setup():
	# AI-3D depth estimation is native (no JNI/JVM) on Linux as of 2026-08-20
	# (see depth_bridge.cpp's NIGHTFALL_PLATFORM_LINUX branch/MidasDepthEngine,
	# and settings_controller.gd's _ai_3d_supported()) - depth_estimator.setup()
	# needs to run there too now, split out from the rest of this genuinely
	# Android-only setup (controller models, hand fade materials, mouse
	# capture - none of which apply to a desktop Linux client). Must run
	# BEFORE _init_backgrounds_and_comp_layer() creates comp_viewport_left/
	# right - depth_estimator's upsample/offset SubViewports (stereo_mode 5)
	# produce the warp data those actually-displayed per-eye viewports
	# consume every frame (via yuv_display.gdshader), and Godot updates
	# SubViewports in scene-tree order, so the producer must be added to the
	# tree first. (The upsample pass used to also depend on comp_viewport -
	# the OPPOSITE direction - which was the real source of a stutter/
	# double-image bug; that dependency was removed by having it decode YUV
	# directly instead, see depth_upsample.gdshader.)
	if OS.get_name() == "Android" or OS.get_name() == "Linux":
		depth_estimator.setup()
	if OS.get_name() == "Android":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# Projectionless (gl_compatibility) builds never render the mesh
		# controller models - comp.in_use always ends up true (see _init_xr's
		# set_submit_projection_layer(false)), and composition-space ray
		# indicators are used instead. The bundled FBX assets are excluded
		# from the Android export (export_presets.cfg exclude_filter) for
		# this reason, so skip trying to load them here too.
		if RenderingServer.get_current_rendering_method() != "gl_compatibility":
			_load_controller_models()
			if DEBUG_RENDER_MODEL_CONTROLLERS:
				_setup_render_model_controllers()
		_prepare_fade_materials("right")
		_prepare_fade_materials("left")
	settings.host.sbs_mode = clampi(settings.host.sbs_mode, 0, 2)
	settings.host.ai_3d_model = clampi(settings.host.ai_3d_model, 0, settings_controller.ai_3d_models.size() - 1)
	settings.host.ai_3d_speed = clampi(settings.host.ai_3d_speed, 0, 3)
	settings.host.ai_3d_last_mode = clampi(settings.host.ai_3d_last_mode, 1, 3)
	settings.host.ai_3d_backend_pref = 1 if settings.host.ai_3d_backend_pref == 1 else 2
	# Runs before any per-host state (state_manager.gd's load_host_state()
	# has its own call for that, and its own comment) - also covers a
	# brand-new install/host, which never reaches that call at all (see
	# load_host_state()'s early return when the host has no saved section
	# yet), so a fresh Android install can't boot pointed at settings.host.ai_3d_model's
	# compiled-in default (MiDaS-256-GPU, not bundled there).
	settings_controller.enforce_ai3d_platform_lock()
	if not [12, 15, 20, 30, 40].has(settings.host.ai_3d_hz_cap):
		settings.host.ai_3d_hz_cap = 20
	if not [50, 75, 100, 125, 150].has(settings.host.ai_3d_separation_pct):
		settings.host.ai_3d_separation_pct = 100
	if not [30, 40, 50, 60, 70].has(settings.host.ai_3d_convergence_pct):
		settings.host.ai_3d_convergence_pct = 50
	settings.host.ai_3d_debug = clampi(settings.host.ai_3d_debug, 0, 3)

	if right_hand and left_hand:
		var right_ray = right_hand.get_node_or_null("HandRayCast")
		if right_ray:
			var right_laser_node = right_ray.get_node_or_null("Laser")
			if right_laser_node:
				var tex = _make_laser_gradient()
				if tex:
					var mat = StandardMaterial3D.new()
					mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					mat.albedo_color = Color(1, 1, 1, 0.5)
					mat.albedo_texture = tex
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					mat.render_priority = 127
					mat.no_depth_test = true
					right_laser_node.material_override = mat
			left_hand_raycast = right_ray.duplicate()
			left_hand_raycast.name = "LeftHandRayCast"
			left_hand.add_child(left_hand_raycast)

func _init_ui():
	virtual_keyboard = VirtualKeyboard.new(self)
	add_child(virtual_keyboard)
	virtual_keyboard.build()

	screen_mesh.setup(self, &"m0")
	screen_registry.initialize(screen_mesh)
	screen_shortcuts.setup_screen(screen_mesh)
	primary_screen.grid_pos = Vector2i(3, 1)
	layout = ScreenLayout.single(Vector2i(1920, 1080))
	primary_screen.apply_monitor(layout.get_primary(), layout.frame_size)
	_mesh_size = screen_mesh.mesh.size
	screen_manager.create_corner_handles()
	screen_manager.create_bezel()
	_create_contact_dot()
	ui_panel_3d.set_meta(&"nf_role", &"panel")

	ui_controller.build_ui()
	welcome_screen.build_welcome_ui()
	_set_viewport_active(ui_viewport, false)

	%IPInput.gui_input.connect(func(e): ui_controller.on_ipinput_gui_input(e))
	ui_controller.setup_numpad()
	ui_controller.refresh_ui_buttons()

const VR_SCREEN_SCENE := preload("res://src/vr_screen.tscn")
const MAX_SCREENS := ScreenRegistry.MAX_SCREENS
# Gap between adjacent screen edges, in meters. Shared with MonitorGrid so
# grid-mode spacing and add_screen()'s free-placement spacing can't drift apart.
const SCREEN_GAP := 0.05

# Local-space offset (from mesh center) of a curved screen's left/right edge,
# matching the vertex math in VRScreen.apply_curvature(): the edge sits at
# chord half-width (not mesh_size.x * 0.5) and bows back in +Z.
func _curve_edge_local_offset(mesh_w: float, radius: float, curvature: int, sign: float) -> Vector3:
	if curvature == 0 or radius <= 0.0:
		return Vector3(sign * mesh_w * 0.5, 0, 0)
	var angle = mesh_w / radius
	var half_w = sin(angle * 0.5) * radius
	var edge_z = radius * (1.0 - cos(angle * 0.5))
	return Vector3(sign * half_w, 0, edge_z)

# Euler angles (same convention as Node3D.rotation) that orient something at
# `pos` to face the headset: yaw via atan2(cam.x-pos.x, cam.z-pos.z) (this
# mesh's front faces local +Z, not -Z, so Node3D.look_at() is 180 degrees off
# and must not be used here). with_pitch also tilts up/down toward the
# headset, for screens placed above/below primary's height. Pure function (no
# node mutation) so grid_cell_transform() below can use it mid-walk, before a
# screen has actually been moved to the position being evaluated.
func _face_camera_angles(pos: Vector3, cam_pos: Vector3, with_pitch: bool) -> Vector3:
	var yaw = atan2(cam_pos.x - pos.x, cam_pos.z - pos.z)
	var pitch = 0.0
	if with_pitch:
		var to_cam = cam_pos - pos
		var dist = to_cam.length()
		pitch = -asin(clampf(to_cam.y / dist, -1.0, 1.0)) if dist > 0.001 else 0.0
	return Vector3(pitch, yaw, 0.0)

func _face_camera(node: Node3D, cam_pos: Vector3, with_pitch: bool) -> void:
	node.rotation = _face_camera_angles(node.global_position, cam_pos, with_pitch)

# Degrees each grid square is turned from its neighbor square (a 155-degree
# dihedral fold between adjacent squares) - a fixed, constant spacing,
# deliberately NOT derived from curvature/radius: the grid's own angle stays
# "a standard size" regardless of whatever Flat/Slight/Curved the screens
# themselves are set to, and the screens' own existing curve/bow rendering
# (VRScreen.apply_curvature(), _curve_edge_local_offset()) is completely
# unaffected by any of this - it stays exactly as it already is. Sized for the
# common case (3 screens = 6 squares, not the full 8), hence sharper than a
# naive 120deg/8 would give. A screen is 2 squares wide, so consecutive
# SCREENS are rotated by 2x this amount from each other.
const GRID_SQUARE_TURN_DEG := 25.0

# Transform of the screen `n` screen-widths to the right (n>0) or left (n<0)
# of primary (n=0 = primary itself), for every n from -max_n to +max_n,
# computed via a single outward walk in each direction (used to be recomputed
# from scratch for every one of nearest_free_grid_cell()'s ~21 candidates,
# every frame during a live drag - real cost saver to do it once and look up).
#
# Each hop places the next screen's near edge exactly SCREEN_GAP from the
# current screen's far edge - same anchor+near_offset edge math add_screen()
# already uses for its own hops (_curve_edge_local_offset(), so a genuinely
# curved screen's real bowed-backward edge is what the gap is measured from,
# not an idealized flat one - a curved screen's edge sits well behind its
# flat mesh_size.x width, and measuring the gap against the flat width was
# exactly why curved screens kept touching even though the gap looked correct
# on paper), just with a fixed rotation increment instead of a
# curvature-derived one - then rotates by 2*GRID_SQUARE_TURN_DEG for the next
# screen. Using an explicit edge-to-edge gap term like this (rather than
# deriving screen spacing from a folded multi-square chord) is what
# guarantees screens never drift closer than SCREEN_GAP as the turn angle
# increases - an earlier version derived spacing from a chord across 2
# individually-folded squares, which shrank as the angle increased.
func _grid_screen_transforms(max_n: int) -> Dictionary:
	var transforms := {0: Transform3D(primary_screen.global_transform.basis, primary_screen.global_position)}
	var mesh_w = primary_screen.mesh_size.x
	var curvature = primary_screen.curvature
	var radius = primary_screen.get_cylinder_radius() if curvature > 0 else 0.0
	var turn = deg_to_rad(GRID_SQUARE_TURN_DEG * 2.0)
	for dir in [1.0, -1.0]:
		var pos = primary_screen.global_position
		var basis = primary_screen.global_transform.basis
		for n in range(1, max_n + 1):
			var far_edge = _curve_edge_local_offset(mesh_w, radius, curvature, dir)
			var anchor = pos + basis * far_edge
			anchor += basis.x * dir * SCREEN_GAP
			basis = basis.rotated(Vector3.UP, -dir * turn)
			var near_edge = _curve_edge_local_offset(mesh_w, radius, curvature, -dir)
			pos = anchor - basis * near_edge
			transforms[int(dir) * n] = Transform3D(basis, pos)
	return transforms

# World transform for grid cell (gx,gy), given a screen-transform cache from
# _grid_screen_transforms() above. Row (vertical) offsets stay horizontally
# unrotated (curvature has always been horizontal-only here) but DO pitch to
# face the viewer, same as add_screen()'s existing "above" placement always
# has - a row that ends up above eye height needs to tilt down to read
# comfortably, and a row below needs to tilt up.
func _cell_transform_from_screens(gx: int, gy: int, anchor_gx: int, anchor_gy: int, transforms: Dictionary) -> Transform3D:
	var n = (gx - anchor_gx) / MonitorGrid.SPAN
	var t: Transform3D = transforms[n]

	var row_steps = (gy - anchor_gy) / MonitorGrid.SPAN
	if row_steps != 0:
		# gy increases downward in the grid, which is -Y (lower) in world space.
		var row_span = primary_screen.mesh_size.y + SCREEN_GAP
		t.origin += t.basis.y * (-row_steps) * row_span
		var yaw = t.basis.get_euler().y
		var pitch = _face_camera_angles(t.origin, xr_camera.global_position, true).x
		t.basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))

	return t

# Single-cell convenience wrapper around _cell_transform_from_screens() - fine
# for the one-off calls (preset apply, default placement); the live-drag hot
# path below builds one shared cache instead of using this per candidate.
func grid_cell_transform(gx: int, gy: int, anchor_gx: int, anchor_gy: int) -> Transform3D:
	var n = absi((gx - anchor_gx) / MonitorGrid.SPAN)
	return _cell_transform_from_screens(gx, gy, anchor_gx, anchor_gy, _grid_screen_transforms(n))

# Nearest unoccupied SPANxSPAN cell to raw_pos. Brute-forces all
# (COLS-SPAN+1)*(ROWS-SPAN+1) = 21 candidate cells against a single shared
# transform cache - cheap enough to run every frame during a live drag.
# occupied is an Array[Vector2i] of other screens' current grid cells.
# Returns Vector2i(-1,-1) if every cell is blocked.
func nearest_free_grid_cell(raw_pos: Vector3, occupied: Array, anchor_gx: int, anchor_gy: int) -> Vector2i:
	var transforms = _grid_screen_transforms(MonitorGrid.COLS / MonitorGrid.SPAN)
	var best := Vector2i(-1, -1)
	var best_dist := INF
	for gy in range(MonitorGrid.ROWS - MonitorGrid.SPAN + 1):
		for gx in range(MonitorGrid.COLS - MonitorGrid.SPAN + 1):
			var cand := Vector2i(gx, gy)
			var blocked := false
			for occ in occupied:
				if MonitorGrid.cells_overlap(cand, occ):
					blocked = true
					break
			if blocked:
				continue
			var t = _cell_transform_from_screens(gx, gy, anchor_gx, anchor_gy, transforms)
			var d = t.origin.distance_to(raw_pos)
			if d < best_dist:
				best_dist = d
				best = cand
	return best

func add_screen(monitor_id: StringName, real_x_hint: float = INF, with_stereo: bool = false) -> VRScreen:
	if not screen_registry.can_add():
		_log("[SCREEN] Refusing to add screen %s: MAX_SCREENS=%d reached" % [String(monitor_id), MAX_SCREENS])
		return null
	var s: VRScreen = VR_SCREEN_SCENE.instantiate()
	add_child(s)
	s.setup(self, monitor_id)
	s.mesh_size = primary_screen.mesh_size if primary_screen else Vector2(2.24, 1.26)
	s.curvature = primary_screen.curvature if primary_screen else 2
	if primary_screen:
		var gap = SCREEN_GAP
		var cam_pos = xr_camera.global_position
		var new_radius = primary_screen.get_cylinder_radius() if primary_screen.curvature > 0 else 0.0
		# Prefer the monitor's real desktop x-position (when the caller has one,
		# i.e. apply_screen_layout() passing a manifest-backed MonitorSpec) to
		# decide which side of the chain a new screen extends, and which
		# existing screen it attaches next to. The old approach only tracked
		# "is there already anything on the left/right" - it can't distinguish
		# "further right than the current rightmost" from "should go on the
		# left", so a 3rd non-primary monitor could land on the wrong side, or
		# (once both sides already had one) get forced to stack "above" even
		# when it was really just the next one over in the row. That
		# visual/real mismatch mattered beyond looks: uv_to_host_point() maps
		# clicks using the real desktop_rect regardless of where the screen
		# visually ended up, so a wrongly-placed screen made clicks land on
		# whatever content was really at that position - often the primary.
		var have_hint = real_x_hint != INF and primary_screen.monitor != null
		var primary_real_x = primary_screen.monitor.desktop_rect.position.x if have_hint else 0.0
		var slot: String
		if have_hint:
			slot = "left" if real_x_hint < primary_real_x else "right"
		else:
			var eps = 0.05
			var has_left = false
			var has_right = false
			for existing in screens:
				if existing == primary_screen:
					continue
				if existing.global_position.x < primary_screen.global_position.x - eps:
					has_left = true
				elif existing.global_position.x > primary_screen.global_position.x + eps:
					has_right = true
			slot = "above" if (has_left and has_right) else ("left" if has_right else "right")
		if slot == "above":
			var ref_offset = Vector3(0, primary_screen.mesh_size.y * 0.5, 0)
			var anchor = primary_screen.global_transform * ref_offset
			anchor += primary_screen.global_transform.basis.y * gap
			var near_offset = Vector3(0, -s.mesh_size.y * 0.5, 0)
			s.global_position = anchor - near_offset
			_face_camera(s, cam_pos, true)
			var rotated_near_offset = s.global_transform.basis * near_offset
			s.global_position = anchor - rotated_near_offset
			_face_camera(s, cam_pos, true)
		else:
			var dir = -1.0 if slot == "left" else 1.0
			var edge_screen = primary_screen
			var edge_key = primary_real_x
			for existing in screens:
				if existing == primary_screen:
					continue
				var existing_key = existing.monitor.desktop_rect.position.x if (have_hint and existing.monitor) else existing.global_position.x
				var cmp_key = edge_key if have_hint else edge_screen.global_position.x
				if dir > 0 and existing_key > cmp_key:
					edge_screen = existing
					edge_key = existing_key
				elif dir < 0 and existing_key < cmp_key:
					edge_screen = existing
					edge_key = existing_key
			var ref_radius = edge_screen.get_cylinder_radius() if edge_screen.curvature > 0 else 0.0
			var ref_offset = _curve_edge_local_offset(edge_screen.mesh_size.x, ref_radius, edge_screen.curvature, dir)
			var anchor = edge_screen.global_transform * ref_offset
			anchor += edge_screen.global_transform.basis.x * dir * gap
			var near_offset = _curve_edge_local_offset(s.mesh_size.x, new_radius, s.curvature, -dir)
			s.global_position = anchor - near_offset
			_face_camera(s, cam_pos, false)
			var rotated_near_offset = s.global_transform.basis * near_offset
			s.global_position = anchor - rotated_near_offset
			_face_camera(s, cam_pos, false)
	screen_manager.create_corner_handles_for(s)
	screen_shortcuts.setup_screen(s)
	screen_manager.create_bezel_for(s)
	s.apply_curvature()
	if comp.available:
		comp.setup_screen(s, with_stereo)
		if is_streaming and stream_viewport:
			var stream_size: Vector2i = stream_manager.get_current_stream_size() if stream_manager else stream_viewport.size
			if stream_size.x > 0 and stream_size.y > 0:
				s.comp_viewport.size = stream_size
				s.comp_base_size = stream_size
	if not screen_registry.add(s):
		push_error("Screen registry rejected prepared screen %s" % String(monitor_id))
		s.queue_free()
		return null
	_log("[SCREEN] Added screen %s (total=%d)" % [String(monitor_id), screens.size()])
	if comp.available and comp.in_use and s.comp_cylinder:
		s.comp_cylinder.visible = true
		s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		s.comp_shader_mat.set_shader_parameter("stereo_mode", 0)
		s.bezel_mesh.visible = false
		comp.make_screen_transparent()
		comp.update_cylinder_params()
		comp.update_bezel()
	if comp.available and is_streaming:
		comp.invalidate_yuv_cache()
		_bind_yuv_textures()
	var layer_count = screens.size() + 5
	_log("[COMP] screens=%d layers=%d" % [screens.size(), layer_count])
	if comp.available and s.comp_cylinder and not s.comp_cylinder.is_natively_supported():
		_log("[COMP] Screen %s cylinder not natively supported, falling back to mesh rendering for this screen" % String(monitor_id))
	return s

func remove_screen(monitor_id: StringName) -> void:
	for i in range(screens.size()):
		if screens[i].monitor_id == monitor_id:
			var s = screens[i]
			if s == primary_screen:
				_log("[SCREEN] Refusing to remove the primary screen %s" % String(monitor_id))
				return
			if not screen_registry.remove(s):
				return
			if comp.available:
				if s.comp_cylinder:
					s.comp_cylinder.visible = false
					s.comp_cylinder.set_layer_viewport(null)
					xr_origin.remove_child(s.comp_cylinder)
					s.comp_cylinder.queue_free()
				if s.comp_cylinder_left:
					s.comp_cylinder_left.visible = false
					s.comp_cylinder_left.set_layer_viewport(null)
					xr_origin.remove_child(s.comp_cylinder_left)
					s.comp_cylinder_left.queue_free()
				if s.comp_cylinder_right:
					s.comp_cylinder_right.visible = false
					s.comp_cylinder_right.set_layer_viewport(null)
					xr_origin.remove_child(s.comp_cylinder_right)
					s.comp_cylinder_right.queue_free()
				if s.comp_viewport:
					remove_child(s.comp_viewport)
					s.comp_viewport.queue_free()
				if s.comp_viewport_left:
					remove_child(s.comp_viewport_left)
					s.comp_viewport_left.queue_free()
				if s.comp_viewport_right:
					remove_child(s.comp_viewport_right)
					s.comp_viewport_right.queue_free()
			# screen_mesh is main.gd's own permanent $MeshInstance3D (see
			# _init_ui()'s screens = [screen_mesh]/primary_screen = screen_mesh) -
			# reused for the welcome screen and referenced directly all over this
			# codebase (dozens of call sites), not a disposable VR_SCREEN_SCENE
			# instance like every screen add_screen() creates. It's already been
			# demoted out of the screens[] array and had its comp-layer resources
			# torn down above by this point (the normal "replace the welcome
			# placeholder with the real primary" flow on first connect always
			# reaches here for it, once it's no longer primary_screen) - freeing
			# the node itself as well would free a node the rest of the app still
			# holds direct references to, producing "previously freed" errors on
			# every subsequent access (confirmed live: repeating every frame via
			# whatever still reads screen_mesh.* after this).
			if s != screen_mesh:
				s.queue_free()
			_log("[SCREEN] Removed screen %s (total=%d)" % [String(monitor_id), screens.size()])
			if comp.available and is_streaming:
				comp.invalidate_yuv_cache()
				_bind_yuv_textures()
			_update_cursor_layer()
			return

func _init_stream_backend():
	if config_mgr and comp_mgr:
		comp_mgr.set_config_manager(config_mgr)
	if not ClassDB.class_exists("NightfallStream"):
		_log("[FATAL] NightfallStream GDExtension failed to load - missing .so or incompatible glibc")
		if not Engine.is_editor_hint():
			get_tree().quit()
		return
	var v2_node = ClassDB.instantiate("NightfallStream")
	add_child(v2_node)
	v2_node.set_auto_reconnect(settings.auto_reconnect_enabled)
	v2_node.set_max_reconnect_attempts(5)
	v2_node.set_reconnect_delay_ms(2000)
	stream_backend = StreamBackend.new(v2_node)
	stream_backend.set_config_manager(config_mgr)
	stream_backend.set_computer_manager(comp_mgr)
	if OS.get_name() == "Android":
		# "hollywood" (Quest 2's real device codename) - Build.MODEL itself is
		# useless (confirmed on a real Quest 3 to just return "Quest", not the
		# generation), see GodotApp.java's getDeviceModel() comment.
		var device_codename = stream_backend.get_device_model()
		device_is_quest2 = device_codename.to_lower() == "hollywood"
		device_is_quest3 = device_codename.to_lower() == "eureka"
		_log("[DEVICE] Build.DEVICE='%s' device_is_quest2=%s device_is_quest3=%s" % [device_codename, str(device_is_quest2), str(device_is_quest3)])
	_client_codec_support = stream_backend.probe_all_video_formats()
	_log("[CODEC] Client support: h264=%s hevc=%s av1=%s raw=%s" % [
		str(_client_codec_support.get("h264", false)),
		str(_client_codec_support.get("hevc", false)),
		str(_client_codec_support.get("av1", false)),
		str(_client_codec_support.get("raw", true))])
	v2_node.pair_completed.connect(func(s, m): stream_manager.on_pair_completed(s, m))
	if v2_node.has_signal("log_message"):
		v2_node.log_message.connect(func(message: String):
			_log("[MOONLIGHT] %s" % message)
		)
	v2_node.stream_started.connect(func():
		_on_stream_started()
	)
	v2_node.stream_terminated.connect(func(err_code, err_msg):
		_on_stream_terminated(err_msg, err_code)
	)
	if v2_node.has_signal("restore_token_updated"):
		v2_node.restore_token_updated.connect(func(tok):
			_log("[PORTAL] Restore token updated")
			settings.pipewire_restore_token = tok
			state_manager.save_state()
		)
	if v2_node.has_signal("reconnect_scheduled"):
		v2_node.reconnect_scheduled.connect(func(attempt, max_attempts, delay_ms):
			session_lifecycle.reconnect_scheduled()
			ui_controller.set_status("Reconnecting %d/%d in %ds..." % [attempt, max_attempts, delay_ms / 1000])
			_log("[RECONNECT] Attempt %d/%d in %dms" % [attempt, max_attempts, delay_ms])
		)
	if v2_node.has_signal("reconnect_failed"):
		v2_node.reconnect_failed.connect(func():
			session_lifecycle.fail()
			_log("[RECONNECT] All attempts failed")
			_full_disconnect_cleanup("Reconnect failed")
		)
	if v2_node.has_signal("h264_hw_upgraded"):
		v2_node.h264_hw_upgraded.connect(func():
			_bind_yuv_textures()
			_log("[H264] HW upgrade: re-bound YUV textures for NV12")
		)
	if v2_node.has_signal("hdr_mode_changed"):
		v2_node.hdr_mode_changed.connect(func(enabled: bool, metadata: Dictionary):
			_log("[HDR] Protocol mode changed: enabled=%s metadata=%s" % [str(enabled), str(metadata)])
			# The native callback persists transfer metadata immediately, then
			# applies it on the render thread. Rebind on this frame and once more
			# after a rendered frame so either ordering updates the composition
			# shader variant without relying on stream-start retry timing.
			comp.invalidate_yuv_cache()
			_bind_yuv_textures()
			await get_tree().process_frame
			comp.invalidate_yuv_cache()
			_bind_yuv_textures()
		)
	if v2_node.has_signal("controller_rumble"):
		v2_node.controller_rumble.connect(func(controller, low_freq, high_freq):
			_trigger_haptic(controller, low_freq, high_freq)
		)
	if v2_node.has_signal("controller_trigger_rumble"):
		v2_node.controller_trigger_rumble.connect(func(controller, left_motor, right_motor):
			_trigger_haptic(controller, left_motor, right_motor)
		)
func _init_xr(interface):
	var render_size = interface.get_render_target_size()
	_xr_render_width = int(render_size.x)
	_log("[XR] OpenXR render target: %dx%d" % [render_size.x, render_size.y])
	_log("[XR] Blend modes: %s" % str(interface.get_supported_environment_blend_modes()))
	if OS.get_name() == "Android" and RenderingServer.get_current_rendering_method() == "gl_compatibility" and interface.has_method("set_submit_projection_layer"):
		interface.set_submit_projection_layer(false)
		_log("[XR] Projectionless mode enabled; submitting composition layers only")

	var blend_modes = interface.get_supported_environment_blend_modes()
	passthrough_supported = false
	for bm in blend_modes:
		if bm == XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND:
			passthrough_supported = true
			break

	if passthrough_supported:
		get_viewport().transparent_bg = true
		world_env.environment.background_mode = Environment.BG_COLOR
		world_env.environment.background_color = Color(0, 0, 0, 0)
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	else:
		world_env.environment.background_mode = Environment.BG_COLOR
		world_env.environment.background_color = Color(0, 0, 0, 1)
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE

	get_viewport().size = render_size
	get_viewport().use_xr = true
	if OS.get_name() == "Android":
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	else:
		get_viewport().msaa_3d = Viewport.MSAA_2X
	_xr_base_render_scale = get_viewport().scaling_3d_scale
	is_xr_active = true
	# Godot's own comp-layer/texture bindings (connect_welcome_texture() et al)
	# only ever run once, here at boot, regardless of whether the OpenXR
	# session is actually visible yet - is_initialized() (checked before this
	# function is even called) only means a session exists, not that the
	# headset is being worn: the proximity sensor is a separate state Quest
	# tracks independently of session creation. Launching headlessly (e.g. via
	# adb) and only putting the headset on afterward left the welcome screen
	# showing its plain grey placeholder texture, because nothing ever
	# re-touched the binding once the session actually became visible.
	# user_presence_changed is the proximity-sensor signal itself - re-run the
	# one-time welcome-texture binding whenever the headset is (re-)donned,
	# which is cheap and idempotent, so it's safe even on a session that was
	# already correctly bound.
	if interface.has_signal("user_presence_changed"):
		interface.user_presence_changed.connect(_on_user_presence_changed)
	settings.host.sbs_mode = 0
	settings.host.ai_3d_speed = 0
	# Establish the default 60fps -> 120Hz mapping before composition-layer
	# swapchains are created. Delaying this until stream startup makes the
	# runtime transition every live layer from 72Hz to 120Hz at once, which is
	# measurably less stable on Quest. StreamManager applies the selected host's
	# saved FPS again at the actual connection boundary.
	# Applied and awaited by _ready() immediately after native-provider setup.
	# Yielding here would let OpenXR start its session first, after which provider
	# registration is rejected for the lifetime of this launch.

func _on_user_presence_changed(is_present: bool):
	if not is_present:
		return
	_schedule_xr_surface_refresh("headset present")

func _schedule_xr_surface_refresh(reason: String) -> void:
	# Activity resume and user-presence signals can arrive before Godot has
	# recreated its Android EGL surface and composition-layer swapchains. Retry
	# across several rendered frames instead of betting the screen on one early
	# callback. Menu and keyboard use independent layers, which is why they can
	# survive while only the main screen disappears.
	_xr_resume_refresh_attempts = 3
	_xr_resume_refresh_wait_frames = 1
	_log("[XR] Scheduled composition refresh: %s" % reason)

func _process_xr_surface_refresh() -> void:
	if _xr_resume_refresh_attempts <= 0:
		return
	_xr_resume_refresh_wait_frames -= 1
	if _xr_resume_refresh_wait_frames > 0:
		return
	_xr_resume_refresh_attempts -= 1
	_xr_resume_refresh_wait_frames = 4
	if is_streaming:
		if native_xr_renderer and native_xr_renderer.active:
			native_xr_renderer.request_redraw()
		else:
			_bind_yuv_textures()
	else:
		# Rebind the welcome texture and reassert the mono layer after Godot has
		# rebuilt its viewport swapchain following Android activity resume.
		if comp and comp.available:
			comp.connect_welcome_texture()
			if comp.in_use:
				comp.switch_to_comp_layer()
	_log("[XR] Composition refresh attempt completed (%d remaining)" % _xr_resume_refresh_attempts)

func _init_backgrounds_and_comp_layer():
	_create_backgrounds()
	_screen_mesh_original_mat = screen_mesh.material_override
	_setup_comp_layer()
	comp.connect_welcome_texture()

func _init_post_xr():
	state_manager.load_state()

	if comp.available:
		_switch_to_comp_layer()

	settings_controller.apply_passthrough(settings.passthrough_enabled)

	ui_visible = false
	_set_ui_visible(false)
	_ui_has_saved_offset = false
	# _reposition_screen_and_ui() (triggered from _process()) can race with the
	# await above, so re-sync everything one last time now that load_state()/
	# switch_to_comp_layer() have both definitely finished - the same fix a
	# manual grab performs, just run automatically before the cover lifts.
	for s in screens:
		s.apply_curvature()
	if comp.available:
		comp.update_cylinder_params()
	_debug_log_cyl("init_post_xr")
	_startup_ready = true

func _init_textures_and_ui():
	var saved_ip = ""
	if config_mgr:
		config_mgr.load_config()
		var save = ConfigFile.new()
		if save.load("user://last_connection.cfg") == OK:
			saved_ip = save.get_value("connection", "ip", "")
			var saved_unique_id: String = save.get_value("connection", "server_unique_id", "")
			if saved_ip != "":
				%IPInput.text = saved_ip
				# state_manager's host_state.cfg is keyed by the raw field text
				# (see save_host_state()), so load_host_state() needs that same
				# raw text - but localaddress/detect_polaris_host() need the
				# parsed (port-suffix stripped) ip, see main.parse_ip_port().
				state_manager.load_host_state(saved_ip)
				var saved_host_ip: String = parse_ip_port(saved_ip)[0]
				# Match by server_unique_id first (2026-08-27) - a host reached
				# via NAT port-forwarding can share a bare IP with a different,
				# already-paired host (see stream_manager.gd's
				# on_pair_completed() fix). Fall back to bare-IP matching only
				# if no unique_id was saved (e.g. an older last_connection.cfg).
				if not saved_unique_id.is_empty():
					for h in config_mgr.get_hosts():
						if h.get("server_unique_id", "") == saved_unique_id:
							current_host_id = h.id
							break
				if current_host_id < 0:
					for h in config_mgr.get_hosts():
						if h.has("localaddress") and h.localaddress == saved_host_ip:
							current_host_id = h.id
							break
				if current_host_id >= 0:
					settings_controller.detect_polaris_host(saved_host_ip, current_host_id)
				welcome_screen.update_welcome_info()

	stream_manager.bind_texture()
	if screen_mesh.material_override is ShaderMaterial:
		screen_mesh.material_override.set_shader_parameter("main_texture", welcome_viewport.get_texture())
	comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var _wt = welcome_viewport.get_texture()

	stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	ui_controller.update_ui()
	ui_controller.update_stereo_shader()
	session_lifecycle.show_server_selection()

func _try_auto_connect():
	var saved_ip = parse_ip_port(%IPInput.text)[0]
	var saved_unique_id: String = ""
	var save = ConfigFile.new()
	if save.load("user://last_connection.cfg") == OK:
		saved_unique_id = save.get_value("connection", "server_unique_id", "")
	var v2_cm = stream_backend.get_config_manager()
	if v2_cm:
		var v2_hosts = v2_cm.get_hosts()
		if v2_hosts.size() > 0:
			var h: Dictionary = {}
			# Match by server_unique_id first (2026-08-27) - see
			# _init_textures_and_ui()'s identical fix above for why bare-IP
			# matching alone can pick the wrong host (NAT port-forwarding
			# sharing one IP across different, already-paired servers).
			if not saved_unique_id.is_empty():
				for candidate in v2_hosts:
					if candidate.get("server_unique_id", "") == saved_unique_id:
						h = candidate
						break
			if h.is_empty():
				for candidate in v2_hosts:
					if candidate.get("localaddress", "") == saved_ip:
						h = candidate
						break
			if h.is_empty():
				h = v2_hosts[0]
			var host_ip = h.get("localaddress", "") if h.has("localaddress") else saved_ip
			var host_id = h.get("id", -1) if h.has("id") else -1
			if host_id != -1 and host_ip != "":
				current_host_id = host_id
				%IPInput.text = host_ip
				_log("[AUTO-CONNECT] Auto-connecting to host_id=%d ip=%s" % [host_id, host_ip])
				await get_tree().create_timer(1.0).timeout
				stream_manager.start_stream(host_id, _selected_app_id)

func _post_ready_check():
	await get_tree().create_timer(0.5).timeout



func _on_joy_changed(device: int, connected: bool):
	pass

func _process(delta):
	if is_xr_active:
		_process_hand_tracking(delta)

	if DEBUG_RENDER_MODEL_CONTROLLERS:
		_process_render_model_controllers(delta)

	_log_flush_timer += delta
	if _log_flush_timer >= 2.0:
		_log_flush_timer = 0.0
		_flush_log()

	_process_button_input()

	if right_click_cooldown > 0.0:
		right_click_cooldown -= delta

	_process_input_release()
	_process_xr_surface_refresh()

	xr_interaction.process_pointer_frame(delta)
	xr_interaction.handle_scroll()
	_update_cursor_layer()
	_sync_composition_panels()
	_sync_interaction_viewports()
	_update_laser_layers()
	_update_marker_layers(delta)
	_update_hand_indicator_layers()
	_update_grab_bar_layers()
	_sync_comp_background()
	if comp:
		comp.process_ambient(delta)

	_process_background_follow()

	auto_detect.process(delta)

	if depth_estimator:
		depth_estimator.process(delta)
		if depth_estimator.depth_texture and settings.host.ai_3d_speed > 0 and comp.in_use:
			var dt = depth_estimator.depth_texture
			if comp_shader_mat_left and not comp_shader_mat_left.get_shader_parameter("depth_texture"):
				comp_shader_mat_left.set_shader_parameter("depth_texture", dt)
			if comp_shader_mat_right and not comp_shader_mat_right.get_shader_parameter("depth_texture"):
				comp_shader_mat_right.set_shader_parameter("depth_texture", dt)

	_process_stats(delta)

	if grabbed_node:
		xr_interaction.handle_grab()

	if grabbed_corner_idx >= 0:
		xr_interaction.handle_corner_resize()

	if _startup_cover:
		if _startup_ready and _startup_reposition == -1:
			_debug_log_cyl("cover_removed")
			_startup_cover.queue_free()
			_startup_cover = null
			_log("[COVER] Startup cover removed")

	_process_controller_fade(delta)

func _prepare_fade_materials(side: String):
	var hand = right_hand if side == "right" else left_hand
	if not hand:
		return
	_fade_materials[side].clear()
	_collect_fade_materials(hand, _fade_materials[side])

func _collect_fade_materials(node: Node, result: Array):
	for child in node.get_children():
		if child is MeshInstance3D and child.name != "Laser":
			var mi := child as MeshInstance3D
			if mi.mesh:
				for surface_idx in mi.mesh.get_surface_count():
					var source := mi.get_active_material(surface_idx) as BaseMaterial3D
					if source:
						var material := source.duplicate() as BaseMaterial3D
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						mi.set_surface_override_material(surface_idx, material)
						result.append(material)
		_collect_fade_materials(child, result)

func _set_hand_alpha(side: String, alpha: float):
	if is_equal_approx(_hand_alpha[side], alpha):
		return
	_hand_alpha[side] = alpha
	for material: BaseMaterial3D in _fade_materials[side]:
		var c = material.albedo_color
		c.a = alpha
		material.albedo_color = c

func _hand_has_activity(hand: XRController3D, side: String) -> bool:
	if not hand:
		return false
	var pos = hand.global_position
	var last_pos = xr_interaction._last_known_right_pos if side == "right" else xr_interaction._last_known_left_pos
	var moved = last_pos.distance_squared_to(pos) > 0.00001
	if side == "right":
		xr_interaction._last_known_right_pos = pos
	else:
		xr_interaction._last_known_left_pos = pos
	if moved:
		return true
	var rot = hand.global_rotation
	var last_rot = xr_interaction._last_known_right_rot if side == "right" else xr_interaction._last_known_left_rot
	if last_rot.distance_squared_to(rot) > 0.0001:
		if side == "right":
			xr_interaction._last_known_right_rot = rot
		else:
			xr_interaction._last_known_left_rot = rot
		return true
	if side == "right":
		xr_interaction._last_known_right_rot = rot
	else:
		xr_interaction._last_known_left_rot = rot
	if hand.get_float("trigger") > 0.1 or hand.get_float("grip") > 0.1:
		return true
	var vec = hand.get_vector2("primary")
	if absf(vec.x) > 0.1 or absf(vec.y) > 0.1:
		return true
	return false

const HAND_REST_THRESHOLD := 4.0
var right_hand_resting: bool = false
var left_hand_resting: bool = false

func _raycast_points_at_stream(raycast: RayCast3D) -> bool:
	if not raycast or not raycast.enabled or not raycast.is_colliding():
		return false
	return PointerTarget.resolve(raycast.get_collider()).role == &"screen"

func _process_controller_fade(delta: float):
	if _is_using_hands or not is_xr_active:
		return
	if _hand_has_activity(right_hand, "right"):
		xr_interaction._right_inactive_time = 0.0
	else:
		xr_interaction._right_inactive_time += delta
	if _hand_has_activity(left_hand, "left"):
		xr_interaction._left_inactive_time = 0.0
	else:
		xr_interaction._left_inactive_time += delta
	_apply_hand_fade("right", xr_interaction._right_inactive_time, delta)
	_apply_hand_fade("left", xr_interaction._left_inactive_time, delta)
	# Keep menu, keyboard, grab-bar, and shortcut pointers available regardless
	# of controller stillness. Once a ray has gone to rest over stream content,
	# preserve that state until physical controller activity wakes it again.
	var right_can_rest := right_hand_resting or _raycast_points_at_stream(hand_raycast)
	var left_can_rest := left_hand_resting or _raycast_points_at_stream(left_hand_raycast)
	_apply_hand_rest("right", xr_interaction._right_inactive_time >= HAND_REST_THRESHOLD and right_can_rest)
	_apply_hand_rest("left", xr_interaction._left_inactive_time >= HAND_REST_THRESHOLD and left_can_rest)

func _apply_hand_fade(side: String, inactive_time: float, delta: float):
	var target_alpha = 1.0 if inactive_time < HAND_REST_THRESHOLD else 0.02
	var new_alpha = move_toward(_hand_alpha[side], target_alpha, delta * 2.0)
	_set_hand_alpha(side, new_alpha)

func _apply_hand_rest(side: String, resting: bool):
	var was_resting = right_hand_resting if side == "right" else left_hand_resting
	if resting == was_resting:
		return
	if side == "right":
		right_hand_resting = resting
		if hand_raycast: hand_raycast.enabled = not resting
	else:
		left_hand_resting = resting
		if left_hand_raycast: left_hand_raycast.enabled = not resting
	_log("[HAND] %s controller %s" % [side, "resting (disabled)" if resting else "picked up (re-enabled)"])

func _process_hand_tracking(_delta):
	var hands_active = get_is_hand_tracking() and get_hand_tracking_has_data()
	if hands_active != _is_using_hands:
		_is_using_hands = hands_active
		if _is_using_hands:
			# The controller nodes below are about to be overwritten with hand
			# joints. Preserve the physical controllers' last positions for their
			# resting markers, and ensure both hand pointers are available even if
			# controller-idle detection had disabled one of their shared raycasts.
			composition_controller_markers.capture_controller_positions(right_hand, left_hand)
			if hand_raycast:
				hand_raycast.enabled = true
			if left_hand_raycast:
				left_hand_raycast.enabled = true
			_log("[INPUT] Hand Tracking active, hiding controller models")
			_set_controller_models_visible(false)
		else:
			# Controllers have taken ownership of these nodes/rays again. Restart
			# inactivity detection from an unambiguous active state.
			right_hand_resting = false
			left_hand_resting = false
			xr_interaction._right_inactive_time = 0.0
			xr_interaction._left_inactive_time = 0.0
			if hand_raycast:
				hand_raycast.enabled = true
			if left_hand_raycast:
				left_hand_raycast.enabled = true
			_log("[INPUT] Controllers active, showing controller models")
			_set_controller_models_visible(true)

	if _is_using_hands:
		var right_tracker = XRServer.get_tracker("/user/hand_tracker/right")
		var left_tracker = XRServer.get_tracker("/user/hand_tracker/left")
		if right_tracker:
			_update_hand_tracker_transform(right_hand, right_tracker)
		if left_tracker:
			_update_hand_tracker_transform(left_hand, left_tracker)

func _process_button_input():
	if not is_xr_active:
		return
	if not controller_mapper or not controller_mapper.is_active():
		var b_pressed = right_hand.is_button_pressed("by_button")
		if b_pressed and not _was_b_pressed:
			screen_shortcuts.invoke(ScreenShortcutBar.ACTION_MENU)
		_was_b_pressed = b_pressed
		var a_pressed = right_hand.is_button_pressed("ax_button")
		if a_pressed and not _was_a_pressed:
			screen_shortcuts.invoke(ScreenShortcutBar.ACTION_KEYBOARD)
		_was_a_pressed = a_pressed
		var r_stick_click = right_hand.is_button_pressed("primary_click")
		var l_stick_click = left_hand.is_button_pressed("primary_click") if left_hand else false
		if r_stick_click and not _was_r_stick_click and not l_stick_click:
			var tp_exited = virtual_keyboard and virtual_keyboard.thumbstick_exit_flag
			if not virtual_keyboard or (not virtual_keyboard.trackpad_active and not tp_exited):
				screen_shortcuts.invoke(ScreenShortcutBar.ACTION_SBS)
		if not r_stick_click:
			if virtual_keyboard:
				virtual_keyboard.thumbstick_exit_flag = false
		_was_r_stick_click = r_stick_click
	if _startup_reposition >= 0 and is_xr_active:
		match _startup_reposition:
			0:  # Waiting for tracking to produce a meaningful camera position
				if xr_camera.global_position.length_squared() > 0.01:
					_startup_reposition = 1
			1:  # Wait one more frame for tracking to stabilize
				_startup_reposition = 2
			2:  # Position screen in front of user
				_reposition_screen_and_ui(true)
				_startup_reposition = -1

func _process_input_release():
	if Input.is_action_just_pressed("ui_focus_next"):
		if mouse_captured_by_stream:
			input_handler.release_stream_mouse()

	if Input.is_key_pressed(KEY_CTRL) and Input.is_key_pressed(KEY_ALT) and Input.is_key_pressed(KEY_SHIFT):
		if mouse_captured_by_stream:
			input_handler.release_stream_mouse()

func _process_idle_activity():
	if not is_streaming or settings.idle_timeout_min <= 0:
		return
	if right_hand:
		var trigger = right_hand.get_float("trigger")
		var primary = right_hand.get_float("primary")
		var grip = right_hand.get_float("grip")
		if trigger > 0.1 or primary > 0.1 or grip > 0.1:
			_last_activity_time = Time.get_ticks_msec() / 1000.0
	if left_hand:
		var l_trigger = left_hand.get_float("trigger")
		var l_primary = left_hand.get_float("primary")
		var l_grip = left_hand.get_float("grip")
		if l_trigger > 0.1 or l_primary > 0.1 or l_grip > 0.1:
			_last_activity_time = Time.get_ticks_msec() / 1000.0

func _process_background_follow():
	if not is_xr_active:
		return
	for i in range(bg_names.size()):
		var bg = get_node_or_null(bg_names[i])
		if bg and bg.visible:
			bg.global_position = xr_camera.global_position + bg_offsets[i]
			break
	# Position-only follow (2026-08-24), matching the real particle
	# systems above - comp_bg_equirect's rotation deliberately stays fixed
	# (world-locked skybox feel, not spinning with head-look) while its
	# position re-centers on the camera every frame, same as the
	# GPUParticles3D backgrounds re-centering via bg_offsets.
	if comp_bg_equirect and comp_bg_equirect.visible:
		comp_bg_equirect.global_position = xr_camera.global_position

# Keeps comp_bg_capture_instance in sync with the currently selected
# background (settings.background_mode) and shows/hides comp_bg_equirect to match
# whether an environment background should currently be visible (passthrough
# off, a background selected, in composition mode). Called from
# apply_background()/apply_passthrough() on real transitions, and also every
# frame from _process() as a safety net (e.g. entering/leaving composition
# mode without touching background/passthrough settings) - safe because the
# work below only runs on an actual state change (bg_idx/want_visible), and
# Unlike the pointer layers, this never repeatedly toggles the composition
# background's visibility.
# once shown, so it doesn't hit the swapchain-teardown crash from earlier.
func _sync_comp_background():
	if not comp_bg_equirect or not comp_bg_capture_viewport:
		return
	var bg_idx = settings.background_mode - 1
	var want_visible = DEBUG_COMP_BG_EQUIRECT and comp.available and comp.in_use and is_xr_active and not settings.passthrough_enabled and bg_idx >= 0 and bg_idx < bg_names.size()
	if not want_visible:
		if comp_bg_equirect.visible:
			comp_bg_equirect.visible = false
		if comp_bg_capture_viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			comp_bg_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if comp_bg_capture_instance:
			comp_bg_capture_instance.queue_free()
			comp_bg_capture_instance = null
			comp_bg_capture_index = -1
		return
	if comp_bg_capture_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		comp_bg_capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if bg_idx != comp_bg_capture_index:
		if comp_bg_capture_instance:
			comp_bg_capture_instance.queue_free()
			comp_bg_capture_instance = null
		comp_bg_capture_instance = bg_manager.create_capture_instance(bg_idx, comp_bg_capture_viewport)
		comp_bg_capture_instance.visible = true
		comp_bg_capture_instance.emitting = true
		comp_bg_capture_index = bg_idx
	if not comp_bg_equirect.visible:
		comp_bg_equirect.visible = true

func _process_stats(delta):
	if not is_streaming:
		if comp:
			comp.set_stats_visible(false)
		return
	if comp.in_use:
		var cur_sharpen = float(settings.sharpen_mode) * 0.5
		var cur_blur_scale = get_blur_scale(primary_screen)
		if cur_sharpen != _cached_sharpen or cur_blur_scale != _cached_blur_scale:
			_cached_sharpen = cur_sharpen
			_cached_blur_scale = cur_blur_scale
			settings_controller.apply_filter()
	var new_video_frame := stream_backend != null and stream_backend.consume_new_frame()
	if video_presentation:
		video_presentation.process_frame(new_video_frame)
	var frame_sample := telemetry.record_frame(delta, new_video_frame)
	if not frame_sample.is_empty():
		# Diagnostic (2026-09-06): video update FPS is inherently capped at app
		# FPS (consume_new_frame() can report at most one "yes" per
		# script tick, no matter how many render-thread completions happened
		# since the last tick) - now that decode-thread throughput and native
		# render cost are both confirmed to track target Hz closely, this
		# checks whether the script tick rate itself is also
		# hitting target, and exactly how close video_update_fps tracks it.
		_log("[STATS] app=%.1ffps video_update=%.1ffps (%.1f%% of app) frames=%d/%d" % [
			frame_sample["app_fps"], frame_sample["video_update_fps"],
			100.0 * frame_sample["video_update_fps"] / maxf(frame_sample["app_fps"], 0.001),
			frame_sample["video_updates"], frame_sample["app_frames"]])
	if telemetry.status_update_due(delta):
		stream_manager.update_stats()
	_process_performance_overlay(delta)

func toggle_performance_overlay():
	settings.performance_overlay_enabled = not settings.performance_overlay_enabled
	telemetry.reset_overlay()
	if stream_backend:
		stream_backend.take_performance_stats()
	# Mutually exclusive: the legacy in-screen TextureRect overlay and the
	# native renderer's own composited overlay quad both sample the same
	# stats_viewport texture through independent, differently-positioned
	# display paths - showing both at once (observed 2026-09-04 as one flat
	# + one bent-along-the-curved-screen overlay) means whichever path isn't
	# actually presenting is still drawing a stale/mispositioned copy.
	var native_active := video_presentation.is_native_active()
	if comp:
		comp.set_stats_visible(settings.performance_overlay_enabled and is_streaming and not native_active)
	video_presentation.set_stats_visible(settings.performance_overlay_enabled and is_streaming)
	if ui_controller:
		ui_controller.update_stats_btn_state()
	if state_manager:
		state_manager.save_state()

func _process_performance_overlay(delta: float):
	if not settings.performance_overlay_enabled or not stream_backend or not comp:
		return
	comp.set_stats_visible(true)
	if not telemetry.overlay_update_due(delta):
		return
	var current = stream_backend.take_performance_stats()
	if current.is_empty():
		return
	var stats = telemetry.combine_performance_window(current)
	var elapsed_s = maxf(float(stats.get("elapsed_us", 0)) / 1000000.0, 0.001)
	var total_frames = int(stats.get("total_frames", 0))
	var received_frames = int(stats.get("received_frames", 0))
	var rendered_frames = int(stats.get("rendered_frames", 0))
	var lost_frames = int(stats.get("network_lost_frames", 0))
	var decoder_queue_drops = int(stats.get("decoder_queue_drops", 0))
	var decoder_queue_size = int(stats.get("decoder_queue_size", 0))
	var total_fps = float(total_frames) / elapsed_s
	var incoming_fps = float(received_frames) / elapsed_s
	var rendering_fps = float(rendered_frames) / elapsed_s
	var lost_pct = 100.0 * float(lost_frames) / float(maxi(total_frames, 1))
	var decoder_ms = float(stats.get("decode_time_us", 0)) / 1000.0 / float(maxi(received_frames, 1))
	var width = stream_backend.get_video_width()
	var height = stream_backend.get_video_height()
	var decoder_name = stream_backend.get_decoder_name()
	if decoder_name.is_empty():
		decoder_name = "Unknown"
	var lines := PackedStringArray([
		"Video stream: %dx%d %.0f FPS" % [width, height, total_fps],
		"Decoder: %s" % decoder_name,
		"Incoming frame rate from network: %.0f FPS" % incoming_fps,
		"Rendering frame rate: %.0f FPS" % rendering_fps,
		"Nightfall application frame rate: %.1f FPS" % telemetry.app_fps,
		"Nightfall video texture update rate: %.1f FPS" % telemetry.video_update_fps,
		"Frames dropped by your network connection: %.2f%%" % lost_pct,
		"Decoder queue drops: %d (queued: %d)" % [decoder_queue_drops, decoder_queue_size],
		"Average network latency: %d ms (variance: %d ms)" % [int(stats.get("network_latency_ms", 0)), int(stats.get("network_variance_ms", 0))],
	])
	var host_samples = int(stats.get("host_latency_samples", 0))
	if host_samples > 0:
		lines.append("Host processing latency min/max/average: %.1f/%.1f/%.1f ms" % [
			float(stats.get("host_latency_tenths_min", 0)) / 10.0,
			float(stats.get("host_latency_tenths_max", 0)) / 10.0,
			float(stats.get("host_latency_tenths_total", 0)) / 10.0 / float(host_samples),
		])
	lines.append("Average decoding time: %.2f ms" % decoder_ms)
	# Moonlight XR owns its native OpenXR renderer and times the warp command
	# buffer directly. Godot exposes no equivalent GPU timestamp to script;
	# retain the same field explicitly as unavailable rather than substituting
	# CPU frame time and creating a misleading comparison.
	var native_warp_ms := video_presentation.get_warp_gpu_ms()
	lines.append("Warp GPU: %.2f ms" % native_warp_ms if native_warp_ms > 0.0 else "Warp GPU: N/A")
	if settings.host.ai_3d_speed > 0 and settings_controller.get_stereo_mode() >= 3:
		lines.append("Depth inference: %.2f ms" % stream_backend.get_depth_last_inference_ms())
		lines.append("Depth GPU priority: %s" % settings_controller.ai_3d_gpu_priority_labels[settings.ai_3d_gpu_priority])
		lines.append("Depth age: %.1f ms" % stream_backend.get_depth_last_age_ms())
		lines.append("Depth frames skipped: %d" % stream_backend.get_depth_last_skipped_frames())
	comp.update_stats_text("\n".join(lines))
	video_presentation.request_stats_overlay_update()
	_log("[PERF] %dx%d stream=%.1f incoming=%.1f render=%.1f lost=%.2f%% queue_drops=%d queued=%d rtt=%dms decode=%.2fms depth=%.2fms" % [
		width, height, total_fps, incoming_fps, rendering_fps, lost_pct,
		decoder_queue_drops, decoder_queue_size,
		int(stats.get("network_latency_ms", 0)), decoder_ms,
		stream_backend.get_depth_last_inference_ms() if settings.host.ai_3d_speed > 0 else 0.0,
	])

func _process_idle_timeout():
	if not is_streaming or settings.idle_timeout_min <= 0:
		return
	var now = Time.get_ticks_msec() / 1000.0
	if now - _last_activity_time > settings.idle_timeout_min * 60.0:
		_log("[IDLE] Idle timeout (%d min), disconnecting" % settings.idle_timeout_min)
		disconnect_stream()
		# stop_stream() emits stream_terminated synchronously; that callback owns
		# the one full-disconnect cleanup. Calling it again here double-tore down
		# the welcome/composition state.

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		state_manager.save_state()
		video_presentation.shutdown()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_schedule_xr_surface_refresh("application resumed")

func _input(event):
	input_handler.handle_input(event)
	if is_streaming and (event is InputEventMouseButton or event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		_last_activity_time = Time.get_ticks_msec() / 1000.0

func _toggle_ui():
	ui_visible = not ui_visible
	_set_viewport_active(ui_viewport, ui_visible)
	if ui_visible:
		if state_manager:
			state_manager.sync_ui_to_settings()
		_set_ui_position()
		if comp.in_use and composition_panels.has_ui():
			composition_panels.show_ui(ui_panel_3d)
			if RenderingServer.get_current_rendering_method() == "gl_compatibility":
				ui_panel_3d.visible = true
				var ui_material = ui_panel_3d.material_override as StandardMaterial3D
				if ui_material:
					ui_material.albedo_color = Color(1, 1, 1, 0.001)
			else:
				ui_panel_3d.visible = false
			if settings.bezel_enabled:
				comp_bezel_rect.color = Color(0, 0, 0, 0)
				if comp_bezel_rect_left:
					comp_bezel_rect_left.color = Color(0, 0, 0, 0)
				if comp_bezel_rect_right:
					comp_bezel_rect_right.color = Color(0, 0, 0, 0)
		else:
			ui_panel_3d.visible = true
			var ui_material = ui_panel_3d.material_override as StandardMaterial3D
			if ui_material:
				ui_material.albedo_color = Color(1, 1, 1, 1)
			var ui_tex = ui_viewport.get_texture()
			ui_panel_3d.material_override.albedo_texture = ui_tex
		var area = ui_panel_3d.get_node_or_null("Area3D")
		if area:
			area.process_mode = Node.PROCESS_MODE_INHERIT
	else:
		composition_panels.hide_ui()
		var ui_material = ui_panel_3d.material_override as StandardMaterial3D
		if ui_material:
			ui_material.albedo_color = Color(1, 1, 1, 1)
		_save_ui_offset()
		ui_panel_3d.visible = false
		var area = ui_panel_3d.get_node_or_null("Area3D")
		if area:
			area.process_mode = Node.PROCESS_MODE_DISABLED
		if comp.in_use and settings.bezel_enabled:
			comp_bezel_rect.color = Color(0, 0, 0, 1)
			if comp_bezel_rect_left:
				comp_bezel_rect_left.color = Color(0, 0, 0, 1)
			if comp_bezel_rect_right:
				comp_bezel_rect_right.color = Color(0, 0, 0, 1)
	ui_controller.set_disconnect_visible(is_streaming)

var _ui_saved_offset: Vector3 = Vector3.ZERO
var _ui_saved_rot_y: float = 0.0
var _ui_saved_rot_x: float = 0.0
var _ui_has_saved_offset: bool = false

func _anchor_to_primary(node: Node3D, offset: Vector3, rot_y: float, rot_x: float):
	node.global_position = primary_screen.global_position + primary_screen.global_transform.basis * offset
	node.rotation.y = primary_screen.global_rotation.y + rot_y
	node.rotation.x = rot_x

func set_primary_screen(s: VRScreen) -> void:
	if s == primary_screen or not screens.has(s):
		return
	var panels: Array = [ui_panel_3d]
	if virtual_keyboard:
		panels.append(virtual_keyboard)
	var world_transforms := {}
	for p in panels:
		world_transforms[p] = p.global_transform
	if not screen_registry.set_primary(s):
		return
	for screen in screens:
		screen.update_shortcut_positions()
		screen_shortcuts.refresh_visuals(screen)
	for p in panels:
		p.global_transform = world_transforms[p]
		if p == ui_panel_3d:
			_save_ui_offset()
		elif p.has_method("_save_offset"):
			p._save_offset()
	state_manager.save_state()

func _set_ui_position():
	if not is_xr_active:
		return
	if _ui_has_saved_offset:
		_anchor_to_primary(ui_panel_3d, _ui_saved_offset, _ui_saved_rot_y, _ui_saved_rot_x)
	else:
		var offset = Vector3(-1.0, -0.5, 0.8)
		ui_panel_3d.global_position = primary_screen.global_position + primary_screen.global_transform.basis * offset
		var cam_pos = xr_camera.global_position
		var to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
		ui_panel_3d.rotation.y = atan2(to_cam.x, to_cam.z)
		ui_panel_3d.rotation.x = -0.15
		_save_ui_offset()

func _save_ui_offset():
	var scr_basis = primary_screen.global_transform.basis.inverse()
	_ui_saved_offset = scr_basis * (ui_panel_3d.global_position - primary_screen.global_position)
	_ui_saved_rot_y = ui_panel_3d.rotation.y - primary_screen.global_rotation.y
	_ui_saved_rot_x = ui_panel_3d.rotation.x
	_ui_has_saved_offset = true

func _set_ui_visible(vis: bool):
	_set_viewport_active(ui_viewport, vis)
	if not vis and ui_controller:
		ui_controller.clear_tooltip()
	ui_panel_3d.visible = vis
	var area = ui_panel_3d.get_node_or_null("Area3D")
	if area:
		area.process_mode = Node.PROCESS_MODE_INHERIT if vis else Node.PROCESS_MODE_DISABLED
	if is_xr_active and vis:
		if _ui_has_saved_offset:
			_anchor_to_primary(ui_panel_3d, _ui_saved_offset, _ui_saved_rot_y, _ui_saved_rot_x)
		else:
			var offset = Vector3(-1.0, -0.5, 0.8)
			ui_panel_3d.global_position = primary_screen.global_position + primary_screen.global_transform.basis * offset
			var cam_pos = xr_camera.global_position
			var to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
			ui_panel_3d.rotation.y = atan2(to_cam.x, to_cam.z)
			ui_panel_3d.rotation.x = -0.15
			_save_ui_offset()
	elif is_xr_active:
		_save_ui_offset()

func _set_viewport_active(viewport: SubViewport, active: bool):
	if not viewport:
		return
	var wanted = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if viewport.render_target_update_mode != wanted:
		viewport.render_target_update_mode = wanted

func _sync_interaction_viewports():
	# These two cursors are only needed for the separately composited menu and
	# keyboard. Screen pointing uses the cursor embedded in the eye viewports.
	var panel_visible = ui_visible or (virtual_keyboard and virtual_keyboard.visible)
	# Native video does not embed the pointer in a Godot video viewport, so
	# its independently composited cursor texture must keep updating even
	# while the menu and keyboard are hidden.
	var independent_screen_cursor := VideoPresentation.uses_independent_screen_cursor(
		comp.in_use, video_presentation.is_native_active())
	composition_pointers.sync_viewports(
		panel_visible or independent_screen_cursor,
		panel_visible)

func _trigger_haptic(_controller: int, low_freq: int, high_freq: int):
	var strength = clampf((low_freq + high_freq) / 510.0, 0.0, 1.0)
	if strength < 0.01:
		return
	if right_hand:
		right_hand.trigger_haptic_pulse("haptic", strength, 0.05)
	if left_hand:
		left_hand.trigger_haptic_pulse("haptic", strength, 0.05)

func _debug_log_cyl(tag: String):
	var mesh_pos = screen_mesh.global_position if screen_mesh else Vector3.ZERO
	var mesh_rot = screen_mesh.global_rotation if screen_mesh else Vector3.ZERO
	var cam_pos = xr_camera.global_position if xr_camera else Vector3.ZERO
	var cyl_pos = comp_cylinder.global_position if comp_cylinder else Vector3.ZERO
	var cyl_rot = comp_cylinder.global_rotation if comp_cylinder else Vector3.ZERO
	var cyl_vis = comp_cylinder.visible if comp_cylinder else false
	_log("[CYLDBG:%s] cam=%s mesh_pos=%s mesh_rot=%s cyl_pos=%s cyl_rot=%s cyl_vis=%s cyl_radius=%.3f cyl_center=%s" % [
		tag, str(cam_pos), str(mesh_pos), str(mesh_rot), str(cyl_pos), str(cyl_rot), str(cyl_vis), _comp_cyl_radius, str(_comp_cyl_center)
	])

func _reposition_screen_and_ui(use_cam_yaw: bool = true):
	if not is_xr_active:
		return
	var cam_pos = xr_camera.global_position
	var cam_fwd = -xr_camera.global_transform.basis.z
	cam_fwd.y = 0.0
	cam_fwd = cam_fwd.normalized()
	screen_mesh.global_position = cam_pos + cam_fwd * 2.16
	screen_mesh.rotation = Vector3.ZERO
	if use_cam_yaw:
		screen_mesh.rotation.y = atan2(-cam_fwd.x, -cam_fwd.z)
	screen_mesh.apply_curvature()
	# get_cylinder_radius() is camera-position-derived, so any screen curved before
	# this point (e.g. _init_post_xr()'s early best-effort pass, which isn't gated on
	# _startup_reposition confirming a real tracking pose yet) may have baked in a
	# wrong radius - grab_bar/corner geometry is fully recomputed by apply_curvature()
	# each call, so re-running it here with a now-valid camera position is a full fix,
	# not just a partial one. Only screen_mesh's world position/rotation gets moved
	# above (it's the one placed relative to the camera); secondary screens are placed
	# relative to it and must keep their own position/rotation untouched here.
	for s in screens:
		if s != screen_mesh:
			s.apply_curvature()
	if comp_cylinder or comp_cylinder_left:
		_update_cylinder_params()
	_log("[POS] Screen at %s, Cam at %s" % [str(screen_mesh.global_position), str(cam_pos)])
	_debug_log_cyl("reposition")

func _reset_positions():
	if ui_visible:
		_toggle_ui()
	if virtual_keyboard and virtual_keyboard.visible:
		virtual_keyboard.toggle()
	_ui_has_saved_offset = false
	if virtual_keyboard:
		virtual_keyboard.reset_position()
	_reposition_screen_and_ui()
	state_manager.save_state()

func _load_controller_models():
	var left_scene = load("res://models/controllers/MetaQuestTouchPlus_Left.fbx")
	var right_scene = load("res://models/controllers/MetaQuestTouchPlus_Right.fbx")
	if left_scene:
		var left_model = left_scene.instantiate()
		left_hand.add_child(left_model)
		left_model.scale = Vector3(1.0, 1.0, 1.0)
		left_model.rotation = Vector3(0, PI, 0)
		_apply_controller_textures(left_model, true)
	if right_scene:
		var right_model = right_scene.instantiate()
		right_hand.add_child(right_model)
		right_model.scale = Vector3(1.0, 1.0, 1.0)
		right_model.rotation = Vector3(0, PI, 0)
		_apply_controller_textures(right_model, false)

func _set_controller_models_visible(visible_state: bool):
	_set_hand_local_model_visible(right_hand, visible_state)
	_set_hand_local_model_visible(left_hand, visible_state)

# Local FBX fallback model visibility, per-hand - factored out of
# _set_controller_models_visible() (2026-08-25) so the render-model
# experiment can hide just one hand's local model without touching the
# other, e.g. if the runtime only supplies a render model for one
# controller.
func _set_hand_local_model_visible(hand: Node3D, visible_state: bool):
	if not hand:
		return
	for child in hand.get_children():
		if child is Node3D and child.name != "HandRayCast" and child.name != "LeftHandRayCast":
			child.visible = visible_state

# OpenXRFbRenderModel is itself a Node3D that self-tracks the runtime's
# controller pose (confirmed via ClassDB introspection, 2026-08-25) - no
# separate XRController3D wrapper needed, unlike an earlier draft of this
# function. It exposes render_model_type (OpenXRFbRenderModel.MODEL_CONTROLLER_LEFT/
# _RIGHT), has_render_model_node()/get_render_model_node(), and an
# openxr_fb_render_model_loaded signal fired once the runtime actually
# supplies geometry - used below for proper async detection instead of a
# guessed timer delay.
func _setup_render_model_controllers():
	if not ClassDB.class_exists("OpenXRFbRenderModel"):
		_log("[CTRLMODEL] OpenXRFbRenderModel not available in this Godot build")
		return
	# Resolve the vendor enum through ClassDB so the project can still be parsed
	# by a stock Godot editor when the optional vendor binary is not installed.
	var right_model_type := ClassDB.class_get_integer_constant(
		"OpenXRFbRenderModel", "MODEL_CONTROLLER_RIGHT")
	var left_model_type := ClassDB.class_get_integer_constant(
		"OpenXRFbRenderModel", "MODEL_CONTROLLER_LEFT")
	right_render_model = ClassDB.instantiate("OpenXRFbRenderModel")
	right_render_model.name = "RightRenderModel"
	right_render_model.render_model_type = right_model_type
	xr_origin.add_child(right_render_model)
	right_render_model.openxr_fb_render_model_loaded.connect(_on_render_model_loaded.bind(true))

	left_render_model = ClassDB.instantiate("OpenXRFbRenderModel")
	left_render_model.name = "LeftRenderModel"
	left_render_model.render_model_type = left_model_type
	xr_origin.add_child(left_render_model)
	left_render_model.openxr_fb_render_model_loaded.connect(_on_render_model_loaded.bind(false))
	_log("[CTRLMODEL] OpenXRFbRenderModel nodes created, waiting on load signal")

# Fired by OpenXRFbRenderModel once the runtime actually supplies real
# geometry for that hand. Hides the local FBX fallback for just that hand
# (_set_hand_local_model_visible - the render model and the fallback should
# never both be visible at once) and leaves the other hand's fallback alone
# if its render model hasn't loaded (or never will - not every runtime
# supports XR_FB_render_model for every controller).
func _on_render_model_loaded(is_right: bool):
	if is_right:
		_right_render_model_ready = true
		_set_hand_local_model_visible(right_hand, false)
		_log("[CTRLMODEL] Right controller render model loaded")
	else:
		_left_render_model_ready = true
		_set_hand_local_model_visible(left_hand, false)
		_log("[CTRLMODEL] Left controller render model loaded")

# Called from _process() - see the DEBUG_RENDER_MODEL_CONTROLLERS var
# comment for why this only runs in normal (mesh) projection mode. Purely
# visibility gating each frame; the FBX-fallback-hiding decision itself
# happens once, in _on_render_model_loaded() above.
func _process_render_model_controllers(_delta: float):
	if not DEBUG_RENDER_MODEL_CONTROLLERS:
		return
	if right_render_model:
		right_render_model.visible = not comp.in_use and _right_render_model_ready
	if left_render_model:
		left_render_model.visible = not comp.in_use and _left_render_model_ready

func _apply_controller_textures(node: Node, is_left: bool):
	var base_color_path = "res://models/controllers/textures/MetaQuestTouchPlus_Left_BaseColor.png" if is_left else "res://models/controllers/textures/MetaQuestTouchPlus_right_BaseColor.png"
	var base_tex = load(base_color_path)
	if not base_tex:
		return
	for child in node.get_children():
		if child is MeshInstance3D:
			for i in range(child.get_surface_override_material_count()):
				var mat = child.get_surface_override_material(i)
				if not mat:
					mat = child.mesh.surface_get_material(i) if child.mesh else null
				if mat is StandardMaterial3D:
					mat = mat.duplicate()
					mat.albedo_texture = base_tex
					mat.render_priority = 127
					child.set_surface_override_material(i, mat)
				elif mat is BaseMaterial3D:
					mat = mat.duplicate()
					mat.albedo_texture = base_tex
					mat.render_priority = 127
					child.set_surface_override_material(i, mat)
		_apply_controller_textures(child, is_left)

var contact_dot: MeshInstance3D
var left_contact_dot: MeshInstance3D
var pointer_cursor: MeshInstance3D
var left_comp_cursor: MeshInstance3D
var _fade_materials: Dictionary = {"left": [], "right": []}
var _hand_alpha: Dictionary = {"left": 1.0, "right": 1.0}

func _create_contact_dot():
	var shared_mat = StandardMaterial3D.new()
	shared_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shared_mat.albedo_color = Color(1, 1, 1, 0.2)
	shared_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shared_mat.render_priority = 127
	shared_mat.no_depth_test = true

	contact_dot = _make_contact_dot(shared_mat)
	contact_dot.name = "ContactDot"
	add_child(contact_dot)
	left_contact_dot = _make_contact_dot(shared_mat)
	left_contact_dot.name = "LeftContactDot"
	add_child(left_contact_dot)

	pointer_cursor = MeshInstance3D.new()
	pointer_cursor.name = "PointerCursor"
	var ptr_mesh = QuadMesh.new()
	ptr_mesh.size = Vector2(0.06, 0.08)
	pointer_cursor.mesh = ptr_mesh
	var ptr_mat = StandardMaterial3D.new()
	ptr_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ptr_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ptr_mat.render_priority = 127
	ptr_mat.no_depth_test = true
	ptr_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ptr_mat.albedo_texture = load("res://src/assets/mouse_pointer_01.png")
	ptr_mat.albedo_color = Color(1, 1, 1, 1.0)
	pointer_cursor.material_override = ptr_mat
	pointer_cursor.visible = false
	pointer_cursor.extra_cull_margin = 10.0
	add_child(pointer_cursor)

	left_comp_cursor = _make_circle_cursor()
	left_comp_cursor.name = "LeftCompCursor"
	add_child(left_comp_cursor)

func _make_circle_cursor() -> MeshInstance3D:
	var m = MeshInstance3D.new()
	var quad = QuadMesh.new()
	quad.size = Vector2(0.035, 0.035)
	m.mesh = quad
	var tex_size = 64
	var img = Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	var center = Vector2((tex_size - 1) * 0.5, (tex_size - 1) * 0.5)
	var radius = tex_size * 0.42
	var edge = max(tex_size * 0.015, 1.0)
	for x in range(tex_size):
		for y in range(tex_size):
			var d = Vector2(x, y).distance_to(center)
			var t = clampf((d - (radius - edge)) / edge, 0.0, 1.0)
			var alpha = (1.0 - t) * 0.3
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = 127
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.material_override = mat
	m.visible = false
	m.extra_cull_margin = 10.0
	return m

func _make_contact_dot(mat: StandardMaterial3D = null) -> MeshInstance3D:
	var dot = MeshInstance3D.new()
	var m = SphereMesh.new()
	m.radius = 0.015
	m.height = 0.03
	dot.mesh = m
	dot.material_override = mat
	dot.visible = false
	return dot

func _hide_all_backgrounds():
	if bg_manager:
		bg_manager.hide_all()

func _create_backgrounds():
	bg_manager = BackgroundManager.new(self)
	bg_manager.create_backgrounds()

func _create_ash():
	bg_manager._create_ash()

func _create_snow():
	bg_manager._create_snow()

func _create_data():
	bg_manager._create_data()

func _update_hand_indicator_layers():
	composition_hand_indicators.update(
		DEBUG_COMP_HANDS and comp.in_use and is_xr_active and _is_using_hands,
		xr_camera.global_position)

func _update_hand_tracker_transform(hand_node: XRController3D, tracker: XRHandTracker):
	var wrist_ok = (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST) & 8) != 0
	var middle_knuckle_ok = (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL) & 8) != 0
	
	if wrist_ok and middle_knuckle_ok:
		var wrist_trans = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
		var middle_knuckle_pos = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL).origin
		var wrist_pos = wrist_trans.origin
		
		var forward = (middle_knuckle_pos - wrist_pos).normalized()
		var temp_up = wrist_trans.basis.y
		var right = forward.cross(temp_up).normalized()
		var up = right.cross(forward).normalized()
		var basis = Basis(right, up, -forward)
		# Pitch down by 30 degrees for relaxed remote-like aiming
		basis = basis.rotated(right, deg_to_rad(-30))
		hand_node.transform = Transform3D(basis, middle_knuckle_pos)
	elif wrist_ok:
		var t = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
		t.basis = t.basis.rotated(t.basis.y, PI)
		hand_node.transform = t
	else:
		var palm_ok = (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM) & 8) != 0
		if palm_ok:
			var t = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM)
			t.basis = t.basis.rotated(t.basis.y, PI)
			hand_node.transform = t

func _make_laser_gradient() -> ImageTexture:
	var img = Image.create(1, 256, false, Image.FORMAT_RGBA8)
	for y in range(256):
		var a = 1.0 - float(y) / 255.0
		img.set_pixel(0, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
