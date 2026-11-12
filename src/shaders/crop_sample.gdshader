shader_type canvas_item;
render_mode unshaded;
uniform sampler2D main_texture : filter_linear, repeat_disable;
uniform int stereo_mode = 0;
void fragment() {
	vec2 uv = UV;
	if (stereo_mode == 1) uv.x *= 0.5;
	else if (stereo_mode == 2) uv = uv * 0.5 + vec2(0.0, 0.25);
	COLOR = texture(main_texture, uv);
}
