// Shared by native GLES and Godot's screen shaders. Compare hue independently
// of brightness so black window shadows over the key background still match.
vec4 nightfall_chroma_key(vec4 sample_color, vec3 key_color, float tolerance) {
	vec3 c = max(sample_color.rgb, vec3(0.0));
	vec3 k = max(key_color, vec3(0.0));
	float high = max(c.r, max(c.g, c.b));
	float low = min(c.r, min(c.g, c.b));
	float chroma = high - low;
	float key_high = max(k.r, max(k.g, k.b));
	float key_low = min(k.r, min(k.g, k.b));
	vec3 hue = (c - vec3(low)) / max(chroma, 0.0001);
	vec3 key_hue = (k - vec3(key_low)) / max(key_high - key_low, 0.0001);
	float hue_distance = distance(hue, key_hue);
	float saturation = chroma / max(high, 0.0001);
	float strength = clamp(tolerance / 0.26, 0.0, 1.0);
	float minimum_saturation = mix(0.45, 0.12, strength);
	float hue_match = 1.0 - smoothstep(tolerance, tolerance + 0.12, hue_distance);
	float colored = smoothstep(minimum_saturation, minimum_saturation + 0.14, saturation);
	// Near-black/neutral pixels have no reliable hue; preserve them.
	float visible_color = smoothstep(0.004, 0.025, high);
	float removed = hue_match * colored * visible_color;
	// Despill: neutralize the excess key channel at visible boundaries rather
	// than leaving a green/blue/magenta tint in the soft, partially keyed edge.
	float spill = (1.0 - smoothstep(tolerance + 0.12, tolerance + 0.35, hue_distance))
		* smoothstep(0.03, 0.15, saturation) * visible_color;
	vec3 neutral_channels = vec3(1.0) - key_hue;
	float neutral = dot(c, neutral_channels) / max(dot(neutral_channels, vec3(1.0)), 0.0001);
	vec3 excess = max(c - vec3(neutral), vec3(0.0)) * key_hue;
	return vec4(c - excess * spill, sample_color.a * (1.0 - removed));
}
