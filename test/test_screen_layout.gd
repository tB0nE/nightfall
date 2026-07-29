extends SceneTree

func _init():
	_test_single_identity()
	_test_split_h()
	_test_validate_catches_short_overflow()
	_test_round_trip()
	print("All screen_layout tests passed")
	quit()

func _test_single_identity():
	var l = ScreenLayout.single(Vector2i(1920, 1080))
	assert(l.validate(l.frame_size) == "")
	assert(l.monitors.size() == 1)
	assert(l.uv_region_for(l.monitors[0]) == Vector4(0, 0, 1, 1))

func _test_split_h():
	var l = ScreenLayout.split_h(Vector2i(3840, 1080), 2)
	assert(l.validate(l.frame_size) == "")
	assert(l.monitors.size() == 2)
	assert(l.monitors[0].frame_rect.size.x + l.monitors[1].frame_rect.size.x == 3840)

func _test_validate_catches_short_overflow():
	var l = ScreenLayout.single(Vector2i(1920, 1080))
	l.desktop_bounds.size = Vector2i(40000, 1080)
	assert(l.validate(l.frame_size) != "")

func _test_round_trip():
	var l = ScreenLayout.split_h(Vector2i(2560, 1080), 2)
	var d = l.to_dict()
	var json = JSON.stringify(d)
	var back = ScreenLayout.from_dict(JSON.parse_string(json))
	assert(back.monitors.size() == l.monitors.size())
	assert(back.monitors[0].frame_rect == l.monitors[0].frame_rect)