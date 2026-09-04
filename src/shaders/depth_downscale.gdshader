shader_type canvas_item;

// Downscale to the depth model's input resolution while decoding the native
// decoder textures directly. This removes the old dependency on a separate
// full-resolution mono YUV->RGB SubViewport; AI-3D now needs only the two
// displayed eye viewports plus this small model-input pass.

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;
uniform int yuv_mode = 0;
uniform int color_matrix_type = 1;
uniform int color_range = 0;
uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

// A 4x4 box filter avoids aliasing when reducing a full desktop frame to a
// 192-384px model input. The pass itself is small, so these taps are much
// cheaper than keeping another full-resolution render target alive.
const int TAPS = 4;

vec3 yuv_to_rgb(vec2 uv) {
	// GLES already converts its external-OES decoder image into an ordinary
	// RGBA texture before exposing it to Godot. color_matrix_type=3 marks that
	// path, so tex_y is sampled directly without touching absent chroma planes.
	if (color_matrix_type == 3) {
		return texture(tex_y, uv).rgb;
	}

	float y_raw = texture(tex_y, uv).r;
	float u_raw = 0.5;
	float v_raw = 0.5;

	if (yuv_mode == 1) {
		ivec2 tex_size = textureSize(tex_u, 0);
		int cx = int(uv.x * float(tex_size.x / 2));
		int cy = int(uv.y * float(tex_size.y));
		cx = clamp(cx, 0, tex_size.x / 2 - 1);
		cy = clamp(cy, 0, tex_size.y - 1);
		u_raw = texelFetch(tex_u, ivec2(cx * 2, cy), 0).r;
		v_raw = texelFetch(tex_u, ivec2(cx * 2 + 1, cy), 0).r;
	} else if (yuv_mode == 2) {
		vec2 uv_val = texture(tex_u, uv).rg;
		u_raw = uv_val.r;
		v_raw = uv_val.g;
	} else if (yuv_mode == 3) {
		u_raw = texture(tex_u, uv).r;
		v_raw = texture(tex_v, uv).r;
	}

	float y;
	float u;
	float v;
	if (color_range == 0) {
		y = (y_raw - 16.0 / 255.0) * (255.0 / 219.0);
		u = (u_raw - 128.0 / 255.0) * (255.0 / 224.0);
		v = (v_raw - 128.0 / 255.0) * (255.0 / 224.0);
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
	return rgb;
}

vec2 to_frame_uv(vec2 tile_uv) {
	return uv_region.xy + clamp(tile_uv, tile_inset, vec2(1.0) - tile_inset) * uv_region.zw;
}

vec3 sample_stream(vec2 uv) {
	if (yuv_mode > 0) {
		return yuv_to_rgb(uv);
	}
	return texture(main_texture, uv).rgb;
}

void fragment() {
	vec2 footprint = fwidth(UV);
	vec2 tap_step = footprint / float(TAPS);
	vec3 sum = vec3(0.0);
	for (int y = 0; y < TAPS; y++) {
		for (int x = 0; x < TAPS; x++) {
			vec2 offset = tap_step * (vec2(float(x), float(y)) + 0.5) - footprint * 0.5;
			sum += sample_stream(to_frame_uv(UV + offset));
		}
	}
	COLOR = vec4(sum / float(TAPS * TAPS), 1.0);
}
