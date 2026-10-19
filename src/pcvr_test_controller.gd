class_name PCVRTestController
extends RefCounted
## DEV projection tests only; never owns a second OpenXR session/frame loop.
const Session = preload("res://src/pcvr_session.gd")
const TIMEOUT_SECONDS := 45.0
const FIRST_FRAME_TIMEOUT_SECONDS := 5.0
var main
var session = Session.new()
var backend = null
var available := false
var status := ""
var elapsed := 0.0
var timeout_seconds := TIMEOUT_SECONDS
var hold_seconds := 0.0
var native_status: Dictionary = {}
var auto_connect_pending := false
var application_paused := false
var _hidden: Array[Node] = []
var _projection_enabled := false
var _preparation_frame_generation := -1
var stream_mode := false
var meteor_mode := false
var _last_remote_status := ""

func _init(owner) -> void:
	main = owner

static func allowed(version: String, args: PackedStringArray, dev_feature: bool = false) -> bool:
	return dev_feature or "--nf-pcvr-projection-test" in args or version.contains("-dev+")

func entry_visible() -> bool:
	return allowed("", OS.get_cmdline_args() + OS.get_cmdline_user_args(), OS.has_feature("nightfall_dev"))

func setup() -> void:
	# Must run synchronously before _ready's first await / XR session startup.
	if not entry_visible() or not ClassDB.class_exists("NightfallXrProjectionTest"):
		return
	backend = ClassDB.instantiate("NightfallXrProjectionTest")
	available = backend != null and backend.register_provider()
	status = "Ready" if available else "Provider registration failed"
	main._log("[PCVR-TEST] DEV entry enabled; provider registered=%s remote_clock=%s" % [available, backend.stream_available() if backend else false])

func is_exclusive() -> bool:
	return session.is_exclusive()

func busy_reason() -> String:
	if application_paused:
		return "Resume the application before starting XR"
	if not main._startup_ready or main._startup_cover != null or auto_connect_pending:
		return "Wait for welcome startup to finish"
	if main._welcome_screen not in ["welcome", "server"]:
		return "Start from the welcome or server-selection screen"
	if main.is_streaming or main.session_lifecycle.connect_timeout_pending or main.session_lifecycle.phase not in [SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED]:
		return "Start from clean welcome: stream/connection is busy"
	if main.screen_sources.switching_primary or main.screens.size() != 1 or main._pcvr_screen_retirements > 0:
		return "Start from clean welcome: screen workspace is busy"
	if main.browser_prototype.active or main.browser_prototype.closing or main.browser_prototype._returning_primary:
		return "Start from clean welcome: browser is active or closing"
	for browser in main.screen_sources._browsers.values():
		if browser.active or browser.closing:
			return "Start from clean welcome: browser is active or closing"
	if main.native_xr_renderer.active or main.native_xr_renderer.stream_started:
		return "Start from clean welcome: native video is busy"
	return ""

func start(remote_stream: bool = false, meteor_stream: bool = false, maximum_seconds: float = TIMEOUT_SECONDS) -> void:
	main._log("[PCVR-TEST] Button pressed remote=%s" % remote_stream)
	if is_exclusive(): return
	if remote_stream:
		_report_status("ALVR experiment retired; Monado transport is not connected yet")
		return
	var reason := busy_reason()
	if not available: reason = "Synthetic projection provider unavailable"
	if not reason.is_empty():
		_report_status(reason)
		return
	stream_mode = remote_stream
	meteor_mode = meteor_stream
	timeout_seconds = 90.0 if meteor_stream and maximum_seconds == 90.0 else TIMEOUT_SECONDS
	_last_remote_status = ""
	session.reset()
	elapsed = 0.0
	hold_seconds = 0.0
	_execute(session.enter())

func _report_status(message: String) -> void:
	status = message
	main._log("[PCVR-TEST] " + message)
	if "welcome_viewport" in main and main.welcome_viewport:
		var label = main.welcome_viewport.get_node_or_null("WelcomeRoot/PCVRTestStatus")
		if label: label.text = message
	if "ui_controller" in main and main.ui_controller:
		main.ui_controller.show_temporary_status(message, 5.0)

func request_stop() -> void:
	_execute(session.exit())

func set_application_paused(paused: bool) -> void:
	application_paused = paused
	if paused:
		hold_seconds = 0.0
		request_stop()
	# Resume never restarts XR automatically; teardown must acknowledge idle first.

func _execute(commands: Array[Dictionary]) -> void:
	# Iterative command queue: no recursive coroutine or deferred await races.
	var pending := commands.duplicate()
	while not pending.is_empty():
		var command: Dictionary = pending.pop_front()
		var token: int = command.generation
		if token != session.generation: continue
		match command.action:
			"prepare_exclusive":
				_log_transition("preparation")
				_prepare_exclusive()
				_queue_preparation_drain(token)
			"connect":
				_log_transition("connecting")
				status = "Starting — hold B or Y for 1 second to exit (%ds timeout)" % int(timeout_seconds)
				var started: bool = backend.start_meteor_test() if meteor_mode else (backend.start_stream() if stream_mode else backend.start_test())
				if not started:
					pending.append_array(session.fail(token, "Native projection start rejected"))
			"stop":
				if "welcome_screen" in main and main.welcome_screen:
					main.welcome_screen.cancel_xr_control(false)
				_log_transition("stopping")
				status = "Stopping; waiting for native projection drain"
				backend.stop_test()
			"show_welcome":
				_log_transition("idle")
				_restore()

