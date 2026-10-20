class_name PCVRWorkspaceHandover
extends RefCounted
## DEV handover over a prepared standby receiver. Never replaces PCVRSession's
## clean-welcome test policy or owns a second OpenXR session/frame loop.
enum State { IDLE, WAITING, DRAINING, ACTIVE, STOPPING }
const STARTUP_TIMEOUT := 20.0
var main
var state := State.IDLE
var generation := 0
var error := ""
var _control
var _lease := ""
var _elapsed := 0.0
var _hold := 0.0
var _drain_started := 0.0
var _saved: Dictionary = {}

func _init(owner) -> void:
	main = owner

func blocks_workspace() -> bool:
	return not _saved.is_empty()

func arm(control) -> bool:
	if state != State.IDLE or not main.pcvr_test.standby_active: return false
	if not main.pcvr_test.backend.has_method("activate_meteor_projection"): return false
	# Initial coexistence scope: one welcome/desktop screen, no browser workspace.
	if main.screens.size() != 1 or main.browser_content_active(): return false
	generation += 1
	state = State.WAITING
	error = ""
	_control = control
	_lease = control.session
	_elapsed = 0.0
	_hold = 0.0
	main._log("[XR-HANDOVER] Armed; desktop retained until application and decoded frame ready")
	return true

func process(delta: float) -> void:
	if state == State.IDLE: return
	_elapsed += delta
	if blocks_workspace(): _enforce_hidden()
	if state == State.STOPPING:
		if not main.pcvr_test.standby_active:
			if blocks_workspace(): _restore_workspace()
			_reset()
		return
	if not main.pcvr_test.standby_active or not _control or _control.state != "prepared" or _control.session != _lease:
		request_stop("XR control or receiver ended")
		return
	var native: Dictionary = main.pcvr_test.backend.get_test_status()
	if str(native.get("state", "failed")) in ["idle", "failed", "stopping"]:
		request_stop("XR native receiver unavailable")
		return
	var runtime: Dictionary = _control.runtime_status
	if str(runtime.get("phase", "")) in ["session_ended", "completed", "cancelled", "failed"]:
		request_stop("XR application ended")
		return
	if state == State.DRAINING and _elapsed - _drain_started >= 3.0:
		request_stop("Desktop layer retirement timed out")
		return
	if state == State.WAITING:
		if _elapsed >= STARTUP_TIMEOUT:
			request_stop("XR handover startup timed out")
		elif runtime.get("phase", "") == "session_active" and native.get("state", "") == "running" and bool(native.get("meteor_frame_ready", false)):
			if main.screens.size() != 1 or main.browser_content_active():
				request_stop("Workspace changed during XR startup")
				return
			state = State.DRAINING
			_drain_started = _elapsed
			if not _capture_and_hide():
				request_stop("Cannot safely suspend desktop presentation")
				return
			_queue_layer_drain(generation)
		return
	if blocks_workspace():
		var held := false
		for hand in [main.right_hand, main.left_hand]:
			if hand and hand.is_button_pressed("by_button"): held = true
		_hold = _hold + delta if held else 0.0
		if _hold >= 1.0: request_stop("Local exit")

func request_stop(reason: String = "Local exit") -> void:
	if state in [State.IDLE, State.STOPPING]: return
	generation += 1 # Invalidate every frame/draw continuation before cleanup.
	error = reason
	state = State.STOPPING
	main._log("[XR-HANDOVER] Stopping: " + reason)
	main.pcvr_test.request_stop()

func handle_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		request_stop()

func _capture_and_hide() -> bool:
	var interface = _xr_interface()
	if not interface or not interface.has_method("get_submit_projection_layer") or not interface.has_method("set_submit_projection_layer"):
		main._log("[XR-HANDOVER] Patched OpenXR projection getter/setter unavailable")
		return false
	var renderer = main.native_xr_renderer
	_saved = {"visible": main.visible, "projection": interface.get_submit_projection_layer(),
		"blend": interface.environment_blend_mode, "transparent": main.get_viewport().transparent_bg,
		"audio_paused": main.audio_player.stream_paused, "mic_paused": main.meteor_microphone._paused,
		"native_suspended": renderer.presentation_suspended}
	if not renderer.set_presentation_suspended(true):
		main._log("[XR-HANDOVER] Native desktop presentation suspension unavailable")
		_saved.clear()
		return false
	main.xr_interaction.cancel_transient_interactions("XR handover")
	main.input_handler.release_host_inputs()
	if main.get("controller_mapper") != null: main.controller_mapper.release_for_focus_loss()
	if main.virtual_keyboard: main.virtual_keyboard.release_for_focus_loss()
	_enforce_hidden()
	return true

func _enforce_hidden() -> void:
	# Hide the parent, not every child: stream termination and other legitimate
	# lifecycle callbacks can still update child visibility/content while hidden.
	main.visible = false
	main.audio_player.stream_paused = true
	main.meteor_microphone.set_paused(true)
	main.native_xr_renderer.set_presentation_suspended(true)
	var interface = _xr_interface()
	if interface:
		interface.set_submit_projection_layer(false)
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	main.get_viewport().transparent_bg = false

func _queue_layer_drain(token: int) -> void:
	# Keep all desktop swapchains alive while the compositor retires their use.
	for _frame in 3:
		await main.get_tree().process_frame
		if token != generation or state != State.DRAINING: return
		_enforce_hidden()
		await RenderingServer.frame_post_draw
		if token != generation or state != State.DRAINING: return
	_layers_drained(token)

func _layers_drained(token: int) -> void:
	if token != generation or state != State.DRAINING: return
	if not _control or _control.state != "prepared" or _control.session != _lease or _control.runtime_status.get("phase", "") != "session_active":
		request_stop("XR application ended before activation")
		return
	if not main.pcvr_test.standby_active or not main.pcvr_test.backend.activate_meteor_projection():
		request_stop("XR activation rejected")
		return
	state = State.ACTIVE
	main._log("[XR-HANDOVER] XR projection activated; Sunshine session/context preserved")

func _restore_workspace() -> void:
	# Native idle is the prerequisite. Never force welcome, reconnect Sunshine,
	# restore stale stream state, or overwrite any saved user setting here.
	var saved := _saved.duplicate()
	_saved.clear()
	main.native_xr_renderer.set_presentation_suspended(saved.native_suspended)
	var interface = _xr_interface()
	if interface:
		interface.set_submit_projection_layer(saved.projection)
		interface.environment_blend_mode = saved.blend
	main.get_viewport().transparent_bg = saved.transparent
	main.visible = saved.visible
	main.audio_player.stream_paused = saved.audio_paused
	main.meteor_microphone.set_paused(saved.mic_paused or main.pcvr_test.application_paused)
	if main.right_hand:
		main._was_b_pressed = main.right_hand.is_button_pressed("by_button")
		main._was_a_pressed = main.right_hand.is_button_pressed("ax_button")
	main._log("[XR-HANDOVER] Native XR drained; previous workspace restored")

func _reset() -> void:
	state = State.IDLE
	_control = null
	_lease = ""
	_hold = 0.0

func _xr_interface():
	return XRServer.find_interface("OpenXR")
