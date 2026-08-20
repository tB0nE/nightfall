shader_type canvas_item;

// Manual box-filtered downscale (2026-08-19), replacing a naive single-tap
// sample. Godot doesn't generate real mip levels for a live SubViewport
// render target by default - comp_viewport/stream_viewport (see
// composition_layer_manager.gd) never call generate_mipmaps or equivalent -
// so the old filter_linear_mipmap hint here had no actual mip chain to draw
// from and silently degraded to plain single-tap bilinear (mip 0) sampling,
// meaning NO real anti-aliasing was happening on this downscale at all.
// That was subtle enough to go unnoticed at 256-384px depth models, but
// became clearly visible ("scrambled"-looking depth output) once a much
// more aggressive downscale ratio was tried at 192px - unfiltered
// minification aliasing/moire baked directly into the captured image fed
// to the depth model, not a model or inference-pipeline bug (confirmed:
// the same 192px model produced clean, coherent output on statically
// resized test photos that never went through this shader path).
//
// fwidth(UV) gives the actual per-fragment UV footprint (how much UV
// changes across one destination texel), which is the correct way to
// determine how many source texels one destination texel should average
// over - this adapts automatically to BOTH the live stream's native
// resolution (changes at runtime as the host negotiates) and whichever
// depth model's resolution (192-384px) is currently driving
// depth_viewport's size, unlike a fixed sample spacing tuned for one ratio.
uniform sampler2D source_tex : filter_linear, repeat_disable;

// 4x4 = 16 taps/fragment - a meaningful prefilter for the downscale ratios
// here (native stream resolution down to 192-384px) without being
// prohibitively expensive: depth_viewport itself is small (at most
// 384x384), so even 16 samples/fragment is cheap on mobile GPU hardware,
// and this pass re-renders every frame (UPDATE_ALWAYS).
const int TAPS = 4;

void fragment() {
	// Full extent of one destination texel, projected back into source UV
	// space.
	vec2 footprint = fwidth(UV);
	vec2 tap_step = footprint / float(TAPS);
	vec4 sum = vec4(0.0);
	for (int y = 0; y < TAPS; y++) {
		for (int x = 0; x < TAPS; x++) {
			// Tile TAPS x TAPS sample points evenly across the footprint,
			// centered on UV - each individual tap is itself bilinear-
			// filtered (filter_linear above), giving smoothing between
			// texels on top of the box average across taps.
			vec2 offset = tap_step * (vec2(float(x), float(y)) + 0.5) - footprint * 0.5;
			sum += texture(source_tex, UV + offset);
		}
	}
	COLOR = sum / float(TAPS * TAPS);
}
