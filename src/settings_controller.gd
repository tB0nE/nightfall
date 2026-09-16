class_name SettingsController
extends RefCounted

var main: Node3D
var _restart_pending: bool = false
var _restart_seq: int = 0
var _ai_3d_commit_seq: int = 0
var _last_effective_backend: int = -1
var _last_backend_status: String = ""
var _stereo_sdr_shader: Shader = null
var _stereo_picture_shader: Shader = null
var _refresh_request_seq: int = 0

var sbs_labels: Array = ["Off", "Stretch", "Crop"]
# MiDaS-GPU (stereo_mode 5) is REMOVED, not disabled - its underlying
# fp16 model/weights, gradle deps, and Java code are gone
# (DepthEstimator.java, build.sh). The real bug (wrong quantization
# parameters on the w8a8 model, see git history 2026-08-18) is fixed now,
# so GPU isn't needed as a working comparison point anymore. Don't restore
# a mapping for stereo_mode 5 without re-adding that code.
# The original "MiDaS" mode (a single-sample parallax shift, stereo_mode 3)
# is REMOVED too (2026-08-18) - stereo_mode 3/4's shader branch in
# yuv_display.gdshader is dead code left in place (harmless, costs nothing
# unless selected) rather than deleted - see stereo_mode 4/5's own history
# for the same pattern.
#
# Collapsed (2026-08-24) from four independent controls (model/backend/
# quality/debug) down to two, per user request - "AI 3D" and "AI Model" felt
# like they should each be a single toggle, not four:
#   ai_3d_speed_labels  - is AI-3D on at all, and at which performance tier.
#                         Off/Auto/Fast/Standard - absorbs both the
#                         old on/off state (previously ai_3d_model==0) and
#                         the old ai_3d_quality_labels tier picker. Fast/
#                         Standard directly select depth_estimator.gd's
#                         warp_tier 1/0 (see MiDaS-Fast's own history in
#                         main.gd for what it trades off - Fastest/tier 2
#                         was removed 2026-08-25, on-device benchmarking
#                         showed it near-identical to Fast at every tested
#                         resolution). Auto instead picks BOTH a tier and a
#                         model from the current resolution/passthrough
#                         state, via a literal lookup table (AUTO_TABLE
#                         below) built from an on-device GPU-inference
#                         benchmark matrix, not a formula - see
#                         resolve_quality_tier()/get_auto_selection() below.
#   ai_3d_models        - WHICH model, dictionaries of {label, java_index,
#                         gpu_available}. Re-split back into two independent
#                         controls (2026-08-28, AI 3D tab) - Model here and
#                         Type (main.settings.host.ai_3d_backend_pref, GPU/CPU) are now
#                         orthogonal, matching Mode/Debug's own independence
#                         above; gpu_available just records whether a GPU
#                         variant exists at all for a given model (DA-V2-252
#                         has none - see get_depth_backend_index()). YOLO26-N/
#                         MiDaS/Depth Anything V2 all share the exact same
#                         downstream warp/postProcess pipeline
#                         (DepthEstimator.java's postProcess() works on a
#                         plain float[] regardless of source model, and the
#                         warp shaders read textureSize(depth_texture, 0)
#                         dynamically), so the speed-tier selection above is
#                         completely orthogonal to which model is active -
#                         only apply_stereo()'s final set_depth_model() call
#                         and depth_estimator.gd's sync_model_size() (256 vs
#                         YOLO's 768) need to know which one is picked here.
#   ai_3d_debug_labels  - debug depth-data VIEWS (DMap/-Raw/-Input), overlaid
#                         on whichever tier is active rather than a mode of
#                         its own - see get_stereo_mode() and
#                         _schedule_ai_3d_commit(). Left untouched by this
#                         collapse (still its own hidden/disabled button).
# History prior to the collapse (model roster, retired entries, etc.) lives
# in git blame for this file rather than repeated here - see commits through
# 2026-08-20 for the YOLO26-S/MiDaS-GPU/YOLO26-N-resolution/7-way-lineup
# history that produced the roster below.
var ai_3d_speed_labels: Array = ["Off", "Auto", "Fast", "Standard"]
var ai_3d_gpu_priority_labels: Array = ["Stream", "Default"]
# Back to its original 5-entry shape (2026-08-28, AI 3D tab - briefly
# deduplicated to 3 entries with an independent Type control, corrected
# after clarifying the actual request: Type doesn't just gate Model, it
# FILTERS which entries Model cycles through - GPU shows MiDaS-256-GPU/
# MiDaS-192-GPU, CPU shows MiDaS-192/MiDaS-256/DA-V2-252. cycle_ai_3d_model()
# below only cycles entries whose .gpu matches main.settings.host.ai_3d_backend_pref;
# cycle_ai_3d_type() snaps main.settings.host.ai_3d_model to the new Type's first entry
# whenever the current selection doesn't match. Same order/indices as the
# original list for MiDaS-256-GPU (0) and MiDaS-192-GPU (1), so AUTO_TABLE/
# QUEST2_AUTO_TABLE's stored model_idx values need no changes. ZipDepth
# entries (below) are additive on top of this same 5-entry shape.
var ai_3d_models: Array = [
	{"label": "MiDaS-256-GPU", "java_index": 3, "gpu": true},
	{"label": "MiDaS-192-GPU", "java_index": 10, "gpu": true},
	{"label": "ZipDepth-384-GPU", "java_index": 14, "gpu": true},
	{"label": "MiDaS-192", "java_index": 10, "gpu": false},
	{"label": "MiDaS-256", "java_index": 3, "gpu": false},
	{"label": "DA-V2-252", "java_index": 1, "gpu": false},
	{"label": "ZipDepth-512x288-GPU (Experimental)", "java_index": 15, "gpu": true},
	{"label": "ZipDepth-672x384-GPU (Experimental)", "java_index": 16, "gpu": true},
	# Keep this appended so existing persisted indices for the experimental
	# widescreen GPU models do not change. Type=CPU includes it in the model
	# cycle; it shares Java index 14 with the GPU entry above, while Type selects
	# the full-head W8A32/XNNPACK interpreter instead of the GPU delegate.
	{"label": "ZipDepth-384", "java_index": 14, "gpu": false},
]
var ai_3d_debug_labels: Array = ["Off", "DMap", "DMap-Raw", "DMap-Input"]
const AI3D_BACKEND_CPU := 1
const AI3D_BACKEND_GPU := 2
const AI3D_HZ_CAP_VALUES: Array = [12, 15, 20, 30, 40]
const AI3D_SEPARATION_VALUES: Array = [50, 75, 100, 125, 150]
const AI3D_CONVERGENCE_VALUES: Array = [30, 40, 50, 60, 70]
const AI3D_CURSOR_POSITION_LABELS: Array = ["Left", "Default", "Right"]
# stereo_screen.gdshader's own live-path separation constant (mesh-
# projection rendering, not the composition path yuv_display.gdshader
# covers) - independently tuned to a different magnitude than
# depth_estimator.gd's _pass_parallax (0.006), matching that file's own
# comment about the two paths never having been unified. Scaled by
# main.settings.host.ai_3d_separation_pct the same way, just against its own base.
const STEREO_SCREEN_BASE_PARALLAX := 0.042

# Picture tab (2026-08-31). Brightness is additive (-20%..20%, mapped to
# -0.2..0.2 in apply_filter()); Contrast/Gamma are multiplier/exponent-style
# like AI3D_SEPARATION_VALUES above (50%..150% around a neutral 100%).
const PICTURE_BRIGHTNESS_VALUES: Array = [-20, -10, 0, 10, 20]
const PICTURE_CONTRAST_VALUES: Array = [50, 75, 100, 125, 150]
const PICTURE_GAMMA_VALUES: Array = [50, 75, 100, 125, 150]

# HorizonOS v2.7 accepts arbitrary integer display rates through 207 Hz on
# Quest 3 using the standard API. Rates above that require developer-only
# global display scaling, so they are deliberately not exposed here.
# Keep the stream choices device-independent. apply_display_refresh_rate()
# requests the unlisted standard extended rates only on known Quest 3
# hardware, then verifies them and falls back to the runtime's reported list.
const STREAM_FPS_RATES: Array = [30, 60, 72, 90, 120, 144, 165, 200, 207]
const QUEST3_REFRESH_REQUEST_MAX := 207.0
# The Quest runtime recreates display surfaces asynchronously after accepting
# a refresh-rate request. Do not allocate/resize any stream GLES resources
# until that transition has completed. A fixed post-request settling window is
# intentional: get_display_refresh_rate() can report the new value before the
# Android surface transition itself has finished.
const REFRESH_SURFACE_SETTLE_SEC := 0.35

# Auto-mode resolution classification (2026-08-25) - aspect first (ultrawide
# vs 16:9; 2560x1080's aspect is 2.37 and 3440x1440's is 2.39, both cleanly
# separated from 16:9's 1.778 by a 2.0 threshold), then bucket by pixel
# count within that aspect class at the midpoint between each pair of named
# reference resolutions - anything below the lowest or above the highest
# named bucket clamps to the nearest end rather than extrapolating. See
# _classify_auto_resolution()/get_auto_selection() below.
const AUTO_ASPECT_ULTRAWIDE_THRESHOLD := 2.0
const AUTO_CLASS_16_9 := [
	{"name": "720p", "px": 1280 * 720},
	{"name": "HD", "px": 1920 * 1080},
	{"name": "2K", "px": 2560 * 1440},
	{"name": "4K", "px": 3840 * 2160},
]
const AUTO_CLASS_ULTRAWIDE := [
	{"name": "21:9 HD", "px": 2560 * 1080},
	{"name": "21:9 2K", "px": 3440 * 1440},
]

# The Auto-mode target table (2026-08-25, on-device GPU-inference benchmark
# matrix - MiDaS-192-GPU/MiDaS-256-GPU x Fast/Fastest/Standard x six
# resolution classes x passthrough on/off, Quest 3/3s). A literal lookup,
# NOT a formula - which model wins (192 vs 256) does not follow a
# monotonic rule against resolution or passthrough alone (2K-on picks 192
# but 2K-off picks 256; 21:9-2K-on picks 256 but -off picks 192) - these
# are direct empirical judgment calls per combo. tier: 0=Standard/1=Fast
# (matches depth_estimator.gd's warp_tier - Fastest/2 was removed the same
# day). model_idx: index into ai_3d_models above (0=MiDaS-256, 1=MiDaS-192
# - Auto never picks DA-V2, and always resolves to GPU - see
# get_depth_backend_index()). cap_px: 0 = no
# cap, else the sqrt-pixel-budget resolution cap compute_requested_resolution()
# applies (replaces the old flat MIDAS_FAST_MAX_PIXELS/MIDAS_FASTEST_MAX_PIXELS
# constants, which this table's per-combo caps supersede - see main.gd).
# Keyed by class name, then main.settings.passthrough_enabled (bool).
const AUTO_TABLE := {
	"720p":    {false: {"tier": 0, "model_idx": 0, "cap_px": 0}, true: {"tier": 0, "model_idx": 0, "cap_px": 0}},
	"HD":      {false: {"tier": 0, "model_idx": 0, "cap_px": 0}, true: {"tier": 1, "model_idx": 0, "cap_px": 0}},
	"21:9 HD": {false: {"tier": 1, "model_idx": 0, "cap_px": 0}, true: {"tier": 1, "model_idx": 0, "cap_px": 0}},
	"2K":      {false: {"tier": 1, "model_idx": 0, "cap_px": 0}, true: {"tier": 1, "model_idx": 1, "cap_px": 0}},
	"21:9 2K": {false: {"tier": 1, "model_idx": 1, "cap_px": 0}, true: {"tier": 1, "model_idx": 0, "cap_px": 2560 * 1080}},
	"4K":      {false: {"tier": 1, "model_idx": 0, "cap_px": 2560 * 1440}, true: {"tier": 1, "model_idx": 1, "cap_px": 2560 * 1440}},
}

