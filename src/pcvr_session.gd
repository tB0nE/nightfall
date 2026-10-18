class_name PCVRSession
extends RefCounted
## Pure exclusive-PCVR policy. The caller executes returned commands and passes
## their generation back on acknowledgement. No backend or OpenXR session is
## created here: connect/stop must use the application's existing OpenXR session.
## prepare_exclusive must stop ALL stream/browser/other content and acknowledge
## only after cleanup. stop must cancel/join outstanding preparation/connection
## and release PCVR resources before acknowledging, even if connect never ran.
## Commands intentionally carry no previous-content snapshot or restore action.

enum State { IDLE, PREPARING, CONNECTING, RUNNING, STOPPING, FAILED }

var state: State = State.IDLE
var generation: int = 0
var error: String = ""

func enter() -> Array[Dictionary]:
	if state != State.IDLE:
		return []
	generation += 1
	error = ""
	state = State.PREPARING
	return [_command("prepare_exclusive")]

func preparation_finished(token: int, succeeded: bool, reason: String = "Preparation failed") -> Array[Dictionary]:
	if token != generation or state != State.PREPARING:
		return []
	if not succeeded:
		return fail(token, reason)
	state = State.CONNECTING
	return [_command("connect")]

func connected(token: int) -> Array[Dictionary]:
	if token != generation or state != State.CONNECTING:
		return []
	state = State.RUNNING
	return []

## Used for cancellation, user exit, or a clean remote disconnect.
func exit() -> Array[Dictionary]:
	if state not in [State.PREPARING, State.CONNECTING, State.RUNNING]:
		return []
	return _stop()

func fail(token: int, reason: String) -> Array[Dictionary]:
	if token != generation or state not in [State.PREPARING, State.CONNECTING, State.RUNNING]:
		return []
	error = reason if not reason.is_empty() else "PCVR failed"
	return _stop()

func stopped(token: int) -> Array[Dictionary]:
	if token != generation or state != State.STOPPING:
		return []
	state = State.IDLE if error.is_empty() else State.FAILED
	return [_command("show_welcome")]

## Retry is explicit and only possible after teardown has been acknowledged.
func reset() -> void:
	if state == State.FAILED:
		state = State.IDLE
		error = ""

## Blocks all competing content throughout preparation and teardown as well.
func is_exclusive() -> bool:
	return state in [State.PREPARING, State.CONNECTING, State.RUNNING, State.STOPPING]

func owns_input() -> bool:
	return state == State.RUNNING

func owns_presentation() -> bool:
	return state == State.RUNNING

func _stop() -> Array[Dictionary]:
	# Invalidate every outstanding work callback; teardown has its own token.
	generation += 1
	state = State.STOPPING
	return [_command("stop")]

func _command(action: String) -> Dictionary:
	return {"action": action, "generation": generation}
