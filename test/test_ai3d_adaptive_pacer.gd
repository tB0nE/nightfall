extends SceneTree

func _init():
	_test_backs_off_when_stream_slips()
	_test_recovers_while_healthy()
	_test_respects_floor_and_cap()
	print("All ai3d_adaptive_pacer tests passed")
	quit()

func _test_backs_off_when_stream_slips() -> void:
	var pacer := Ai3dAdaptivePacer.new()
	pacer.reset(20)
	# App can't hold 90 Hz: inference rate drops by 25%.
	assert(pacer.on_sample(80.0, 80.0, 90.0, 90.0, 20) == 15)
	# Video updates falling behind also counts as unhealthy.
	assert(pacer.on_sample(90.0, 70.0, 90.0, 90.0, 20) == 11)

func _test_recovers_while_healthy() -> void:
	var pacer := Ai3dAdaptivePacer.new()
	pacer.reset(20)
	pacer.on_sample(80.0, 80.0, 90.0, 90.0, 20)
	assert(pacer.current_hz == 15.0)
	# Needs several healthy samples in a row before stepping up.
	assert(pacer.on_sample(89.5, 89.0, 90.0, 90.0, 20) == -1)
	assert(pacer.on_sample(89.5, 89.0, 90.0, 90.0, 20) == -1)
	assert(pacer.on_sample(89.5, 89.0, 90.0, 90.0, 20) == 17)
	# A slip resets the healthy streak.
	pacer.on_sample(89.5, 89.0, 90.0, 90.0, 20)
	pacer.on_sample(60.0, 60.0, 90.0, 90.0, 20)
	assert(pacer.current_hz < 17.0)

func _test_respects_floor_and_cap() -> void:
	var pacer := Ai3dAdaptivePacer.new()
	pacer.reset(20)
	for i in 20:
		pacer.on_sample(40.0, 40.0, 90.0, 90.0, 20)
	assert(pacer.current_hz == Ai3dAdaptivePacer.FLOOR_HZ)
	for i in 60:
		pacer.on_sample(90.0, 90.0, 90.0, 90.0, 20)
	assert(pacer.current_hz == 20.0)
	# A cap below the floor wins.
	pacer.reset(8)
	pacer.on_sample(40.0, 40.0, 90.0, 90.0, 8)
	assert(pacer.current_hz == 8.0)
	# Stream fps below display rate: video target is the stream rate.
	pacer.reset(20)
	assert(pacer.on_sample(90.0, 60.0, 90.0, 60.0, 20) == -1)