# Quest 2 Auto table (2026-08-27) - NOT benchmarked on real Quest 2 hardware
# (none available) - extrapolated from Meta's own published XR2 Gen 1 vs
# Gen 2 GPU figures (roughly 2-2.5x slower on Quest 2, worse under sustained
# thermal load) applied to the real Quest 3 benchmark data above. main.gd's
# QUEST2_MAX_RESOLUTION already hard-caps the stream to 1080p before this
# table is even consulted (Quest 2's own display is lower-res than Quest 3's
# anyway, and dividing AUTO_TABLE's 4K/cap_px=2560x1440 entry by ~2.2x lands
# almost exactly on 1080p's pixel count) - so only 720p/HD rows exist here,
# always the cheapest surviving tier+model (Fast, MiDaS-192-GPU), with an
# extra pixel-budget cap on HD+passthrough since passthrough adds real GPU
# cost this hardware has much less headroom for. Treat as a starting point
# to be corrected once real on-device Quest 2 feedback comes in, not a
# measured result like the table above.
const QUEST2_AUTO_TABLE := {
	"720p": {false: {"tier": 1, "model_idx": 1, "cap_px": 0}, true: {"tier": 1, "model_idx": 1, "cap_px": 0}},
	"HD":   {false: {"tier": 1, "model_idx": 1, "cap_px": 0}, true: {"tier": 1, "model_idx": 1, "cap_px": 1280 * 720}},
}
var idle_labels: Array = ["Off", "5m", "15m", "30m", "60m"]
var idle_values: Array = [0, 5, 15, 30, 60]

func _init(owner: Node3D):
	main = owner

func get_stereo_mode() -> int:
	if main.settings.host.sbs_mode > 0:
		return main.settings.host.sbs_mode
	if main.settings.host.ai_3d_speed == 0:
		return 0
	if main.settings.host.ai_3d_debug == 1:
		return 7 # MiDaS-DMap
	elif main.settings.host.ai_3d_debug == 2:
		return 8 # MiDaS-DMap-Raw
	elif main.settings.host.ai_3d_debug == 3:
		return 9 # MiDaS-DMap-Input
	match resolve_quality_tier():
		1: return 10 # MiDaS-Fast
		_: return 6 # MiDaS-Std

# 0=Standard, 1=Fast - matches depth_estimator.gd's warp_tier numbering
# exactly, so apply_stereo() can pass this straight through. Fastest/2 was
# removed 2026-08-25 (was ai_3d_speed==3) - near-identical to Fast at every
# resolution benchmarked, not worth the extra tier. ai_3d_speed_labels =
# ["Off", "Auto", "Fast", "Standard"] - Off never reaches here
# (get_stereo_mode() short-circuits on it above).
func resolve_quality_tier() -> int:
	match main.settings.host.ai_3d_speed:
		2: return 1 # Fast
		3: return 0 # Standard
		_: return get_auto_selection().tier

# Reads the pre-AI3D-cap BASE resolution (compute_requested_resolution(false),
# NOT the live/possibly-already-capped value - reading the capped value
# would be circular, since Auto's own tier choice is what determines the
# cap in the first place), classifies it (aspect + pixel-count bucket, see
# AUTO_CLASS_16_9/AUTO_CLASS_ULTRAWIDE above), and looks up the matching
# AUTO_TABLE row. Public (unlike the old _auto_quality_tier()) - main.gd's
# compute_requested_resolution() and ui_controller.gd's AI-Model-button
# labeling both need this same combo, not just resolve_quality_tier() here.
# Deliberately NOT cached - get_stereo_mode() (which calls this via
# resolve_quality_tier()) already gets called every frame from several
# places with no caching today, and this is exactly as cheap as the
# function it replaces (one Vector2i compute + a handful of comparisons,
# no allocations) - a cache/invalidation path would be new complexity for
# no measured benefit.
func _classify_auto_resolution(w: int, h: int) -> String:
	if h <= 0:
		return "720p"
	var aspect := float(w) / float(h)
	var refs: Array = AUTO_CLASS_ULTRAWIDE if aspect >= AUTO_ASPECT_ULTRAWIDE_THRESHOLD else AUTO_CLASS_16_9
	var pixels := w * h
	for i in range(refs.size() - 1):
		var midpoint: float = (refs[i].px + refs[i + 1].px) / 2.0
		if pixels <= midpoint:
			return refs[i].name
	return refs[refs.size() - 1].name

func get_auto_selection() -> Dictionary:
	var res: Vector2i = main.compute_requested_resolution(false)
	var cls := _classify_auto_resolution(res.x, res.y)
	if main.device_is_quest2:
		# QUEST2_AUTO_TABLE only has 720p/HD rows (see its own comment) -
		# QUEST2_MAX_RESOLUTION means classification should never actually
		# produce anything above HD on Quest 2, but clamp defensively rather
		# than throw if it somehow does.
		var quest2_cls = cls if QUEST2_AUTO_TABLE.has(cls) else "HD"
		return QUEST2_AUTO_TABLE[quest2_cls][main.settings.passthrough_enabled]
	return AUTO_TABLE[cls][main.settings.passthrough_enabled]

func _save_setting(btn: Button, label: String):
	if btn:
		main.ui_controller.update_option_btn(btn, label)
	main.state_manager.save_state()

func cycle_sbs_mode():
	var previous_mode: int = main.settings.host.sbs_mode
	main.settings.host.sbs_mode = (main.settings.host.sbs_mode + 1) % 3
	_save_setting(main._ui_sbs_btn, sbs_labels[main.settings.host.sbs_mode])
	main.ui_controller.update_3d_btn_state()
	apply_stereo()
	main._log("[SBS] Mode changed: %s -> %s" % [
		sbs_labels[previous_mode], sbs_labels[main.settings.host.sbs_mode]])
	if main.settings.host.sbs_mode > 0 and main.screens.size() > 1:
		main._ui_status_label.text = "SBS applies to primary screen only"

# AI-3D depth estimation is native (no JNI/JVM) on Linux as of 2026-08-20
# (see depth_bridge.cpp's NIGHTFALL_PLATFORM_LINUX branch / MidasDepthEngine) -
# Linux uses the same selectable native TFLite models as Android. A shared
# check here avoids repeating "Android or Linux" three times below.
func _ai_3d_supported() -> bool:
	return OS.get_name() == "Android" or OS.get_name() == "Linux"

# Main-page On/Off toggle (2026-08-28) - replaces the old direct
# Off/Auto/Fast/Standard cycle on this button. Flips main.settings.host.ai_3d_speed
# between 0 and whichever mode was last active (main.settings.host.ai_3d_last_mode,
# kept current by cycle_ai_3d_mode() below) instead of always landing on
# Auto - tier selection itself now lives on the AI 3D tab.
func toggle_ai_3d_enabled():
	if not _ai_3d_supported():
		return
	if main.settings.host.sbs_mode > 0:
		return
	if main.settings.host.ai_3d_speed == 0:
		main.settings.host.ai_3d_speed = main.settings.host.ai_3d_last_mode
	else:
		main.settings.host.ai_3d_last_mode = main.settings.host.ai_3d_speed
		main.settings.host.ai_3d_speed = 0
	_save_setting(main._ui_3d_speed_btn, "On" if main.settings.host.ai_3d_speed != 0 else "Off")
	main.ui_controller.update_3d_btn_state()
	_schedule_ai_3d_commit()

# AI 3D tab's "3D Mode" control (2026-08-28) - cycles Auto/Fast/Standard
# (1-3) only; Off lives on the main page's toggle instead
# (toggle_ai_3d_enabled() above). Greyed out via update_3d_btn_state()
# whenever ai_3d_speed==0, but guarded here too since a disabled Button
# still technically has this connected.
func cycle_ai_3d_mode():
	if not _ai_3d_supported() or ai3d_options_locked():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0:
		return
	# Only the label updates immediately - actually applying the mode
	# (apply_stereo(), which reconfigures depth_estimator and can trigger a
	# resolution-cap stream restart) is debounced below, same UX as
	# cycle_resolution()/_schedule_stream_restart(): click through to find
	# the setting you want, and it only commits once you stop, instead of
	# reconfiguring/restarting on every single click along the way.
	main.settings.host.ai_3d_speed = (main.settings.host.ai_3d_speed % 3) + 1 # 1->2->3->1 (Auto/Fast/Standard)
	main.settings.host.ai_3d_last_mode = main.settings.host.ai_3d_speed
	# Type can now change while Auto is active (2026-08-30, cycle_ai_3d_type())
	# without touching Model (frozen/table-driven under Auto) - re-sync Model
	# to Type here on the way OUT of Auto, in case they drifted apart while
	# Auto was active.
	normalize_ai_3d_model_for_type()
	_save_setting(main._ui_3d_mode_btn, ai_3d_speed_labels[main.settings.host.ai_3d_speed])
	main.ui_controller.update_3d_btn_state()
	_schedule_ai_3d_commit()

# Returns the indices into ai_3d_models whose .gpu matches want_gpu -
# shared by cycle_ai_3d_model() (cycles within the current Type's subset)
# and cycle_ai_3d_type() (snaps Model to the new Type's subset).
func _ai_3d_model_indices_for_type(want_gpu: bool) -> Array:
	var result: Array = []
	for i in range(ai_3d_models.size()):
		if ai_3d_models[i].gpu == want_gpu:
			result.append(i)
	return result

# AI 3D tab's "Type" control (2026-08-28) - filters which ai_3d_models
# entries Model can cycle through (GPU: MiDaS-256-GPU/MiDaS-192-GPU; CPU:
# MiDaS-192/MiDaS-256/DA-V2-252), not just a passive preference. Snaps
# main.settings.host.ai_3d_model to the new Type's first matching entry whenever the
# current selection doesn't belong to it (e.g. switching CPU->GPU while
# DA-V2-252 was selected).
func cycle_ai_3d_type():
	if not _ai_3d_supported() or ai3d_options_locked():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0:
		return
	main.settings.host.ai_3d_backend_pref = AI3D_BACKEND_CPU if main.settings.host.ai_3d_backend_pref == AI3D_BACKEND_GPU else AI3D_BACKEND_GPU
	# Under Auto (2026-08-30), Model stays table-driven (AUTO_TABLE/
	# get_auto_selection()) - main.settings.host.ai_3d_model itself is frozen/irrelevant,
	# so there's nothing to snap here; only Fast/Standard need Model kept in
	# sync with the new Type.
	if main.settings.host.ai_3d_speed != 1:
		var candidates = _ai_3d_model_indices_for_type(main.settings.host.ai_3d_backend_pref == AI3D_BACKEND_GPU)
		if not candidates.is_empty() and not candidates.has(main.settings.host.ai_3d_model):
			main.settings.host.ai_3d_model = candidates[0]
	main.state_manager.save_state()
	main.ui_controller.update_stereo_shader() # refreshes both Type's and Model's labels
	_schedule_ai_3d_commit()

