#version 450
layout(set=0,binding=0) uniform sampler2D source_image;
layout(push_constant) uniform Push {
    vec4 corner[4];
    vec4 uv_rect;
    vec4 color_scale;
    vec4 color_bias;
    uvec4 options;
} pc;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 color;
void main() {
    color = texture(source_image, uv);
    if ((pc.options.x & 16u) != 0u) color = color * pc.color_scale + pc.color_bias;
    if ((pc.options.x & 2u) == 0u) color.a = 1.0;
    else if ((pc.options.x & 4u) != 0u) color.rgb *= color.a;
}
