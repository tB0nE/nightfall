extends Node3D

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
	if tracking_mode != 1:
		return false
	for tracker_name in ["/user/hand_tracker/right", "/user/hand_tracker/left"]:
		var tracker = XRServer.get_tracker(tracker_name)
		if tracker and tracker is XRHandTracker:
			return true
	return false

func get_hand_tracking_has_data() -> bool:
	if tracking_mode != 1:
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
var _connect_timeout_pending: bool = false
var _auto_connect: bool = false
var quick_start_enabled: bool = false
# Whether the host is drawing its own cursor into the captured frame (Polaris-only:
# a POST /polaris/v1/session/cursor endpoint neither Sunshine nor Apollo expose today).
# Support is detected per-connection from the launch response, not guessed up front,
# since a version-string heuristic already burned us once for microphone detection.
var host_cursor_visible: bool = false
var _host_cursor_toggle_supported: bool = false
var _restarting_stream: bool = false
var _did_initial_monitor_trim: bool = false
var _stream_start_seq: int = 0
var is_streaming: bool = false
var sbs_mode: int = 0
# Split (2026-08-18) from a single flat ai_3d_mode into three independent
# axes - see settings_controller.gd's ai_3d_model_labels/ai_3d_quality_labels/
# ai_3d_debug_labels and get_stereo_mode() for how they combine.
var ai_3d_model: int = 0 # 0=Off, 1=MiDaS
var ai_3d_quality: int = 0 # 0=Auto, 1=Fastest, 2=Fast, 3=Standard
var ai_3d_debug: int = 0 # 0=Off, 1=DMap, 2=DMap-Raw, 3=DMap-Input
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
var tracking_mode: int = 0
var tracking_labels: Array = ["Off", "Hands"]
var right_hand_visual: Node3D = null
var left_hand_visual: Node3D = null
var left_hand_raycast: RayCast3D = null
var mouse_captured_by_stream: bool = false
var suppress_input_frames: int = 0
var auto_detect_enabled: bool = false
var auto_detect_timer: float = 0.0
var auto_detect_running: bool = false
var detection_history: Array = []
var mouse_sensitivity: float = 0.002
var grabbed_node: Node3D = null
var pipewire_restore_token: String = ""
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
var grid_mode_enabled: bool = true
var grab_snap_candidate: Vector2i = Vector2i(-1, -1)
var stats_timer: float = 0.0
var stats_fps: float = 0.0
var stats_frame_times: Array = []
var stats_network_events: int = 0
var passthrough_enabled: bool = false
var passthrough_supported: bool = false
var background_mode: int = 0
var background_labels: Array = ["Black", "Starfield", "Ash", "Snow", "Data"]
var bg_names: Array = ["Starfield", "Ash", "Snow", "Data"]
var bg_offsets: Array = [Vector3.ZERO, Vector3.ZERO, Vector3(0, 10, 0), Vector3(0, -3, 0)]
var ui_visible: bool = false
var bezel_enabled: bool = true
var bezel_mesh: MeshInstance3D:
	get: return primary_screen.bezel_mesh if primary_screen else null
	set(v):
		if primary_screen: primary_screen.bezel_mesh = v
var curvature: int:
	get: return primary_screen.curvature if primary_screen else 2
	set(v):
		if primary_screen: primary_screen.curvature = v
var curvature_labels: Array = ["Flat", "Slight Curve", "Curved"]
var smooth_mode: int = 0
var sharpen_mode: int = 0
var smooth_labels: Array = ["0%", "10%", "20%", "30%", "40%", "50%"]
var sharpen_labels: Array = ["0%", "10%", "20%", "30%", "40%", "50%"]
var _xr_base_render_scale: float = 1.0
var _xr_render_width: int = 2064
var _mesh_size: Vector2:
	get: return primary_screen.mesh_size if primary_screen else Vector2(2.24, 1.26)
	set(v):
		if primary_screen: primary_screen.mesh_size = v
var stream_fps: int = 60
var _cached_filter_mode: int = -1
var _cached_sharpen: float = -1.0
var _cached_blur_scale: float = -1.0
# host_resolution is the actual WxH about to be (or last) requested from the
# host - computed as native_resolution * resolution_scale_pct / 100, not set
# directly. It always matches whatever the host's real desktop/composite
# shape is (single monitor or multi-monitor composite alike), instead of a
# fixed target size that would force the host to letterbox/squeeze a
# mismatched-aspect composite to fit.
var host_resolution: Vector2i = Vector2i(1920, 1080)
# Last known real desktop/composite size for the currently selected host, as
# reported by its display manifest (or session_optimization's negotiated
# width/height for hosts without one). Cached per-host in host_state.cfg so a
# repeat connection can request the correctly-scaled resolution on the first
# try instead of needing the mismatch-triggered reconnect every time.
var native_resolution: Vector2i = Vector2i(1920, 1080)
var resolution_scale_pct: int = 100
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
# match - so native_resolution has nothing real to hold for them and the
# percentage system's "MAX"/percent labels would just describe the wrong
# thing (confirmed: reported "1080p" against a real 2560x1440 Sunshine
# display, because native_resolution never left its 1920x1080 fallback).
# Defaults false (the old fixed-list picker) so a host that hasn't been probed
# yet - or a probe that's still in flight - never shows a percentage of a
# guess as if it meant something.
var is_polaris_host: bool = false
# The pre-percentage fixed-resolution picker, used for any non-Polaris host
# (see is_polaris_host above) - the user picks what they actually want
# instead of the client trying to detect anything, matching how Sunshine
# itself expects to be driven. Untouched by the H264/HEVC dimension/pixel
# caps in compute_max_resolution_pct() below - every entry here is well
# under all of those caps on its own (largest is 3840x2160), so there's
# nothing to filter for the single-screen case this picker is used for.
var resolution_idx: int = 1
var resolutions: Array = [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(1600, 1200), Vector2i(3440, 1440)]
var resolution_labels: Array = ["720", "HD", "2K", "4K", "4:3", "21:9"]
var double_h: bool = false
var bitrate_idx: int = -1
var bitrates: Array = [5, 10, 15, 20, 30, 40, 50, 60, 80, 100, 120]
var bitrate_labels: Array = ["Auto", "5", "10", "15", "20", "30", "40", "50", "60", "80", "100", "120"]
var display_refresh_rate: float = 72.0

