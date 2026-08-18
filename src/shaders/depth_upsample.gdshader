shader_type canvas_item;

// Runs once per frame (not per eye) at a modest fraction of the stream's own
// resolution - see depth_estimator.gd for the sizing. Ported from
// Gilleece/moonlight-android-xr's xr_renderer.c UPSAMPLE_FRAGMENT_SRC: a
// joint bilateral upsample of the depth model's raw 256x256 output, guided
// by the real decoded color frame, so depth edges snap to color edges
// instead of the raw output's blurry ones (which is what made small objects
// like a taskbar icon or a clock widget stretch/warp instead of standing
// apart from the background).
//
// Decodes YUV directly (duplicated from yuv_display.gdshader) rather than
// depending on comp_viewport's rendered RGB output. comp_viewport is itself
// a SubViewport, and Godot updates SubViewports in scene-tree order - since
// THIS pass's own output is a dependency of comp_viewport_left/right (the
// actually-displayed eyes, via yuv_display.gdshader's stereo_mode 5 branch),
// this pass must render BEFORE them, which conflicts with also needing to
// render AFTER comp_viewport if comp_viewport were the color source. tex_y/
// tex_u/tex_v are plain uploaded textures with no such render-order
// dependency, so sourcing color from them directly breaks the cycle.

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;
uniform int yuv_mode = 0;
uniform int color_matrix_type = 1;
uniform int color_range = 0;
uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

uniform sampler2D depth_texture : hint_default_white, filter_linear;
// Low-res (same resolution as depth_texture) downscaled color frame the
// depth model itself saw - the neighbour-comparison guide. Kept separate
// from the full-res "here" comparison so the 5x5 neighbour taps stay cheap
// texelFetches instead of 25 extra full-res texture() samples.
uniform sampler2D depth_guide_texture : hint_default_black, filter_linear;
// Matches Gilleece/moonlight-android-xr's own measured/shipped defaults
// (xr_renderer.c) exactly, not guesses: sigma_r=0.25 was "measured best on a
// captured frame: same 5px edge as tighter values with a tenth of the
// speckle" (a tighter sigma_r, which is what this had before, gives the same
// edge sharpness but far noisier depth); sharp=0.0 (the hard edge-snap
// below) was tested and shipped OFF - "off until it earns its place in a
// blind comparison on device."
uniform float sigma_r = 0.25;
uniform float sharp = 0.0;

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

vec3 sample_stream(vec2 uv) {
	if (yuv_mode > 0) {
		return yuv_to_rgb(uv);
	}
	return texture(main_texture, uv).rgb;
}

void fragment() {
	vec3 hi = sample_stream(to_frame_uv(UV));
	ivec2 low_sz = textureSize(depth_texture, 0);
	float n = float(low_sz.x);
	vec2 lp = UV * n - 0.5;
	ivec2 base = ivec2(floor(lp));

	float num = 0.0;
	float den = 0.0;
	float dlo = 1.0;
	float dhi = 0.0;
	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -2; dx <= 2; dx++) {
			ivec2 q = clamp(base + ivec2(dx, dy), ivec2(0), ivec2(int(n) - 1));
			float s = texelFetch(depth_texture, q, 0).r;
			vec3 gcol = texelFetch(depth_guide_texture, q, 0).rgb;
			vec2 off = vec2(q) - lp;
			float ws = exp(-dot(off, off) / (2.0 * 1.5 * 1.5));
			vec3 cd = hi - gcol;
			float wr = exp(-dot(cd, cd) / (2.0 * sigma_r * sigma_r));
			float w = ws * wr;
			num += w * s;
			den += w;
			dlo = min(dlo, s);
			dhi = max(dhi, s);
		}
	}
	float d = num / max(den, 1e-6);
	float span = dhi - dlo;
	if (sharp > 0.0 && span >= 0.05) {
		float u2 = clamp((d - dlo) / max(span, 1e-6), 0.0, 1.0);
		float snapped = dlo + span / (1.0 + exp(-24.0 * (u2 - 0.5)));
		d = mix(d, snapped, sharp);
	}
	COLOR = vec4(d, d, d, 1.0);
}
