extends SceneTree

func _init():
	assert(PassthroughFade.next_fade(0) == 25)
	assert(PassthroughFade.next_fade(75) == 90)
	assert(PassthroughFade.next_fade(90) == 0)
	assert(PassthroughFade.next_fade(33) == 0, "an unknown value starts over")
	assert(PassthroughFade.label(0) == "Off")
	assert(PassthroughFade.label(50) == "50%")
	# Above the vendors plugin's passthrough layer (-100), below projection (0).
	assert(PassthroughFade.SORT_ORDER > -100 and PassthroughFade.SORT_ORDER < 0)
	# Without an OpenXR runtime there is no layer, and applying is harmless.
	var fade := PassthroughFade.new()
	fade.apply(true, 50)
	assert(fade.layer == null)
	print("All passthrough_fade tests passed")
	quit()
