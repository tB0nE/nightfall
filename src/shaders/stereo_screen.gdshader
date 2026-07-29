shader_type spatial;
render_mode unshaded;

uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D depth_texture : hint_default_white, filter_linear_mipmap;
uniform int stereo_mode = 0;
uniform float convergence = 0.5;
uniform float balance_shift = 0.5;
uniform int filter_mode = 0;
uniform float sharpen = 0.0;

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;
uniform int yuv_mode = 0;
uniform int color_matrix_type = 1;
uniform int color_range = 0;
uniform float blur_scale = 1.0;

uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

vec3 yuv_to_rgb(vec2 uv) {
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

	return rgb;
}

vec3 srgb_to_linear(vec3 c) {
	return pow(c, vec3(2.2));
}

vec2 to_frame_uv(vec2 t) {
	return uv_region.xy + clamp(t, tile_inset, vec2(1.0) - tile_inset) * uv_region.zw;
}

vec2 clamp_to_region(vec2 f) {
	vec2 ts = (yuv_mode > 0) ? vec2(textureSize(tex_y, 0)) : vec2(textureSize(main_texture, 0));
	vec2 guard = 0.5 / ts;
	return clamp(f, uv_region.xy + guard, uv_region.xy + uv_region.zw - guard);
}

vec3 sample_stream(vec2 uv) {
	uv = clamp_to_region(uv);
	if (yuv_mode > 0) {
		return srgb_to_linear(yuv_to_rgb(uv));
	}
	return texture(main_texture, uv).rgb;
}

vec3 cas_sharpen_stream(vec2 uv, float strength) {
	vec2 texel = 1.0 / vec2(textureSize(tex_y, 0)) * blur_scale;

	vec3 c = sample_stream(uv);
	vec3 n = sample_stream(uv + vec2( 0.0, -texel.y));
	vec3 w = sample_stream(uv + vec2(-texel.x,  0.0));
	vec3 e = sample_stream(uv + vec2( texel.x,  0.0));
	vec3 s = sample_stream(uv + vec2( 0.0,  texel.y));

	vec3 mn = min(c, min(n, min(w, min(e, s))));
	vec3 mx = max(c, max(n, max(w, max(e, s))));
	vec3 range = mx - mn;

	vec3 peak = max(mx, vec3(0.0001));
	vec3 weight = vec3(strength) * clamp((peak - range) / peak, vec3(0.0), vec3(1.0));

	vec3 avg = (n + w + e + s) * 0.25;
	return c + weight * (c - avg);
}

vec3 filtered_stream(vec2 uv) {
	vec3 original = sample_stream(uv);

	if (filter_mode == 0 && sharpen <= 0.0) {
		return original;
	}

	vec2 texel = (yuv_mode > 0)
		? 1.0 / vec2(textureSize(tex_y, 0)) * blur_scale
		: 1.0 / vec2(textureSize(main_texture, 0)) * blur_scale;

	if (filter_mode > 0) {
		float s = float(filter_mode) * 4.0;
		vec3 blurred = original * 4.0;
		blurred += sample_stream(uv + vec2(-1.0, -1.0) * texel * s);
		blurred += sample_stream(uv + vec2( 1.0, -1.0) * texel * s);
		blurred += sample_stream(uv + vec2(-1.0,  1.0) * texel * s);
		blurred += sample_stream(uv + vec2( 1.0,  1.0) * texel * s);
		blurred += sample_stream(uv + vec2(-1.0,  0.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 1.0,  0.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 0.0, -1.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 0.0,  1.0) * texel * s) * 2.0;
		blurred /= 16.0;
		if (sharpen > 0.0) {
			return blurred + sharpen * (original - blurred);
		}
		return blurred;
	}

	return cas_sharpen_stream(uv, sharpen);
}

void fragment() {
	vec2 tile_uv = UV;

	if (stereo_mode == 1) {
		tile_uv = (int(VIEW_INDEX) == 0)
			? vec2(tile_uv.x * 0.5, tile_uv.y)
			: vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y);
	} else if (stereo_mode == 2) {
		tile_uv = (int(VIEW_INDEX) == 0)
			? vec2(tile_uv.x * 0.5, tile_uv.y * 0.5 + 0.25)
			: vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y * 0.5 + 0.25);
	}

	vec2 uv = to_frame_uv(tile_uv);

	if (stereo_mode == 0 || stereo_mode == 1 || stereo_mode == 2) {
		ALBEDO = filtered_stream(uv);
	}
	else if (stereo_mode == 3 || stereo_mode == 4) {
		vec2 depth_texel = 1.0 / vec2(textureSize(depth_texture, 0));
		float parallax = 0.042;
		float half_parallax = parallax * 0.5;

		vec2 depth_uv = uv - vec2(half_parallax, 0.0);
		depth_uv = clamp(depth_uv, vec2(0.0), vec2(1.0));
		float depth = texture(depth_texture, depth_uv).r;

		float depth_diff = clamp(depth - convergence, -convergence, 1.0 - convergence);

		float dist_from_convergence = abs(depth - convergence);
		float zone_radius = 0.70;
		float fade_multiplier = smoothstep(0.0, zone_radius, dist_from_convergence);
		depth_diff *= fade_multiplier;

		float shift = parallax * depth_diff;

		bool is_left = (int(VIEW_INDEX) == 0);
		float eye_sign = is_left ? -1.0 : 1.0;

		if ((depth - convergence) < 0.0) {
			shift *= is_left ? balance_shift : (1.0 - balance_shift);
		} else {
			shift *= is_left ? (1.0 - balance_shift) : balance_shift;
		}

		float edge_width = 3.0 * depth_texel.x;
		float depth_left = texture(depth_texture, vec2(edge_width, 0.5)).r;
		float depth_right = texture(depth_texture, vec2(1.0 - edge_width, 0.5)).r;
		float max_edge_shift = max(abs(depth_left - convergence), abs(depth_right - convergence));
		float max_shift_possible = parallax * max_edge_shift;
		float vignette_bias = (convergence - 0.5) * 0.3;
		float vignette_start = mix(0.7 - vignette_bias, 1.0 - vignette_bias, clamp(max_shift_possible / 0.05, 0.0, 1.0));

		float h_dist = abs(uv.x - 0.5) * 2.0;
		float vignette = 1.0 - smoothstep(vignette_start, 1.0, pow(h_dist, 1.5));

		shift *= vignette;

		vec2 src_uv = vec2(clamp(uv.x - shift * eye_sign, 0.0, 1.0), uv.y);
		ALBEDO = filtered_stream(src_uv);
	}
}