# AI 3D tab's "Hz Cap" control (2026-08-28).
func cycle_ai_3d_hz_cap():
	if not _ai_3d_supported():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0 or main.settings.host.ai_3d_speed == 1:
		return
	var idx = AI3D_HZ_CAP_VALUES.find(main.settings.host.ai_3d_hz_cap)
	main.settings.host.ai_3d_hz_cap = AI3D_HZ_CAP_VALUES[(maxi(idx, 0) + 1) % AI3D_HZ_CAP_VALUES.size()]
	_save_setting(main._ui_3d_hz_cap_btn, "%dhz" % main.settings.host.ai_3d_hz_cap)
	_schedule_ai_3d_commit()

# AI 3D tab's "Stereo Separation" control (2026-08-28) - a percentage
# multiplier on top of the warp shaders' own tuned base values (see
# STEREO_SCREEN_BASE_PARALLAX/depth_estimator.gd's _pass_parallax), not a
# replacement absolute value. Left live under Auto (unlike Type/Model/Hz
# Cap) - it's a general 3D-strength tune, not something the Auto table
# decides.
func cycle_ai_3d_separation():
	if not _ai_3d_supported():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0:
		return
	var idx = AI3D_SEPARATION_VALUES.find(main.settings.host.ai_3d_separation_pct)
	main.settings.host.ai_3d_separation_pct = AI3D_SEPARATION_VALUES[(maxi(idx, 0) + 1) % AI3D_SEPARATION_VALUES.size()]
	_save_setting(main._ui_3d_separation_btn, "%d%%" % main.settings.host.ai_3d_separation_pct)
	_schedule_ai_3d_commit()

# AI 3D tab's "Convergence" control (2026-08-28) - maps directly to the
# warp shaders' already-declared "convergence" uniform (0.30-0.70), which
# was never actually driven from GDScript before this - see
# _push_ai3d_effect_uniforms(). Left live under Auto, same reasoning as
# Separation above.
func cycle_ai_3d_convergence():
	if not _ai_3d_supported():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0:
		return
	var idx = AI3D_CONVERGENCE_VALUES.find(main.settings.host.ai_3d_convergence_pct)
	main.settings.host.ai_3d_convergence_pct = AI3D_CONVERGENCE_VALUES[(maxi(idx, 0) + 1) % AI3D_CONVERGENCE_VALUES.size()]
	_save_setting(main._ui_3d_convergence_btn, "%d%%" % main.settings.host.ai_3d_convergence_pct)
	_schedule_ai_3d_commit()

# Moves the rendered cursor over the AI-warped image without changing the
# raycast or host click coordinates. This corrects visual click alignment;
# it deliberately does not alter cursor depth/binocular disparity.
func cycle_ai_3d_cursor_position():
	if not _ai_3d_supported():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0:
		return
	main.settings.host.ai_3d_cursor_position = ((clampi(main.settings.host.ai_3d_cursor_position, -1, 1) + 1 + 1) % AI3D_CURSOR_POSITION_LABELS.size()) - 1
	_save_setting(main._ui_3d_cursor_position_btn, get_ai_3d_cursor_position_label())

func get_ai_3d_cursor_position_label() -> String:
	return AI3D_CURSOR_POSITION_LABELS[clampi(main.settings.host.ai_3d_cursor_position, -1, 1) + 1]

func toggle_ai_3d_depth_sync():
	if OS.get_name() != "Android" or main.settings.host.sbs_mode > 0 \
			or main.settings.host.ai_3d_speed == 0:
		return
	main.settings.host.ai_3d_depth_sync = not main.settings.host.ai_3d_depth_sync
	_save_setting(main._ui_3d_depth_sync_btn,
		"On" if main.settings.host.ai_3d_depth_sync else "Off")

# AI 3D tab's "Reset" button (2026-08-28) - restores only this tab's own
# settings to their defaults (today's real, previously-hardcoded values -
# see each field's own comment on main.gd). Deliberately does NOT touch
# the main-page On/Off state: if AI-3D is currently off, it stays off, just
# with ai_3d_last_mode reset to Auto for whenever it's turned back on; if
# currently on, its active mode is reset to Auto too (matching "3D Mode
# -> Auto" being one of the reset targets).
func reset_ai_3d_effect_settings():
	if not _ai_3d_supported():
		return
	main.settings.host.ai_3d_last_mode = 1
	if main.settings.host.ai_3d_speed != 0:
		main.settings.host.ai_3d_speed = 1
	main.settings.host.ai_3d_backend_pref = AI3D_BACKEND_GPU
	main.settings.host.ai_3d_model = 0
	main.settings.host.ai_3d_hz_cap = 20
	main.settings.host.ai_3d_separation_pct = 100
	main.settings.host.ai_3d_convergence_pct = 50
	main.settings.host.ai_3d_cursor_position = 0
	main.settings.host.ai_3d_depth_sync = false
	enforce_ai3d_platform_lock()
	main.state_manager.save_state()
	main.ui_controller.update_stereo_shader()
	_schedule_ai_3d_commit()

# Cycles only within the entries matching the current Type
# (main.settings.host.ai_3d_backend_pref) - see _ai_3d_model_indices_for_type() above.
func cycle_ai_3d_model():
	if not _ai_3d_supported() or ai3d_options_locked():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0 or main.settings.host.ai_3d_speed == 1:
		return
	var candidates = _ai_3d_model_indices_for_type(main.settings.host.ai_3d_backend_pref == AI3D_BACKEND_GPU)
	if candidates.is_empty():
		return
	var pos = candidates.find(main.settings.host.ai_3d_model)
	main.settings.host.ai_3d_model = candidates[(maxi(pos, -1) + 1) % candidates.size()]
	_save_setting(main._ui_3d_btn, ai_3d_models[main.settings.host.ai_3d_model].label)
	_schedule_ai_3d_commit()

func cycle_ai_3d_gpu_priority():
	if not depth_gpu_priority_available():
		return
	main.settings.ai_3d_gpu_priority = (main.settings.ai_3d_gpu_priority + 1) % ai_3d_gpu_priority_labels.size()
	_save_setting(main._ui_3d_priority_btn, ai_3d_gpu_priority_labels[main.settings.ai_3d_gpu_priority])
	apply_depth_gpu_priority(true)

func apply_depth_gpu_priority(notify: bool = false):
	if not depth_gpu_priority_available() or not main.stream_backend:
		return
	if not main.stream_backend.has_method("set_depth_gpu_priority"):
		return
	main.stream_backend.set_depth_gpu_priority(main.settings.ai_3d_gpu_priority)
	var label: String = ai_3d_gpu_priority_labels[main.settings.ai_3d_gpu_priority]
	main._log("[DEPTH] GPU priority selected: %s" % label)
	if notify and main.ui_controller:
		main.ui_controller.set_status("Depth GPU priority: %s (reloading inference)" % label)

# Safety net for main.settings.host.ai_3d_model/ai_3d_backend_pref disagreeing (e.g. a
# save file edited/corrupted outside the normal cycle_ai_3d_model()/
# cycle_ai_3d_type() paths, which otherwise always keep them in sync) -
# called after loading persisted state. Snaps Model to Type's first entry
# if the current selection doesn't belong to it; a no-op otherwise.
func normalize_ai_3d_model_for_type():
	var candidates = _ai_3d_model_indices_for_type(main.settings.host.ai_3d_backend_pref == AI3D_BACKEND_GPU)
	if not candidates.is_empty() and not candidates.has(main.settings.host.ai_3d_model):
		main.settings.host.ai_3d_model = candidates[0]

# AI-3D Type/Model/3D-Mode are locked to GPU/ZipDepth-384-GPU/Standard on
# Android (2026-09-07) - ZipDepth-384-GPU replaces MiDaS as strictly better
# in every way tested, and Auto/Fast's tier and resolution-cap thresholds in
# AUTO_TABLE above were empirically benchmarked around MiDaS's specific
# speed, not ZipDepth's, so leaving them reachable would apply stale
# calibration to a different model rather than actually saving anything -
# Standard is simply forced instead until AUTO_TABLE is re-benchmarked
# against ZipDepth. build.sh only bundles zipdepth-base-384-gpu.tflite for
# Android (MiDaS/DA-V2/CPU-backend/experimental-widescreen models are
# commented out there, not deleted, so this can be reverted by uncommenting
# those cp lines and this lock together). Linux keeps every model/tier
# selectable - it never had ZipDepth support to begin with (native
# MidasDepthEngine only), so this lock would remove capability there for no
# corresponding size/perf win.
func ai3d_options_locked() -> bool:
	return SettingsPlatformPolicy.ai3d_options_locked()

func depth_gpu_priority_available() -> bool:
	return SettingsPlatformPolicy.depth_gpu_priority_available()

func _locked_ai3d_model_index() -> int:
	for i in range(ai_3d_models.size()):
		if ai_3d_models[i].label == "ZipDepth-384-GPU":
			return i
	return 0

# Called after loading persisted state (any format/migration branch - see
# load_host_state()'s own comment) and by reset_ai_3d_effect_settings(), so
# a save file from before this lock existed (or Reset's own MiDaS/Auto
# defaults) can never leave Android pointed at a model that isn't actually
# bundled. No-op on Linux.
func enforce_ai3d_platform_lock():
	if not ai3d_options_locked():
		return
	main.settings.host.ai_3d_backend_pref = AI3D_BACKEND_GPU
	main.settings.host.ai_3d_model = _locked_ai3d_model_index()
	main.settings.host.ai_3d_last_mode = 3
	if main.settings.host.ai_3d_speed != 0:
		main.settings.host.ai_3d_speed = 3

# Maps main.settings.host.ai_3d_model (the persisted UI selection, an index into
# ai_3d_models) to DepthEstimator's real Java-side model index. Under Auto
# (ai_3d_speed==1), main.settings.host.ai_3d_model is frozen/irrelevant - the table picks
# the model instead (see get_auto_selection()/AUTO_TABLE above).
func get_depth_model_index() -> int:
	if main.settings.host.ai_3d_speed == 0:
		return 0
	if main.settings.host.ai_3d_speed == 1:
		return ai_3d_models[get_auto_selection().model_idx].java_index
	return ai_3d_models[main.settings.host.ai_3d_model].java_index

# The backend to actually request from configure_depth() (2026-08-28 -
# now driven by main.settings.host.ai_3d_backend_pref, the "Type" control). Model is
# always kept filtered to match Type by cycle_ai_3d_model()/
# cycle_ai_3d_type(), so main.settings.host.ai_3d_backend_pref and
# ai_3d_models[main.settings.host.ai_3d_model].gpu can never disagree - no need to
# fall back based on the model's own .gpu flag here.
func get_depth_backend_index() -> int:
	if main.settings.host.ai_3d_speed == 0:
		return AI3D_BACKEND_CPU # irrelevant, AI-3D is off
	# 2026-08-30: Auto follows the Type control the same as Fast/Standard do -
	# it was never meant to force GPU unconditionally, just default to it
	# (main.settings.host.ai_3d_backend_pref's own default value). AUTO_TABLE's model_idx
	# entries (0/1, the "-GPU"-labeled rows) resolve to the exact same
	# java_index as their CPU-labeled counterparts (2/3) - GPU vs CPU is
	# entirely this return value's job, not which model_idx AUTO_TABLE
	# picked, so honoring Type here needs no AUTO_TABLE change.
	return main.settings.host.ai_3d_backend_pref

# AI 3D tab's Hz Cap control ignores itself under Auto (which always
# targets a fixed 20Hz) - see cycle_ai_3d_hz_cap()'s own comment. Used both
# for the button's displayed label and the actual value pushed to the
# Java inference loop, so they can never disagree.
func get_effective_hz_cap() -> int:
	return 20 if main.settings.host.ai_3d_speed == 1 else main.settings.host.ai_3d_hz_cap

