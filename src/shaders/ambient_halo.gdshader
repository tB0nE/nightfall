shader_type canvas_item;

// This shader runs only in the small ambient-light SubViewport. It samples
// a 32x32 copy of the already-rendered screen rather than duplicating the hot
// YUV, HDR, or AI-depth paths. That copy comes from either the legacy viewport
// or the native renderer's asynchronous final-image sample.
uniform sampler2D source_texture : source_color, filter_linear, repeat_disable;
uniform bool reactive = false;
uniform int style_mode = 0; // 0 = glow, 1 = neon, 2 = both, 3 = blurred edge
uniform vec4 static_color : source_color = vec4(1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.35;

const float LAYER_SCALE = 1.30;

vec3 sample_edge_color(vec2 source_uv) {
	// The source has already been reduced to 32x32. Four bilinear lookups
	// approximate a cubic B-spline, removing the visible grid that plain
	// magnification would otherwise put across a broad glow.
	vec2 size = vec2(textureSize(source_texture, 0));
	vec2 tc = source_uv * size - 0.5;
	vec2 base = floor(tc);
	vec2 f = tc - base;
	vec2 f2 = f * f;
	vec2 f3 = f2 * f;
	vec2 w0 = (vec2(1.0) - 3.0 * f + 3.0 * f2 - f3) / 6.0;
	vec2 w1 = (vec2(4.0) - 6.0 * f2 + 3.0 * f3) / 6.0;
	vec2 w2 = (vec2(1.0) + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
	vec2 w3 = f3 / 6.0;
	vec2 g0 = w0 + w1;
	vec2 g1 = w2 + w3;
	vec2 h0 = (base - 0.5 + w1 / max(g0, vec2(0.0001))) / size;
	vec2 h1 = (base + 1.5 + w3 / max(g1, vec2(0.0001))) / size;
	vec3 c00 = texture(source_texture, h0).rgb;
	vec3 c10 = texture(source_texture, vec2(h1.x, h0.y)).rgb;
	vec3 c01 = texture(source_texture, vec2(h0.x, h1.y)).rgb;
	vec3 c11 = texture(source_texture, h1).rgb;
	return mix(mix(c11, c01, g0.x), mix(c10, c00, g0.x), g0.y);
}

vec3 sample_blurred_edge_color(vec2 source_uv) {
	// Nine taps now all land in the tiny 32x32 colour map, never in the
	// full-resolution YUV/HDR/AI-3D screen texture.
	vec2 d = vec2(0.055, 0.085);
	vec3 c = texture(source_texture, source_uv).rgb * 4.0;
	c += texture(source_texture, clamp(source_uv + vec2(-d.x, 0.0), vec2(0.0), vec2(1.0))).rgb * 2.0;
	c += texture(source_texture, clamp(source_uv + vec2(d.x, 0.0), vec2(0.0), vec2(1.0))).rgb * 2.0;
	c += texture(source_texture, clamp(source_uv + vec2(0.0, -d.y), vec2(0.0), vec2(1.0))).rgb * 2.0;
	c += texture(source_texture, clamp(source_uv + vec2(0.0, d.y), vec2(0.0), vec2(1.0))).rgb * 2.0;
	c += texture(source_texture, clamp(source_uv + vec2(-d.x, -d.y), vec2(0.0), vec2(1.0))).rgb;
	c += texture(source_texture, clamp(source_uv + vec2(d.x, -d.y), vec2(0.0), vec2(1.0))).rgb;
	c += texture(source_texture, clamp(source_uv + vec2(-d.x, d.y), vec2(0.0), vec2(1.0))).rgb;
	c += texture(source_texture, clamp(source_uv + vec2(d.x, d.y), vec2(0.0), vec2(1.0))).rgb;
	return c * 0.0625;
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
	} else if (style_mode == 3) {
		// A softer, broader falloff makes the blurred screen edge appear to
		// continue naturally into the surrounding glow.
		alpha = pow(clamp(1.0 - edge_distance, 0.0, 1.0), 1.15);
	}
	alpha *= intensity * outside_mask;

	// Sample a short distance inside the picture rather than its exact outer
	// pixel. Black desktop borders/letterboxing otherwise make reactive modes
	// look disabled even while the source is updating correctly.
	vec2 source_uv = mix(vec2(0.055), vec2(0.945), clamp((UV - inner_min) / inner_size, vec2(0.0), vec2(1.0)));
	vec3 color;
	if (style_mode == 3) {
		color = sample_blurred_edge_color(source_uv);
	} else {
		color = reactive ? sample_edge_color(source_uv) : static_color.rgb;
	}
	COLOR = vec4(color, alpha);
}
