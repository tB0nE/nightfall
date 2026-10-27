extends SceneTree

class Owner extends Node:
	func _log(_text: String) -> void: pass

func _initialize() -> void:
	var owner_node := Owner.new()
	var control = preload("res://src/meteor_xr_control.gd").new(owner_node)
	assert(control.effective_foveation(true)) # Legacy host compatibility.
	control.apply_encoder_capabilities({"encoder":{"backend":"vaapi", "foveated_encoding":false, "live_bitrate":false,"codecs":["h264","h265"]}})
	assert(not control.foveation_available())
	assert(not control.effective_foveation(true))
	assert(not control.queue_foveation(true))
	assert(control.preferred_codec(true) == "h265")
	assert(control.preferred_codec(false) == "h264")
	control.apply_encoder_capabilities({"encoder":{"backend":"nvenc", "foveated_encoding":true, "live_bitrate":true,"codecs":["h265"]}})
	assert(control.effective_foveation(true))
	assert(not control.effective_foveation(false))
	assert(control.preferred_codec(false) == "h265")
	control.cancel()
	assert(control.encoder_capabilities.is_empty())
	owner_node.free()
	print("PASS: host encoder capabilities gate foveation without changing the saved preference")
	quit()
