shader_type spatial;
render_mode unshaded;

uniform sampler2D main_texture : source_color;
uniform bool stereo_enabled = false;

void fragment() {
    vec2 uv = UV;
    if (stereo_enabled) {
        // VIEW_INDEX 0 is Left Eye, 1 is Right Eye (Multiview)
        if (int(VIEW_INDEX) == 0) {
            // Sample only the left half of the SBS texture
            ALBEDO = texture(main_texture, vec2(uv.x * 0.5, uv.y)).rgb;
        } else {
            // Sample only the right half
            ALBEDO = texture(main_texture, vec2(uv.x * 0.5 + 0.5, uv.y)).rgb;
        }
    } else {
        // Standard 2D view
        ALBEDO = texture(main_texture, uv).rgb;
    }
}
