extends SceneTree

class Lifecycle extends RefCounted:
	func is_reconnecting() -> bool: return false

class Welcome extends RefCounted:
	var notice := ""
	func show_notice(message: String) -> void: notice = message

class Owner extends Node3D:
	var session_lifecycle := Lifecycle.new()
	var welcome_screen := Welcome.new()
	var _ui_status_label := Label.new()
	var restored := ""
	func _log(_message: String) -> void: pass
	func restore_after_failed_connect(message: String) -> void: restored = message

func _init() -> void:
	var owner := Owner.new()
	var stream := StreamManager.new(owner)
	# No backend is supplied: deleting a host or starting pairing would fail.
	var missing := "Session URL not found in response. Game may be stuck."
	stream._on_v2_launch_response({"status": "error", "message": missing})
	assert(owner.restored == "Launch failed: " + missing)
	assert(owner.welcome_screen.notice == owner.restored)
	# A busy host must not receive an immediate second launch via bypass.
	stream._meteor = {"ports": {"https": 48984}}
	var busy := "Another stream operation is still running. Retry after it completes"
	stream._on_v2_launch_response({"status": "error", "message": busy})
	assert(owner.restored == "Launch failed: " + busy)
	assert(not stream._meteor.is_empty())
	for message in [missing, "Launch/Resume failed (-1): Timeout was reached"]:
		stream._on_v2_launch_response({"status": "error", "message": message})
		assert(owner.restored == "Launch failed: " + message)
		assert(not stream._meteor.is_empty())
	owner._ui_status_label.free()
	owner.free()
	print("All stream_launch_failure tests passed")
	quit()
