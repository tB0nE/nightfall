shader_type canvas_item;

// Runs once per frame (not per eye) at the same resolution as
// depth_upsample.gdshader's output, reading it directly. Ported from
// Gilleece/moonlight-android-xr's xr_renderer.c OFFSET_FRAGMENT_SRC:
// inverts the warp properly by searching, for this destination pixel,
// which source offset t actually satisfies
//   e(t) = t + disparity * (depth(here + t) - convergence) = 0
// Every zero crossing is a source pixel that genuinely lands here; when more
// than one does (an occlusion), the nearer surface (larger depth) wins -
// this is what a single forward shift can never resolve, and why it
// stretches/smears across depth discontinuities instead of keeping small
// objects visually separate from what's behind them.
//
// The sign here (+disp, not -disp) matches the reference exactly - getting
// this backwards doesn't crash or look obviously broken, it just searches
// in the wrong direction, which shows up as the post-upsample warp (and
// DMap, which visualizes this same data) looking WORSE than the raw
// unprocessed depth instead of better. Verified against xr_renderer.c
// directly (see git history 2026-08) rather than re-derived from scratch.

uniform sampler2D upsampled_depth_texture : hint_default_white, filter_linear;
// disparity, in this pass's own texels: parallax_fraction * this_pass_width
uniform float disp_texels = 10.0;
uniform float convergence = 0.5;

void fragment() {
	ivec2 sz = textureSize(upsampled_depth_texture, 0);
	int x = int(FRAGCOORD.x);
	int y = int(FRAGCOORD.y);
	int reach = int(ceil(abs(disp_texels) * max(convergence, 1.0 - convergence))) + 2;

	vec2 result = vec2(0.0);
	// eye 0 = left (positive disparity), eye 1 = right (negative) - matches
	// yuv_display.gdshader's is_left ? +parallax : -parallax convention.
	for (int eye = 0; eye < 2; eye++) {
		float disp = (eye == 0) ? disp_texels : -disp_texels;
		float here = texelFetch(upsampled_depth_texture, ivec2(x, y), 0).r;
		float best_off = -disp * (here - convergence);
		float best_d = -1.0;
		float pd = texelFetch(upsampled_depth_texture, ivec2(clamp(x - reach, 0, sz.x - 1), y), 0).r;
		float pe = float(-reach) + disp * (pd - convergence);
		for (int t = -reach + 1; t <= reach; t++) {
			float cd = texelFetch(upsampled_depth_texture, ivec2(clamp(x + t, 0, sz.x - 1), y), 0).r;
			float ce = float(t) + disp * (cd - convergence);
			float span = ce - pe;
			if (pe * ce <= 0.0 && abs(span) > 1e-6) {
				float f = clamp(-pe / span, 0.0, 1.0);
				float rd = pd + f * (cd - pd);
				if (rd > best_d) {
					best_d = rd;
					best_off = float(t - 1) + f;
				}
			}
			pd = cd;
			pe = ce;
		}
		result[eye] = best_off;
	}
	COLOR = vec4(result / (2.0 * float(reach)) + 0.5, 0.0, 1.0);
}
