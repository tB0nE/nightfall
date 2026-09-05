shader_type canvas_item;

// HDR variant of yuv_display.gdshader (2026-08-30) - deliberately a SEPARATE
// compiled shader, not a branch inside the plain one. color_transfer_type is
// a uniform, not a compile-time constant, so a branch for it in the normal
// shader would still get compiled into that program's instruction/register
// footprint even when never taken - and that shader runs on every pixel of
// the video plane every frame, sharing the GPU with AI-3D's depth-warp code
// in the same program. That cost showed up as a measured AI-3D throughput
// regression even on plain SDR streams that never touched the PQ/HLG path
// at all. Swapped in by composition_layer_manager.gd's bind_yuv_textures()
// only when a stream is actually detected as HDR - the plain shader (and
// everything using it) is completely unaffected by this file's existence.
//
// Its non-HDR flow mirrors yuv_display_core.gdshaderinc, with the transfer/
// gamut/tonemap stage and LUT added here. It remains standalone so no HDR
// code can enter the plain shader's compiled instruction footprint.

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;
uniform int yuv_mode = 0;
uniform int color_matrix_type = 1;
uniform int color_range = 0;
uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform int filter_mode = 0;
uniform float sharpen = 0.0;
uniform float blur_scale = 1.0;
uniform int stereo_mode = 0;
uniform int eye_index = 0;
uniform sampler2D depth_texture : hint_default_white, filter_linear, repeat_disable;
uniform sampler2D upsampled_depth_texture : hint_default_white, filter_linear;
uniform sampler2D offset_texture : hint_default_white, filter_linear;
uniform sampler2D depth_guide_texture : hint_default_black, filter_linear;
uniform float mode5_parallax = 0.006;
uniform int warp_newton_steps = 2;
uniform float convergence = 0.5;
uniform float balance_shift = 0.5;

uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

// Picture grading is a final grade on top of the already-tonemapped HDR
// result, not part of the tonemap math. HDR is already an opt-in shader, so
// this does not affect the normal SDR/AI-depth program.
uniform float brightness = 0.0;
uniform float contrast = 1.0;
uniform float gamma = 1.0;

vec3 apply_picture(vec3 c) {
	c = (c - 0.5) * contrast + 0.5 + brightness;
	return pow(max(c, vec3(0.0)), vec3(1.0 / gamma));
}

// 1 = PQ/ST 2084 (HDR10), 2 = HLG - see
// StreamConnection::_resolve_frame_transfer(). This shader is only ever
// assigned while one of those is true, but reads the real uniform anyway
// rather than assuming, so a mid-stream PQ<->HLG change (or a drop back to
// SDR, before composition_layer_manager.gd swaps the shader back) still
// renders correctly the very next frame.
uniform int color_transfer_type = 0;
// 256 wide (LUT input resolution) x 3 tall (row 0 = PQ decode, row 1 = HLG
// decode, row 2 = linear->sRGB encode) - each row is a full per-channel
// nonlinear curve, precomputed once in composition_layer_manager.gd
// (_get_hdr_lut()) and never rebuilt after. Trades ~7 pow()/exp() calls per
// pixel for 6 texture fetches (3 channels x decode-then-encode) - cheap on
// mobile GPU texture units, especially for a texture this small that stays
// cache-resident, vs. transcendental ALU ops on every one of the video
// plane's pixels every frame.
uniform sampler2D hdr_eotf_lut : filter_linear, repeat_disable;

float hdr_lut_sample(float e, float row) {
	float u = (clamp(e, 0.0, 1.0) * 255.0 + 0.5) / 256.0;
	float v = (row + 0.5) / 3.0;
	return texture(hdr_eotf_lut, vec2(u, v)).r;
}

// Fixed BT.2020 -> BT.709 primaries matrix (ITU-R BT.2087), applied in
// linear light. HDR content here is always BT.2020-tagged (see
// StreamConnection::_resolve_frame_colorspace()). Plain vector/matrix math,
// not transcendental - no LUT benefit, left as-is.
vec3 bt2020_to_bt709(vec3 c) {
	float r = 1.6604910 * c.r - 0.5876411 * c.g - 0.0728499 * c.b;
	float g = -0.1245505 * c.r + 1.1328999 * c.g - 0.0083494 * c.b;
	float b = -0.0181508 * c.r - 0.1005789 * c.g + 1.1187297 * c.b;
	return vec3(r, g, b);
}