# 2026-08-30: only ever "GPU" or "CPU" now - no silent runtime GPU->CPU
# substitution to represent as a third hybrid state (see
# runScheduledGpuInference()/configureDepth() in DepthEstimator.java, and
# refresh_depth_backend_status() below for how a GPU failure is surfaced
# instead: a persistent status message, not a quiet backend swap).
func get_depth_backend_label() -> String:
	return "GPU" if get_depth_backend_index() == AI3D_BACKEND_GPU else "CPU"

# A non-empty backend_status while GPU is requested means GPU depth failed
# and (per 2026-08-30's "fail visibly, no fallback" request) is simply not
# producing frames - not that it silently switched to CPU. Shown as a
# persistent status message for as long as the failure lasts, not just a
# one-off transition blip, so it stays visible the whole time it's true
# (matters most for Auto, which now defaults to GPU but never used to
# surface this at all).
func refresh_depth_backend_status(notify_transition: bool = false):
	if not main.stream_backend:
		return
	var status = main.stream_backend.get_depth_backend_status()
	var requested = get_depth_backend_index()
	var failed = not status.is_empty() and requested == AI3D_BACKEND_GPU
	if notify_transition and failed and status != _last_backend_status:
		main._log("[DEPTH] GPU depth failed: " + status)
		if main.ui_controller:
			main.ui_controller.set_status(status)
	elif notify_transition and not failed and not _last_backend_status.is_empty():
		main._log("[DEPTH] GPU depth recovered")
		if main.ui_controller:
			main.ui_controller.set_status("GPU depth recovered")
	_last_backend_status = status if failed else ""

func cycle_ai_3d_debug():
	if not _ai_3d_supported():
		return
	if main.settings.host.sbs_mode > 0 or main.settings.host.ai_3d_speed == 0:
		return
	main.settings.host.ai_3d_debug = (main.settings.host.ai_3d_debug + 1) % ai_3d_debug_labels.size()
	_save_setting(main._ui_3d_debug_btn, ai_3d_debug_labels[main.settings.host.ai_3d_debug])
	_schedule_ai_3d_commit()

func _schedule_ai_3d_commit():
	_ai_3d_commit_seq += 1
	var my_seq = _ai_3d_commit_seq
	# Shorter than _schedule_stream_restart()'s own 0.8s - this one's mostly
	# used for fast click-through debugging (checking DMap/DMap-Raw/-Input
	# against whichever tier is active), where quick feedback matters more
	# than matching the restart delay exactly. Shared across all three
	# cycle_ai_3d_*() functions above (one sequence counter), so clicking
	# between model/quality/debug controls in quick succession still only
	# commits once, for whatever the final combined state ends up being.
	await main.get_tree().create_timer(0.6).timeout
	if _ai_3d_commit_seq != my_seq:
		return
	# MiDaS-DMap/-Raw/-Input are debug VIEWS of whatever depth data is
	# already flowing, not a separate mode with its own resolution needs -
	# deliberately inherit whatever resolution (including a MiDaS-Fast
	# cap) is already active instead of recomputing/restarting back
	# to the full uncapped resolution. That restart actively worked against
	# debugging: switching to a debug view to inspect what a tier was doing
	# changed the very thing being inspected (a different, uncapped
	# resolution) and interrupted the stream to do it. They never restart,
	# so apply_stereo() is always safe to call immediately here.
	if main.settings.host.ai_3d_debug != 0:
		apply_stereo()
		return
	# MiDaS-Fast caps the actual requested stream resolution (see
	# AUTO_TABLE's cap_px above, applied in main.gd). Checked BEFORE apply_stereo(), not
	# after - if a restart is needed, apply_stereo() is skipped here
	# entirely and left to main.gd's _on_stream_started(), which now calls
	# it once the new session actually lands, instead of calling it here too
	# and applying the new stereo/depth mode against the OLD, about-to-be-
	# replaced video for the ~0.8-1.3s the restart takes. That was a real,
	# visible bug (2026-08-18, user diagnosed it directly): the new effect
	# would visibly apply and then get lost the moment the restart landed,
	# since depth_estimator's pre-pass/warp state got initialized against a
	# session that was seconds from being torn down, not the one that
	# actually mattered.
	var new_res = main.compute_requested_resolution()
	if new_res != main.host_resolution:
		main.host_resolution = new_res
		refresh_resolution_btn_label()
		if main.is_streaming:
			_schedule_stream_restart()
			return
	apply_stereo()

func apply_stereo():
	var mode = get_stereo_mode()
	# native_xr_renderer.gd's refresh() re-activates on its own the moment the
	# decoder reports the new stream's video size (normally within a frame or
	# two of _on_stream_started(), which calls this), calling
	# _disable_legacy_video() to turn comp_viewport's update mode back off.
	# Unconditionally switching to the legacy composition layer here first -
	# on every single connect/restart, not just ones legacy actually ends up
	# serving - re-acquires that OpenXRCompositionLayerQuad's own OpenXR
	# swapchain for the brief window in between, racing whatever teardown/
	# recreate it was left in by the *previous* native-active session. That
	# race, not anything resolution-specific, is what was producing the
	# repeatable fault-addr-0xe0 GLThread SIGSEGV on resolution/refresh-rate
	# changes (confirmed via on-device logging: comp_viewport's own size
	# never lined up with crash/no-crash, but this activation window is
	# common to every case that crashed). Skip it here when native rendering
	# is eligible for the new config - can_render_current_config() is the
	# same static check native_xr_renderer.gd's own _eligible() uses, so this
	# stays in sync with whatever it decides moments later. If native
	# rendering then fails to actually start, deactivate(true)'s own
	# switch_to_comp_layer()/switch_to_stereo_comp_layer() fallback still
	# covers activating legacy properly.
	main.video_presentation.apply_mode(mode, main.is_streaming)
	if main.screen_mesh.material_override is ShaderMaterial:
		main.screen_mesh.material_override.set_shader_parameter("stereo_mode", mode)
	if main.depth_estimator:
		# mode 7 (MiDaS-DMap) visualizes upsampled_depth_texture (the real
		# post-upsample data the actual warp uses), so it needs the warp
		# passes running too. mode 8 (MiDaS-DMap-Raw) visualizes the raw
		# pre-upsample depth_texture directly - no warp passes needed. mode 9
		# (MiDaS-DMap-Input) visualizes the literal color capture fed to the
		# model - also no warp passes needed. mode 10 (MiDaS-Fast) is the
		# same warp passes as mode 6, just throttled/shrunk - see
		# warp_update_interval's comment in depth_estimator.gd. warp_tier
		# (0=Standard, 1=Fast - Fastest/2 removed 2026-08-25) comes from
		# resolve_quality_tier() - the SAME tier drives the pre-pass config
		# whether you're looking at the real warp (mode 6/10) or a debug
		# view of it (mode 7/8/9), since debug views are just a lens on
		# whichever tier is actually active, not a tier of their own. mode
		# 11 (MiDaS-Fastest) below is unreachable dead code, left in place
		# same as this file's other retired-stereo_mode conventions.
		var warp_tier = resolve_quality_tier() if main.settings.host.ai_3d_speed > 0 else 0
		main.depth_estimator.set_enabled(mode >= 3, mode == 6 or mode == 7 or mode == 10 or mode == 11, warp_tier)
		# Direct decoder textures feed the small depth-input viewport without a
		# third full-resolution mono render. refresh_stream_source() keeps the
		# old mono path available only when a backend cannot expose those textures.
		main.depth_estimator.refresh_stream_source()
	# Which Java-side model/interpreter to run is entirely orthogonal to mode
	# (stereo_mode only encodes speed tier / debug view, see ai_3d_models'
	# comment above) - it comes straight from main.settings.host.ai_3d_model. Modes
	# 6/7/8/9/10 (Std, DMap, DMap-Raw, DMap-Input,
	# Fast) are pure visualizations/warp-pass variants of whatever
	# model's depth data is already flowing, not a separate source - mode 9
	# doesn't even read the model's output (just the color capture), but
	# MUST still resolve to the same model index here: leaving it out
	# previously silently swapped the active model down to a different one
	# every time mode 9 was selected, which then poisoned the other modes
	# with stale/wrong-quality data the next time they ran, since all modes
	# share one depth_texture/ImageTexture.
	var model_idx = get_depth_model_index() if mode >= 3 else 0
	main.stream_backend.configure_depth(model_idx, get_depth_backend_index())
	main.stream_backend.set_depth_hz_cap(get_effective_hz_cap())
	refresh_depth_backend_status(true)
	# sync_model_size() (2026-08-27 - moved BEFORE the texture-capture block
	# below, was after) resizes depth_viewport in place, which recreates
	# its underlying render-target texture - reading/pushing
	# de.depth_viewport.get_texture() etc. into the comp shader materials
	# before this ran meant every model switch that actually changed size
	# (e.g. 256<->192) pushed a texture reference that was about to go
	# stale, confirmed via on-device logcat showing "Condition
	# 't->is_render_target' is true" / "Parameter 'from_tex' is null"
	# errors at the exact moment of a model switch, and reported as
	# "sometimes stops loading the depth map" after switching models.
	# configure_depth() above must still run first - sync_model_size()
	# reads get_depth_model_width()/get_depth_model_height(), which only
	# reflect the new model once the Java side has been reconfigured.
	if mode >= 3 and main.depth_estimator:
		main.depth_estimator.sync_model_size()
		main.depth_estimator.set_separation_pct(main.settings.host.ai_3d_separation_pct)
		if main.depth_estimator.depth_texture:
			var de = main.depth_estimator
			var upsampled_tex = de.upsample_viewport.get_texture() if de.upsample_viewport else null
			var offset_tex = de.offset_viewport.get_texture() if de.offset_viewport else null
			var guide_tex = de.depth_viewport.get_texture() if de.depth_viewport else null
			if main.comp_shader_mat_left:
				main.comp_shader_mat_left.set_shader_parameter("depth_texture", de.depth_texture)
				main.comp_shader_mat_left.set_shader_parameter("upsampled_depth_texture", upsampled_tex)
				main.comp_shader_mat_left.set_shader_parameter("offset_texture", offset_tex)
				main.comp_shader_mat_left.set_shader_parameter("depth_guide_texture", guide_tex)
			if main.comp_shader_mat_right:
				main.comp_shader_mat_right.set_shader_parameter("depth_texture", de.depth_texture)
				main.comp_shader_mat_right.set_shader_parameter("upsampled_depth_texture", upsampled_tex)
				main.comp_shader_mat_right.set_shader_parameter("offset_texture", offset_tex)
				main.comp_shader_mat_right.set_shader_parameter("depth_guide_texture", guide_tex)
	_push_ai3d_effect_uniforms()

# Pushes Stereo Separation/Convergence to every material that reads them -
# unconditional (not gated on mode >= 3) so a value change while AI-3D is
# off is already correct the instant it's turned back on. mode5_parallax on
# comp_shader_mat_left/right is handled separately by depth_estimator.gd's
# set_separation_pct() above (it needs _pass_size, which only depth_
# estimator.gd tracks) - this covers stereo_screen.gdshader's own
# independently-tuned copy plus convergence everywhere, including
# depth_offset.gdshader's offset_mat, which nothing pushed to before this.
func _push_ai3d_effect_uniforms():
	var convergence = main.settings.host.ai_3d_convergence_pct / 100.0
	if main.screen_mesh.material_override is ShaderMaterial:
		main.screen_mesh.material_override.set_shader_parameter("mode5_parallax", STEREO_SCREEN_BASE_PARALLAX * (main.settings.host.ai_3d_separation_pct / 100.0))
		main.screen_mesh.material_override.set_shader_parameter("convergence", convergence)
	for mat in [main.comp_shader_mat_left, main.comp_shader_mat_right]:
		if mat:
			mat.set_shader_parameter("convergence", convergence)
	if main.depth_estimator and main.depth_estimator.offset_mat:
		main.depth_estimator.offset_mat.set_shader_parameter("convergence", convergence)

