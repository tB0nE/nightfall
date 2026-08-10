class_name MonitorGrid
extends RefCounted

# Client-side VR presentation grid: an 8-column x 4-row grid of "blocks", each
# screen occupies a 2x2 block footprint (SPAN). Grid coordinates [gx, gy] are
# the 0-indexed top-left block of that footprint; gx increases rightward, gy
# increases downward (matches the preset JSON authoring convention).
#
# Pure index/bounds math only - actual world-space placement of a screen at a
# grid cell is main.gd::grid_cell_transform(), which deliberately reuses the
# EXISTING neighbor-edge curvature math (_curve_edge_local_offset(), the same
# one add_screen() already uses) rather than any independent grid-specific
# curve formula, so a screen's grid position can never drift out of sync with
# its own (unchanged) curved-mesh geometry - see that function's comment.

const COLS := 8
const ROWS := 4
const SPAN := 2


static func col_center(gx: int) -> float:
	return gx + 1.0


static func row_center(gy: int) -> float:
	return gy + 1.0


static func cell_in_bounds(gx: int, gy: int) -> bool:
	return gx >= 0 and gy >= 0 and gx + SPAN <= COLS and gy + SPAN <= ROWS


static func cells_overlap(a: Vector2i, b: Vector2i) -> bool:
	return not (a.x + SPAN <= b.x or b.x + SPAN <= a.x or a.y + SPAN <= b.y or b.y + SPAN <= a.y)
