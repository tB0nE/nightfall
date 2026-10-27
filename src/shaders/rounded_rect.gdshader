shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, blend_mix;

// A flat rounded rectangle, e.g. the dark panel behind the screen shortcut
// icons. The quad's UVs span the rectangle; `aspect` is its width / height
// and `corner` the corner radius as a fraction of its height.
uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 0.55);
uniform float aspect = 5.0;
uniform float corner : hint_range(0.0, 0.5) = 0.4;

void fragment() {
	vec2 half_size = vec2(aspect, 1.0) * 0.5;
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0);
	vec2 q = abs(p) - (half_size - corner);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
	float edge = fwidth(dist);
	ALBEDO = color.rgb;
	ALPHA = color.a * (1.0 - smoothstep(-edge, edge, dist));
}