// Luminance-preserving Reinhard tonemap: compresses dynamic range toward SDR
// without desaturating highlights the way a per-channel Reinhard would.
// One dot product + one divide - cheap, no LUT benefit.
vec3 tonemap_hdr_linear(vec3 c) {
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	if (l <= 0.0001) {
		return c;
	}
	float l_out = l / (1.0 + l);
	return c * (l_out / l);
}

// Apply the transfer/gamut/tonemap stage to either shader-decoded YUV RGB or
// an already-RGB decoder texture. The GLES SurfaceTexture bridge and Vulkan
// AHB compute path both publish a single RGB texture (color_matrix_type=3),
// but its samples still carry the stream's PQ/HLG transfer and BT.2020
// primaries; "already RGB" must not mean "already SDR-tonemapped".
vec3 decode_and_tonemap_hdr(vec3 rgb) {
	if (color_transfer_type == 1 || color_transfer_type == 2) {
		float row = color_transfer_type == 1 ? 0.0 : 1.0;
		vec3 lin = vec3(
			hdr_lut_sample(rgb.r, row),
			hdr_lut_sample(rgb.g, row),
			hdr_lut_sample(rgb.b, row)
		);
		lin = tonemap_hdr_linear(bt2020_to_bt709(lin));
		return vec3(
			hdr_lut_sample(lin.r, 2.0),
			hdr_lut_sample(lin.g, 2.0),
			hdr_lut_sample(lin.b, 2.0)
		);
	}
	return rgb;
}