func toggle_passthrough():
	if not main.is_xr_active or not main.passthrough_supported:
		main._log("[PASSTHROUGH] toggle ignored: is_xr_active=%s passthrough_supported=%s" % [str(main.is_xr_active), str(main.passthrough_supported)])
		return
	main.settings.passthrough_enabled = not main.settings.passthrough_enabled
	apply_passthrough(main.settings.passthrough_enabled)
	_save_setting(main._ui_pt_btn, "On" if main.settings.passthrough_enabled else "Off")
	main._log("[PASSTHROUGH] toggled to %s and saved" % str(main.settings.passthrough_enabled))
	# AUTO_TABLE's tier/model/cap picks all key off passthrough_enabled (see
	# get_auto_selection()) - and manual Fast's resolution cap does too, same
	# table. Refresh the AI Model button immediately (was showing a stale
	# label otherwise - Auto's resolved model can silently change here, e.g.
	# 2K flips between MiDaS-192-GPU and MiDaS-256-GPU) and re-commit the
	# actual depth config/resolution cap the same debounced way any other
	# AI-3D-affecting change does - nothing else calls apply_stereo() on a
	# passthrough toggle otherwise, so the server-side model/cap would
	# silently stay stale too, not just the label.
	if main.settings.host.ai_3d_speed != 0 and main.ui_controller:
		main.ui_controller.update_stereo_shader()
		_schedule_ai_3d_commit()

func apply_passthrough(enable: bool):
	if not main.is_xr_active:
		return
	_hide_all_backgrounds()
	main._sync_comp_background()
	var interface = XRServer.find_interface("OpenXR")
	if not interface:
		return
	if enable:
		main.get_viewport().transparent_bg = true
		main.world_env.environment.background_mode = Environment.BG_COLOR
		main.world_env.environment.background_color = Color(0, 0, 0, 0)
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	else:
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		main.get_viewport().transparent_bg = false
		apply_background(main.settings.background_mode)

func cycle_background():
	main.settings.background_mode = (main.settings.background_mode + 1) % main.background_labels.size()
	apply_background(main.settings.background_mode)
	_save_setting(main._ui_bg_btn, main.background_labels[main.settings.background_mode])

func apply_background(bg_mode: int):
	if not main.is_xr_active or main.settings.passthrough_enabled:
		return
	_hide_all_backgrounds()
	main.world_env.environment.background_color = Color(0, 0, 0, 1 if bg_mode == 0 else 0)
	if bg_mode > 0:
		var bg_idx = bg_mode - 1
		if bg_idx >= 0 and bg_idx < main.bg_names.size():
			var bg = main.get_node_or_null(main.bg_names[bg_idx])
			if bg:
				bg.visible = true
				bg.emitting = true
	main._sync_comp_background()

func _hide_all_backgrounds():
	for name in main.bg_names:
		var bg = main.get_node_or_null(name)
		if bg:
			bg.visible = false
			bg.emitting = false

func cycle_cursor_mode():
	main.settings.cursor_mode = (main.settings.cursor_mode + 1) % main.cursor_labels.size()
	_save_setting(main._ui_cursor_btn, main.cursor_labels[main.settings.cursor_mode])

func cycle_steady():
	main.settings.pointer_steady = (main.settings.pointer_steady + 1) % main.pointer_steady_labels.size()
	main._reset_steady_filter()
	_save_setting(main._ui_steady_btn, main.pointer_steady_labels[main.settings.pointer_steady])

func cycle_double_click_mode():
	main.settings.double_click_mode = (main.settings.double_click_mode + 1) % main.double_click_mode_labels.size()
	_save_setting(main._ui_double_click_btn, main.double_click_mode_labels[main.settings.double_click_mode])

func is_codec_available(idx: int) -> bool:
	var client_ok = false
	var server_ok = false
	match idx:
		0:
			client_ok = main._client_codec_support.get("h264", true)
			server_ok = main._server_codec_support.get("h264", true)
		1:
			client_ok = main._client_codec_support.get("hevc", true)
			server_ok = main._server_codec_support.get("hevc", true)
		2:
			client_ok = main._client_codec_support.get("av1", true)
			server_ok = main._server_codec_support.get("av1", true)
		3:
			client_ok = main._client_codec_support.get("raw", true)
			server_ok = main._server_codec_support.get("raw", true)
	if main._server_codec_support.is_empty():
		return client_ok
	return client_ok and server_ok

func _get_available_codecs() -> PackedInt32Array:
	var result = PackedInt32Array()
	for i in range(main.codec_labels.size()):
		if is_codec_available(i):
			result.append(i)
	return result

func cycle_codec():
	var available = _get_available_codecs()
	if available.is_empty():
		return
	var cur_pos = available.find(main.settings.codec_preference)
	if cur_pos >= 0:
		main.settings.codec_preference = available[(cur_pos + 1) % available.size()]
	else:
		main.settings.codec_preference = available[0]
	main.ui_controller.update_codec_btn()
	# H.264's hardware-decoder dimension cap in compute_requested_resolution() is keyed
	# off codec_preference - recompute host_resolution now that it just changed, or a
	# switch to H.264 while already at (e.g.) 100% would restart still requesting the
	# uncapped resolution left over from whatever codec was active before.
	main.host_resolution = main.compute_requested_resolution()
	refresh_resolution_btn_label()
	main.state_manager.save_state()
	if main.is_streaming:
		_schedule_stream_restart()

func fallback_codec():
	if is_codec_available(1):
		main.settings.codec_preference = 1
	else:
		var available = _get_available_codecs()
		main.settings.codec_preference = available[0] if not available.is_empty() else 0

func cycle_sharpen_mode():
	var choices := get_sharpen_choices()
	var current_idx := choices.find(main.settings.sharpen_mode)
	main.settings.sharpen_mode = choices[(maxi(current_idx, -1) + 1) % choices.size()]
	_save_setting(main._ui_sharpen_btn, get_sharpen_label(main.settings.sharpen_mode))
	apply_filter()

func get_sharpen_choices() -> Array:
	return SettingsPlatformPolicy.sharpen_choices(
		OS.get_name(),
		main.SHARPEN_RUNTIME_NORMAL,
		main.SHARPEN_RUNTIME_QUALITY,
		main.sharpen_labels.size())

func get_sharpen_label(mode: int) -> String:
	return SettingsPlatformPolicy.sharpen_label(
		OS.get_name(),
		mode,
		main.SHARPEN_RUNTIME_NORMAL,
		main.SHARPEN_RUNTIME_QUALITY,
		main.sharpen_labels)

func cycle_brightness():
	var idx = PICTURE_BRIGHTNESS_VALUES.find(main.settings.brightness_pct)
	main.settings.brightness_pct = PICTURE_BRIGHTNESS_VALUES[(maxi(idx, 0) + 1) % PICTURE_BRIGHTNESS_VALUES.size()]
	_save_setting(main._ui_brightness_btn, "%+d%%" % main.settings.brightness_pct)
	apply_filter()

func cycle_contrast():
	var idx = PICTURE_CONTRAST_VALUES.find(main.settings.contrast_pct)
	main.settings.contrast_pct = PICTURE_CONTRAST_VALUES[(maxi(idx, 0) + 1) % PICTURE_CONTRAST_VALUES.size()]
	_save_setting(main._ui_contrast_btn, "%d%%" % main.settings.contrast_pct)
	apply_filter()

func cycle_gamma():
	var idx = PICTURE_GAMMA_VALUES.find(main.settings.gamma_pct)
	main.settings.gamma_pct = PICTURE_GAMMA_VALUES[(maxi(idx, 0) + 1) % PICTURE_GAMMA_VALUES.size()]
	_save_setting(main._ui_gamma_btn, "%d%%" % main.settings.gamma_pct)
	apply_filter()

func cycle_ambient_mode():
	main.settings.ambient_mode = (main.settings.ambient_mode + 1) % main.ambient_mode_labels.size()
	_save_setting(main._ui_ambient_btn, main.ambient_mode_labels[main.settings.ambient_mode])
	main.comp.apply_ambient_settings()
	main.ui_controller.update_ambient_btn_state()

func cycle_ambient_color():
	main.settings.ambient_color = (main.settings.ambient_color + 1) % main.ambient_color_labels.size()
	_save_setting(main._ui_ambient_color_btn, main.ambient_color_labels[main.settings.ambient_color])
	main.comp.apply_ambient_settings()
	main.ui_controller.update_ambient_btn_state()

func cycle_auto_reconnect():
	main.settings.auto_reconnect_enabled = not main.settings.auto_reconnect_enabled
	if main.stream_backend and main.stream_backend._v2:
		main.stream_backend._v2.set_auto_reconnect(main.settings.auto_reconnect_enabled)
	_save_setting(main._ui_reconnect_btn, "On" if main.settings.auto_reconnect_enabled else "Off")

func cycle_quick_start():
	main.settings.quick_start_enabled = not main.settings.quick_start_enabled
	_save_setting(main._ui_quick_start_btn, "On" if main.settings.quick_start_enabled else "Off")

func cycle_idle_timeout():
	var idx = idle_values.find(main.settings.idle_timeout_min)
	idx = (idx + 1) % idle_values.size()
	main.settings.idle_timeout_min = idle_values[idx]
	_save_setting(main._ui_idle_btn, idle_labels[idx])

func toggle_host_cursor():
	if not main._host_cursor_toggle_supported or not main.is_streaming:
		return
	var target = not main.host_cursor_visible
	main.stream_backend.set_cursor_visible(main.current_host_id, target, func(response: Dictionary):
		if response.get("status", "") == "success":
			main.host_cursor_visible = response.get("visible", target)
			main.ui_controller.update_host_cursor_btn_state()
	)

