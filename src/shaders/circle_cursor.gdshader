shader_type canvas_item;

// Multiplies the final alpha - used by the controller position marker to
// switch between a full-opacity pickup flash and a very faint idle dot
// (main.gd's MARKER_ACTIVE_ALPHA/MARKER_IDLE_ALPHA). COLOR is fully
// overwritten below rather than derived from the incoming modulate-tinted
// vertex color, so node .modulate has no effect here - this uniform is the
// only way to control opacity from GDScript.
uniform float alpha_mult : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(UV, center);
	float radius = 0.42;
	float edge = 0.015;
	float alpha = smoothstep(radius, radius - edge, dist);
	COLOR = vec4(1.0, 1.0, 1.0, alpha * 0.3 * alpha_mult);
}
