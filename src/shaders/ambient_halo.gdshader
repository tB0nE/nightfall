shader_type canvas_item;

// This shader runs only in the small ambient-light SubViewport. It samples
// the already-rendered screen viewport rather than duplicating the hot YUV,
// HDR, or AI-depth paths.
uniform sampler2D source_texture : source_color, filter_linear, repeat_disable;
uniform bool reactive = false;
uniform int style_mode = 0; // 0 = glow, 1 = neon, 2 = both
uniform vec4 static_color : source_color = vec4(1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.35;

const float LAYER_SCALE = 1.30;

vec3 sample_edge_color(vec2 source_uv) {
	// Four nearby bilinear samples soften small, rapidly-changing details
	// without requiring a separate blur/downsample pass.
	vec2 d = vec2(0.016, 0.024);
	vec3 c = texture(source_texture, clamp(source_uv + vec2(-d.x, 0.0), vec2(0.0), vec2(1.0))).rgb;
	c += texture(source_texture, clamp(source_uv + vec2(d.x, 0.0), vec2(0.0), vec2(1.0))).rgb;
	c += texture(source_texture, clamp(source_uv + vec2(0.0, -d.y), vec2(0.0), vec2(1.0))).rgb;
	c += texture(source_texture, clamp(source_uv + vec2(0.0, d.y), vec2(0.0), vec2(1.0))).rgb;
	return c * 0.25;
}

void fragment() {
	vec2 inner_half = vec2(0.5 / LAYER_SCALE);
	vec2 inner_min = vec2(0.5) - inner_half;
	vec2 inner_size = inner_half * 2.0;
	vec2 from_center = abs(UV - vec2(0.5));
	vec2 outside = max(from_center - inner_half, vec2(0.0));
	float outside_mask = step(0.000001, max(outside.x, outside.y));

	// Normalize the distance through the halo margin. Euclidean distance gives
	// naturally rounded outer corners instead of a hard rectangular plate.
	vec2 margin = vec2(0.5) - inner_half;
	float edge_distance = length(outside / max(margin, vec2(0.0001)));
	float glow = pow(clamp(1.0 - edge_distance, 0.0, 1.0), 1.65);
	float neon = 1.0 - smoothstep(0.0, 0.10, edge_distance);

	float alpha = glow;
	if (style_mode == 1) {
		alpha = neon;
	} else if (style_mode == 2) {
		alpha = max(glow * 0.72, neon);
	}
	alpha *= intensity * outside_mask;

	vec2 source_uv = clamp((UV - inner_min) / inner_size, vec2(0.0), vec2(1.0));
	vec3 color = reactive ? sample_edge_color(source_uv) : static_color.rgb;
	COLOR = vec4(color, alpha);
}