var cursor_mode: int = 1
var cursor_labels: Array = ["Circle", "Pointer"]
var pointer_steady: int = 1
var pointer_steady_labels: Array = ["Off", "Low", "High"]
var _steady_hit: Vector3 = Vector3.ZERO
var _steady_active: bool = false
var _steady_factor: float = 0.3
var _steady_dead_zone: float = 0.002
var codec_preference: int = 1
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
var screens: Array[VRScreen] = []
var primary_screen: VRScreen = null
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
var virtual_keyboard: VirtualKeyboard
var welcome_screen: WelcomeScreen
var screen_manager: ScreenManager
var settings_controller: SettingsController
var state_manager: StateManager
var controller_mapper: ControllerMapper
var comp: CompositionLayerManager
var bg_manager: BackgroundManager

var comp_cursor: Node3D = null
var comp_ui: Node3D = null
var comp_kb: Node3D = null
var comp_cursor_viewport: SubViewport = null
var left_comp_cursor_layer: Node3D = null
var left_comp_cursor_viewport: SubViewport = null

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

var _log_lines: PackedStringArray = []
var _ui_viewport_size := Vector2i(1200, 580)
var _ui_mesh_size := Vector2(1.20, 0.58)
var _ui_host_label: Label
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
var _ui_3d_btn: Button
var _ui_3d_quality_btn: Button
var _ui_3d_debug_btn: Button
var _ui_res_btn: Button
var _ui_fps_btn: Button
var _ui_bitrate_btn: Button
var _ui_ctrl_type_btn: Button
var _ui_btn_toggle_btn: Button
var _ui_primary_btn: Button
var _ui_quick_start_btn: Button
var _ui_host_cursor_btn: Button
var _ui_render_btn: Button
var _ui_sharpen_btn: Button
var _ui_ctrl_mode_btn: Button
var _ui_cursor_btn: Button
var _ui_steady_btn: Button
var _ui_codec_btn: Button
var auto_reconnect_enabled: bool = true
var _reconnecting: bool = false
var idle_timeout_min: int = 0
var _last_activity_time: float = 0.0
var _ui_idle_btn: Button
var _ui_reconnect_btn: Button
var _ui_exit_btn: Button
var _ui_disconnect_btn: Button
var _ui_close_btn: Button
var _ui_center_btn: Button

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
# docs/multi-monitor-encode-budget-and-layout.md): HEVC on this hardware is
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

# Extra resolution ceilings applied only while MiDaS-Fast/-Fastest are the
# active stereo mode (2026-08-18) - unlike every knob AI-3D's own pipeline
# exposes (pre-pass resolution/throttle, Newton-refinement cadence, depth-
# capture throttle), none of which moved FPS at 4K when tested, capping the
# actual decoded/composited stream size directly attacks the real cost:
# general per-pixel video decode + compositing work, which scales with
# resolution regardless of AI-3D. MiDaS-Std is intentionally NOT capped here -
# it stays the uncapped/known-good reference. See compute_requested_resolution().
#
# History: capped both tiers, then MiDaS-Fast/-Fastest's 3D quality looked
# visibly worse than MiDaS-Std. [DEPTH]-tagged logging in depth_estimator.gd
# ruled out the depth pipeline itself (capture/submission/polling equally
# healthy across all tiers) and the bitrate cliff bug (fixed separately,
# stream_manager.gd's _auto_bitrate() now scales from the UNCAPPED
# resolution). Root cause found 2026-08-18: these caps were width/height
# pairs, aspect-scaled with min(target_w/w, target_h/h) - on a WIDE source
# (native_resolution here is a 2.96:1 multi-monitor composite, not 16:9),
# the width dimension binds first, so "cap to 2560x1440" actually produced
# 2560x864 (2.21M px) instead of the 3.69M px the "1440p" label implied -
# confirmed directly: manually selecting 1440p and letting Fastest's cap
# reduce down to "1440p" were NOT delivering the same pixel count at all,
# despite looking like they should be equal. Fixed by capping to a total
# PIXEL BUDGET via sqrt(target_px/actual_px) instead of a width/height pair
# - same approach this file already uses for HEVC_MAX_TOTAL_PIXELS just
# below, which doesn't have this problem because it already works in pixels.
const MIDAS_RES_CAP_ENABLED := true
const MIDAS_FAST_MAX_PIXELS := 3200 * 1800
const MIDAS_FASTEST_MAX_PIXELS := 2560 * 1440

# The highest resolution_scale_pct that keeps compute_requested_resolution()'s
# result under every constraint that applies to the given codec at the
# current native_resolution, i.e. the point past which compute_requested_resolution()
# would otherwise silently downscale further than the requested percentage
# implied. Used to build the UI's resolution option list (compute_resolution_options())
# so a user can never select a percentage compute_requested_resolution() would
# have quietly overridden anyway.
func compute_max_resolution_pct(codec: int) -> int:
	if native_resolution.x <= 0 or native_resolution.y <= 0:
		return 100
	var nw = float(native_resolution.x)
	var nh = float(native_resolution.y)
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
	var max_pct = compute_max_resolution_pct(codec_preference)
	var opts: Array = [max_pct]
	for p in RESOLUTION_PRESETS:
		if p < max_pct:
			opts.append(p)
	return opts

