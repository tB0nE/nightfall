shader_type spatial;
render_mode unshaded;

uniform sampler2D main_texture : source_color;
// 0: 2D, 1: SBS Stretch, 2: SBS Crop
uniform int stereo_mode = 0;

void fragment() {
    vec2 uv = UV;
    
    if (stereo_mode == 0) {
        // Mode 0: Standard 2D
        ALBEDO = texture(main_texture, uv).rgb;
    } 
    else if (stereo_mode == 1) {
        // Mode 1: SBS Stretch (Half-SBS)
        if (int(VIEW_INDEX) == 0) {
            ALBEDO = texture(main_texture, vec2(uv.x * 0.5, uv.y)).rgb;
        } else {
            ALBEDO = texture(main_texture, vec2(uv.x * 0.5 + 0.5, uv.y)).rgb;
        }
    }
    else if (stereo_mode == 2) {
        // Mode 2: SBS Crop (Maintain aspect ratio by zooming)
        // Samples 0.5 width and 0.5 height from the center of each half
        if (int(VIEW_INDEX) == 0) {
            ALBEDO = texture(main_texture, vec2(uv.x * 0.5, uv.y * 0.5 + 0.25)).rgb;
        } else {
            ALBEDO = texture(main_texture, vec2(uv.x * 0.5 + 0.5, uv.y * 0.5 + 0.25)).rgb;
        }
    }
}