func apply_filter():
	if not main.is_xr_active:
		return
	# The standalone Blur control was removed. Keep the legacy shader uniform
	# neutral; its neighbourhood taps remain available only for shader-sharpen
	# fallback on runtimes without compositor sharpening.
	var filter_val = 0
	var runtime_sharpen_requested = main.settings.sharpen_mode >= main.SHARPEN_RUNTIME_NORMAL
	var runtime_sharpen_active = main.comp.apply_compositor_sharpen(main.settings.sharpen_mode) if main.comp else false
	# Retain an application-shader fallback for desktop, stock Godot templates,
	# and runtimes that do not advertise XR_FB_composition_layer_settings.
	var sharp_val: float
	if runtime_sharpen_requested:
		sharp_val = 0.0 if runtime_sharpen_active else (0.5 if main.settings.sharpen_mode == main.SHARPEN_RUNTIME_NORMAL else 1.0)
	else:
		sharp_val = float(main.settings.sharpen_mode) * 0.5
	# Picture tab (2026-08-31) - percent state -> shader-unit conversion
	# lives here, shaders themselves stay unit-agnostic (0.0/1.0/1.0
	# neutral defaults).
	var brightness_val = main.settings.brightness_pct / 100.0
	var contrast_val = main.settings.contrast_pct / 100.0
	var gamma_val = main.settings.gamma_pct / 100.0
	var picture_adjusted = main.settings.brightness_pct != 0 or main.settings.contrast_pct != 100 or main.settings.gamma_pct != 100
	# Keep pow() and the three grading uniforms out of the default mesh and
	# composition shader programs. Shader swaps only occur when crossing the
	# neutral/adjusted boundary, not for every value within that state.
	if not _stereo_sdr_shader:
		_stereo_sdr_shader = load("res://src/shaders/stereo_screen.gdshader")
	if not _stereo_picture_shader:
		_stereo_picture_shader = load("res://src/shaders/stereo_screen_picture.gdshader")
	var mat = main.screen_mesh.material_override
	if mat and mat is ShaderMaterial:
		var desired_shader = _stereo_picture_shader if picture_adjusted else _stereo_sdr_shader
		if mat.shader != desired_shader:
			mat.shader = desired_shader
		mat.set_shader_parameter("filter_mode", filter_val)
		mat.set_shader_parameter("sharpen", sharp_val)
		mat.set_shader_parameter("blur_scale", main.get_blur_scale(main.primary_screen))
		mat.set_shader_parameter("brightness", brightness_val)
		mat.set_shader_parameter("contrast", contrast_val)
		mat.set_shader_parameter("gamma", gamma_val)
	main.comp.refresh_picture_shader_state()
	for s in main.screens:
		for cm in main.comp.get_shader_mats(s):
			if cm:
				cm.set_shader_parameter("filter_mode", filter_val)
				cm.set_shader_parameter("sharpen", sharp_val)
				cm.set_shader_parameter("blur_scale", main.get_blur_scale(s))
				cm.set_shader_parameter("brightness", brightness_val)
				cm.set_shader_parameter("contrast", contrast_val)
				cm.set_shader_parameter("gamma", gamma_val)

func apply_display_refresh_rate() -> bool:
	if not main.is_xr_active:
		return false
	var interface = XRServer.find_interface("OpenXR")
	if not interface:
		return false
	_refresh_request_seq += 1
	var request_seq = _refresh_request_seq
	var target_hz: float = float(main.settings.host.stream_fps)
	match main.settings.host.stream_fps:
		30: target_hz = 90.0
		# 2026-08-29: testing 120Hz again now that stereo rendering is
		# projectionless (no more per-eye mesh reprojection cost) - this was
		# 72.0 since 1132efd (2026-06-12), when 120Hz was too expensive for
		# the old mesh-projection render path and caused stutter. Revert to
		# 72.0 if that's still true here.
		60: target_hz = 120.0
	var available = interface.get_available_display_refresh_rates()
	Engine.max_fps = main.settings.host.stream_fps
	if available.is_empty():
		main._log("[REFRESH] No available refresh rates reported")
		main.display_refresh_rate = target_hz
		return false
	available.sort()
	var current_hz: float = interface.get_display_refresh_rate()
	main._log("[REFRESH] Runtime rates=%s current=%.0fHz target=%.0fHz" % [str(available), current_hz, target_hz])

	# Preserve an exact current rate. Otherwise request every Quest 3 extended
	# target through the standard API up to the documented 207 Hz maximum;
	# verification below selects a reported fallback if the runtime rejects it.
	var target_already_active := absf(current_hz - target_hz) < 0.6
	var best: float = 0.0
	if target_already_active:
		best = current_hz
	elif main.device_is_quest3 and target_hz > 120.0 and target_hz <= QUEST3_REFRESH_REQUEST_MAX:
		# Meta deprecated the enumeration API; HorizonOS still returns only
		# legacy presets even though Quest 3 accepts arbitrary integer rates.
		# Request the unlisted rate directly, then verify it and fall back to
		# the reported list on older/currently-limited runtime versions.
		interface.set_display_refresh_rate(target_hz)
		await main.get_tree().create_timer(REFRESH_SURFACE_SETTLE_SEC).timeout
		if request_seq != _refresh_request_seq:
			return false
		var applied_hz: float = interface.get_display_refresh_rate()
		if absf(applied_hz - target_hz) < 0.6:
			best = applied_hz
		else:
			best = _reported_refresh_fallback(available, target_hz)
			interface.set_display_refresh_rate(best)
			main._log("[REFRESH] Quest 3 rejected unlisted %.0fHz (actual %.0fHz); using reported %.0fHz" % [target_hz, applied_hz, best])
			await main.get_tree().create_timer(REFRESH_SURFACE_SETTLE_SEC).timeout
			if request_seq != _refresh_request_seq:
				return false
	else:
		best = _reported_refresh_fallback(available, target_hz)
		interface.set_display_refresh_rate(best)
		await main.get_tree().create_timer(REFRESH_SURFACE_SETTLE_SEC).timeout
		if request_seq != _refresh_request_seq:
			return false
	main.display_refresh_rate = best
	# 2026-08-29: capping render fps to the stream's own fps again (was
	# uncapped since 8ffa8fe, 2026-05-05, "remove 60fps cap causing Quest ASW
	# reprojection blur") - testing whether that ASW blur was a symptom of
	# the old mesh-projection render path specifically, now that rendering
	# is projectionless. Revert to 0 (uncapped) if the blur is still there.
	if target_already_active:
		main._log("[REFRESH] Preserved active %.0fHz for %dfps, capped render to %dfps" % [best, main.settings.host.stream_fps, main.settings.host.stream_fps])
	elif absf(best - target_hz) < 0.6:
		main._log("[REFRESH] Set headset to %.0fHz for %dfps, capped render to %dfps" % [best, main.settings.host.stream_fps, main.settings.host.stream_fps])
	else:
		main._log("[REFRESH] %.0fHz unavailable; fell back to reported %.0fHz for %dfps stream, capped render to %dfps" % [target_hz, best, main.settings.host.stream_fps, main.settings.host.stream_fps])
	return true

func _reported_refresh_fallback(available: Array, target_hz: float) -> float:
	var best := 0.0
	for rate in available:
		if rate >= target_hz and (best == 0.0 or rate < best):
			best = rate
	if best == 0.0:
		best = available[available.size() - 1]
	# Changing the OpenXR display rate tears down/recreates runtime-owned
	# surfaces on Quest, which can race a stream restart's just-rebuilt native
	# and Godot GLES resources. That protection now lives in the caller,
	# apply_display_refresh_rate()'s target_already_active check above (computed
	# once, before either set_display_refresh_rate() call site) - this helper
	# only computes which rate to fall back to, it doesn't apply anything.
	return best

func cycle_fps():
	var idx = STREAM_FPS_RATES.find(main.settings.host.stream_fps)
	var next_idx = 0 if idx < 0 else (idx + 1) % STREAM_FPS_RATES.size()
	main.settings.host.stream_fps = STREAM_FPS_RATES[next_idx]
	_save_setting(main._ui_fps_btn, "%d" % main.settings.host.stream_fps)
	if main.is_streaming:
		_schedule_stream_restart()
	else:
		apply_display_refresh_rate()

func cycle_resolution():
	if main.settings.host.is_polaris_host:
		var opts = main.compute_resolution_options()
		# opts[0] is always the current max (see compute_resolution_options()) - find by
		# value for everything else, but treat "currently at-or-past the max" as being
		# at slot 0 rather than falling through to opts.find()'s -1-not-found case,
		# which used to skip straight past MAX to the second entry on the very next
		# click after a codec/monitor change made the old selection unreachable.
		var idx = 0 if main.settings.host.resolution_scale_pct >= opts[0] else opts.find(main.settings.host.resolution_scale_pct)
		main.settings.host.resolution_scale_pct = opts[(maxi(idx, 0) + 1) % opts.size()]
	else:
		main.settings.host.resolution_idx = (main.settings.host.resolution_idx + 1) % main.resolutions.size()
	main.host_resolution = main.compute_requested_resolution()
	_save_setting(main._ui_res_btn, _resolution_btn_label())
	_schedule_stream_restart()

# The MAX ceiling (compute_resolution_options()[0]) depends on codec_preference
# and native_resolution, both of which can change without the user ever
# touching the resolution button itself (codec cycling, monitors being
# added/removed, the host's real desktop turning out a different size than
# assumed) - call this after any of those to keep the button's label honest
# instead of showing a stale percentage that no longer matches what's actually
# being requested.
func refresh_resolution_btn_label():
	if main._ui_res_btn:
		main.ui_controller.update_option_btn(main._ui_res_btn, _resolution_btn_label())

func _resolution_btn_label() -> String:
	if not main.settings.host.is_polaris_host:
		return main.resolution_labels[main.settings.host.resolution_idx]
	var opts = main.compute_resolution_options()
	# Show the actual resulting pixel dimensions, not just an abstract
	# percentage - a bare "%" doesn't tell you what you're really getting once
	# any of compute_requested_resolution()'s caps are in play (which is
	# exactly the case whenever this shows "MAX"). No parens/space between
	# the two - this has to fit the same 250px/26pt budget every other
	# option button uses (2026-08-18: this used to get its own wider button
	# + smaller font instead of fitting the shared size, which looked
	# inconsistent next to the rest of the row).
	var res = main.compute_requested_resolution()
	var dims = "%dx%d" % [res.x, res.y]
	if main.settings.host.resolution_scale_pct >= opts[0]:
		return "MAX %s" % dims
	return "%d%% %s" % [main.settings.host.resolution_scale_pct, dims]

# Best-effort, cached, one-time-per-host-selection probe for whether this host
# is a Polaris server (which reports its real, possibly multi-monitor desktop
# size via a display-manifest extension no other GameStream-compatible host
# implements) vs everything else, e.g. Sunshine, which is client-driven - the
# client picks a resolution and the host adapts to match it, so there's
# nothing for it to report and main.settings.host.is_polaris_host correctly defaults to
# false (the old fixed-list picker) for it. Deliberately decoupled from the
# connect/launch flow itself: the original pre-launch probe (removed in
# 6a5c17d) shared an HTTP/session lock with establish_stream() and was a
# plausible contributor to a real connection hang. This fires once when a
# host is selected in the welcome-screen UI, well before any stream launch,
# and never blocks or gates anything - is_polaris_host just keeps whatever
# value it already had (loaded from host_state.cfg, or the false default for
# a never-seen host) until this resolves.
func detect_polaris_host(ip: String, host_id: int):
	if ip.is_empty() or host_id < 0:
		return
	main.stream_backend.fetch_display_manifest(host_id, func(manifest: Dictionary):
		var was_polaris = main.settings.host.is_polaris_host
		main.settings.host.is_polaris_host = manifest is Dictionary and not manifest.is_empty()
		if main.settings.host.is_polaris_host != was_polaris:
			refresh_resolution_btn_label()
			main.ui_controller.update_monitor_tab()
			main.state_manager.save_host_state()
	)

func cycle_bitrate():
	main.settings.host.bitrate_idx += 1
	if main.settings.host.bitrate_idx >= main.bitrate_labels.size():
		main.settings.host.bitrate_idx = -1
	var label = main.bitrate_labels[main.settings.host.bitrate_idx + 1] if main.settings.host.bitrate_idx >= 0 else "Auto"
	_save_setting(main._ui_bitrate_btn, label)
	_schedule_stream_restart()

func cycle_double_h():
	main.settings.host.double_h = not main.settings.host.double_h
	main.state_manager.save_state()
	_schedule_stream_restart()