func compute_requested_resolution(apply_midas_cap: bool = true) -> Vector2i:
	var w: int
	var h: int
	if is_polaris_host:
		w = int(native_resolution.x * resolution_scale_pct / 100.0)
		h = int(native_resolution.y * resolution_scale_pct / 100.0)
	else:
		var res: Vector2i = resolutions[resolution_idx]
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
	if codec_preference == 0 and (w > H264_MAX_DIMENSION or h > H264_MAX_DIMENSION):
		var scale = minf(float(H264_MAX_DIMENSION) / w, float(H264_MAX_DIMENSION) / h)
		w = int(w * scale)
		h = int(h * scale)
	elif codec_preference == 1:
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
	# MiDaS-Fast/-Fastest only - see MIDAS_FAST_MAX_PIXELS's comment above.
	# Keyed off the actually-active stereo mode (accounts for sbs_mode
	# overriding ai_3d_model/quality/debug, same as
	# settings_controller.get_stereo_mode() itself), not those raw fields
	# directly. Caps by total pixel budget (like
	# HEVC_MAX_TOTAL_PIXELS above), NOT a width/height pair scaled by
	# min(target_w/w, target_h/h) - that approach silently delivered far
	# fewer pixels than intended on a non-16:9 source (see history above).
	# apply_midas_cap=false lets a caller ask "what would this resolution be
	# WITHOUT the AI-3D cap" - see stream_manager.gd's start_stream(), which
	# uses that to pick Auto bitrate from the uncapped resolution instead of
	# the capped encode resolution (same bitrate, fewer pixels should mean
	# MORE bits per pixel, not fewer).
	if apply_midas_cap and MIDAS_RES_CAP_ENABLED and settings_controller:
		var stereo_mode = settings_controller.get_stereo_mode()
		var max_pixels := 0
		if stereo_mode == 10:
			max_pixels = MIDAS_FAST_MAX_PIXELS
		elif stereo_mode == 11:
			max_pixels = MIDAS_FASTEST_MAX_PIXELS
		if max_pixels > 0 and w * h > max_pixels:
			var cap_scale = sqrt(float(max_pixels) / float(w * h))
			w = int(w * cap_scale)
			h = int(h * cap_scale)
	w = maxi(w - (w % 2), 320)
	h = maxi(h - (h % 2), 180)
	return Vector2i(w, h)

func _log(msg: String):
	_log_lines.append(msg)
	push_warning("NF: %s" % msg)

func _flush_log():
	var f = FileAccess.open("user://debug.log", FileAccess.WRITE)
	if f:
		for line in _log_lines:
			f.store_line(line)
		f.close()

func _setup_comp_layer():
	comp = CompositionLayerManager.new(self)
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
	return (s.uv_region.z * float(stream_viewport.size.x)) / float(_xr_render_width)

func _get_steady_hit(raw: Vector3) -> Vector3:
	if pointer_steady == 0 or not is_xr_active:
		_steady_active = false
		return raw
	if not _steady_active:
		_steady_hit = raw
		_steady_active = true
		return raw
	var factor := 0.3 if pointer_steady == 1 else 0.1
	var dead_zone := 0.002 if pointer_steady == 1 else 0.005
	var delta = raw - _steady_hit
	if delta.length() < dead_zone:
		return _steady_hit
	_steady_hit = _steady_hit.lerp(raw, factor)
	return _steady_hit

func _get_cylinder_normal_at(hit_point: Vector3) -> Vector3:
	return primary_screen.get_cylinder_normal_at(hit_point)

func _hit_point_to_uv(hit_point: Vector3) -> Vector2:
	return primary_screen.hit_point_to_uv(hit_point)

func _show_stream_cursor(cursor: TextureRect, circle: ColorRect, cx: float, cy: float, cursor_px: int):
	if cursor_mode == 0:
		if cursor: cursor.visible = false
		if circle:
			circle.visible = true
			circle.position = Vector2(cx - cursor_px * 0.5, cy - cursor_px * 0.5)
			circle.size = Vector2(cursor_px, cursor_px)
	else:
		if circle: circle.visible = false
		if cursor:
			cursor.visible = true
			cursor.position = Vector2(cx, cy)
			cursor.size = Vector2(cursor_px, cursor_px * 1.6)

func _hide_stream_cursor(cursor: TextureRect, circle: ColorRect):
	if cursor: cursor.visible = false
	if circle: circle.visible = false

func _hide_all_stream_cursors():
	for s in screens:
		_hide_stream_cursor(s.comp_stream_cursor, s.comp_stream_cursor_circle)
		_hide_stream_cursor(s.comp_stream_cursor_left, s.comp_stream_cursor_circle_left)
		_hide_stream_cursor(s.comp_stream_cursor_right, s.comp_stream_cursor_circle_right)

