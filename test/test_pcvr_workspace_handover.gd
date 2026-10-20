extends SceneTree
const Handover = preload("res://src/pcvr_workspace_handover.gd")

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

class Owner extends Node3D:
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

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var owner := Owner.new()
	root.add_child(owner)
	var child := Node3D.new()
	owner.add_child(child)
	var control := ControlState.new()
	var handover := Harness.new(owner)
	assert(handover.arm(control))
	assert(not handover.arm(control))
	owner.pcvr_test.backend.ready = true
	handover.process(.1)
	assert(not handover.blocks_workspace() and owner.visible)
	control.runtime_status.phase = "session_active"
	owner.pcvr_test.backend.ready = false
	handover.process(.1)
	assert(not handover.blocks_workspace())
	owner.pcvr_test.backend.ready = true
	handover.process(.1)
	var token: int = handover.generation
	assert(handover.state == Handover.State.DRAINING and handover.blocks_workspace())
	assert(not owner.visible and owner.native_xr_renderer.presentation_suspended)
	assert(owner.audio_player.stream_paused and owner.meteor_microphone._paused)
	assert(owner.input_handler.releases == 1 and owner.is_streaming)
	assert(not handover.interface.enabled)
	assert(owner.pcvr_test.backend.activations == 0)
	# A legitimate lifecycle update while hidden must not be overwritten on exit.
	child.visible = false
	handover._layers_drained(token)
	assert(handover.state == Handover.State.ACTIVE and owner.pcvr_test.backend.activations == 1)
	handover.set_desktop_visible(true)
	assert(owner.visible and handover.owns_workspace() and not handover.blocks_workspace())
	assert(not owner.native_xr_renderer.presentation_suspended and owner.pcvr_test.backend.focused)
	assert(not handover.interface.enabled) # Never submit a second base projection.
	handover.set_desktop_visible(false)
	assert(not owner.visible and handover.blocks_workspace())
	assert(owner.native_xr_renderer.presentation_suspended)
	control.state = "failed"
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
	control.runtime_status.phase = "starting"
	assert(handover.arm(control))
	handover.process(20.1)
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
