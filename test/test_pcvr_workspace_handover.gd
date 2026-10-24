extends SceneTree
const Handover = preload("res://src/pcvr_workspace_handover.gd")

class HeldHand extends RefCounted:
	func is_button_pressed(action: String) -> bool:
		return action == "by_button"

class Native extends RefCounted:
	var ready := false
	var activations := 0
	var reject := false
	var focused := false
	func set_workspace_input_focus(value: bool) -> void: focused = value
	func get_test_status() -> Dictionary:
		return {"state": "running", "meteor_frame_ready": ready}
	func activate_meteor_projection() -> bool:
		activations += 1
		return not reject

class PCVR extends RefCounted:
	var standby_active := true
	var application_paused := false
	var stops := 0
	var backend := Native.new()
	func request_stop() -> void: stops += 1

class Renderer extends RefCounted:
	var presentation_suspended := false
	var reject := false
	func set_presentation_suspended(value: bool) -> bool:
		if reject: return false
		presentation_suspended = value
		return true

class Audio extends RefCounted:
	var stream_paused := false

class Microphone extends RefCounted:
	var _paused := false
	func set_paused(value: bool) -> void: _paused = value

class Inputs extends RefCounted:
	var releases := 0
	func release_host_inputs() -> void: releases += 1

class Interaction extends RefCounted:
	func cancel_transient_interactions(_reason: String) -> void: pass

class Panels extends RefCounted:
	var ui_layer = null
	func hide_ui() -> void: pass

class Pointers extends RefCounted:
	var cursor_layer = null
	var secondary_cursor_layer = null

class UI extends RefCounted:
	var opened := 0
	func open_pcvr_page() -> void: opened += 1

class Owner extends Node3D:
	var ui_visible := false
	var ui_panel_3d := Node3D.new()
	var xr_origin := Node3D.new()
	var composition_panels := Panels.new()
	var composition_pointers := Pointers.new()
	var ui_controller := UI.new()
	func _toggle_ui() -> void: ui_visible = not ui_visible
	func _set_ui_visible(value: bool) -> void: ui_visible = value
	var pcvr_test := PCVR.new()
	var native_xr_renderer := Renderer.new()
	var audio_player := Audio.new()
	var meteor_microphone := Microphone.new()
	var input_handler := Inputs.new()
	var xr_interaction := Interaction.new()
	var virtual_keyboard = null
	var right_hand = null
	var left_hand = null
	var screens := [1]
	var is_streaming := true
	func browser_content_active() -> bool: return false
	func _log(_text: String) -> void: pass

class ControlState extends RefCounted:
	var session_fps := 60
	var state := "prepared"
	var session := "a".repeat(32)
	var runtime_status := {"phase": "starting"}

class Interface extends RefCounted:
	var enabled := true
	var environment_blend_mode := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	# Match the API bound by godot-4.7-projectionless.patch, not a guessed name.
	func get_submit_projection_layer() -> bool: return enabled
	func set_submit_projection_layer(value: bool) -> void: enabled = value

class Harness extends Handover:
	var interface := Interface.new()
	var drains: Array[int] = []
	func _xr_interface(): return interface
	func _queue_layer_drain(token: int) -> void: drains.append(token)

class TimingSettings extends RefCounted:
	var started := 0
	var ended := 0
	var ready := false
	func pcvr_timing_active() -> bool: return false
	func begin_pcvr_timing(fps: int) -> bool:
		assert(fps == 60)
		started += 1
		return true
	func pcvr_desktop_timing_ready() -> bool: return ready
	func end_pcvr_timing() -> void: ended += 1

class TimingOwner extends Owner:
	var settings_controller := TimingSettings.new()

func _initialize() -> void:
	_run.call_deferred()