func _update_cursor_layer():
	if not comp_cursor or not comp.in_use:
		if comp_cursor:
			comp_cursor.visible = false
		_hide_all_stream_cursors()
		return
	var active_raycast = xr_interaction.get_active_raycast() if xr_interaction else (hand_raycast if is_xr_active else mouse_raycast)
	var on_screen = false
	var pad_on_screen = controller_mapper and controller_mapper.is_active() and controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD
	var tp_capturing = virtual_keyboard and virtual_keyboard.visible and virtual_keyboard.trackpad_active
	var stereo = settings_controller.get_stereo_mode() if settings_controller else 0
	var use_in_stream = is_streaming and on_screen and not pad_on_screen and not tp_capturing
	var hovered_screen: VRScreen = null
	if active_raycast.is_colliding():
		var hit_point = _get_steady_hit(active_raycast.get_collision_point())
		var col = active_raycast.get_collider()
		var t = PointerTarget.resolve(col) if col else {"role": &""}
		on_screen = (t.role == &"screen")
		hovered_screen = t.screen if on_screen else null
		use_in_stream = is_streaming and on_screen and not pad_on_screen and not tp_capturing
		if on_screen and (pad_on_screen or tp_capturing):
			comp_cursor.visible = false
			_hide_all_stream_cursors()
		elif use_in_stream and on_screen:
			# Only hovered_screen gets shown below - explicitly hide every other
			# screen's cursor the instant the hover target changes, rather than
			# leaving whichever screen was PREVIOUSLY hovered showing its last
			# cursor position until something else happens to call
			# _hide_all_stream_cursors() (e.g. the ray briefly leaving every
			# screen entirely) - that gap is what let two cursors show at once
			# when moving straight from one screen to another.
			for s in screens:
				if s != hovered_screen:
					_hide_stream_cursor(s.comp_stream_cursor, s.comp_stream_cursor_circle)
					_hide_stream_cursor(s.comp_stream_cursor_left, s.comp_stream_cursor_circle_left)
					_hide_stream_cursor(s.comp_stream_cursor_right, s.comp_stream_cursor_circle_right)
			var uv = hovered_screen.hit_point_to_uv(hit_point)
			var bezel_px = 8 if bezel_enabled else 0
			var base_w = hovered_screen.comp_base_size.x
			var base_h = hovered_screen.comp_base_size.y
			# cx/cy position the cursor in the comp viewport's own pixel space,
			# which is sized to the real stream resolution - a fixed pixel size
			# here shrinks/grows on screen as that resolution changes. Scale
			# against a 1080p baseline instead (same approach as the loading dots).
			var cursor_px = maxi(1, int(48.0 * base_h / 1080.0))
			var cx = bezel_px + uv.x * base_w
			var cy = bezel_px + uv.y * base_h
			comp_cursor.visible = false
			_show_stream_cursor(hovered_screen.comp_stream_cursor, hovered_screen.comp_stream_cursor_circle, cx, cy, cursor_px)
			if stereo > 0 and hovered_screen == primary_screen:
				var left_cx = cx
				if stereo == 5 or stereo == 6 or stereo == 10 or stereo == 11:
					# This hand-tuned pop was calibrated against the old, much
					# weaker mode 3/4 warp (parallax ~0.042) - scaled down by
					# the same ratio for the real occlusion-aware warp's
					# actual, much smaller calibrated parallax
					# (depth_estimator.gd's _pass_parallax, ~0.006) rather
					# than reused verbatim, or the cursor pops far more than
					# anything actually in the depth-warped video. Modes
					# 5/6/10/11 (MiDaS-Std/-Fast/-Fastest) all share the
					# exact same warp pipeline/parallax magnitude - only the
					# pre-pass resolution/throttling differs between them
					# (see depth_estimator.gd's warp_tier), not the parallax
					# itself. 10/11 were missing from this condition
					# (2026-08-18 fix) and fell through to the elif below,
					# getting the old crude mode's un-scaled offset - about
					# 7x too large for their actual warp magnitude, which is
					# what made the cursor "float" uncomfortably on the
					# tiers most people actually use.
					left_cx += (0.015 / 0.042) * depth_estimator._pass_parallax * base_w
				elif stereo >= 3:
					left_cx += 0.015 * base_w
				_show_stream_cursor(hovered_screen.comp_stream_cursor_left, hovered_screen.comp_stream_cursor_circle_left, left_cx, cy, cursor_px)
				_show_stream_cursor(hovered_screen.comp_stream_cursor_right, hovered_screen.comp_stream_cursor_circle_right, cx, cy, cursor_px)
			else:
				_hide_stream_cursor(hovered_screen.comp_stream_cursor_left, hovered_screen.comp_stream_cursor_circle_left)
				_hide_stream_cursor(hovered_screen.comp_stream_cursor_right, hovered_screen.comp_stream_cursor_circle_right)
		else:
			_hide_all_stream_cursors()
			var surf_normal = _get_cylinder_normal_at(hit_point) if on_screen else (xr_camera.global_position - hit_point).normalized()
			var to_cam = (xr_camera.global_position - hit_point).normalized()
			var screen_dist = xr_camera.global_position.distance_to(screen_mesh.global_position)
			var cursor_dist = xr_camera.global_position.distance_to(hit_point)
			var dist_scale = cursor_dist / screen_dist
			var pointer = comp_cursor_viewport.get_node_or_null("PointerTexture")
			var circle = comp_cursor_viewport.get_node_or_null("CircleTexture")
			var cursor_size = 0.035 * dist_scale if on_screen else 0.035
			if cursor_mode == 0:
				if pointer: pointer.visible = false
				if circle: circle.visible = true
				comp_cursor_viewport.size = Vector2i(256, 256)
				comp_cursor.set_quad_size(Vector2(cursor_size, cursor_size))
				comp_cursor.global_position = hit_point + surf_normal * 0.002
				comp_cursor.look_at(comp_cursor.global_position + to_cam, Vector3.UP)
				comp_cursor.rotate_object_local(Vector3.UP, PI)
			elif on_screen:
				if pointer: pointer.visible = true
				if circle: circle.visible = false
				comp_cursor_viewport.size = Vector2i(40, 64)
				comp_cursor.set_quad_size(Vector2(0.04 * dist_scale, 0.064 * dist_scale))
				comp_cursor.global_position = hit_point + surf_normal * 0.002
				comp_cursor.look_at(comp_cursor.global_position + to_cam, Vector3.UP)
				comp_cursor.rotate_object_local(Vector3.UP, PI)
				var right = comp_cursor.global_transform.basis.x
				var up = comp_cursor.global_transform.basis.y
				comp_cursor.global_position += right * 0.02 - up * 0.032
			else:
				if pointer: pointer.visible = false
				if circle: circle.visible = true
				comp_cursor_viewport.size = Vector2i(256, 256)
				comp_cursor.set_quad_size(Vector2(0.035, 0.035))
				comp_cursor.global_position = hit_point + surf_normal * 0.002
				comp_cursor.look_at(comp_cursor.global_position + to_cam, Vector3.UP)
				comp_cursor.rotate_object_local(Vector3.UP, PI)
			comp_cursor.visible = true
	else:
		comp_cursor.visible = false
		_hide_all_stream_cursors()
	if pointer_cursor:
		pointer_cursor.visible = false
	if contact_dot:
		contact_dot.visible = false
	if comp_ui and comp_ui.visible:
		comp_ui.global_position = ui_panel_3d.global_position
		comp_ui.global_rotation = ui_panel_3d.global_rotation
	if comp_kb and virtual_keyboard and virtual_keyboard.visible:
		comp_kb.global_position = virtual_keyboard.global_position
		comp_kb.global_rotation = virtual_keyboard.global_rotation
		comp_kb.visible = true
		if virtual_keyboard.mesh_instance.visible:
			_make_kb_transparent()
	else:
		if comp_kb:
			comp_kb.visible = false
		if virtual_keyboard and not virtual_keyboard.mesh_instance.visible:
			_restore_kb_material()

