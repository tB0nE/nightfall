#version 450
layout(push_constant) uniform Push {
    vec4 corner[4];
    vec4 uv_rect;
    vec4 color_scale;
    vec4 color_bias;
    uvec4 options;
} pc;
layout(location=0) out vec2 uv;
layout(location=1) out vec3 panorama_ray;
void main() {
    const int indices[6] = int[](0, 1, 2, 2, 1, 3);
    int i = indices[gl_VertexIndex];
    panorama_ray = pc.corner[i].xyz;
    // Fixed reads avoid black quads seen with dynamic gl_Position indexing on
    // RADV Polaris. Keep the exact homogeneous positions/interpolation.
    vec4 position=pc.corner[0];
    if(i==1) position=pc.corner[1];
    if(i==2) position=pc.corner[2];
    if(i==3) position=pc.corner[3];
    gl_Position = pc.options.y != 0u ? vec4((i & 1) == 0 ? -1.0 : 1.0, (i & 2) == 0 ? -1.0 : 1.0,0,1) : position;
    uv = pc.uv_rect.xy + vec2(i & 1, i >> 1) * pc.uv_rect.zw;
}
