shader_type canvas_item;

// Same alpha_mult convention as circle_cursor.gdshader (main.gd's
// MARKER_IDLE_ALPHA etc) - COLOR is fully overwritten below, so node
// .modulate has no effect; this uniform is the only opacity control.
uniform float alpha_mult : hint_range(0.0, 1.0) = 1.0;

// Live triangle vertices in UV space [0,1]^2 (2026-08-27) - set every frame
// by main.gd's _update_one_hand_indicator() from the wrist and two
// knuckle joints' real projected positions, replacing the original fixed
// triangle shape. Defaults here only matter before the first real update.
uniform vec2 point_a = vec2(0.12, 0.12);
uniform vec2 point_b = vec2(0.5, 0.88);
uniform vec2 point_c = vec2(0.88, 0.12);

// Signed distance to the line through a-b, in UV space. Sign depends on
// winding direction - only used relative to itself below, so that's fine.
float edge_dist(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	vec2 ap = p - a;
	return (ab.x * ap.y - ab.y * ap.x) / max(length(ab), 0.0001);
}

void fragment() {
	// Normalize all three edge distances to the same "inside" sign as the
	// first edge, so this works regardless of the triangle's own winding
	// direction (any simple triangle is convex, so this is safe).
	float s = sign(edge_dist(UV, point_a, point_b));
	float d1 = edge_dist(UV, point_a, point_b) * s;
	float d2 = edge_dist(UV, point_b, point_c) * s;
	float d3 = edge_dist(UV, point_c, point_a) * s;
	float inside = min(min(d1, d2), d3);

	float edge_soft = 0.015;
	float alpha = smoothstep(0.0, edge_soft, inside);
	COLOR = vec4(1.0, 1.0, 1.0, alpha * 0.5 * alpha_mult);
}