func set_comp_grab_bar_color(viewport: SubViewport, color: Color):
	CompositionLayerManager.set_grab_bar_color(viewport, color)

func exit_app():
	get_tree().quit()

func disconnect_stream():
	if current_host_id >= 0:
		stream_backend.cancel_host_stream(current_host_id)
	stream_backend.stop_play_stream()

func start_connect_timeout():
	_connect_timeout_pending = true
	get_tree().create_timer(10.0).timeout.connect(_on_connect_timeout)

func _on_connect_timeout():
	if not _connect_timeout_pending:
		return
	_connect_timeout_pending = false
	_log("[CONNECT] Connection timed out")
	ui_controller.set_status("Failed to connect (timeout)")
	welcome_screen.reset_connect_button()
	stream_backend.stop_play_stream()

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
	var was_restarting = _restarting_stream
	is_streaming = true
	_restarting_stream = false
	_connect_timeout_pending = false
	_reconnecting = false
	_last_activity_time = Time.get_ticks_msec() / 1000.0
	ui_controller.set_status("Connecting...")
	ui_controller.update_host_label()
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
		if comp_ui:
			comp_ui.visible = false
	if passthrough_enabled:
		_hide_all_backgrounds()
	var all_btn_flags = 0x1000|0x2000|0x4000|0x8000|0x0001|0x0002|0x0004|0x0008|0x0100|0x0200|0x0010|0x0020|0x0040|0x0080|0x0400
	stream_backend.send_controller_arrival(0, 1, 1, all_btn_flags, 0x01|0x02)

	# The host's real desktop can be a very different shape than native_resolution
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
				native_resolution = primary_m.frame_rect.size
			host_resolution = compute_requested_resolution()
			settings_controller.refresh_resolution_btn_label()
			stream_manager._resolution_retry_done = true
			var retry_host_id = current_host_id
			var retry_app_id = _selected_app_id
			var retry_resolution = host_resolution
			_log("[LAYOUT] Trimming to primary-only on first connect (host defaulted to %d monitors)" % enabled_at_connect.size())
			_restarting_stream = true
			_clear_comp_yuv_textures()
			await get_tree().process_frame
			await get_tree().process_frame
			stream_backend.stop_play_stream()
			await get_tree().create_timer(0.5).timeout
			stream_manager.start_stream(retry_host_id, retry_app_id, retry_resolution)
			return

	# Polaris-only: this whole comparison is "does the manifest-reported real
	# desktop size match what native_resolution assumed" - meaningless (and,
	# confirmed live, actively harmful) for any host that never populates a
	# real manifest, since layout.frame_size then never reflects this actual
	# connection at all. Against a Sunshine host this fired repeatedly every
	# single connect, restarting over and over chasing a comparison that could
	# never converge - each restart also being a real cost (see
	# stream_connection.cpp's deferred-free GPU resource queue).
	if is_polaris_host and layout and layout.frame_size != Vector2i.ZERO and layout.frame_size != native_resolution:
		native_resolution = layout.frame_size
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
				str(layout.frame_size), str(retry_resolution), resolution_scale_pct])
			_restarting_stream = true
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
	_log("[NF] _on_stream_terminated: auto=" + str(_auto_connect) + " restarting=" + str(_restarting_stream) + " reconnecting=" + str(_reconnecting) + " msg=" + str(msg) + " err=" + str(err_code))
	if _auto_connect:
		_auto_connect = false
		return
	if _restarting_stream:
		is_streaming = false
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
	if auto_reconnect_enabled and err_code != 0:
		_log("[RECONNECT] Keeping stream alive for auto-reconnect")
		is_streaming = false
		ui_controller.set_status("Connection lost, reconnecting...")
		return
	_reconnecting = false
	is_streaming = false
	_full_disconnect_cleanup("Disconnected: " + str(msg))

func _full_disconnect_cleanup(status_msg: String):
	_connect_timeout_pending = false
	_server_codec_support = {}
	_host_cursor_toggle_supported = false
	ui_controller.update_codec_btn()
	ui_controller.update_host_cursor_btn_state()
	ui_controller.set_status(status_msg)
	ui_controller.set_disconnect_visible(false)
	_log("[STREAM] Full disconnect: %s" % status_msg)
	welcome_screen.show_welcome_screen("welcome")
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
	if comp_ui:
		comp_ui.visible = false
	welcome_screen.reset_connect_button()
	settings_controller.apply_passthrough(passthrough_enabled)
	welcome_screen.update_welcome_info()
	stream_manager.resize_stream_viewport(1920, 1080)

func _clear_comp_yuv_textures():
	comp.clear_yuv_textures()

func _ready():
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
	_init_backgrounds_and_comp_layer()
	await get_tree().create_timer(0.5).timeout
	screen_mesh.extra_cull_margin = 10.0
	ui_panel_3d.extra_cull_margin = 10.0
	_init_post_xr()
	_init_textures_and_ui()

	if _auto_connect or quick_start_enabled:
		_try_auto_connect()

	Input.joy_connection_changed.connect(func(device, connected):
		_on_joy_changed(device, connected)
	)

	if right_hand:
		right_hand.pose = "aim"
	if left_hand:
		left_hand.pose = "aim"

	_post_ready_check.call_deferred()

