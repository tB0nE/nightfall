class_name ScreenLayout
extends RefCounted

class MonitorSpec:
	extends RefCounted
	var id: StringName = &""
	var label: String = ""
	var enabled: bool = true
	# True when the host output has an active CRTC and could be captured at all (mirrors the
	# host's monitor_manifest_entry_t::capturable). Distinct from `enabled`, which also folds in
	# whether this session's outputs= currently selects it. A connected-but-disabled host output
	# is capturable=false regardless of selection state - callers picking N monitors to request
	# (settings_controller.gd's _real_monitor_count()/_build_staged_layout()) must filter on this,
	# not just enabled/hint.virtual, or they can pick a monitor the host will always refuse.
	# Defaults true for older hosts that don't send this field yet.
	var capturable: bool = true
	var is_primary: bool = false
	var frame_rect: Rect2i = Rect2i()
	var desktop_rect: Rect2i = Rect2i()
	var hint: Dictionary = {}

	func to_dict() -> Dictionary:
		return {
			"id": String(id),
			"label": label,
			"enabled": enabled,
			"capturable": capturable,
			"is_primary": is_primary,
			"frame_rect": [frame_rect.position.x, frame_rect.position.y, frame_rect.size.x, frame_rect.size.y],
			"desktop_rect": [desktop_rect.position.x, desktop_rect.position.y, desktop_rect.size.x, desktop_rect.size.y],
			"hint": hint,
		}

	static func from_dict(d: Dictionary) -> MonitorSpec:
		var m := MonitorSpec.new()
		m.id = StringName(d.get("id", ""))
		m.label = d.get("label", "")
		m.enabled = d.get("enabled", true)
		m.capturable = d.get("capturable", true)
		m.is_primary = d.get("is_primary", false)
		var fr: Array = d.get("frame_rect", [0, 0, 0, 0])
		m.frame_rect = Rect2i(fr[0], fr[1], fr[2], fr[3])
		var dr: Array = d.get("desktop_rect", fr)
		m.desktop_rect = Rect2i(dr[0], dr[1], dr[2], dr[3])
		m.hint = d.get("hint", {})
		return m

var version: int = 1
var source: StringName = &"client_split"
var frame_size: Vector2i = Vector2i.ZERO
var desktop_bounds: Rect2i = Rect2i()
var monitors: Array[MonitorSpec] = []

func to_dict() -> Dictionary:
	var mons := []
	for m in monitors:
		mons.append(m.to_dict())
	return {
		"version": version,
		"source": String(source),
		"frame_size": [frame_size.x, frame_size.y],
		"desktop_bounds": [desktop_bounds.position.x, desktop_bounds.position.y, desktop_bounds.size.x, desktop_bounds.size.y],
		"monitors": mons,
	}

static func from_dict(d: Dictionary) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.version = d.get("version", 1)
	l.source = StringName(d.get("source", "client_split"))
	var fs: Array = d.get("frame_size", [1920, 1080])
	l.frame_size = Vector2i(fs[0], fs[1])
	var db: Array = d.get("desktop_bounds", [0, 0, fs[0], fs[1]])
	l.desktop_bounds = Rect2i(db[0], db[1], db[2], db[3])
	l.monitors = []
	for md in d.get("monitors", []):
		l.monitors.append(MonitorSpec.from_dict(md))
	return l

static func single(frame: Vector2i) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.frame_size = frame
	l.desktop_bounds = Rect2i(0, 0, frame.x, frame.y)
	var m := MonitorSpec.new()
	m.id = &"m0"
	m.label = "Display"
	m.enabled = true
	m.is_primary = true
	m.frame_rect = Rect2i(0, 0, frame.x, frame.y)
	m.desktop_rect = m.frame_rect
	l.monitors = [m]
	return l

static func split_h(frame: Vector2i, n: int) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.frame_size = frame
	l.desktop_bounds = Rect2i(0, 0, frame.x, frame.y)
	var w := int(frame.x / float(n))
	for i in range(n):
		var m := MonitorSpec.new()
		m.id = StringName("m%d" % i)
		m.label = "Display %d" % (i + 1)
		m.enabled = true
		m.is_primary = (i == 0)
		var x := i * w
		var this_w := w if i < n - 1 else (frame.x - x)
		m.frame_rect = Rect2i(x, 0, this_w, frame.y)
		m.desktop_rect = m.frame_rect
		l.monitors.append(m)
	return l

# Client-only placeholder layout: every monitor shows the whole frame (no real
# cropping), just duplicated across N independently-placed VR screens. Used
# until host-side compositing (real per-monitor tiling) exists; split_h()
# above is the real-split path this will switch to later.
static func replicate(frame: Vector2i, n: int) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.frame_size = frame
	l.desktop_bounds = Rect2i(0, 0, frame.x, frame.y)
	for i in range(n):
		var m := MonitorSpec.new()
		m.id = StringName("m%d" % i)
		m.label = "Display %d" % (i + 1)
		m.enabled = true
		m.is_primary = (i == 0)
		m.frame_rect = Rect2i(0, 0, frame.x, frame.y)
		m.desktop_rect = m.frame_rect
		l.monitors.append(m)
	return l

func get_primary() -> MonitorSpec:
	for m in monitors:
		if m.is_primary and m.enabled:
			return m
	for m in monitors:
		if m.enabled:
			return m
	return null

func enabled_monitors() -> Array[MonitorSpec]:
	var out: Array[MonitorSpec] = []
	for m in monitors:
		if m.enabled:
			out.append(m)
	return out