func _schedule_stream_restart():
	if not main.is_streaming or main.current_host_id < 0:
		return
	_restart_pending = true
	_restart_seq += 1
	var my_seq = _restart_seq
	await main.get_tree().create_timer(0.8).timeout
	if _restart_seq != my_seq:
		return
	_restart_pending = false
	main._log("[RESTART] Restarting stream")
	main.session_lifecycle.request_restart()
	# The native renderer owns an OpenXR swapchain and a shared EGL context.
	# Stop it before changing the display rate or destroying decoder textures;
	# otherwise the runtime can recreate its display surface while either
	# renderer still references the old one, which crashes Quest's GLThread.
	if main.video_presentation:
		main.video_presentation.deactivate_native(false)
	# Stop the composition layer shader from referencing the current session's
	# texture BEFORE tearing the connection down. stop_play_stream() triggers
	# native decoder cleanup, which frees the underlying GPU texture/uniform
	# set synchronously (on the decode/cleanup thread) - if the shader
	# material still points at it when that happens, the OpenXR compositor's
	# own render pass (independent of our own binding code) can end up
	# rebuilding a uniform set against an already-freed texture on the render
	# thread, which crashes (not just renders wrong). Clearing first and
	# yielding a frame gives the renderer a chance to actually pick up the
	# null texture before the free happens, closing that race instead of
	# just narrowing it.
	main._clear_comp_yuv_textures()
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	main.stream_backend.stop_play_stream()
	await main.get_tree().create_timer(0.5).timeout
	# start_stream() is the single owner of refresh application at a connection
	# boundary. It awaits the Quest surface transition before resizing Godot
	# viewports or creating decoder/native-renderer resources.
	await main.stream_manager.start_stream(main.current_host_id, main._selected_app_id)

func toggle_hand_tracking():
	main.settings.tracking_mode = (main.settings.tracking_mode + 1) % 2
	main.state_manager.save_state()
	main.state_manager.sync_ui_to_settings()

func apply_screen_layout(new_layout: ScreenLayout):
	var err = new_layout.validate(new_layout.frame_size)
	if err != "":
		main._log("[LAYOUT] Refusing invalid layout: %s" % err)
		return
	var wanted_ids: Array = []
	for m in new_layout.enabled_monitors():
		wanted_ids.append(m.id)
	# The screen about to be replaced as primary (e.g. the welcome screen's
	# placeholder on the very first real connect) - used below to hand its exact
	# position off to whatever takes over as primary, instead of add_screen()
	# positioning the new one "next to" a screen that's about to disappear.
	var old_primary_being_replaced: VRScreen = main.primary_screen if (main.primary_screen and not wanted_ids.has(main.primary_screen.monitor_id)) else null
	var new_primary: VRScreen = null
	# add_screen() positions each new VRScreen relative to whichever screens
	# already exist, purely by insertion order (grows left/right of primary).
	# The manifest's monitor array order is the host's own RandR enumeration
	# order, not spatial order (confirmed: a 4-monitor grid capture came back
	# as [HDMI-0, DP-0, DP-2, DP-4], not left-to-right) - inserting in that
	# raw order scattered screens in VR space in an order that didn't match
	# their real desktop_rect positions, looking "scrambled". Sort by real
	# x-position first so insertion order matches physical left-to-right order.
	var ordered_monitors := new_layout.enabled_monitors()
	ordered_monitors.sort_custom(func(a, b): return a.desktop_rect.position.x < b.desktop_rect.position.x)
	for m in ordered_monitors:
		var existing: VRScreen = null
		for s in main.screens:
			if s.monitor_id == m.id:
				existing = s
				break
		var s = existing if existing else main.add_screen(m.id, m.desktop_rect.position.x, m.is_primary)
		if s == null:
			continue
		s.apply_monitor(m, new_layout.frame_size)
		if m.is_primary:
			new_primary = s
	if old_primary_being_replaced and new_primary and new_primary != old_primary_being_replaced:
		new_primary.global_transform = old_primary_being_replaced.global_transform
	main.layout = new_layout
	# Reassign primary BEFORE removing unwanted screens below - remove_screen()
	# refuses to remove whatever is currently primary_screen (a real safety net
	# for normal add/remove-monitor flows), but on the very first real connect
	# the welcome screen's placeholder VRScreen *is* primary_screen, with a
	# monitor_id that's essentially never going to match the real manifest's
	# primary id. Removing in the old order left that placeholder permanently
	# stuck (un-removable, since it was still primary_screen at removal time)
	# with its own grab bar, while the real primary got added next to it
	# instead of replacing it - "screen appears in the wrong position, two
	# grab bars" was this, not a positioning bug in add_screen() itself.
	if new_primary and new_primary != main.primary_screen:
		main.set_primary_screen(new_primary)
		# Stereo/AI-3D (switch_to_stereo_comp_layer()) only ever activates
		# whatever was primary AT THE TIME it was called - it sets up that
		# screen's own comp_cylinder_left/right visibility, viewport update
		# mode, and stereo_mode shader param, none of which set_primary_screen()
		# above carries over to the new primary. On the very first real
		# connect (this branch always runs then: the welcome screen's
		# placeholder VRScreen is primary with a monitor_id that can't match
		# any real manifest id), that left the real primary silently stuck in
		# flat/non-stereo comp-layer mode even with SBS/AI-3D still toggled
		# on - looked correct on the welcome screen (where it WAS applied)
		# and broken the moment the stream's real manifest swapped primary in.
		apply_stereo()
	for s in main.screens.duplicate():
		if not wanted_ids.has(s.monitor_id):
			main.remove_screen(s.monitor_id)
	# resize_screen_to_aspect() now calls update_cylinder_params() itself
	# (2026-08-20) - no need to pair it here anymore.
	main.screen_manager.resize_screen_to_aspect(new_layout.frame_size.x, new_layout.frame_size.y)
	if main.comp.in_use and main.is_streaming:
		main.comp.invalidate_yuv_cache()
		main.comp.bind_yuv_textures()
	main.ui_controller.update_monitor_tab()

# ---------------------------------------------------------------------------
# Monitors tab (grid-mode redesign): staged Monitors/Virtual counts + preset
# picker, committed together by Apply. Nothing below auto-restarts the stream
# or touches main.layout/screens until apply_staged_monitor_config() runs -
# per spec this needed "a lot more to consider" than the old per-toggle
# auto-restart behavior above. Grid/free screen placement here is purely
# client-side VR presentation (MonitorGrid) and never touches ScreenLayout/
# MonitorSpec beyond enabled/is_primary, which apply_screen_layout() (above,
# unmodified) already owns.
# ---------------------------------------------------------------------------

func _real_monitor_count() -> int:
	var count = 0
	for m in main.layout.monitors:
		if not m.hint.get("virtual", false) and m.capturable:
			count += 1
	return count

func staged_total() -> int:
	return main._staged_physical_count + main._staged_virtual_count

func _clear_staged_preset_if_mismatched():
	if main._staged_preset_id == &"":
		return
	var p = MonitorPresets.find_preset(String(main._staged_preset_id))
	if p.is_empty() or p.get("screen_count", -1) != staged_total():
		main._staged_preset_id = &""

# Call whenever the Monitors tab is opened, so its dropdowns reflect what's
# actually live rather than whatever was last staged in a previous visit.
func sync_staged_from_current_layout():
	var real_enabled = 0
	var virtual_enabled = 0
	for m in main.layout.monitors:
		if not m.enabled:
			continue
		if m.hint.get("virtual", false):
			virtual_enabled += 1
		else:
			real_enabled += 1
	main._staged_physical_count = maxi(real_enabled, 1)
	main._staged_virtual_count = virtual_enabled
	main._staged_preset_id = &""

func stage_monitor_count(n: int):
	main._staged_physical_count = clampi(n, 1, maxi(_real_monitor_count(), 1))
	main._staged_virtual_count = clampi(main._staged_virtual_count, 0, main.MAX_SCREENS - main._staged_physical_count)
	_clear_staged_preset_if_mismatched()
	main._log("[LAYOUT] stage_monitor_count(%d): real_monitor_count=%d -> staged_physical=%d" % [n, _real_monitor_count(), main._staged_physical_count])

func stage_virtual_count(n: int):
	main._staged_virtual_count = clampi(n, 0, main.MAX_SCREENS - main._staged_physical_count)
	_clear_staged_preset_if_mismatched()

func select_monitor_preset(id: StringName):
	if MonitorPresets.find_preset(String(id)).is_empty():
		return
	main._staged_preset_id = id

# Builds the ScreenLayout implied by the current staged counts: the N
# leftmost real (non-virtual) monitors from the live manifest, plus M
# client-side-only virtual placeholders (hint.virtual=true, see
# stream_manager.gd::_compute_capture_outputs() for why those are excluded
# from the real outputs= request). Real monitors' frame_rect/desktop_rect are
# carried over untouched; only enabled/is_primary and the synthetic virtual
# entries are new.
func _build_staged_layout() -> ScreenLayout:
	var real_monitors: Array = []
	for m in main.layout.monitors:
		# Excludes capturable=false (connected-but-disabled host outputs) too, not just
		# virtual placeholders - otherwise the N-leftmost-by-x pick below can select a
		# monitor the host will always refuse, silently wasting a slot (the host drops it
		# from capture but this client still thinks it asked for N real monitors).
		if not m.hint.get("virtual", false) and m.capturable:
			real_monitors.append(m)
	main._log("[LAYOUT] _build_staged_layout: main.layout.monitors=%d real=%d staged_physical=%d staged_virtual=%d source=%s" % [main.layout.monitors.size(), real_monitors.size(), main._staged_physical_count, main._staged_virtual_count, str(main.layout.source)])
	if real_monitors.is_empty():
		return null
	real_monitors.sort_custom(func(a, b): return a.desktop_rect.position.x < b.desktop_rect.position.x)
	var phys_count = clampi(main._staged_physical_count, 1, real_monitors.size())
	var picked: Array = real_monitors.slice(0, phys_count)

	var new_layout := ScreenLayout.new()
	new_layout.version = main.layout.version
	new_layout.source = main.layout.source
	new_layout.frame_size = main.layout.frame_size
	new_layout.desktop_bounds = main.layout.desktop_bounds

	for m in real_monitors:
		var nm := ScreenLayout.MonitorSpec.new()
		nm.id = m.id
		nm.label = m.label
		nm.frame_rect = m.frame_rect
		nm.desktop_rect = m.desktop_rect
		nm.hint = {}
		nm.enabled = picked.has(m)
		nm.is_primary = false
		new_layout.monitors.append(nm)

	var vcount = clampi(main._staged_virtual_count, 0, main.MAX_SCREENS - phys_count)
	_append_virtual_placeholders(new_layout, vcount)

	var enabled := new_layout.enabled_monitors()
	if enabled.is_empty():
		return null
	enabled[0].is_primary = true
	return new_layout

# Client-side-only synthetic monitors (no real RandR output behind them - see
# stream_manager.gd::_compute_capture_outputs(), which skips hint.virtual
# entries when building the real outputs= request). Placed just past the real
# desktop's right edge so they don't overlap any real monitor's desktop_rect.
func _append_virtual_placeholders(layout: ScreenLayout, vcount: int):
	var max_x = layout.desktop_bounds.position.x + layout.desktop_bounds.size.x
	for i in range(vcount):
		var vm := ScreenLayout.MonitorSpec.new()
		vm.id = StringName("virtual_%d" % i)
		vm.label = ""
		vm.enabled = true
		vm.is_primary = false
		vm.frame_rect = Rect2i(0, 0, layout.frame_size.x, layout.frame_size.y)
		vm.desktop_rect = Rect2i(max_x + i * layout.frame_size.x, layout.desktop_bounds.position.y, layout.frame_size.x, layout.frame_size.y)
		vm.hint = {"virtual": true}
		layout.monitors.append(vm)

