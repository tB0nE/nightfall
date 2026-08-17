shader_type canvas_item;

// Plain fragment-shader downscale of comp_viewport into depth_viewport
// (256x256), replacing a TextureRect+STRETCH_SCALE that showed a
// persistent, unexplained crop to a sub-region of the frame despite the
// bound texture's RID being verified identical to comp_viewport's own
// texture - a TextureRect can cache the source texture's reported size for
// its stretch-mode math and not always notice a live ViewportTexture's
// underlying content being resized later (comp_viewport gets resized
// dynamically as the real stream resolution negotiates in). Sampling
// directly here has no such cache - COLOR is recomputed fresh from
// source_tex's CURRENT size every render frame, every time.
uniform sampler2D source_tex : filter_linear_mipmap, repeat_disable;

void fragment() {
	COLOR = texture(source_tex, UV);
}
