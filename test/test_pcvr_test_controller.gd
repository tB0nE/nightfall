extends SceneTree

const Controller = preload("res://src/pcvr_test_controller.gd")
const Session = preload("res://src/pcvr_session.gd")

class Owner extends Node3D:
	var right_hand = null
	var left_hand = null
	var logs: Array[String] = []
	var welcome_viewport: SubViewport
	var welcome_screen
	func _log(message: String) -> void: logs.append(message)

class Hand extends RefCounted:
	var held := true
	func is_button_pressed(action: String) -> bool:
		return held and action == "by_button"

class Backend extends RefCounted:
	var stops := 0
	var starts := 0
	var remote_starts := 0
	var meteor_starts := 0
	var standby_starts := 0
	var frame_ready := false
	var state := "starting"
	var frames := 12
	func start_test() -> bool:
		starts += 1
		return true
	func stop_test() -> void: stops += 1
	func start_stream() -> bool:
		remote_starts += 1
		return true
	func start_meteor_test() -> bool:
		meteor_starts += 1
		return true
	func start_meteor_standby() -> bool:
		standby_starts += 1
		state = "starting"
		frame_ready = false
		return true
	func get_test_status() -> Dictionary:
		return {"state": state, "frames": frames, "error": "test failure", "session": 1, "meteor_frame_ready": frame_ready}

class Harness extends Controller:
	var restores := 0
	var drains: Array[int] = []
	var suppressions := 0
	func _prepare_exclusive() -> void: pass
	func _queue_preparation_drain(token: int) -> void: drains.append(token)
	func _suppress(_node: Node) -> void: suppressions += 1
	func _restore() -> void: restores += 1

class StandbyHarness extends Harness:
	func standby_busy_reason() -> String:
		if application_paused: return "Resume first"
		if standby_active or is_exclusive(): return "XR busy"
		return ""

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	assert(not Controller.allowed("1.0", []))
	assert(not Controller.allowed("1.0-debug", []))
	assert(Controller.allowed("1.0-dev+123", []))
	assert(Controller.allowed("1.0", ["--nf-pcvr-projection-test"]))
	assert(Controller.allowed("", [], true))
	assert(not Controller.allowed("", [], false))
	var owner := Owner.new()
	root.add_child(owner)
	owner.welcome_viewport = SubViewport.new()
	owner.add_child(owner.welcome_viewport)
	var welcome_root := Control.new()
	welcome_root.name = "WelcomeRoot"
	owner.welcome_viewport.add_child(welcome_root)
	var status_label := Label.new()
	status_label.name = "PCVRTestStatus"
	welcome_root.add_child(status_label)
	var controller := Harness.new(owner)
	controller.backend = Backend.new()
	controller._report_status("Visible welcome rejection")
	assert(status_label.text == "Visible welcome rejection")
	assert(owner.logs[-1].contains("Visible welcome rejection"))
	controller.start(true)
	assert(controller.status.contains("ALVR experiment retired"))
	assert(controller.backend.remote_starts == 0)
	_test_preparation_drain(owner)
	_test_remote_timeout(owner)
	_test_meteor_timeout(owner)
	_test_pause_recovery(owner)
	_test_standby(owner)
	controller.session.enter()
	controller.session.preparation_finished(controller.session.generation, true)
	controller.backend.state = "running"
	controller.backend.frames = 0
	controller.process(0.01)
	assert(controller.session.state == Session.State.CONNECTING)
	assert(controller.is_exclusive() and not controller.session.owns_input())
	controller.backend.frames = 12
	controller.process(0.01)
	assert(controller.session.state == Session.State.RUNNING)
	assert(controller.session.owns_input() and controller.session.owns_presentation())
	assert(owner.logs.any(func(line): return line.contains("firstframe") and line.contains("session=1 frames=12")))
	var old_generation: int = controller.session.generation
	controller.request_stop()
	controller.request_stop()
	assert(controller.backend.stops == 1)
	assert(controller.session.connected(old_generation).is_empty())
	controller.backend.state = "stopping"
	controller.process(0.01)
	assert(controller.is_exclusive() and controller.restores == 0)
	controller.backend.state = "failed"
	controller.process(0.01)
	assert(controller.is_exclusive() and controller.restores == 0)
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(not controller.is_exclusive() and controller.restores == 1)
	controller.session.enter()
	controller.session.preparation_finished(controller.session.generation, true)
	controller.backend.state = "starting"
	controller.process(45.0)
	assert(controller.session.state == Session.State.STOPPING)
	assert(controller.backend.stops == 2)
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(controller.restores == 2)
	controller.elapsed = 0.0
	controller.session.enter()
	controller.session.preparation_finished(controller.session.generation, true)
	controller.backend.state = "running"
	controller.backend.frames = 0
	controller.process(5.0)
	assert(controller.session.state == Session.State.STOPPING)
	assert(controller.backend.stops == 3)
	assert(controller.session.error.contains("5 seconds"))
	controller.backend.state = "failed"
	controller.process(0.01)
	assert(controller.restores == 2 and controller.is_exclusive())
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(controller.session.state == Session.State.FAILED and controller.restores == 3)
	controller.session.reset()
	controller.session.enter()
	controller.session.preparation_finished(controller.session.generation, true)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	controller.handle_input(escape)
	assert(controller.backend.stops == 4 and controller.is_exclusive())
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(controller.restores == 4 and not controller.is_exclusive())
	controller.session.enter()
	controller.session.preparation_finished(controller.session.generation, true)
	controller.session.connected(controller.session.generation)
	controller.elapsed = 0.0
	controller.backend.state = "running"
	controller.backend.frames = 12
	owner.left_hand = Hand.new()
	owner.right_hand = Hand.new()
	controller.meteor_mode = true
	controller.process(1.5)
	assert(controller.session.state == Session.State.RUNNING)
	assert(controller.backend.stops == 4 and controller.hold_seconds == 0.0)
	controller.meteor_mode = false
	owner.right_hand.held = false
	controller.process(0.6)
	assert(controller.session.state == Session.State.RUNNING)
	owner.left_hand.held = false
	controller.process(0.1)
	assert(controller.hold_seconds == 0.0)
	owner.left_hand.held = true
	controller.process(0.6)
	assert(controller.session.state == Session.State.RUNNING)
	controller.process(0.41)
	assert(controller.session.state == Session.State.STOPPING and controller.backend.stops == 5)
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(controller.restores == 5)
	var visibility := Controller.new(owner)
	var visuals := Node3D.new()
	var layer := OpenXRCompositionLayerQuad.new()
	var ui := Control.new()
	visuals.add_child(layer)
	visuals.add_child(ui)
	visibility._suppress(visuals)
	assert(not visuals.visible and not layer.visible and not ui.visible)
	assert(visibility._hidden.size() == 3)
	visibility._suppress(visuals)
	assert(visibility._hidden.size() == 3)
	visuals.free()
	# Registration remains on the synchronous boot path; activation is separate.
	var source := FileAccess.get_file_as_string("res://main.gd")
	var ready := source.substr(source.find("func _ready():"))
	ready = ready.substr(0, ready.find("func _on_session_phase_changed"))
	assert(ready.find("pcvr_test.setup()") < ready.find("await "))
	assert(ready.find("pcvr_test.start()") == -1)
	owner.free()
	print("All pcvr_test_controller tests passed")
	quit()