func _prepare_exclusive() -> void:
	main.xr_interaction.cancel_transient_interactions("synthetic PCVR test")
	main.video_presentation.deactivate_native(false)
	main.depth_estimator.set_enabled(false)
	main.depth_estimator.meteor.stop()
	main.stream_backend.configure_depth(0, 0)
	main.meteor_microphone.set_paused(true)
	main.audio_player.stop()
	var interface = XRServer.find_interface("OpenXR")
	_projection_enabled = interface.is_submit_projection_layer_enabled() if interface.has_method("is_submit_projection_layer_enabled") else not (OS.get_name() == "Android" and RenderingServer.get_current_rendering_method() == "gl_compatibility")
	if interface.has_method("set_submit_projection_layer"):
		interface.set_submit_projection_layer(false)
	interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	main.get_viewport().transparent_bg = false
	_suppress(main.get_tree().root)

func _queue_preparation_drain(token: int) -> void:
	# The initiating pointer dispatch can finish the ordinary main frame after
	# hiding layers. Suppress again next frame, then drain render-thread removal.
	await main.get_tree().process_frame
	if not _preparation_frame(token): return
	await RenderingServer.frame_post_draw
	_preparation_drawn(token)

func _preparation_frame(token: int) -> bool:
	if token != session.generation or session.state != Session.State.PREPARING:
		return false
	_suppress(main.get_tree().root)
	_preparation_frame_generation = token
	return true

func _preparation_drawn(token: int) -> void:
	if token != session.generation or token != _preparation_frame_generation or session.state != Session.State.PREPARING:
		return
	_suppress(main.get_tree().root)
	_execute(session.preparation_finished(token, true))

func _log_transition(event: String) -> void:
	var snapshot: Dictionary = backend.get_test_status() if backend else {}
	if event in ["stopping", "idle"] and snapshot.has("meteor_device_counts"):
		main._log("[XR-DEVICE] %s %s" % [event, JSON.stringify(snapshot.meteor_device_counts)])
	main._log("[PCVR-TEST] %s generation=%d session=%d frames=%d state=%s error=%s" % [
		event, session.generation, int(snapshot.get("session", 0)),
		int(snapshot.get("frames", 0)), str(snapshot.get("state", "unavailable")),
		str(snapshot.get("error", ""))])

func _suppress(node: Node) -> void:
	# Include layers anywhere in the tree, including layers added after entry.
	if node is Node3D or node is CanvasItem:
		if node.visible:
			if not _hidden.has(node): _hidden.append(node)
			node.visible = false
	for child in node.get_children():
		_suppress(child)

func process(delta: float) -> void:
	if not is_exclusive(): return
	_suppress(main.get_tree().root)
	elapsed += delta
	var held := false
	for hand in [main.right_hand, main.left_hand]:
		if hand and hand.is_button_pressed("by_button"): held = true
	hold_seconds = hold_seconds + delta if held else 0.0
	if hold_seconds >= 1.0 or elapsed >= timeout_seconds:
		request_stop()
	native_status = backend.get_test_status()
	var remote_message: String = native_status.get("remote_status", "")
	if remote_message != _last_remote_status:
		_last_remote_status = remote_message
		main._log("[PCVR-TEST] Remote: " + remote_message)
	var state: String = native_status.get("state", "failed")
	if session.state == Session.State.STOPPING:
		# Failed is not an acknowledgement: native must drain all the way to idle.
		if state == "idle": _execute(session.stopped(session.generation))
	elif session.state == Session.State.PREPARING:
		return # Only the draw-drain continuation can acknowledge preparation.
	elif state == "failed":
		_execute(session.fail(session.generation, str(native_status.get("error", "Native test failed"))))
	elif session.state == Session.State.CONNECTING and elapsed >= (15.0 if meteor_mode else (30.0 if stream_mode else FIRST_FRAME_TIMEOUT_SECONDS)) and int(native_status.get("frames", 0)) == 0:
		_execute(session.fail(session.generation, "No Meteor decoded frame within 15 seconds" if meteor_mode else ("No remote frame within 30 seconds" if stream_mode else "No tracked projection frame within 5 seconds")))
	elif state == "running" and int(native_status.get("frames", 0)) > 0:
		if session.state == Session.State.CONNECTING:
			_log_transition("firstframe")
		session.connected(session.generation)
		status = "Running: %d frames, session %d" % [int(native_status.get("frames", 0)), int(native_status.get("session", 0))]
		if meteor_mode: status += " — " + str(native_status.get("meteor_status", "USB diagnostic"))
	elif state == "idle" and session.state == Session.State.RUNNING:
		_execute(session.fail(session.generation, "Native projection ended unexpectedly"))

func handle_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		request_stop()

func _restore() -> void:
	for node in _hidden:
		if is_instance_valid(node): node.visible = true
	_hidden.clear()
	var interface = XRServer.find_interface("OpenXR")
	if interface and interface.has_method("set_submit_projection_layer"):
		interface.set_submit_projection_layer(_projection_enabled)
	main.session_lifecycle.show_server_selection()
	main.ui_visible = false
	main._set_ui_visible(false)
	main.composition_panels.hide_ui()
	main.comp.connect_welcome_texture()
	main.welcome_screen.show_welcome_screen("welcome")
	main.settings_controller.apply_passthrough(main.settings.passthrough_enabled)
	main.settings_controller.apply_stereo()
	main.meteor_microphone.set_paused(application_paused)
	status = session.error if not session.error.is_empty() else "Projection test stopped"
	var label = main.welcome_viewport.get_node_or_null("WelcomeRoot/PCVRTestStatus")
	if label: label.text = status
	main._log("[PCVR-TEST] " + status)
	main.ui_controller.show_temporary_status(status, 5.0)
