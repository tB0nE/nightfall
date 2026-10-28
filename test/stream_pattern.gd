extends SceneTree

## A test pattern for measuring a stream end to end (tools/verify.py e2e,
## test/analyze_stream_pattern.py). A borderless, always-on-top window on the
## streamed screen draws two rows of blocks every frame:
##   row 0: white, a 24-bit frame counter, black
##   row 1: white, the low 24 bits of the Unix time in ms when it was drawn, black
## Bits are most significant first; a white block is a 1.
##
##   godot --path . --script test/stream_pattern.gd -- --x=0 --y=0 --block=48 --seconds=20
## --save=<dir> also writes the first 30 frames as PNGs, to test the decoder.

const BITS := 24

var block := 48
var seconds := 20.0
var counter := 0
var canvas: Control
var started := 0
var save_dir := ""

func _initialize() -> void:
	var x := 0
	var y := 0
	for arg in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		match arg.get_slice("=", 0):
			"--x": x = int(value)
			"--y": y = int(value)
			"--block": block = maxi(8, int(value))
			"--seconds": seconds = float(value)
			"--save": save_dir = value
	var window := root
	window.borderless = true
	window.always_on_top = true
	window.unresizable = true
	window.size = Vector2i((BITS + 2) * block, 2 * block)
	window.position = Vector2i(x, y)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	# A compositor can ignore vsync for a small window; draw no faster than
	# the display, so each captured frame shows a fresh, evenly timed pattern.
	var refresh := DisplayServer.screen_get_refresh_rate()
	Engine.max_fps = int(round(refresh)) if refresh > 0 else 60
	canvas = Control.new()
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.draw.connect(_draw_pattern)
	window.add_child(canvas)
	started = Time.get_ticks_msec()

func _process(_delta: float) -> bool:
	if not save_dir.is_empty() and counter >= 2 and counter <= 31:
		root.get_texture().get_image().save_png("%s/pattern-%03d.png" % [save_dir, counter - 1])
	counter += 1
	canvas.queue_redraw()
	return Time.get_ticks_msec() - started > seconds * 1000.0

func _draw_pattern() -> void:
	var now := int(Time.get_unix_time_from_system() * 1000.0)
	_row(0, counter)
	_row(1, now)

func _row(row: int, value: int) -> void:
	var y := row * block
	canvas.draw_rect(Rect2(0, y, block, block), Color.WHITE)
	for bit in BITS:
		var on := (value >> (BITS - 1 - bit)) & 1 == 1
		canvas.draw_rect(Rect2((bit + 1) * block, y, block, block), Color.WHITE if on else Color.BLACK)
	canvas.draw_rect(Rect2((BITS + 1) * block, y, block, block), Color.BLACK)