# Mirrors the host's own non-contiguous-outputs rejection (X11's capture is a
# bounding-box crop, so a gap in the selected set pulls in an unrequested
# monitor's pixels and the host now refuses to launch at all for that). Rather
# than let the user hit that rejection blind - monitor tab order is host
# enumeration order, not spatial order, so "the next monitor" is not
# necessarily "the adjacent one" - auto-enable whatever disabled monitor(s)
# sit inside the x-span of the requested enabled set, so every selection made
# through the UI is guaranteed contiguous before it's ever sent to the host.
# Uses desktop_rect (real position in the host's full desktop), not frame_rect
# (meaningless/zeroed for currently-disabled monitors).
func fill_gaps(enabled_ids: Array) -> Array:
	if enabled_ids.is_empty():
		return enabled_ids
	var min_x = INF
	var max_x = -INF
	for m in monitors:
		if enabled_ids.has(m.id):
			min_x = minf(min_x, m.desktop_rect.position.x)
			max_x = maxf(max_x, m.desktop_rect.position.x + m.desktop_rect.size.x)
	var result = enabled_ids.duplicate()
	for m in monitors:
		if result.has(m.id):
			continue
		var mx0 = m.desktop_rect.position.x
		var mx1 = mx0 + m.desktop_rect.size.x
		if mx0 >= min_x and mx1 <= max_x:
			result.append(m.id)
	return result

func validate(frame: Vector2i) -> String:
	if monitors.is_empty():
		return "layout has no monitors"
	var enabled := enabled_monitors()
	if enabled.is_empty():
		return "layout has no enabled monitors"
	var primary_count := 0
	for m in enabled:
		if m.is_primary:
			primary_count += 1
		if m.frame_rect.size.x < 64 or m.frame_rect.size.y < 64:
			return "monitor %s frame_rect too small (%dx%d)" % [String(m.id), m.frame_rect.size.x, m.frame_rect.size.y]
		var frame_bounds := Rect2i(0, 0, frame.x, frame.y)
		if not frame_bounds.encloses(m.frame_rect):
			return "monitor %s frame_rect %s outside frame %s" % [String(m.id), str(m.frame_rect), str(frame_bounds)]
	if primary_count != 1:
		return "expected exactly 1 primary monitor, found %d" % primary_count
	if desktop_bounds.size.x > 32767 or desktop_bounds.size.y > 32767:
		return "desktop_bounds %s exceeds int16 range used by LiSendMousePositionEvent" % str(desktop_bounds.size)
	return ""

func rescale_to(new_frame: Vector2i) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.version = version
	l.source = source
	l.frame_size = new_frame
	var sx := float(new_frame.x) / float(frame_size.x) if frame_size.x > 0 else 1.0
	var sy := float(new_frame.y) / float(frame_size.y) if frame_size.y > 0 else 1.0
	l.desktop_bounds = Rect2i(
		desktop_bounds.position.x, desktop_bounds.position.y,
		int(desktop_bounds.size.x * sx), int(desktop_bounds.size.y * sy)
	)
	for m in monitors:
		var nm := MonitorSpec.new()
		nm.id = m.id
		nm.label = m.label
		nm.enabled = m.enabled
		nm.is_primary = m.is_primary
		nm.frame_rect = Rect2i(
			int(m.frame_rect.position.x * sx), int(m.frame_rect.position.y * sy),
			int(m.frame_rect.size.x * sx), int(m.frame_rect.size.y * sy)
		)
		nm.desktop_rect = Rect2i(
			int(m.desktop_rect.position.x * sx), int(m.desktop_rect.position.y * sy),
			int(m.desktop_rect.size.x * sx), int(m.desktop_rect.size.y * sy)
		)
		nm.hint = m.hint
		l.monitors.append(nm)
	return l

func uv_region_for(m: MonitorSpec) -> Vector4:
	return Vector4(
		float(m.frame_rect.position.x) / float(frame_size.x),
		float(m.frame_rect.position.y) / float(frame_size.y),
		float(m.frame_rect.size.x) / float(frame_size.x),
		float(m.frame_rect.size.y) / float(frame_size.y),
	)

func uv_to_host_point(m: MonitorSpec, uv: Vector2) -> Vector2i:
	# Moonlight's absolute mouse position protocol (LiSendMousePositionEvent)
	# sends x,y as a point WITHIN a refW x refH frame - the host scales that
	# onto its own capture region using its own knowledge of which outputs
	# are currently selected. So this must use frame_rect/frame_size (the
	# monitor's position within the actual COMPOSITED/CAPTURED video frame),
	# not desktop_rect/desktop_bounds (the monitor's position in the host's
	# real absolute multi-monitor desktop). Those two are identical whenever
	# every captured monitor's combined bounding box starts at the desktop
	# origin - which covers "all monitors captured" and "solo primary
	# captured", so this bug only ever showed up capturing a lone
	# non-origin monitor (e.g. a secondary made the sole captured output):
	# frame_rect there is normalized to (0,0)-sized-to-itself, but
	# desktop_rect still carried its real offset in the full desktop,
	# sending clicks scaled/offset into the wrong place.
	return Vector2i(
		m.frame_rect.position.x + int(uv.x * m.frame_rect.size.x),
		m.frame_rect.position.y + int(uv.y * m.frame_rect.size.y),
	)

func host_ref() -> Vector2i:
	return frame_size