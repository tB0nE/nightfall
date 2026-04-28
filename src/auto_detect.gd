class_name AutoDetect
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func process(delta: float):
	if main.is_streaming and main.auto_detect_enabled and not main.auto_detect_running:
		main.auto_detect_timer += delta
		if main.auto_detect_timer >= 0.3:
			main.auto_detect_timer = 0.0
			main.auto_detect_running = true
			run()
	elif not main.is_streaming:
		main.auto_detect_timer = 0.0

func run():
	main.detection_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img = main.detection_viewport.get_texture().get_image()
	if !img or img.get_width() < 64:
		main.auto_detect_running = false
		return
	img.convert(Image.FORMAT_L8)
	var data = img.get_data()
	var w = img.get_width()
	var total_diff = 0.0
	var center_seam = 0.0
	for y in range(4, 28):
		var row_offset = y * w
		for x in range(0, 32):
			total_diff += absf(float(data[row_offset + x]) - float(data[row_offset + x + 32]))
		center_seam += absf(float(data[row_offset + 31]) - float(data[row_offset + 32]))
	var avg_diff = total_diff / (24.0 * 32.0) / 255.0
	var avg_seam = center_seam / 24.0 / 255.0
	var detected_mode = 0
	if avg_seam > 0.08:
		var top_brightness = 0.0
		var center_brightness = 0.0
		var row_top = 2 * w
		var row_center = 16 * w
		for x in range(0, 64):
			top_brightness += float(data[row_top + x])
			center_brightness += float(data[row_center + x])
		var avg_top = top_brightness / 64.0 / 255.0
		var avg_center = center_brightness / 64.0 / 255.0
		detected_mode = 2 if top_brightness < (center_brightness * 0.3) else 1
		print("[AUTO-SBS] SBS: seam=%.4f diff=%.4f top=%.2f center=%.2f -> %s" % [avg_seam, avg_diff, avg_top, avg_center, "CROP" if detected_mode == 2 else "STRETCH"])
	else:
		print("[AUTO-SBS] 2D: seam=%.4f diff=%.4f" % [avg_seam, avg_diff])
	main.detection_history.append(detected_mode)
	if main.detection_history.size() > 5:
		main.detection_history.pop_front()
	var all_match = true
	for val in main.detection_history:
		if val != detected_mode:
			all_match = false
			break
	if all_match and main.detection_history.size() >= 5 and detected_mode != main.stereo_mode:
		main.stereo_mode = detected_mode
		main.ui_controller.update_stereo_shader()
	main.auto_detect_running = false
