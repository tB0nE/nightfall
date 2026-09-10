shader_type canvas_item;

// Multiplies the final alpha for faint controller and cursor markers. COLOR
// is fully overwritten below rather than derived from the incoming
// modulate-tinted vertex color, so this uniform is the opacity control used
// by the composition marker module.
uniform float alpha_mult : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(UV, center);
	float radius = 0.42;
	float edge = 0.015;
	float alpha = smoothstep(radius, radius - edge, dist);
	COLOR = vec4(1.0, 1.0, 1.0, alpha * 0.3 * alpha_mult);
}