func _init_modules():
	stream_manager = StreamManager.new(self)
	xr_interaction = XRInteraction.new(self)
	input_handler = InputHandler.new(self)
	ui_controller = UIController.new(self)
	auto_detect = AutoDetect.new(self)
	depth_estimator = DepthEstimatorModule.new(self)
	welcome_screen = WelcomeScreen.new(self)
	screen_manager = ScreenManager.new(self)
	settings_controller = SettingsController.new(self)
	state_manager = StateManager.new(self)
	controller_mapper = ControllerMapper.new(self)
	add_child(controller_mapper)

func _init_android_setup():
	if OS.get_name() == "Android":
		# Must run BEFORE _init_backgrounds_and_comp_layer() creates
		# comp_viewport_left/right - depth_estimator's upsample/offset
		# SubViewports (stereo_mode 5) produce the warp data those actually-
		# displayed per-eye viewports consume every frame (via
		# yuv_display.gdshader), and Godot updates SubViewports in scene-tree
		# order, so the producer must be added to the tree first. (The
		# upsample pass used to also depend on comp_viewport - the OPPOSITE
		# direction - which was the real source of a stutter/double-image
		# bug; that dependency was removed by having it decode YUV directly
		# instead, see depth_upsample.gdshader.)
		depth_estimator.setup()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_load_controller_models()
		_prepare_fade_materials("right")
		_prepare_fade_materials("left")
	sbs_mode = clampi(sbs_mode, 0, 2)
	ai_3d_model = clampi(ai_3d_model, 0, 1)
	ai_3d_quality = clampi(ai_3d_quality, 0, 3)
	ai_3d_debug = clampi(ai_3d_debug, 0, 3)

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

	right_hand_visual = _create_hand_visualizer(false)
	left_hand_visual = _create_hand_visualizer(true)

func _init_ui():
	virtual_keyboard = VirtualKeyboard.new(self)
	add_child(virtual_keyboard)
	virtual_keyboard.build()

	screen_mesh.setup(self, &"m0")
	screens = [screen_mesh]
	primary_screen = screen_mesh
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

	%IPInput.gui_input.connect(func(e): ui_controller.on_ipinput_gui_input(e))
	ui_controller.setup_numpad()
	ui_controller.refresh_ui_buttons()

const VR_SCREEN_SCENE := preload("res://src/vr_screen.tscn")
const MAX_SCREENS := 4
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
	if screens.size() >= MAX_SCREENS:
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
	screen_manager.create_bezel_for(s)
	s.apply_curvature()
	if comp.available:
		comp.setup_screen(s, with_stereo)
		if is_streaming and stream_viewport:
			var stream_size = stream_viewport.size
			if stream_size.x > 0 and stream_size.y > 0:
				s.comp_viewport.size = stream_size
				s.comp_base_size = stream_size
	screens.append(s)
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
			screens.remove_at(i)
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
	v2_node.set_auto_reconnect(auto_reconnect_enabled)
	v2_node.set_max_reconnect_attempts(5)
	v2_node.set_reconnect_delay_ms(2000)
	stream_backend = StreamBackend.new(v2_node)
	stream_backend.set_config_manager(config_mgr)
	stream_backend.set_computer_manager(comp_mgr)
	_client_codec_support = stream_backend.probe_all_video_formats()
	_log("[CODEC] Client support: h264=%s hevc=%s av1=%s raw=%s" % [
		str(_client_codec_support.get("h264", false)),
		str(_client_codec_support.get("hevc", false)),
		str(_client_codec_support.get("av1", false)),
		str(_client_codec_support.get("raw", true))])
	v2_node.pair_completed.connect(func(s, m): stream_manager.on_pair_completed(s, m))
	v2_node.stream_started.connect(func():
		_on_stream_started()
	)
	v2_node.stream_terminated.connect(func(err_code, err_msg):
		_on_stream_terminated(err_msg, err_code)
	)
	if v2_node.has_signal("restore_token_updated"):
		v2_node.restore_token_updated.connect(func(tok):
			_log("[PORTAL] Storing new restore token: " + tok)
			pipewire_restore_token = tok
			state_manager.save_state()
		)
	if v2_node.has_signal("reconnect_scheduled"):
		v2_node.reconnect_scheduled.connect(func(attempt, max_attempts, delay_ms):
			_reconnecting = true
			ui_controller.set_status("Reconnecting %d/%d in %ds..." % [attempt, max_attempts, delay_ms / 1000])
			_log("[RECONNECT] Attempt %d/%d in %dms" % [attempt, max_attempts, delay_ms])
		)
	if v2_node.has_signal("reconnect_failed"):
		v2_node.reconnect_failed.connect(func():
			_reconnecting = false
			_log("[RECONNECT] All attempts failed")
			_full_disconnect_cleanup("Reconnect failed")
		)
	if v2_node.has_signal("h264_hw_upgraded"):
		v2_node.h264_hw_upgraded.connect(func():
			_bind_yuv_textures()
			_log("[H264] HW upgrade: re-bound YUV textures for NV12")
		)
	if v2_node.has_signal("controller_rumble"):
		v2_node.controller_rumble.connect(func(controller, low_freq, high_freq):
			_trigger_haptic(controller, low_freq, high_freq)
		)
	if v2_node.has_signal("controller_trigger_rumble"):
		v2_node.controller_trigger_rumble.connect(func(controller, left_motor, right_motor):
			_trigger_haptic(controller, left_motor, right_motor)
		)
	v2_node.log_message.connect(func(msg):
		if "dropped" in msg or "Unrecoverable" in msg or "Waiting for IDR" in msg:
			stats_network_events += 1
	)

func _init_xr(interface):
	var render_size = interface.get_render_target_size()
	_xr_render_width = int(render_size.x)
	_log("[XR] OpenXR render target: %dx%d" % [render_size.x, render_size.y])
	_log("[XR] Blend modes: %s" % str(interface.get_supported_environment_blend_modes()))

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
	sbs_mode = 0
	ai_3d_model = 0

	settings_controller.apply_display_refresh_rate()