vec3 yuv_to_rgb(vec2 uv) {
	if (color_matrix_type == 3) {
		return decode_and_tonemap_hdr(texture(tex_y, uv).rgb);
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

	return decode_and_tonemap_hdr(rgb);
}

vec2 to_frame_uv(vec2 t) {
	return uv_region.xy + clamp(t, tile_inset, vec2(1.0) - tile_inset) * uv_region.zw;
}

vec2 clamp_to_region(vec2 f) {
	vec2 ts = (yuv_mode > 0) ? vec2(textureSize(tex_y, 0)) : vec2(textureSize(main_texture, 0));
	vec2 guard = 0.5 / ts;
	return clamp(f, uv_region.xy + guard, uv_region.xy + uv_region.zw - guard);
}

vec3 heatmap(float t) {
	t = clamp(t, 0.0, 1.0);
	vec3 c1 = vec3(0.0, 0.0, 1.0);
	vec3 c2 = vec3(0.0, 1.0, 1.0);
	vec3 c3 = vec3(0.0, 1.0, 0.0);
	vec3 c4 = vec3(1.0, 1.0, 0.0);
	vec3 c5 = vec3(1.0, 0.0, 0.0);
	if (t < 0.25) {
		return mix(c1, c2, t / 0.25);
	} else if (t < 0.5) {
		return mix(c2, c3, (t - 0.25) / 0.25);
	} else if (t < 0.75) {
		return mix(c3, c4, (t - 0.5) / 0.25);
	} else {
		return mix(c4, c5, (t - 0.75) / 0.25);
	}
}

vec3 sample_stream(vec2 uv) {
	uv = clamp_to_region(uv);
	if (yuv_mode > 0) {
		return yuv_to_rgb(uv);
	}
	return texture(main_texture, uv).rgb;
}

vec3 filtered_stream(vec2 uv) {
	vec3 original = sample_stream(uv);
	if (filter_mode == 0 && sharpen <= 0.0) {
		return original;
	}
	vec2 texel = 1.0 / vec2(textureSize(tex_y, 0)) * blur_scale;
	if (yuv_mode == 0) {
		texel = 1.0 / vec2(textureSize(main_texture, 0)) * blur_scale;
	}
	if (filter_mode > 0) {
		float s = float(filter_mode) * 0.3;
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
	vec3 n = sample_stream(uv + vec2( 0.0, -texel.y));
	vec3 w = sample_stream(uv + vec2(-texel.x,  0.0));
	vec3 e = sample_stream(uv + vec2( texel.x,  0.0));
	vec3 s = sample_stream(uv + vec2( 0.0,  texel.y));
	vec3 mn = min(original, min(n, min(w, min(e, s))));
	vec3 mx = max(original, max(n, max(w, max(e, s))));
	vec3 range = mx - mn;
	vec3 peak = max(mx, vec3(0.0001));
	vec3 weight = vec3(sharpen) * clamp((peak - range) / peak, vec3(0.0), vec3(1.0));
	vec3 avg = (n + w + e + s) * 0.25;
	return original + weight * (original - avg);
}

void fragment() {
	vec2 tile_uv = UV;

	if (stereo_mode == 1) {
		tile_uv = (eye_index == 1) ? vec2(tile_uv.x * 0.5, tile_uv.y) : vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y);
	} else if (stereo_mode == 2) {
		tile_uv = (eye_index == 1) ? vec2(tile_uv.x * 0.5, tile_uv.y * 0.5 + 0.25) : vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y * 0.5 + 0.25);
	}

	vec2 uv = to_frame_uv(tile_uv);

	if (stereo_mode == 3 || stereo_mode == 4) {
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
		bool is_left = (eye_index == 1);
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

		uv = vec2(clamp(uv.x - shift * eye_sign, 0.0, 1.0), uv.y);
	}
	else if (stereo_mode == 5 || stereo_mode == 6 || stereo_mode == 10 || stereo_mode == 11) {
		float low_res_width = float(textureSize(upsampled_depth_texture, 0).x);
		float parallax = mode5_parallax;
		float disp_texels = parallax * low_res_width;
		int reach = int(ceil(abs(disp_texels) * max(convergence, 1.0 - convergence))) + 2;

		vec2 enc = texture(offset_texture, tile_uv).rg;
		bool is_left = (eye_index == 1);
		float eye_off = (is_left ? enc.r : enc.g) - 0.5;
		float tc_x = tile_uv.x + eye_off * 2.0 * float(reach) / low_res_width;

		float disparity = is_left ? parallax : -parallax;
		float h = 1.0 / low_res_width;
		for (int i = 0; i < 2; i++) {
			if (i >= warp_newton_steps) {
				break;
			}
			float d0 = texture(upsampled_depth_texture, vec2(tc_x, tile_uv.y)).r;
			float dm = texture(upsampled_depth_texture, vec2(tc_x - h, tile_uv.y)).r;
			float dp = texture(upsampled_depth_texture, vec2(tc_x + h, tile_uv.y)).r;
			float e = (tc_x - tile_uv.x) + disparity * (d0 - convergence);
			float slope = 1.0 + disparity * (dp - dm) / (2.0 * h);
			if (abs(slope) < 0.25) {
				slope = 0.25;
			}
			tc_x -= clamp(e / slope, -4.0 * h, 4.0 * h);
		}

		uv = to_frame_uv(vec2(clamp(tc_x, 0.0, 1.0), tile_uv.y));
	}

	if (stereo_mode == 7) {
		float d = texture(upsampled_depth_texture, tile_uv).r;
		COLOR = vec4(heatmap(d), 1.0);
	} else if (stereo_mode == 8) {
		float d = texture(depth_texture, tile_uv).r;
		COLOR = vec4(heatmap(d), 1.0);
	} else if (stereo_mode == 9) {
		COLOR = vec4(texture(depth_guide_texture, tile_uv).rgb, 1.0);
	} else if (filter_mode > 0 || sharpen > 0.0) {
		vec3 col = filtered_stream(uv);
		COLOR = vec4(apply_picture(col), 1.0);
	} else if (yuv_mode > 0) {
		COLOR = vec4(apply_picture(yuv_to_rgb(clamp_to_region(uv))), 1.0);
	} else {
		COLOR = texture(main_texture, clamp_to_region(uv));
		COLOR.rgb = apply_picture(COLOR.rgb);
	}
}
