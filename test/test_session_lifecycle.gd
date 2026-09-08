extends SceneTree

func _init():
	_test_normal_connection()
	_test_restart_preserves_intent()
	_test_reconnect_and_failure()
	_test_manual_disconnect()
	print("All session_lifecycle tests passed")
	quit()

func _test_normal_connection() -> void:
	var lifecycle := SessionLifecycle.new()
	assert(lifecycle.phase == SessionLifecycle.Phase.BOOT)
	lifecycle.show_server_selection()
	lifecycle.arm_connect_timeout()
	assert(lifecycle.phase == SessionLifecycle.Phase.CONNECTING)
	assert(lifecycle.connect_timeout_pending)
	assert(not lifecycle.stream_started())
	assert(lifecycle.phase == SessionLifecycle.Phase.STREAMING)
	assert(lifecycle.media_active)
	assert(not lifecycle.connect_timeout_pending)

func _test_restart_preserves_intent() -> void:
	var lifecycle := _streaming_lifecycle()
	lifecycle.request_restart()
	assert(lifecycle.is_restarting())
	assert(lifecycle.media_active)
	lifecycle.stream_terminated(false, 0)
	assert(lifecycle.is_restarting())
	assert(not lifecycle.media_active)
	lifecycle.begin_connect()
	assert(lifecycle.is_restarting())
	assert(lifecycle.stream_started())
	assert(lifecycle.phase == SessionLifecycle.Phase.STREAMING)

func _test_reconnect_and_failure() -> void:
	var lifecycle := _streaming_lifecycle()
	lifecycle.stream_terminated(true, 1)
	assert(lifecycle.is_reconnecting())
	assert(not lifecycle.media_active)
	lifecycle.begin_connect()
	assert(lifecycle.is_reconnecting())
	assert(not lifecycle.stream_started())
	lifecycle.reconnect_scheduled()
	assert(lifecycle.is_reconnecting())
	lifecycle.fail()
	assert(lifecycle.phase == SessionLifecycle.Phase.FAILED)
	lifecycle.finish_cleanup()
	assert(lifecycle.phase == SessionLifecycle.Phase.FAILED)

func _test_manual_disconnect() -> void:
	var lifecycle := _streaming_lifecycle()
	lifecycle.request_disconnect()
	assert(lifecycle.phase == SessionLifecycle.Phase.DISCONNECTING)
	assert(lifecycle.media_active)
	lifecycle.stream_terminated(false, 0)
	lifecycle.finish_cleanup()
	assert(lifecycle.phase == SessionLifecycle.Phase.SERVER_SELECTION)
	assert(not lifecycle.media_active)

func _streaming_lifecycle() -> SessionLifecycle:
	var lifecycle := SessionLifecycle.new()
	lifecycle.begin_connect()
	lifecycle.stream_started()
	return lifecycle
