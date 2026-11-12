extends SceneTree

func _init(): _run.call_deferred()

func _run():
	# Source-only CI does not build the streaming GDExtension. Keep the real
	# native teardown regression active wherever the compiled addon is present.
	if not ClassDB.class_exists("NightfallStream"):
		print("SKIP: native stream shutdown requires the built NightfallStream addon")
		quit()
		return
	var result: Dictionary = preload("res://test/native_stream_shutdown.gd").run(root)
	assert(result.destruction_is_silent)
	print("All native stream shutdown tests passed")
	quit()
