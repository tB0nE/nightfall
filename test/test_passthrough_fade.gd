extends SceneTree

func _init():
	assert(PassthroughFade.next_fade(0) == 25)
	assert(PassthroughFade.next_fade(75) == 0)
	assert(PassthroughFade.next_fade(33) == 0, "an unknown value starts over")
	assert(PassthroughFade.label(0) == "Off")
	assert(PassthroughFade.label(50) == "50%")
	# Without an OpenXR runtime there is no layer, and applying is harmless.
	var fade := PassthroughFade.new()
	fade.apply(true, 50)
	assert(fade.layer == null)
	print("All passthrough_fade tests passed")
	quit()
