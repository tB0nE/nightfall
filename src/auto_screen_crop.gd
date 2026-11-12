class_name AutoScreenCrop
extends RefCounted

# A deliberately conservative detector. Unknown/dark images never change state.
const SAMPLE_SIZE := Vector2i(128, 72)
const INTERVAL_MS := 300
const CONFIRMATIONS := 5
const IDENTITY := Vector4(0, 0, 1, 1)
var region := IDENTITY
var _candidate := -1
var _count := 0
var _candidate_region := IDENTITY
var last_analysis_usec := 0

func reset() -> void:
	region = IDENTITY
	_candidate = -1
	_count = 0
	_candidate_region = IDENTITY

static func _black(image: Image, vertical: bool, index: int) -> bool:
	var length := image.get_height() if vertical else image.get_width()
	for i in length:
		var c := image.get_pixel(index, i) if vertical else image.get_pixel(i, index)
		# All colour channels: dark saturated UI is not a black bar.
		if maxf(c.r, maxf(c.g, c.b)) > 0.035: return false
	return true

static func detect(image: Image, size: Vector2i) -> int:
	return int(_analyze(image, size).get("mode", -1))

static func _analyze(image: Image, size: Vector2i) -> Dictionary:
	if image == null or image.is_empty() or size.x <= 0 or size.y <= 0: return {}
	var w := image.get_width()
	var h := image.get_height()
	# Fades, very dark scenes and loading screens provide no useful evidence.
	var bright := 0
	for y in range(h / 4, h * 3 / 4):
		for x in range(w / 4, w * 3 / 4):
			var c := image.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.10: bright += 1
	if bright < w * h * 0.025: return {}
	var margins := [0, 0, 0, 0]
	for edge in 4:
		var vertical := edge < 2
		var length := w if vertical else h
		for i in range(length / 3):
			var index := i if edge % 2 == 0 else length - 1 - i
			if not _black(image, vertical, index): break
			margins[edge] += 1
	# Asymmetric bars or content (subtitles/HUD) in either bar: preserve it.
	if absi(margins[0] - margins[1]) > 1 or absi(margins[2] - margins[3]) > 1: return {"mode": 0, "region": IDENTITY}
	if margins.max() <= 1: return {"mode": 0, "region": IDENTITY}
	if mini(margins[0], margins[1]) > 1 and mini(margins[2], margins[3]) > 1: return {"mode": 0, "region": IDENTITY}
	var measured := Vector4(float(margins[0]) / w, float(margins[2]) / h,
		1.0 - float(margins[0] + margins[1]) / w, 1.0 - float(margins[2] + margins[3]) / h)
	var best := -1
	var error := 0.03
	for mode in range(1, ScreenImageOptions.ASPECTS.size()):
		var expected := ScreenImageOptions.crop_region(size, mode)
		if expected == IDENTITY: continue
		var difference := maxf(absf(expected.z - measured.z), absf(expected.w - measured.w))
		# Never crop farther than the measured black strip (allow one sample pixel).
		if expected.x > measured.x + 1.0 / w or expected.y > measured.y + 1.0 / h: continue
		if difference < error:
			best = mode
			error = difference
	if best < 0: return {}
	# Presets validate plausibility only. Use measured edges so real 2.39:1,
	# rounded game modes, etc. do not inherit a border from a nominal ratio.
	return {"mode": best, "region": measured}

func observe(image: Image, size: Vector2i) -> bool:
	var started := Time.get_ticks_usec()
	var analysis := _analyze(image, size)
	last_analysis_usec = Time.get_ticks_usec() - started
	if analysis.is_empty():
		_candidate = -1
		_count = 0
		return false
	var mode: int = analysis.mode
	var measured: Vector4 = analysis.region
	# A different boundary must settle too, even if it matches the same preset.
	var tolerance := Vector4(0.5 / image.get_width(), 0.5 / image.get_height(),
		1.0 / image.get_width(), 1.0 / image.get_height())
	var difference := (measured - _candidate_region).abs()
	if mode != _candidate or difference.x > tolerance.x or difference.y > tolerance.y or difference.z > tolerance.z or difference.w > tolerance.w:
		_candidate = mode
		_candidate_region = measured
		_count = 0
	_count += 1
	if _count < CONFIRMATIONS: return false
	# No intentional retained black margin. Quantization is limited to the
	# small sample grid; ignore sub-grid jitter to avoid continuously resizing.
	if region.is_equal_approx(_candidate_region): return false
	region = _candidate_region
	return true