func _on_user_presence_changed(is_present: bool):
	# Only the welcome screen depends on this - once actually streaming, the
	# real video texture bindings are already refreshed by their own paths
	# (_on_stream_started() et al) and re-running connect_welcome_texture()
	# here would incorrectly stomp them back to the welcome viewport.
	if is_present and comp and comp.available and not is_streaming:
		comp.connect_welcome_texture()

func _init_backgrounds_and_comp_layer():
	_create_backgrounds()
	_screen_mesh_original_mat = screen_mesh.material_override
	_setup_comp_layer()
	comp.connect_welcome_texture()

func _init_post_xr():
	state_manager.load_state()

	if comp.available:
		_switch_to_comp_layer()

	settings_controller.apply_passthrough(passthrough_enabled)

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
			if saved_ip != "":
				%IPInput.text = saved_ip
				state_manager.load_host_state(saved_ip)
				for h in config_mgr.get_hosts():
					if h.has("localaddress") and h.localaddress == saved_ip:
						current_host_id = h.id
						break
				if current_host_id >= 0:
					settings_controller.detect_polaris_host(saved_ip, current_host_id)
				ui_controller.update_host_label()
				welcome_screen.update_welcome_info()

	stream_manager.bind_texture()
	if screen_mesh.material_override is ShaderMaterial:
		screen_mesh.material_override.set_shader_parameter("main_texture", welcome_viewport.get_texture())
	comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var _wt = welcome_viewport.get_texture()

	stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	ui_controller.update_ui()
	ui_controller.update_stereo_shader()

func _try_auto_connect():
	var saved_ip = %IPInput.text
	var v2_cm = stream_backend.get_config_manager()
	if v2_cm:
		var v2_hosts = v2_cm.get_hosts()
		if v2_hosts.size() > 0:
			var h: Dictionary = {}
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
				_auto_connect = false
				await get_tree().create_timer(1.0).timeout
				stream_manager.start_stream(host_id, _selected_app_id)

func _post_ready_check():
	await get_tree().create_timer(0.5).timeout



func _on_joy_changed(device: int, connected: bool):
	pass

func _process(delta):
	if is_xr_active:
		_process_hand_tracking(delta)

	if Engine.get_frames_drawn() % 120 == 0:
		_flush_log()

	_process_button_input()

	if right_click_cooldown > 0.0:
		right_click_cooldown -= delta

	_process_input_release()

	xr_interaction.process_pointer_frame(delta)
	xr_interaction.handle_scroll()
	_update_cursor_layer()

	_process_idle_activity()

	_process_background_follow()

	auto_detect.process(delta)

	if depth_estimator:
		depth_estimator.process(delta)
		if depth_estimator.depth_texture and ai_3d_model > 0 and comp.in_use:
			var dt = depth_estimator.depth_texture
			if comp_shader_mat_left and not comp_shader_mat_left.get_shader_parameter("depth_texture"):
				comp_shader_mat_left.set_shader_parameter("depth_texture", dt)
			if comp_shader_mat_right and not comp_shader_mat_right.get_shader_parameter("depth_texture"):
				comp_shader_mat_right.set_shader_parameter("depth_texture", dt)

	_process_stats(delta)

	_process_idle_timeout()

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

const HAND_REST_THRESHOLD := 2.0
var right_hand_resting: bool = false
var left_hand_resting: bool = false

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
	_apply_hand_rest("right", xr_interaction._right_inactive_time >= HAND_REST_THRESHOLD)
	_apply_hand_rest("left", xr_interaction._left_inactive_time >= HAND_REST_THRESHOLD)

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
			_log("[INPUT] Hand Tracking active, hiding controller models")
			_set_controller_models_visible(false)
		else:
			_log("[INPUT] Controllers active, showing controller models")
			_set_controller_models_visible(true)

	if _is_using_hands:
		var right_tracker = XRServer.get_tracker("/user/hand_tracker/right")
		var left_tracker = XRServer.get_tracker("/user/hand_tracker/left")
		if right_tracker:
			_update_hand_tracker_transform(right_hand, right_tracker)
			_update_hand_visualizer(right_hand_visual, right_tracker)
		if left_tracker:
			_update_hand_tracker_transform(left_hand, left_tracker)
			_update_hand_visualizer(left_hand_visual, left_tracker)
	else:
		if right_hand_visual: right_hand_visual.visible = false
		if left_hand_visual: left_hand_visual.visible = false
	if Engine.get_frames_drawn() % 90 == 0:
		_log("[INPUT-DEBUG] HandsActive: %s, RightHand tracker: %s, pos: %s, rot: %s" % [
			str(_is_using_hands),
			str(right_hand.tracker),
			str(right_hand.global_position),
			str(right_hand.global_rotation)
		])

func _process_button_input():
	if not is_xr_active:
		return
	if not controller_mapper or not controller_mapper.is_active():
		var b_pressed = right_hand.is_button_pressed("by_button")
		if b_pressed and not _was_b_pressed:
			_toggle_ui()
		_was_b_pressed = b_pressed
		var a_pressed = right_hand.is_button_pressed("ax_button")
		if a_pressed and not _was_a_pressed:
			virtual_keyboard.toggle()
		_was_a_pressed = a_pressed
		var r_stick_click = right_hand.is_button_pressed("primary_click")
		var l_stick_click = left_hand.is_button_pressed("primary_click") if left_hand else false
		if r_stick_click and not _was_r_stick_click and not l_stick_click:
			var tp_exited = virtual_keyboard and virtual_keyboard.thumbstick_exit_flag
			if not virtual_keyboard or (not virtual_keyboard.trackpad_active and not tp_exited):
				settings_controller.cycle_sbs_mode()
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
	if not is_streaming or idle_timeout_min <= 0:
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