# Primary first (never repositioned by preset apply - it's the free-mode
# anchor everything else is placed relative to), then the rest sorted by real
# desktop x position - deterministic and matches apply_screen_layout()'s own
# insertion order in the common case.
func _screens_in_ordinal_order() -> Array:
	if not main.primary_screen:
		return []
	var rest: Array = []
	for s in main.screens:
		if s != main.primary_screen:
			rest.append(s)
	rest.sort_custom(func(a, b):
		var ax = a.monitor.desktop_rect.position.x if a.monitor else a.global_position.x
		var bx = b.monitor.desktop_rect.position.x if b.monitor else b.global_position.x
		return ax < bx
	)
	var ordered: Array = [main.primary_screen]
	ordered.append_array(rest)
	return ordered

func _place_secondaries_default(secondaries: Array):
	var primary: VRScreen = main.primary_screen
	if primary.grid_pos == Vector2i(-1, -1):
		primary.grid_pos = Vector2i(3, 1)
	primary.grid_mode = true
	var occupied: Array = [primary.grid_pos]
	for s in secondaries:
		var cand = main.nearest_free_grid_cell(s.global_position, occupied, primary.grid_pos.x, primary.grid_pos.y)
		if cand.x < 0:
			continue
		occupied.append(cand)
		s.grid_mode = true
		s.grid_pos = cand
		s.global_transform = main.grid_cell_transform(cand.x, cand.y, primary.grid_pos.x, primary.grid_pos.y)

# Applies the selected preset's per-screen grid/free position onto the
# VRScreens apply_screen_layout() just created/kept, in ordinal order. Falls
# back to a sane grid default (primary keeps its grid_pos or [3,1], others
# auto-placed via nearest_free_cell) when no preset is staged or its
# screen_count no longer matches what's actually enabled.
func _apply_preset_positions_to_screens():
	var ordered: Array = _screens_in_ordinal_order()
	if ordered.is_empty():
		return
	var primary: VRScreen = ordered[0]
	var preset := {}
	if main._staged_preset_id != &"":
		var p = MonitorPresets.find_preset(String(main._staged_preset_id))
		if not p.is_empty() and p.get("screen_count", -1) == ordered.size():
			preset = p
	if preset.is_empty():
		_place_secondaries_default(ordered.slice(1))
	else:
		var screens_data: Array = preset.get("screens", [])
		for i in range(ordered.size()):
			var s: VRScreen = ordered[i]
			var data: Dictionary = screens_data[i]
			var is_grid: bool = data.get("grid_mode", true)
			s.grid_mode = is_grid
			if is_grid:
				var gp: Array = data.get("grid_pos", [3, 1])
				s.grid_pos = Vector2i(gp[0], gp[1])
			if s == primary:
				continue
			if is_grid:
				s.global_transform = main.grid_cell_transform(s.grid_pos.x, s.grid_pos.y, primary.grid_pos.x, primary.grid_pos.y)
			else:
				var fp: Array = data.get("free_pos", [s.position.x, s.position.y, s.position.z])
				var fr: Array = data.get("free_rot", [s.rotation.x, s.rotation.y, s.rotation.z])
				s.position = Vector3(fp[0], fp[1], fp[2])
				s.rotation = Vector3(fr[0], fr[1], fr[2])
	# Primary itself is deliberately never repositioned above (it's the free-
	# mode anchor everything else is placed relative to) - but Godot's
	# CollisionObject3D only pushes a node's transform to PhysicsServer3D on
	# NOTIFICATION_TRANSFORM_CHANGED, which a node that never actually moves
	# never receives. Confirmed live: right after adding a second monitor,
	# primary's own pointer/raycast interaction went laggy/unusable (its
	# Area3D's physics-side transform was stale relative to whatever the new
	# secondary's Area3D just did to the broadphase) until manually grabbing
	# and moving primary even slightly, which fixed it - because a real grab
	# always writes global_position, firing the notification this never
	# otherwise gets. Reassigning to its own current transform is a no-op
	# geometrically but still fires that notification, without needing an
	# actual (visible) move.
	primary.global_transform = primary.global_transform
	if main.comp.available:
		main.comp.update_cylinder_params()

# Re-derives world transform for every grid-mode secondary from its existing
# grid_pos. Needed whenever curvature changes: a grid cell's world position
# depends on curvature/radius (_grid_screen_transforms() measures gaps against
# the curved edge, see main.gd), but grid_pos itself is just coordinates and
# doesn't change with curvature - so without this, a screen placed under the
# old curvature keeps its old (now wrong) position/rotation until something
# else, like a drag, happens to recompute it.
func reflow_grid_screens():
	var primary: VRScreen = main.primary_screen
	if not primary or primary.grid_pos == Vector2i(-1, -1):
		return
	for s in main.screens:
		if s == primary or not s.grid_mode or s.grid_pos == Vector2i(-1, -1):
			continue
		s.global_transform = main.grid_cell_transform(s.grid_pos.x, s.grid_pos.y, primary.grid_pos.x, primary.grid_pos.y)

# The only place that actually calls apply_screen_layout() from the new
# Monitors tab. Cycling the Monitors/Virtual dropdowns or picking a preset
# (Row 1/Row 2) never restarts anything on their own - clarification #9 asked
# for that ("a lot more to consider") - but Apply is the explicit commit
# point, and if the real (server-facing) monitor selection actually changed,
# the host needs a fresh outputs= request to capture the new set.
#
# A monitor's frame_rect (its position within the CAPTURED/composited video
# frame) is only meaningful once it's actually part of a live capture - one
# we haven't asked the host to capture yet reports frame_rect (0,0) in the
# manifest (there's no video content for it at all), which
# apply_screen_layout()'s validate() correctly refuses. So when the real
# selection changes, this does NOT try to build/position VR screens against
# that stale/invalid geometry up front - it only updates which real monitors
# are enabled/primary (what the next launch's outputs= will request) and
# restarts; the restart's own fresh manifest response
# (stream_manager.gd::_on_v2_launch_response) re-derives and applies a fully
# valid ScreenLayout once the host actually replies with real geometry for the
# new set, and finish_pending_monitor_apply() (called from there) finishes the
# job - adding virtual placeholders (never reported by any real manifest) and
# positioning every screen per the staged preset.
func apply_staged_monitor_config():
	var target = _build_staged_layout()
	if target == null:
		main._log("[LAYOUT] apply_staged_monitor_config: _build_staged_layout() returned null (no real monitors known yet)")
		return
	var old_real_ids: Array = []
	for m in main.layout.enabled_monitors():
		if not m.hint.get("virtual", false):
			old_real_ids.append(m.id)
	var new_real_ids: Array = []
	for m in target.enabled_monitors():
		if not m.hint.get("virtual", false):
			new_real_ids.append(m.id)
	var real_changed = old_real_ids != new_real_ids
	main._log("[LAYOUT] apply_staged_monitor_config: staged=%d+%dvirtual old_real=%s new_real=%s real_changed=%s streaming=%s" % [main._staged_physical_count, main._staged_virtual_count, str(old_real_ids), str(new_real_ids), str(real_changed), str(main.is_streaming)])

	if real_changed and main.is_streaming:
		var new_primary = target.get_primary()
		var new_primary_id = new_primary.id if new_primary else &""
		for m in main.layout.monitors:
			if m.hint.get("virtual", false):
				continue
			m.enabled = new_real_ids.has(m.id)
			m.is_primary = (m.id == new_primary_id)
		# Narrowing to exactly one real monitor makes the resulting capture
		# size exactly knowable right now, client-side: that monitor's own
		# frame_rect (already reported in the last manifest) doesn't change
		# size when captured alone - only its position within the composite
		# does (ScreenLayout always repositions a lone monitor to the
		# origin). Update native_resolution before scheduling the restart so
		# the very first launch of the new session already requests the
		# right size, instead of restarting at the OLD (still-cached)
		# composite size and relying on _process()'s "doesn't match cached
		# size" mismatch-retry to correct it via a SECOND restart -
		# confirmed via logcat to cost a real ~10s stall decoding an
		# oversized stream before self-correcting. General N>1 targets are
		# deliberately left to that same mismatch-retry (see its comment in
		# main.gd) - an arbitrary multi-monitor composite's exact frame_size
		# depends on host-side gap-filling this client can't predict.
		if new_real_ids.size() == 1:
			for m in main.layout.monitors:
				if m.id == new_real_ids[0]:
					main.settings.host.native_resolution = m.frame_rect.size
					break
		main._pending_monitor_apply = true
		_schedule_stream_restart()
	else:
		apply_screen_layout(target)
		_apply_preset_positions_to_screens()

	main.host_resolution = main.compute_requested_resolution()
	main.state_manager.save_host_state()
	if main._ui_status_label:
		if real_changed and main.is_streaming:
			main.ui_controller.set_status("Applying - restarting stream for new monitor selection...")
		elif main._staged_virtual_count > 0:
			main.ui_controller.set_status("%d virtual monitor(s) - placeholder only, not yet requested from server" % main._staged_virtual_count)
		else:
			main.ui_controller.set_status("Monitor layout applied")

# Called once by stream_manager.gd's launch-response handler right after it
# applies the fresh post-restart manifest (real frame_rect data now valid for
# the newly-requested set). Re-adds any staged virtual placeholders (the
# server-sourced manifest only ever describes real outputs, so
# apply_screen_layout() would otherwise have just dropped them) and applies
# the staged preset's grid/free positions now that every screen actually exists.
func finish_pending_monitor_apply():
	if main._staged_virtual_count > 0:
		var with_virtual := ScreenLayout.new()
		with_virtual.version = main.layout.version
		with_virtual.source = main.layout.source
		with_virtual.frame_size = main.layout.frame_size
		with_virtual.desktop_bounds = main.layout.desktop_bounds
		with_virtual.monitors = main.layout.monitors.duplicate()
		_append_virtual_placeholders(with_virtual, main._staged_virtual_count)
		apply_screen_layout(with_virtual)
	_apply_preset_positions_to_screens()

func save_current_as_preset():
	var ordered = _screens_in_ordinal_order()
	if ordered.is_empty():
		return
	var screens_data: Array = []
	for s in ordered:
		var gp = s.grid_pos if s.grid_pos != Vector2i(-1, -1) else Vector2i(3, 1)
		screens_data.append({
			"is_primary": s == main.primary_screen,
			"grid_mode": s.grid_mode,
			"grid_pos": [gp.x, gp.y],
			"free_pos": [s.position.x, s.position.y, s.position.z],
			"free_rot": [s.rotation.x, s.rotation.y, s.rotation.z],
		})
	var customs = MonitorPresets.load_custom_presets()
	var id = MonitorPresets.next_custom_id(customs)
	customs.append({
		"version": 1,
		"id": id,
		"built_in": false,
		"screen_count": screens_data.size(),
		"screens": screens_data,
	})
	MonitorPresets.save_custom_presets(customs)
	main._staged_preset_id = StringName(id)
	if main._ui_status_label:
		main.ui_controller.set_status("Preset saved")

func remove_selected_preset():
	if main._staged_preset_id == &"":
		return
	var p = MonitorPresets.find_preset(String(main._staged_preset_id))
	if p.is_empty() or p.get("built_in", false):
		return
	MonitorPresets.remove_custom_preset(String(main._staged_preset_id))
	main._staged_preset_id = &""
	if main._ui_status_label:
		main.ui_controller.set_status("Preset removed")

func toggle_grid_mode():
	main.settings.grid_mode_enabled = not main.settings.grid_mode_enabled
	main.state_manager.save_state()
	if main._ui_grid_mode_btn:
		main.ui_controller.update_option_btn(main._ui_grid_mode_btn, "On" if main.settings.grid_mode_enabled else "Off")
