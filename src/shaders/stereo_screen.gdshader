shader_type spatial;
render_mode unshaded;

uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D depth_texture : hint_default_white, filter_linear_mipmap;
// Same-resolution downscaled color frame the depth model itself saw
// (depth_estimator.gd's depth_viewport) - used as the edge guide for
// stereo_mode 5's joint bilateral depth upsample.
uniform sampler2D depth_guide_texture : hint_default_black, filter_linear;
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

// Classic 5-stop jet-style heatmap (blue -> cyan -> green -> yellow -> red)
// for visualizing a scalar depth value - matches yuv_display.gdshader's own
// heatmap(), duplicated here since this shader has no shared include.
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

// Joint bilateral tap: weight each low-res depth neighbour by how closely
// its guide color matches the real color at `uv`, so the depth edge snaps
// to the color edge instead of straddling it. Shared by the mode 5/6/10/11
// warp below (which also needs dlo/dhi for its edge-snap) and mode 7
// (MiDaS-DMap), which visualizes this exact interpolated value as a heatmap
// instead of using it to warp.
float bilateral_depth(vec2 uv, out float dlo, out float dhi) {
	ivec2 low_sz = textureSize(depth_texture, 0);
	float n = float(low_sz.x);
	vec3 hi_color = sample_stream(uv);
	vec2 lp = uv * n - 0.5;
	ivec2 base = ivec2(floor(lp));

	float num = 0.0;
	float den = 0.0;
	dlo = 1.0;
	dhi = 0.0;
	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -2; dx <= 2; dx++) {
			ivec2 q = clamp(base + ivec2(dx, dy), ivec2(0), ivec2(int(n) - 1));
			float s = texelFetch(depth_texture, q, 0).r;
			vec3 gcol = texelFetch(depth_guide_texture, q, 0).rgb;
			vec2 off = vec2(q) - lp;
			float ws = exp(-dot(off, off) / (2.0 * 1.5 * 1.5));
			vec3 cd = hi_color - gcol;
			float wr = exp(-dot(cd, cd) / (2.0 * 0.12 * 0.12));
			float w = ws * wr;
			num += w * s;
			den += w;
			dlo = min(dlo, s);
			dhi = max(dhi, s);
		}
	}
	return num / max(den, 1e-6);
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
	else if (stereo_mode == 5 || stereo_mode == 6 || stereo_mode == 10 || stereo_mode == 11) {
		// Joint-bilateral-upsampled, occlusion-aware warp (MiDaS-GPU path).
		// The plain branch above samples one raw, blurry low-res depth texel
		// per destination pixel and always trusts it - correct only where
		// depth is flat, and wrong by most of the disparity range at a depth
		// step, which is what makes small objects (taskbar icons, a clock
		// widget) stretch/warp instead of standing apart from the background.
		// This instead (a) snaps the low-res depth to the real color edges
		// via a bilateral upsample, guided by depth_guide_texture - the same
		// downscaled frame the depth model itself saw - and (b) searches a
		// short span along the epipolar line for whichever candidate source
		// actually lands on this destination pixel, preferring the nearest
		// of any that do (real occlusion resolution), instead of a single
		// forward shift. Ported from Gilleece/moonlight-android-xr's
		// xr_renderer.c (UPSAMPLE_FRAGMENT_SRC + OFFSET_FRAGMENT_SRC's
		// occlusion branch), collapsed into one pass since Godot's per-eye
		// fragment shader here doesn't have a cheap way to share a
		// pre-pass between the two eye invocations.
		//
		// stereo_mode 10/11 (MiDaS-Fast/-Fastest) get the exact same
		// treatment as 6 (Std) here - this single-pass mesh-rendering
		// fallback (used when comp.available is false) has no equivalent to
		// depth_estimator.gd's tiered pre-pass throttling/shrinking or
		// yuv_display.gdshader's warp_newton_steps amortization, so there's
		// no cheaper version of this warp to give them; full quality is the
		// only quality this path has.
		float parallax = 0.042;
		ivec2 low_sz = textureSize(depth_texture, 0);
		float n = float(low_sz.x);
		float texel = 1.0 / n;

		vec2 lp = uv * n - 0.5;
		ivec2 base = ivec2(floor(lp));

		float dlo, dhi;
		float depth_here = bilateral_depth(uv, dlo, dhi);
		float span = dhi - dlo;
		if (span >= 0.05) {
			float edge_u = clamp((depth_here - dlo) / max(span, 1e-6), 0.0, 1.0);
			float snapped = dlo + span / (1.0 + exp(-24.0 * (edge_u - 0.5)));
			depth_here = mix(depth_here, snapped, 0.6);
		}

		bool is_left = (int(VIEW_INDEX) == 0);
		float eye_sign = is_left ? -1.0 : 1.0;

		// Solve e(t) = t + eye_sign * parallax * (depth(uv.x + t) - convergence) = 0
		// for t: every zero crossing is a source pixel that genuinely lands
		// on this destination pixel. Search the raw low-res depth (cheap,
		// matches the reference implementation's design) and keep whichever
		// crossing has the nearest (largest) depth - the surface that wins
		// the occlusion.
		int reach = int(ceil(parallax * n * max(convergence, 1.0 - convergence))) + 2;
		float best_off = eye_sign * -parallax * (depth_here - convergence);
		float best_depth = -1.0;
		ivec2 prev_q = clamp(base + ivec2(-reach, 0), ivec2(0), ivec2(int(n) - 1));
		float prev_depth = texelFetch(depth_texture, prev_q, 0).r;
		float prev_t = float(-reach) * texel;
		float prev_err = prev_t + eye_sign * parallax * (prev_depth - convergence);
		for (int t = -reach + 1; t <= reach; t++) {
			ivec2 q = clamp(base + ivec2(t, 0), ivec2(0), ivec2(int(n) - 1));
			float cur_depth = texelFetch(depth_texture, q, 0).r;
			float cur_t = float(t) * texel;
			float cur_err = cur_t + eye_sign * parallax * (cur_depth - convergence);
			if (prev_err * cur_err <= 0.0 && abs(cur_err - prev_err) > 1e-6) {
				float f = clamp(-prev_err / (cur_err - prev_err), 0.0, 1.0);
				float rd = prev_depth + f * (cur_depth - prev_depth);
				if (rd > best_depth) {
					best_depth = rd;
					best_off = mix(prev_t, cur_t, f);
				}
			}
			prev_err = cur_err;
			prev_depth = cur_depth;
			prev_t = cur_t;
		}

		vec2 src_uv = vec2(clamp(uv.x + best_off, 0.0, 1.0), uv.y);
		ALBEDO = filtered_stream(src_uv);
	}
	else if (stereo_mode == 7) {
		// MiDaS-DMap: the bilateral-upsampled depth the real warp above
		// (mode 5/6/10/11) actually consumes, as a heatmap instead of used
		// to warp - matches yuv_display.gdshader's stereo_mode 7, except
		// that path reads a precomputed upsampled_depth_texture while this
		// one recomputes bilateral_depth() inline, since this shader has no
		// equivalent precomputed pass to read from.
		float dlo, dhi;
		float d = bilateral_depth(uv, dlo, dhi);
		ALBEDO = heatmap(d);
	}
	else if (stereo_mode == 8) {
		// MiDaS-DMap-Raw: the RAW pre-upsample depth_texture (the model's
		// actual 256x256 output), no bilateral upsample applied.
		float d = texture(depth_texture, uv).r;
		ALBEDO = heatmap(d);
	}
	else if (stereo_mode == 9) {
		// MiDaS-DMap-Input: the literal color capture fed to the model, no
		// heatmap, no processing at all.
		ALBEDO = texture(depth_guide_texture, uv).rgb;
	}
}