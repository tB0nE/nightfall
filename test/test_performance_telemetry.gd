extends SceneTree

func _init():
	_test_frame_sampling()
	_test_timers()
	_test_window_combination()
	print("All performance_telemetry tests passed")
	quit()

func _test_frame_sampling() -> void:
	var telemetry := PerformanceTelemetry.new()
	for index in 3:
		assert(telemetry.record_frame(0.25, index % 2 == 0).is_empty())
	var sample := telemetry.record_frame(0.25, false)
	assert(is_equal_approx(sample["app_fps"], 4.0))
	assert(is_equal_approx(sample["video_update_fps"], 2.0))
	assert(sample["app_frames"] == 4)
	assert(sample["video_updates"] == 2)
	telemetry.reset_session()
	assert(telemetry.app_fps == 0.0)
	assert(telemetry.video_update_fps == 0.0)

func _test_timers() -> void:
	var telemetry := PerformanceTelemetry.new()
	assert(not telemetry.status_update_due(0.05))
	assert(telemetry.status_update_due(0.05))
	assert(not telemetry.overlay_update_due(0.5))
	assert(telemetry.overlay_update_due(0.5))

func _test_window_combination() -> void:
	var previous := {
		"elapsed_us": 500000,
		"total_frames": 40,
		"host_latency_tenths_min": 20,
		"host_latency_tenths_max": 40,
	}
	var current := {
		"elapsed_us": 500000,
		"total_frames": 50,
		"host_latency_tenths_min": 30,
		"host_latency_tenths_max": 60,
	}
	var combined := PerformanceTelemetry.combine_windows(previous, current)
	assert(combined["elapsed_us"] == 1000000)
	assert(combined["total_frames"] == 90)
	assert(combined["host_latency_tenths_min"] == 20)
	assert(combined["host_latency_tenths_max"] == 60)