func _process_stats(delta):
	if not is_streaming:
		return
	if comp.in_use:
		var cur_filter = smooth_mode
		var cur_sharpen = float(sharpen_mode) * 0.5
		var cur_blur_scale = get_blur_scale(primary_screen)
		if cur_filter != _cached_filter_mode or cur_sharpen != _cached_sharpen or cur_blur_scale != _cached_blur_scale:
			_cached_filter_mode = cur_filter
			_cached_sharpen = cur_sharpen
			_cached_blur_scale = cur_blur_scale
			settings_controller.apply_filter()
	stats_frame_times.append(delta)
	stats_timer += delta
	if stats_timer >= 0.5:
		var avg = 0.0
		for t in stats_frame_times:
			avg += t
		if stats_frame_times.size() > 0:
			avg /= stats_frame_times.size()
		stats_fps = 1.0 / avg if avg > 0 else 0.0
		stream_manager.update_stats()
		stats_timer = 0.0
		stats_frame_times.clear()

func _process_idle_timeout():
	if not is_streaming or idle_timeout_min <= 0:
		return
	var now = Time.get_ticks_msec() / 1000.0
	if now - _last_activity_time > idle_timeout_min * 60.0:
		_log("[IDLE] Idle timeout (%d min), disconnecting" % idle_timeout_min)
		disconnect_stream()
		_full_disconnect_cleanup("Idle timeout")

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		state_manager.save_state()

func _input(event):
	input_handler.handle_input(event)
	if is_streaming and (event is InputEventMouseButton or event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		_last_activity_time = Time.get_ticks_msec() / 1000.0

func _toggle_ui():
	ui_visible = not ui_visible
	if ui_visible:
		if state_manager:
			state_manager.sync_ui_to_settings()
		_set_ui_position()
		if comp.in_use:
			if comp_ui:
				comp_ui.visible = true
				comp_ui.global_position = ui_panel_3d.global_position
				comp_ui.global_rotation = ui_panel_3d.global_rotation
			ui_panel_3d.visible = false
			if bezel_enabled:
				comp_bezel_rect.color = Color(0, 0, 0, 0)
				if comp_bezel_rect_left:
					comp_bezel_rect_left.color = Color(0, 0, 0, 0)
				if comp_bezel_rect_right:
					comp_bezel_rect_right.color = Color(0, 0, 0, 0)
		else:
			ui_panel_3d.visible = true
			var ui_tex = ui_viewport.get_texture()
			ui_panel_3d.material_override.albedo_texture = ui_tex
		var area = ui_panel_3d.get_node_or_null("Area3D")
		if area:
			area.process_mode = Node.PROCESS_MODE_INHERIT
	else:
		if comp_ui:
			comp_ui.visible = false
		_save_ui_offset()
		ui_panel_3d.visible = false
		var area = ui_panel_3d.get_node_or_null("Area3D")
		if area:
			area.process_mode = Node.PROCESS_MODE_DISABLED
		if comp.in_use and bezel_enabled:
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
	primary_screen = s
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
	for hand in [right_hand, left_hand]:
		if hand:
			for child in hand.get_children():
				if child is Node3D and child.name != "HandRayCast" and child.name != "LeftHandRayCast":
					child.visible = visible_state

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
	shared_mat.render_priority = 200
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

func _create_starfield():
	bg_manager._create_starfield()

func _create_ash():
	bg_manager._create_ash()

func _create_snow():
	bg_manager._create_snow()

func _create_data():
	bg_manager._create_data()

func _create_hand_visualizer(is_left: bool) -> Node3D:
	var hand_vis = Node3D.new()
	hand_vis.name = "LeftHandVisual" if is_left else "RightHandVisual"
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.7, 1.0, 0.3) # soft semi-transparent blue
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 100
	
	var palm_mesh = MeshInstance3D.new()
	palm_mesh.name = "Palm"
	var sphere = SphereMesh.new()
	sphere.radius = 0.04
	sphere.height = 0.06
	palm_mesh.mesh = sphere
	palm_mesh.material_override = mat
	hand_vis.add_child(palm_mesh)
	
	var index_mesh = MeshInstance3D.new()
	index_mesh.name = "Index"
	var cap = CylinderMesh.new()
	cap.top_radius = 0.008
	cap.bottom_radius = 0.008
	cap.height = 1.0 # scaled dynamically
	index_mesh.mesh = cap
	index_mesh.material_override = mat
	hand_vis.add_child(index_mesh)
	
	hand_vis.visible = false
	xr_origin.add_child(hand_vis)
	return hand_vis

func _update_hand_visualizer(hand_vis: Node3D, tracker: XRHandTracker):
	if not hand_vis or not tracker:
		return
		
	var palm_has = (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM) & 8) != 0
	var knuckle_has = (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL) & 8) != 0
	var tip_has = (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP) & 8) != 0
	
	if not palm_has and not knuckle_has:
		hand_vis.visible = false
		return
		
	hand_vis.visible = true
	
	var palm_mesh = hand_vis.get_node("Palm")
	if palm_has:
		palm_mesh.transform = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM)
		palm_mesh.visible = true
	else:
		palm_mesh.visible = false
		
	var index_mesh = hand_vis.get_node("Index")
	if knuckle_has and tip_has:
		var knuckle_pos = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL).origin
		var tip_pos = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
		
		var delta = tip_pos - knuckle_pos
		var dist = delta.length()
		if dist > 0.001:
			var center = knuckle_pos + delta * 0.5
			var dir = delta.normalized()
			
			var up = dir
			var right = dir.cross(Vector3.UP).normalized()
			if right.length_squared() < 0.01:
				right = dir.cross(Vector3.FORWARD).normalized()
			var fwd = right.cross(up).normalized()
			
			var basis = Basis(right, up, fwd)
			index_mesh.transform = Transform3D(basis, center)
			index_mesh.scale = Vector3(1, dist, 1) # scale height
			index_mesh.visible = true
		else:
			index_mesh.visible = false
	else:
		index_mesh.visible = false

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
