#version 450

// PyroWave decodes to planar YCbCr 4:2:0; GLES samples the result as plain RGB
// (color_matrix_type == 3). The math must match yuv_display_core.gdshaderinc's
// planar path (yuv_mode == 3, color_range == 0, color_matrix_type == 1):
// BT.709 limited range, bilinear chroma via normalized UVs.
//
// A fragment pass rather than compute: writing the AHardwareBuffer as a colour
// attachment takes Adreno's render-target path, measured at half the cost of
// compute imageStore (0.66ms vs 1.26ms at 1440p).

layout(set = 0, binding = 0) uniform mediump sampler2D tex_y;
layout(set = 0, binding = 1) uniform mediump sampler2D tex_cb;
layout(set = 0, binding = 2) uniform mediump sampler2D tex_cr;

layout(location = 0) out mediump vec4 out_rgba;

void main()
{
	ivec2 p = ivec2(gl_FragCoord.xy);
	vec2 uv = gl_FragCoord.xy / vec2(textureSize(tex_y, 0));

	mediump float y = (texelFetch(tex_y, p, 0).r - 16.0 / 255.0) * (255.0 / 219.0);
	mediump float u = (texture(tex_cb, uv).r - 128.0 / 255.0) * (255.0 / 224.0);
	mediump float v = (texture(tex_cr, uv).r - 128.0 / 255.0) * (255.0 / 224.0);

	mediump vec3 rgb = vec3(y + 1.5748 * v, y - 0.1873 * u - 0.4681 * v, y + 1.8556 * u);
	out_rgba = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
