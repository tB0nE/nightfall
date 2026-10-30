extends SceneTree

func _init(): _run.call_deferred()

func _run():
	var result: Dictionary = preload("res://test/native_stream_shutdown.gd").run(root)
	assert(result.destruction_is_silent)
	print("All native stream shutdown tests passed")
	quit()
