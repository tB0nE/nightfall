shader_type canvas_item;

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
// stereo_mode 5's pre-computed textures (depth_estimator.gd owns the passes
// that produce these, once per frame, shared by both eyes - see
// depth_upsample.gdshader / depth_offset.gdshader for how).
uniform sampler2D upsampled_depth_texture : hint_default_white, filter_linear;
uniform sampler2D offset_texture : hint_default_white, filter_linear;
// The literal 256x256 RGBA color capture depth_viewport.gd feeds to MiDaS
// (depth_estimator.gd's depth_viewport, same texture depth_upsample.gdshader
// calls depth_guide_texture) - stereo_mode 9 (MiDaS-DMap-Input) shows this
// directly, unprocessed, to check whether a fixed/scene-independent artifact
// seen in DMap is already present in the model's INPUT (a capture/mapping
// bug) rather than something the model or the upsample pass invented.
uniform sampler2D depth_guide_texture : hint_default_black, filter_linear;
// Must match depth_estimator.gd's _pass_parallax exactly - it's baked into
// offset_texture's encoding via depth_offset.gdshader's own reach
// computation from the same value, and decoding here needs the identical
// reach or the disparity comes out scaled wrong. Set from GDScript
// (depth_estimator.gd's _setup_warp_passes()/set_parallax()) rather than
// left at this default, precisely so the two can't drift apart.
uniform float mode5_parallax = 0.006;
// How many Newton refinement steps the gather below does THIS frame (see
// it in use further down) - computed and pushed every render frame by
// depth_estimator.gd's process()/set_enabled() based on the active warp
// tier (MiDaS-Std always pushes 2; MiDaS-Fast/-Fastest cycle 1-then-0s on
// a period, amortizing the refinement's cost across frames instead of
// paying it every frame). The shader just reads whatever's here - it
// doesn't know or care which tier is active.
uniform int warp_newton_steps = 2;
uniform float convergence = 0.5;
uniform float balance_shift = 0.5;

uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

vec3 yuv_to_rgb(vec2 uv) {
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

vec2 to_frame_uv(vec2 t) {
	return uv_region.xy + clamp(t, tile_inset, vec2(1.0) - tile_inset) * uv_region.zw;
}

vec2 clamp_to_region(vec2 f) {
	vec2 ts = (yuv_mode > 0) ? vec2(textureSize(tex_y, 0)) : vec2(textureSize(main_texture, 0));
	vec2 guard = 0.5 / ts;
	return clamp(f, uv_region.xy + guard, uv_region.xy + uv_region.zw - guard);
}

// Classic 5-stop jet-style heatmap (blue -> cyan -> green -> yellow -> red)
// for visualizing a scalar depth value - far more legible than grayscale for
// spotting subtle variation, which is the whole point of stereo_mode 7.
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
		// MiDaS-GPU path's gather: cheap by design, since depth_estimator.gd
		// already ran the expensive edge-aware upsample + occlusion search
		// ONCE per frame (not per eye) into upsampled_depth_texture /
		// offset_texture - see depth_upsample.gdshader / depth_offset.gdshader.
		// This just decodes the offset-search's result and does up to two
		// Newton steps for sub-texel accuracy, mirroring xr_renderer.c's
		// FRAGMENT_SRC occlusion branch. Both textures are addressed in
		// tile_uv space (matching how depth_estimator.gd rendered them),
		// not uv (which already has uv_region's tiling/cropping applied).
		// The error function's sign here (+disparity, not -) must match
		// depth_offset.gdshader's own search exactly - verified against
		// xr_renderer.c directly (see git history 2026-08); refining toward
		// a root of the WRONG equation is worse than not refining at all.
		//
		// MiDaS-Fast/-Fastest (stereo_mode 10/11) are a GPU-cost experiment
		// (2026-08-18): they also drive depth_estimator.gd to run the
		// pre-pass above at a smaller divisor and throttled to
		// warp_update_interval instead of every render frame - see
		// warp_update_interval's comment in depth_estimator.gd for why.
		// stereo_mode 6 (MiDaS-Std) is untouched by any of this.
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

	// MiDaS-DMap: shows upsampled_depth_texture - the actual post-upsample
	// data stereo_mode 5/6's real warp consumes (depth_estimator.gd's
	// depth_upsample.gdshader pass), not the raw pre-upsample depth_texture -
	// as a heatmap instead of the video, mono (no warp/disparity). This is
	// what the warp is actually working with, so it's the right thing to
	// stare at when asking "is the depth data itself the problem". Same
	// tile_uv addressing as the mode 5/6 branch above uses for the same
	// texture. Separate if/else from the stereo_mode chain above (not
	// chained onto it with else-if) because that chain only adjusts uv -
	// modes 1-6 still need to fall through to the normal color-sampling
	// block below, which this must skip instead.
	if (stereo_mode == 7) {
		float d = texture(upsampled_depth_texture, tile_uv).r;
		COLOR = vec4(heatmap(d), 1.0);
	} else if (stereo_mode == 8) {
		// MiDaS-DMap-Raw: the RAW pre-upsample depth_texture (the model's
		// actual 256x256 output, before depth_upsample.gdshader's joint
		// bilateral filter touches it) - lets us tell apart "the model
		// itself produced this" from "the upsample/warp pass invented
		// this", when DMap shows content that doesn't correspond to
		// anything on the real desktop. Same UV mapping as
		// upsampled_depth_texture (both cover UV 0..1 = the full cropped
		// frame 1:1), just coarser since it's the raw 256x256 grid instead
		// of the quarter-native-res upsample.
		float d = texture(depth_texture, tile_uv).r;
		COLOR = vec4(heatmap(d), 1.0);
	} else if (stereo_mode == 9) {
		// MiDaS-DMap-Input: the literal color image fed to the model, no
		// heatmap, no processing at all - if a fixed/scene-independent
		// artifact is already visible HERE, it's a capture/mapping bug
		// (depth_viewport/depth_target in depth_estimator.gd), not the
		// model or either shader pass.
		COLOR = vec4(texture(depth_guide_texture, tile_uv).rgb, 1.0);
	} else if (filter_mode > 0 || sharpen > 0.0) {
		vec3 col = filtered_stream(uv);
		COLOR = vec4(col, 1.0);
	} else if (yuv_mode > 0) {
		COLOR = vec4(yuv_to_rgb(clamp_to_region(uv)), 1.0);
	} else {
		COLOR = texture(main_texture, clamp_to_region(uv));
	}
}