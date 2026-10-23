#version 450
layout(push_constant) uniform Push {
    vec4 corner[4];
    vec4 uv_rect;
    vec4 color_scale;
    vec4 color_bias;
    uvec4 options;
} pc;
layout(location=0) out vec2 uv;
void main() {
    const int indices[6] = int[](0, 1, 2, 2, 1, 3);
    int i = indices[gl_VertexIndex];
    gl_Position = pc.corner[i];
    uv = pc.uv_rect.xy + vec2(i & 1, i >> 1) * pc.uv_rect.zw;
}