func _test_standby(owner: Owner) -> void:
	owner.welcome_screen = WelcomeScreen.new(owner)
	var controller := StandbyHarness.new(owner)
	controller.backend = Backend.new()
	controller.available = true
	assert(controller.start_meteor_standby())
	assert(not controller.start_meteor_standby())
	assert(controller.standby_active and not controller.is_exclusive())
	assert(controller.backend.standby_starts == 1 and controller.backend.starts == 0)
	controller.backend.state = "running"
	controller.backend.frame_ready = true
	controller.process_standby(0.1)
	assert(controller.session.state == Session.State.IDLE)
	assert(controller.suppressions == 0 and controller.restores == 0)
	controller.request_stop()
	controller.request_stop()
	assert(controller.backend.stops == 1 and controller.standby_active)
	assert(not owner.welcome_screen._auto_suppressed, "Normal game teardown must allow the next automatic launch")
	controller.backend.state = "idle"
	controller.process_standby(0.1)
	assert(not controller.standby_active and controller.restores == 0)
	assert(controller.start_meteor_standby())
	controller.set_application_paused(true)
	assert(controller.backend.stops == 2)
	controller.backend.state = "idle"
	controller.process_standby(0.1)
	assert(not controller.start_meteor_standby())
	controller.set_application_paused(false)
	assert(not controller.standby_active and controller.backend.standby_starts == 2)
	assert(controller.start_meteor_standby())
	controller.process_standby(45.1)
	assert(controller.backend.stops == 3 and controller.restores == 0)
	controller.backend.state = "idle"
	controller.process_standby(0.1)
	assert(not controller.standby_active)
	# The game-testing profile survives the old 90s cutoff, but stays bounded.
	assert(controller.start_meteor_standby(Controller.LONG_TIMEOUT_SECONDS))
	controller.backend.state = "running"
	controller.process_standby(90.1)
	assert(controller.backend.stops == 3 and controller.standby_active)
	controller.process_standby(209.8)
	assert(controller.backend.stops == 3)
	controller.process_standby(.2)
	assert(controller.backend.stops == 4)
	assert(owner.logs.any(func(line): return line.contains("DEV session timeout") and line.contains("limit=300.0s")))
	controller.backend.state = "idle"
	controller.process_standby(.1)
	assert(controller.start_meteor_standby(99999.0))
	assert(controller.timeout_seconds == Controller.TIMEOUT_SECONDS) # Not arbitrary/unbounded.
	controller.request_stop()
	controller.backend.state = "idle"
	controller.process_standby(.1)

