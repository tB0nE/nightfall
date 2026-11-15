class_name DefaultStreamResolution
extends RefCounted

## Fit the selected monitor size without changing a packed stream's aspect.
static func packed_frame(target: Vector2i, frame: Vector2i, primary: Vector2i) -> Vector2i:
	if frame.x <= 0 or frame.y <= 0 or primary.x <= 0 or primary.y <= 0: return target
	var scale := minf(float(target.x) / primary.x, float(target.y) / primary.y)
	return Vector2i(maxi(1, roundi(frame.x * scale)), maxi(1, roundi(frame.y * scale)))