func _test_timing_handover() -> void:
	var owner := TimingOwner.new()
	root.add_child(owner)
	var control := ControlState.new()
	var handover := Harness.new(owner)
	assert(handover.arm(control))
	assert(owner.settings_controller.started == 1)
	owner.pcvr_test.backend.ready = true
	control.runtime_status.phase = "session_active"
	handover.process(.1)
	assert(handover.state == Handover.State.WAITING and owner.visible)
	assert(handover.drains.is_empty(), "Do not hide desktop before its timing restart completes")
	owner.settings_controller.ready = true
	handover.process(.1)
	assert(handover.state == Handover.State.DRAINING)
	handover.request_stop("Test cancellation")
	assert(owner.settings_controller.ended == 0, "Do not restore timing before native receiver stops")
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	assert(handover.state == Handover.State.IDLE and owner.settings_controller.ended == 1)
	handover.process(.1)
	assert(owner.settings_controller.ended == 1)
	owner.ui_panel_3d.free()
	owner.xr_origin.free()
	owner.free()

func _run() -> void:
	_test_timing_handover()
	var owner := Owner.new()
	root.add_child(owner)
	owner.add_child(owner.ui_panel_3d)
	owner.add_child(owner.xr_origin)
	var child := Node3D.new()
	owner.add_child(child)
	var control := ControlState.new()
	var handover := Harness.new(owner)
	assert(handover.arm(control))
	assert(not handover.arm(control))
	control.runtime_status.phase = "ready_for_application"
	handover.process(21.0)
	assert(handover.state == Handover.State.WAITING and owner.visible and not handover.blocks_workspace())
	control.runtime_status.phase = "starting"
	owner.pcvr_test.backend.ready = true
	handover.process(.1)
	assert(not handover.blocks_workspace() and owner.visible)
	control.runtime_status.phase = "session_active"
	owner.pcvr_test.backend.ready = false
	handover.process(.1)
	assert(not handover.blocks_workspace())
	# Steam's runtime probe may begin/end repeatedly before real game video.
	# Session churn must not stop or reset the bounded startup timer.
	for _probe in 2:
		control.runtime_status.phase = "session_ended"
		handover.process(.1)
		assert(handover.state == Handover.State.WAITING and owner.visible)
		assert(owner.pcvr_test.stops == 0 and owner.pcvr_test.backend.activations == 0)
		control.runtime_status.phase = "session_active"
		handover.process(.1)
		assert(handover.state == Handover.State.WAITING)
	owner.pcvr_test.backend.ready = true
	handover.process(.1)
	var token: int = handover.generation
	assert(handover.state == Handover.State.DRAINING and handover.blocks_workspace())
	assert(not owner.visible and owner.native_xr_renderer.presentation_suspended)
	assert(not owner.audio_player.stream_paused and owner.meteor_microphone._paused)
	assert(owner.input_handler.releases == 1 and owner.is_streaming)
	assert(not handover.interface.enabled)
	assert(owner.pcvr_test.backend.activations == 0)
	# A legitimate lifecycle update while hidden must not be overwritten on exit.
	child.visible = false
	handover._layers_drained(token)
	assert(handover.state == Handover.State.ACTIVE and owner.pcvr_test.backend.activations == 1)
	# Retain desktop audio through XR/menu transitions; stop stale playback if
	# the desktop disconnects, and respect a player paused before handover.
	owner.is_streaming = false
	handover.process(.1)
	assert(owner.audio_player.stream_paused)
	owner.is_streaming = true
	handover.process(.1)
	assert(not owner.audio_player.stream_paused)
	handover._saved.audio_paused = true
	handover.process(.1)
	assert(owner.audio_player.stream_paused)
	handover._saved.audio_paused = false
	handover.process(.1)
	assert(not owner.audio_player.stream_paused)
	# The automatic standby-to-XR path must leave B/Y entirely to the game.
	owner.right_hand = HeldHand.new()
	owner.left_hand = HeldHand.new()
	handover.process(1.5)
	assert(handover.state == Handover.State.ACTIVE and owner.pcvr_test.stops == 0)
	owner.right_hand = null
	owner.left_hand = null
	handover.set_desktop_visible(true)
	assert(owner.visible and handover.owns_workspace() and not handover.blocks_workspace())
	assert(not owner.native_xr_renderer.presentation_suspended and owner.pcvr_test.backend.focused)
	assert(not handover.interface.enabled) # Never submit a second base projection.
	handover.set_desktop_visible(false)
	assert(not owner.visible and handover.blocks_workspace())
	assert(owner.native_xr_renderer.presentation_suspended)
	var desktop_mesh := MeshInstance3D.new()
	owner.add_child(desktop_mesh)
	var desktop_hit := Area3D.new()
	desktop_hit.collision_layer = 8
	desktop_mesh.add_child(desktop_hit)
	handover.open_pcvr_menu()
	assert(handover.menu_only and not handover.desktop_visible and owner.visible)
	assert(not handover.blocks_workspace() and owner.pcvr_test.backend.focused)
	assert(not desktop_mesh.visible and desktop_hit.collision_layer == 0)
	assert(owner.ui_visible and owner.ui_controller.opened == 1)
	assert(owner.native_xr_renderer.presentation_suspended)
	handover.toggle_pcvr_menu()
	assert(not handover.menu_only and not owner.visible and not owner.ui_visible)
	assert(desktop_mesh.visible and desktop_hit.collision_layer == 8)
	assert(not owner.pcvr_test.backend.focused)
	# Once actual video has activated, session end still restores the desktop.
	control.runtime_status.phase = "session_ended"
	handover.process(.1)
	assert(handover.state == Handover.State.STOPPING and owner.pcvr_test.stops == 1)
	handover.request_stop()
	handover._layers_drained(token)
	assert(owner.pcvr_test.stops == 1 and owner.pcvr_test.backend.activations == 1)
	handover.process(.1)
	assert(not owner.visible) # No restoration before native idle.
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	assert(handover.state == Handover.State.IDLE and owner.visible and owner.is_streaming)
	assert(not child.visible) # Parent-only snapshot preserved updated child state.
	assert(not owner.native_xr_renderer.presentation_suspended and handover.interface.enabled)
	assert(not owner.audio_player.stream_paused and not owner.meteor_microphone._paused)
	# Cancellation before the draw acknowledgement cannot activate stale work.
	owner.pcvr_test.standby_active = true
	control.state = "prepared"
	control.runtime_status.phase = "session_active"
	assert(handover.arm(control))
	handover.process(.1)
	token = handover.generation
	handover.request_stop("Application paused")
	owner.pcvr_test.application_paused = true
	handover._layers_drained(token)
	assert(owner.pcvr_test.backend.activations == 1)
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	assert(owner.visible and owner.meteor_microphone._paused)
	# Activation failure rolls back only after native cleanup.
	owner.pcvr_test.application_paused = false
	owner.pcvr_test.standby_active = true
	owner.pcvr_test.backend.reject = true
	assert(handover.arm(control))
	handover.process(.1)
	handover._layers_drained(handover.generation)
	assert(handover.state == Handover.State.STOPPING and not owner.visible)
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	assert(owner.visible and handover.state == Handover.State.IDLE)
	# Startup timeout must never hide the desktop.
	owner.pcvr_test.standby_active = true
	control.runtime_status.phase = "session_ended"
	assert(handover.arm(control))
	handover.process(20.1)
	assert(handover.state == Handover.State.STOPPING and handover.error == "XR handover startup timed out")
	assert(not handover.blocks_workspace() and owner.visible)
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	# A missing draw acknowledgement is bounded; stale continuations stay inert.
	owner.pcvr_test.standby_active = true
	control.runtime_status.phase = "session_active"
	assert(handover.arm(control))
	handover.process(.1)
	token = handover.generation
	handover.process(3.1)
	assert(handover.state == Handover.State.STOPPING and not owner.visible)
	handover._layers_drained(token)
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	assert(owner.visible)
	# Real supervisor terminal outcomes are not mistaken for harmless probes.
	for terminal in ["completed", "cancelled", "failed"]:
		owner.pcvr_test.standby_active = true
		control.runtime_status.phase = terminal
		assert(handover.arm(control))
		handover.process(.1)
		assert(handover.state == Handover.State.STOPPING and owner.visible)
		owner.pcvr_test.standby_active = false
		handover.process(.1)
	control.runtime_status.phase = "session_active"
	# A renderer that cannot suspend must leave presentation untouched.
	owner.pcvr_test.standby_active = true
	owner.native_xr_renderer.reject = true
	assert(handover.arm(control))
	handover.process(.1)
	assert(handover.state == Handover.State.STOPPING and owner.visible)
	assert(not handover.blocks_workspace())
	owner.pcvr_test.standby_active = false
	handover.process(.1)
	owner.free()
	print("All pcvr_workspace_handover tests passed")
	quit()