func _test_remote_timeout(owner: Owner) -> void:
	var controller := Harness.new(owner)
	controller.backend = Backend.new()
	controller.stream_mode = true
	controller.backend.frames = 0
	controller._execute(controller.session.enter())
	var token: int = controller.session.generation
	assert(controller._preparation_frame(token))
	controller._preparation_drawn(token)
	assert(controller.backend.remote_starts == 1 and controller.backend.starts == 0)
	controller.process(6.0)
	assert(controller.session.state == Session.State.CONNECTING)
	controller.process(24.1)
	assert(controller.session.state == Session.State.STOPPING)
	assert(controller.session.error.contains("30 seconds"))
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(controller.restores == 1)

func _test_pause_recovery(owner: Owner) -> void:
	for phase in [Session.State.PREPARING, Session.State.CONNECTING, Session.State.RUNNING]:
		var controller := Harness.new(owner)
		controller.backend = Backend.new()
		controller._execute(controller.session.enter())
		var token: int = controller.session.generation
		if phase != Session.State.PREPARING:
			assert(controller._preparation_frame(token))
			controller._preparation_drawn(token)
		if phase == Session.State.RUNNING:
			controller.session.connected(token)
		controller.hold_seconds = 0.8
		controller.set_application_paused(true)
		controller.set_application_paused(true)
		assert(controller.hold_seconds == 0.0)
		assert(controller.backend.stops == 1 and controller.is_exclusive())
		assert(controller.busy_reason().contains("Resume"))
		controller._preparation_drawn(token)
		assert(controller.session.connected(token).is_empty())
		controller.set_application_paused(false)
		assert(controller.is_exclusive() and controller.restores == 0)
		controller.backend.state = "idle"
		controller.process(0.01)
		assert(not controller.is_exclusive() and controller.restores == 1)
		var starts: int = controller.backend.starts
		controller.process(0.01)
		assert(controller.backend.starts == starts) # Resume is never an implicit restart.
		controller._execute(controller.session.enter())
		var retry: int = controller.session.generation
		assert(retry != token and controller._preparation_frame(retry))
		controller._preparation_drawn(retry)
		assert(controller.backend.starts == starts + 1)

func _test_meteor_timeout(owner: Owner) -> void:
	var controller := Harness.new(owner)
	controller.backend = Backend.new()
	controller.meteor_mode = true
	controller.backend.frames = 0
	controller._execute(controller.session.enter())
	var token: int = controller.session.generation
	assert(controller._preparation_frame(token))
	controller._preparation_drawn(token)
	assert(controller.backend.meteor_starts == 1 and controller.backend.starts == 0)
	controller.process(6.0)
	assert(controller.session.state == Session.State.CONNECTING)
	controller.process(9.1)
	assert(controller.session.state == Session.State.STOPPING)
	assert(controller.session.error.contains("15 seconds"))
	controller.backend.state = "idle"
	controller.process(0.01)
	assert(controller.restores == 1)

func _test_preparation_drain(owner: Owner) -> void:
	var controller := Harness.new(owner)
	controller.backend = Backend.new()
	controller._execute(controller.session.enter())
	var first_token: int = controller.session.generation
	assert(controller.drains == [first_token])
	assert(controller.session.state == Session.State.PREPARING)
	assert(controller.backend.starts == 0)
	controller._preparation_drawn(first_token)
	assert(controller.backend.starts == 0) # Both drain stages are required.
	assert(controller._preparation_frame(first_token))
	assert(controller.backend.starts == 0) # A main-thread frame is not a draw drain.
	controller._preparation_drawn(first_token)
	assert(controller.backend.starts == 1)
	assert(controller.suppressions == 2) # Re-hide next frame and before connect.
	assert(controller.session.state == Session.State.CONNECTING)
	controller._preparation_drawn(first_token)
	assert(controller.backend.starts == 1)
	controller.request_stop()
	controller.backend.state = "idle"
	controller.process(0.01)
	controller._execute(controller.session.enter())
	var cancelled_before_frame: int = controller.session.generation
	controller.request_stop()
	assert(not controller._preparation_frame(cancelled_before_frame))
	controller._preparation_drawn(cancelled_before_frame)
	assert(controller.backend.starts == 1)
	controller.process(0.01)
	controller._execute(controller.session.enter())
	var cancelled_before_draw: int = controller.session.generation
	assert(controller._preparation_frame(cancelled_before_draw))
	controller.request_stop()
	controller._preparation_drawn(cancelled_before_draw)
	assert(controller.backend.starts == 1 and controller.is_exclusive())
	controller.process(0.01)
	controller._execute(controller.session.enter())
	var retry_token: int = controller.session.generation
	controller._preparation_drawn(cancelled_before_draw)
	assert(controller.session.state == Session.State.PREPARING)
	assert(controller.backend.starts == 1)
	assert(controller._preparation_frame(retry_token))
	controller._preparation_drawn(retry_token)
	assert(controller.backend.starts == 2)
	assert(owner.logs.any(func(line): return line.contains("preparation") and line.contains("session=1 frames=12")))
	assert(owner.logs.any(func(line): return line.contains("connecting")))
	assert(owner.logs.any(func(line): return line.contains("stopping")))
	assert(owner.logs.any(func(line): return line.contains("idle")))
