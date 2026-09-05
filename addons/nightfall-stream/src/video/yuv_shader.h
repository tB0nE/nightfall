#pragma once

static const char *YUV_SHADER_CODE = R"(
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;

uniform bool is_semi_planar;
uniform bool is_nv12_rd;
uniform int color_matrix_type;
uniform int color_range;
// Metadata carrier read back by composition_layer_manager.gd. Conversion is
// intentionally performed by its separate HDR display shader, not here.
uniform int color_transfer_type;
uniform bool swap_uv;

void fragment() {
	if (color_matrix_type == 3) {
		// RGBA passthrough - data was already converted from BGRA in C++
		COLOR = texture(tex_y, UV);
	} else {

	float y_raw = texture(tex_y, UV).r;
	float u_raw = 0.5;
	float v_raw = 0.5;

	if (is_nv12_rd) {
		ivec2 tex_size = textureSize(tex_u, 0);
		int cx = int(UV.x * float(tex_size.x / 2));
		int cy = int(UV.y * float(tex_size.y));
		cx = clamp(cx, 0, tex_size.x / 2 - 1);
		cy = clamp(cy, 0, tex_size.y - 1);
		u_raw = texelFetch(tex_u, ivec2(cx * 2, cy), 0).r;
		v_raw = texelFetch(tex_u, ivec2(cx * 2 + 1, cy), 0).r;
	} else if (is_semi_planar) {
		vec2 uv_val = texture(tex_u, UV).rg;
		u_raw = uv_val.r;
		v_raw = uv_val.g;
		if (swap_uv) {
			float temp = u_raw;
			u_raw = v_raw;
			v_raw = temp;
		}
	} else {
		if (swap_uv) {
			u_raw = texture(tex_v, UV).r;
			v_raw = texture(tex_u, UV).r;
		} else {
			u_raw = texture(tex_u, UV).r;
			v_raw = texture(tex_v, UV).r;
		}
	}

	float y, u, v;

	if (color_range == 0) {
		y = (y_raw - 16.0/255.0) * (255.0/219.0);
		u = (u_raw - 128.0/255.0) * (255.0/224.0);
		v = (v_raw - 128.0/255.0) * (255.0/224.0);
	} else {
		y = y_raw;
		u = u_raw - 0.5;
		v = v_raw - 0.5;
	}

	vec3 rgb = vec3(0.0);

	if (color_matrix_type == 1) {
		rgb.r = y + 1.5748 * v;
		rgb.g = y - 0.1873 * u - 0.4681 * v;
		rgb.b = y + 1.8556 * u;
	} else if (color_matrix_type == 2) {
		rgb.r = y + 1.4746 * v;
		rgb.g = y - 0.16455 * u - 0.57135 * v;
		rgb.b = y + 1.8814 * u;
	} else {
		rgb.r = y + 1.402 * v;
		rgb.g = y - 0.344136 * u - 0.714136 * v;
		rgb.b = y + 1.772 * u;
	}

	COLOR = vec4(rgb, 1.0);
	}
}
)";
