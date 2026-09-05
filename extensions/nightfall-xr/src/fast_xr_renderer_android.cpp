#ifdef __ANDROID__

#include "fast_xr_renderer.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <utility>

#include <android/log.h>
#include <GLES2/gl2ext.h>

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/xr_server.hpp>

#define XR_LOG(...) __android_log_print(ANDROID_LOG_INFO, "nightfall-xr", __VA_ARGS__)
#define XR_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "nightfall-xr", __VA_ARGS__)

#ifndef GL_FRAMEBUFFER_SRGB_EXT
#define GL_FRAMEBUFFER_SRGB_EXT 0x8DB9
#endif

using namespace godot;

// Ported near-verbatim from moonlight-android-xr's xr_renderer.c (FRAGMENT_SRC /
// UPSAMPLE_FRAGMENT_SRC / OFFSET_FRAGMENT_SRC) so the visual result and
// tuning stay identical to the reference implementation. See that file for
// the reasoning behind each pass; not repeated here.
static const char *VERTEX_SRC =
		"#version 300 es\n"
		"in vec4 a_position;\n"
		"in vec4 a_texcoord;\n"
		"out vec2 v_plain;\n"
		"void main() {\n"
		"    gl_Position = a_position;\n"
		"    v_plain = a_texcoord.xy;\n"
		"}\n";

static const char *FRAGMENT_SRC =
		"#version 300 es\n"
		"#extension GL_OES_EGL_image_external_essl3 : require\n"
		"precision highp float;\n"
		"in vec2 v_plain;\n"
		"uniform samplerExternalOES u_texture;\n"
		"uniform sampler2D u_depth;\n"
		"uniform sampler2D u_offsets;\n"
		"uniform mat4 u_texmatrix;\n"
		"uniform float u_disparity;\n"
		"uniform float u_occlusion;\n"
		"uniform float u_eyeIndex;\n"
		"uniform float u_convergence;\n"
		"uniform float u_dispTexels;\n"
		"uniform float u_lowResWidth;\n"
		"uniform float u_frameWidth;\n"
		"uniform float u_debugSolid;\n"
		"uniform int u_stereoMode;\n"
		"#ifdef NIGHTFALL_PICTURE\n"
		"uniform float u_brightness;\n"
		"uniform float u_contrast;\n"
		"uniform float u_gamma;\n"
		"vec3 applyPicture(vec3 c) {\n"
		"    c = (c - 0.5) * u_contrast + 0.5 + u_brightness;\n"
		"    return pow(max(c, vec3(0.0)), vec3(1.0 / u_gamma));\n"
		"}\n"
		"#endif\n"
		"out vec4 fragColor;\n"
		"void main() {\n"
		"    if (u_debugSolid > 0.5) { fragColor = vec4(1.0, 0.0, 1.0, 1.0); return; }\n"
		"    float d = texture(u_depth, v_plain).a;\n"
		"    vec2 tc = v_plain;\n"
		"    if (u_occlusion > 0.5) {\n"
		"        int reach = int(ceil(abs(u_dispTexels)\n"
		"                        * max(u_convergence, 1.0 - u_convergence))) + 2;\n"
		"        vec2 enc = texture(u_offsets, v_plain).rg;\n"
		"        float off = (u_eyeIndex < 0.5 ? enc.r : enc.g) - 0.5;\n"
		"        tc.x = v_plain.x + off * 2.0 * float(reach) / u_lowResWidth;\n"
		"        float h = 1.0 / u_frameWidth;\n"
		"        for (int i = 0; i < 2; i++) {\n"
		"            float d0 = texture(u_depth, vec2(tc.x, v_plain.y)).a;\n"
		"            float dm = texture(u_depth, vec2(tc.x - h, v_plain.y)).a;\n"
		"            float dp = texture(u_depth, vec2(tc.x + h, v_plain.y)).a;\n"
		"            float e = (tc.x - v_plain.x) + u_disparity * (d0 - u_convergence);\n"
		"            float slope = 1.0 + u_disparity * (dp - dm) / (2.0 * h);\n"
		"            if (abs(slope) < 0.25) {\n"
		"                slope = 0.25;\n"
		"            }\n"
		"            tc.x -= clamp(e / slope, -4.0 * h, 4.0 * h);\n"
		"        }\n"
		"    }\n"
		"    else {\n"
		"        tc.x -= u_disparity * (d - u_convergence);\n"
		"    }\n"
		// Defensive clamp (2026-09-04): the occlusion search above falls back
		// to -disparity * (depth - convergence) when it finds no root in its
		// 2-tap Newton refinement, which happens far more often when depth is
		// momentarily stale/garbage (e.g. a frame or two right after an AI-3D
		// speed/model switch, before the pipeline catches up). Because
		// disparity's sign is fixed per eye (+separation for eye 0/left,
		// -separation for eye 1/right), a bad depth value walks tc.x outside
		// [0,1] in a specific direction for one eye only - and Android's
		// external-OES sampler (u_texture below) is documented/observed to
		// return black for out-of-range UVs rather than clamping like a
		// normal 2D texture would. Reported symptom: only the left eye's
		// screen content goes solid black, right eye and the separately
		// composited cursor unaffected, while AI-3D is on; recovers instantly
		// once AI-3D is turned off. Clamping here is correct regardless of
		// the exact upstream cause of a bad tc.x/tc.y.
		"    tc = clamp(tc, 0.0, 1.0);\n"
		"    if (u_stereoMode == 1) {\n"
		"        tc.x = (u_eyeIndex < 0.5) ? tc.x * 0.5 : tc.x * 0.5 + 0.5;\n"
		"    } else if (u_stereoMode == 2) {\n"
		"        tc = (u_eyeIndex < 0.5) ? vec2(tc.x * 0.5, tc.y * 0.5 + 0.25)\n"
		"                                      : vec2(tc.x * 0.5 + 0.5, tc.y * 0.5 + 0.25);\n"
		"    }\n"
		"#ifdef NIGHTFALL_PICTURE\n"
		"    vec3 color = texture(u_texture, (u_texmatrix * vec4(tc, 0.0, 1.0)).xy).rgb;\n"
		"    fragColor = vec4(applyPicture(color), 1.0);\n"
		"#else\n"
		"    fragColor = texture(u_texture, (u_texmatrix * vec4(tc, 0.0, 1.0)).xy);\n"
		"#endif\n"
		"}\n";

// Deliberately separate from FRAGMENT_SRC. A runtime HDR branch in the SDR
// program previously increased the hot shader's compiled instruction/register
// footprint even on SDR streams. Only this program contains transfer decoding,
// gamut conversion, tonemapping, and LUT sampling.
static const char *HDR_FRAGMENT_SRC =
		"#version 300 es\n"
		"#extension GL_OES_EGL_image_external_essl3 : require\n"
		"precision highp float;\n"
		"precision highp int;\n"
		"in vec2 v_plain;\n"
		"uniform samplerExternalOES u_texture;\n"
		"uniform sampler2D u_depth;\n"
		"uniform sampler2D u_offsets;\n"
		"uniform sampler2D u_hdrLut;\n"
		"uniform mat4 u_texmatrix;\n"
		"uniform float u_disparity;\n"
		"uniform float u_occlusion;\n"
		"uniform float u_eyeIndex;\n"
		"uniform float u_convergence;\n"
		"uniform float u_dispTexels;\n"
		"uniform float u_lowResWidth;\n"
		"uniform float u_frameWidth;\n"
		"uniform float u_debugSolid;\n"
		"uniform int u_stereoMode;\n"
		"uniform int u_colorTransfer;\n"
		"uniform float u_brightness;\n"
		"uniform float u_contrast;\n"
		"uniform float u_gamma;\n"
		"out vec4 fragColor;\n"
		// Explicit interpolation makes GL_R32F filtering requirements irrelevant.
		"float hdrLutSample(float value, int row) {\n"
		"    float pos = clamp(value, 0.0, 1.0) * 255.0;\n"
		"    int x0 = int(floor(pos));\n"
		"    int x1 = min(x0 + 1, 255);\n"
		"    float f = fract(pos);\n"
		"    float a = texelFetch(u_hdrLut, ivec2(x0, row), 0).r;\n"
		"    float b = texelFetch(u_hdrLut, ivec2(x1, row), 0).r;\n"
		"    return mix(a, b, f);\n"
		"}\n"
		"vec3 bt2020ToBt709(vec3 c) {\n"
		"    return vec3(\n"
		"        1.6604910 * c.r - 0.5876411 * c.g - 0.0728499 * c.b,\n"
		"       -0.1245505 * c.r + 1.1328999 * c.g - 0.0083494 * c.b,\n"
		"       -0.0181508 * c.r - 0.1005789 * c.g + 1.1187297 * c.b);\n"
		"}\n"
		"vec3 tonemapHdrLinear(vec3 c) {\n"
		"    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));\n"
		"    if (l <= 0.0001) return c;\n"
		"    float lOut = l / (1.0 + l);\n"
		"    return c * (lOut / l);\n"
		"}\n"
		"vec3 hdrToSdr(vec3 rgb) {\n"
		"    int decodeRow = (u_colorTransfer == 1) ? 0 : 1;\n"
		"    vec3 linear = vec3(\n"
		"        hdrLutSample(rgb.r, decodeRow),\n"
		"        hdrLutSample(rgb.g, decodeRow),\n"
		"        hdrLutSample(rgb.b, decodeRow));\n"
		"    linear = tonemapHdrLinear(bt2020ToBt709(linear));\n"
		"    return vec3(\n"
		"        hdrLutSample(linear.r, 2),\n"
		"        hdrLutSample(linear.g, 2),\n"
		"        hdrLutSample(linear.b, 2));\n"
		"}\n"
		"vec3 applyPicture(vec3 c) {\n"
		"    c = (c - 0.5) * u_contrast + 0.5 + u_brightness;\n"
		"    return pow(max(c, vec3(0.0)), vec3(1.0 / u_gamma));\n"
		"}\n"
		"void main() {\n"
		"    if (u_debugSolid > 0.5) { fragColor = vec4(1.0, 0.0, 1.0, 1.0); return; }\n"
		"    float d = texture(u_depth, v_plain).a;\n"
		"    vec2 tc = v_plain;\n"
		"    if (u_occlusion > 0.5) {\n"
		"        int reach = int(ceil(abs(u_dispTexels)\n"
		"                        * max(u_convergence, 1.0 - u_convergence))) + 2;\n"
		"        vec2 enc = texture(u_offsets, v_plain).rg;\n"
		"        float off = (u_eyeIndex < 0.5 ? enc.r : enc.g) - 0.5;\n"
		"        tc.x = v_plain.x + off * 2.0 * float(reach) / u_lowResWidth;\n"
		"        float h = 1.0 / u_frameWidth;\n"
		"        for (int i = 0; i < 2; i++) {\n"
		"            float d0 = texture(u_depth, vec2(tc.x, v_plain.y)).a;\n"
		"            float dm = texture(u_depth, vec2(tc.x - h, v_plain.y)).a;\n"
		"            float dp = texture(u_depth, vec2(tc.x + h, v_plain.y)).a;\n"
		"            float e = (tc.x - v_plain.x) + u_disparity * (d0 - u_convergence);\n"
		"            float slope = 1.0 + u_disparity * (dp - dm) / (2.0 * h);\n"
		"            if (abs(slope) < 0.25) slope = 0.25;\n"
		"            tc.x -= clamp(e / slope, -4.0 * h, 4.0 * h);\n"
		"        }\n"
		"    } else {\n"
		"        tc.x -= u_disparity * (d - u_convergence);\n"
		"    }\n"
		"    tc = clamp(tc, 0.0, 1.0);\n"
		"    if (u_stereoMode == 1) {\n"
		"        tc.x = (u_eyeIndex < 0.5) ? tc.x * 0.5 : tc.x * 0.5 + 0.5;\n"
		"    } else if (u_stereoMode == 2) {\n"
		"        tc = (u_eyeIndex < 0.5) ? vec2(tc.x * 0.5, tc.y * 0.5 + 0.25)\n"
		"                                      : vec2(tc.x * 0.5 + 0.5, tc.y * 0.5 + 0.25);\n"
		"    }\n"
		"    vec3 encoded = texture(u_texture, (u_texmatrix * vec4(tc, 0.0, 1.0)).xy).rgb;\n"
		"    fragColor = vec4(applyPicture(hdrToSdr(encoded)), 1.0);\n"
		"}\n";

static float pq_decode_lut(float e) {
	constexpr float m1 = 0.1593017578125f;
	constexpr float m2 = 78.84375f;
	constexpr float c1 = 0.8359375f;
	constexpr float c2 = 18.8515625f;
	constexpr float c3 = 18.6875f;
	float ep = std::pow(e, 1.0f / m2);
	float num = std::fmax(ep - c1, 0.0f);
	float den = std::fmax(c2 - c3 * ep, 1.0e-6f);
	return std::pow(num / den, 1.0f / m1) / 0.0203f;
}

static float hlg_decode_lut(float e) {
	constexpr float a = 0.17883277f;
	constexpr float b = 1.0f - 4.0f * a;
	const float c = 0.5f - a * std::log(4.0f * a);
	float scene = e < 0.5f ? (e * e) / 3.0f : (std::exp((e - c) / a) + b) / 12.0f;
	return std::pow(std::fmax(scene, 0.0f), 1.2f) / 0.203f;
}

static float srgb_encode_lut(float c) {
	c = std::fmin(std::fmax(c, 0.0f), 1.0f);
	return c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1.0f / 2.4f) - 0.055f;
}

static const char *UPSAMPLE_FRAGMENT_SRC =
		"#version 300 es\n"
		"#extension GL_OES_EGL_image_external_essl3 : require\n"
		"precision highp float;\n"
		"in vec2 v_plain;\n"
		"uniform samplerExternalOES u_texture;\n"
		"uniform sampler2D u_depth;\n"
		"uniform sampler2D u_depthGuide;\n"
		"uniform mat4 u_texmatrix;\n"
		"uniform float u_sigmaR;\n"
		"uniform float u_sharp;\n"
		"out vec4 fragColor;\n"
		"const float SIGMA_S = 1.5;\n"
		"const float FLAT = 0.05;\n"
		"void main() {\n"
		// This grid was originally represented by one scalar N: first a
		// hardcoded 256, then the texture width. Both only work for square
		// models. Using width for Y sends rectangular maps past their last real
		// row and clamps the processed result there, so preserve both dimensions.
		"    ivec2 lowSizeI = textureSize(u_depth, 0);\n"
		"    vec2 lowSize = vec2(lowSizeI);\n"
		"    vec3 hi = texture(u_texture, (u_texmatrix * vec4(v_plain, 0.0, 1.0)).xy).rgb;\n"
		"    vec2 lp = v_plain * lowSize - 0.5;\n"
		"    ivec2 base = ivec2(floor(lp));\n"
		"    float num = 0.0;\n"
		"    float den = 0.0;\n"
		"    float dlo = 1.0;\n"
		"    float dhi = 0.0;\n"
		"    for (int dy = -2; dy <= 2; dy++) {\n"
		"        for (int dx = -2; dx <= 2; dx++) {\n"
		"            ivec2 q = clamp(base + ivec2(dx, dy), ivec2(0), lowSizeI - ivec2(1));\n"
		// u_depth (DepthEstimatorModule's raw MiDaS output, Image.FORMAT_L8) holds pure
		// depth in .r -- unlike xr_renderer.c's own depth texture, which
		// packs a colour guide into .rgb and depth into .a, ours never does,
		// so the guide comes from TextureUploader's native capture texture
		// (u_depthGuide). See fast_xr_renderer.h's
		// submit_frame() comment.
		"            float sd = texelFetch(u_depth, q, 0).r;\n"
		"            vec3 sg = texelFetch(u_depthGuide, q, 0).rgb;\n"
		"            vec2 off = vec2(q) - lp;\n"
		"            float ws = exp(-dot(off, off) / (2.0 * SIGMA_S * SIGMA_S));\n"
		"            vec3 cd = hi - sg;\n"
		"            float wr = exp(-dot(cd, cd) / (2.0 * u_sigmaR * u_sigmaR));\n"
		"            float w = ws * wr;\n"
		"            num += w * sd;\n"
		"            den += w;\n"
		"            dlo = min(dlo, sd);\n"
		"            dhi = max(dhi, sd);\n"
		"        }\n"
		"    }\n"
		"    float d = num / max(den, 1e-6);\n"
		"    float span = dhi - dlo;\n"
		"    if (u_sharp > 0.0 && span >= FLAT) {\n"
		"        float u = clamp((d - dlo) / max(span, 1e-6), 0.0, 1.0);\n"
		"        float snapped = dlo + span / (1.0 + exp(-24.0 * (u - 0.5)));\n"
		"        d = mix(d, snapped, u_sharp);\n"
		"    }\n"
		"    fragColor = vec4(d);\n"
		"}\n";

static const char *OFFSET_FRAGMENT_SRC =
		"#version 300 es\n"
		"precision highp float;\n"
		"in vec2 v_plain;\n"
		"uniform sampler2D u_depth;\n"
		"uniform float u_dispTexels;\n"
		"uniform float u_convergence;\n"
		"out vec4 fragColor;\n"
		"void main() {\n"
		"    ivec2 sz = textureSize(u_depth, 0);\n"
		"    int x = int(gl_FragCoord.x);\n"
		"    int y = int(gl_FragCoord.y);\n"
		"    int reach = int(ceil(abs(u_dispTexels)\n"
		"                    * max(u_convergence, 1.0 - u_convergence))) + 2;\n"
		"    vec2 result = vec2(0.0);\n"
		"    for (int eye = 0; eye < 2; eye++) {\n"
		"        float disp = (eye == 0) ? u_dispTexels : -u_dispTexels;\n"
		"        float here = texelFetch(u_depth, ivec2(x, y), 0).a;\n"
		"        float bestD = -1.0;\n"
		"        float bestOff = -disp * (here - u_convergence);\n"
		"        float pd = texelFetch(u_depth,\n"
		"                ivec2(clamp(x - reach, 0, sz.x - 1), y), 0).a;\n"
		"        float pe = float(-reach) + disp * (pd - u_convergence);\n"
		"        for (int t = -reach + 1; t <= reach; t++) {\n"
		"            float cd = texelFetch(u_depth,\n"
		"                    ivec2(clamp(x + t, 0, sz.x - 1), y), 0).a;\n"
		"            float ce = float(t) + disp * (cd - u_convergence);\n"
		"            float span = ce - pe;\n"
		"            if (pe * ce <= 0.0 && abs(span) > 1e-6) {\n"
		"                float f = clamp(-pe / span, 0.0, 1.0);\n"
		"                float rd = pd + f * (cd - pd);\n"
		"                if (rd > bestD) {\n"
		"                    bestD = rd;\n"
		"                    bestOff = float(t - 1) + f;\n"
		"                }\n"
		"            }\n"
		"            pd = cd;\n"
		"            pe = ce;\n"
		"        }\n"
		"        result[eye] = bestOff;\n"
		"    }\n"
		"    fragColor = vec4(result / (2.0 * float(reach)) + 0.5, 0.0, 1.0);\n"
		"}\n";

static const float VERTEX_DATA[] = {
	-1.0f, -1.0f, 0.0f, 0.0f,
	1.0f, -1.0f, 1.0f, 0.0f,
	-1.0f, 1.0f, 0.0f, 1.0f,
	1.0f, 1.0f, 1.0f, 1.0f
};

#define OVERLAY_WIDTH 768
#define OVERLAY_HEIGHT 512
#define UPSAMPLE_DIVISOR 4
// Screen center height in the play/stage space, matching main.gd's own
// hardcoded assumption for the stats overlay quad and XRCamera3D's fallback
// seated height (both 1.6m) -- quad_layers[] left this at the pose default
// (y=0, i.e. floor height), which put the video well below where the stats
// overlay and camera default assume the screen actually is.
#define SCREEN_CENTER_Y 1.6f

static bool check_xr(XrResult p_res, const char *p_what) {
	if (XR_FAILED(p_res)) {
		XR_LOGE("%s failed: %d", p_what, p_res);
		return false;
	}
	return true;
}

static GLuint compile_shader(GLenum p_type, const char *p_src, const char *p_defines = nullptr) {
	GLuint shader = glCreateShader(p_type);
	if (p_defines != nullptr) {
		// GLSL requires #version to be the first directive. Insert optional
		// compile-time variants immediately after its first line so the neutral
		// SDR program completely preprocesses Picture grading out of existence.
		const char *body = strchr(p_src, '\n');
		if (body != nullptr) {
			body++;
			const char *sources[] = { p_src, p_defines, body };
			GLint lengths[] = { static_cast<GLint>(body - p_src), -1, -1 };
			glShaderSource(shader, 3, sources, lengths);
		} else {
			glShaderSource(shader, 1, &p_src, nullptr);
		}
	} else {
		glShaderSource(shader, 1, &p_src, nullptr);
	}
	glCompileShader(shader);
	GLint ok = 0;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512];
		glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
		XR_LOGE("shader compile failed: %s", log);
		glDeleteShader(shader);
		return 0;
	}
	return shader;
}

static GLuint link_program(const char *p_fragment_src, const char *p_fragment_defines = nullptr) {
	GLuint vs = compile_shader(GL_VERTEX_SHADER, VERTEX_SRC);
	GLuint fs = compile_shader(GL_FRAGMENT_SHADER, p_fragment_src, p_fragment_defines);
	if (vs == 0 || fs == 0) {
		return 0;
	}
	GLuint program = glCreateProgram();
	glAttachShader(program, vs);
	glAttachShader(program, fs);
	glBindAttribLocation(program, 0, "a_position");
	glBindAttribLocation(program, 1, "a_texcoord");
	glLinkProgram(program);
	glDeleteShader(vs);
	glDeleteShader(fs);
	GLint linked = 0;
	glGetProgramiv(program, GL_LINK_STATUS, &linked);
	if (!linked) {
		char log[512];
		glGetProgramInfoLog(program, sizeof(log), nullptr, log);
		XR_LOGE("program link failed: %s", log);
		return 0;
	}
	return program;
}

// get_instance_proc_addr() routes through Godot's own already-resolved
// xrGetInstanceProcAddr (see modules/openxr/openxr_api_extension.cpp) rather
// than us dlopen-ing the loader ourselves: it's the same underlying resolver
// Godot's own OpenXR module uses, so there's no question of a second,
// independently-dispatched loader copy missing the entry for Godot's already-
// created XrInstance.
bool NightfallXrRenderer::resolve_functions() {
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null()) {
		XR_LOGE("get_openxr_api() returned null");
		return false;
	}

#define RESOLVE(name)                                                                       \
	pfn_##name = (PFN_##name)(void *)api->get_instance_proc_addr(String(#name));            \
	if (pfn_##name == nullptr) {                                                             \
		XR_LOGE("get_instance_proc_addr(%s) failed", #name);                                 \
		return false;                                                                          \
	}

	RESOLVE(xrEnumerateInstanceExtensionProperties);
	RESOLVE(xrEnumerateSwapchainFormats);
	RESOLVE(xrCreateSwapchain);
	RESOLVE(xrDestroySwapchain);
	RESOLVE(xrEnumerateSwapchainImages);
	RESOLVE(xrAcquireSwapchainImage);
	RESOLVE(xrWaitSwapchainImage);
	RESOLVE(xrReleaseSwapchainImage);
#undef RESOLVE
	return true;
}

bool NightfallXrRenderer::register_provider() {
	if (registered_as_layer_provider) {
		return true;
	}
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null()) {
		XR_LOGE("register_provider() failed: get_openxr_api() returned null");
		return false;
	}
	xr_instance = (XrInstance)api->get_instance();
	xr_session = (XrSession)api->get_session();
	xr_system_id = (XrSystemId)api->get_system_id();
	xr_space = (XrSpace)api->get_play_space();

	if (xr_instance == XR_NULL_HANDLE || xr_session == XR_NULL_HANDLE) {
		XR_LOGE("register_provider() called with null OpenXR handles; is OpenXRInterface initialized?");
		return false;
	}

	if (!resolve_functions()) {
		return false;
	}

	uint32_t ext_count = 0;
	pfn_xrEnumerateInstanceExtensionProperties(nullptr, 0, &ext_count, nullptr);
	if (ext_count > 0) {
		XrExtensionProperties *exts = (XrExtensionProperties *)calloc(ext_count, sizeof(XrExtensionProperties));
		for (uint32_t i = 0; i < ext_count; i++) {
			exts[i].type = XR_TYPE_EXTENSION_PROPERTIES;
		}
		pfn_xrEnumerateInstanceExtensionProperties(nullptr, ext_count, &ext_count, exts);
		for (uint32_t i = 0; i < ext_count; i++) {
			if (strcmp(exts[i].extensionName, XR_KHR_COMPOSITION_LAYER_CYLINDER_EXTENSION_NAME) == 0) {
				cylinder_supported = true;
			}
		}
		::free(exts);
	}

	api->register_composition_layer_provider(this);
	registered_as_layer_provider = true;
	XR_LOG("nightfall-xr registered as composition layer provider (cylinder=%d)", cylinder_supported);
	return true;
}

bool NightfallXrRenderer::start(int p_video_width, int p_video_height) {
	if (!registered_as_layer_provider) {
		XR_LOGE("start() called before register_provider() succeeded");
		return false;
	}
	if (swapchain != XR_NULL_HANDLE) {
		if (video_width == p_video_width && video_height == p_video_height) {
			return true;
		}
		stop_stream();
	}
	video_width = p_video_width;
	video_height = p_video_height;
	// Reserve a tiny fixed border without adding bezel logic to the hot warp
	// shader. With bezel off, the draw simply covers the reserved pixels too.
	output_width = video_width + 16;
	output_height = video_height + 16;

	if (!init_egl() || !init_swapchain() || !init_gl()) {
		stop_stream();
		return false;
	}

	// init_egl()/init_swapchain()/init_gl() ran with our own context current
	// (needed to create our GL objects); hand Godot's context/surfaces back
	// before returning, since this runs on Godot's own render thread.
	eglMakeCurrent(egl_display, godot_draw_surface, godot_read_surface, godot_context);

	XR_LOG("nightfall-xr swapchain started %dx%d", video_width, video_height);
	return true;
}

// A second EGL context in Godot's share group, current on its own pbuffer.
// The frame loop cannot render on Godot's own context/thread without
// fighting Godot's render loop for it, but textures created by Godot (the
// decoder's OES texture, the depth texture) only resolve here because the
// share group is shared, not because the context is.
bool NightfallXrRenderer::init_egl() {
	egl_display = eglGetCurrentDisplay();
	if (egl_display == EGL_NO_DISPLAY) {
		XR_LOGE("eglGetCurrentDisplay failed; must call start() from Godot's GL render thread");
		return false;
	}
	godot_context = eglGetCurrentContext();
	if (godot_context == EGL_NO_CONTEXT) {
		XR_LOGE("no current EGL context on this thread");
		return false;
	}
	// Godot's own render loop (and hence every callback it drives, including
	// _get_composition_layer_count()) runs on this same thread and assumes
	// its own context stays current between its calls into us. Every place
	// below that makes our own context current must restore these before
	// returning control to Godot, or Godot's subsequent GL calls silently
	// operate on our context/surfaces instead of its own -- this is what was
	// actually breaking the whole render loop, not a composition-layer or
	// registration bug.
	godot_draw_surface = eglGetCurrentSurface(EGL_DRAW);
	godot_read_surface = eglGetCurrentSurface(EGL_READ);

	EGLint config_id = 0;
	eglQueryContext(egl_display, godot_context, EGL_CONFIG_ID, &config_id);
	const EGLint config_attribs[] = { EGL_CONFIG_ID, config_id, EGL_NONE };
	EGLint num_configs = 0;
	if (!eglChooseConfig(egl_display, config_attribs, &egl_config_placeholder, 1, &num_configs) || num_configs < 1) {
		XR_LOGE("eglChooseConfig (matching Godot's config) failed");
		return false;
	}

	const EGLint context_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	egl_context = eglCreateContext(egl_display, egl_config_placeholder, godot_context, context_attribs);
	if (egl_context == EGL_NO_CONTEXT) {
		XR_LOGE("eglCreateContext (shared) failed: %d", eglGetError());
		return false;
	}

	const EGLint pbuffer_attribs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
	egl_pbuffer = eglCreatePbufferSurface(egl_display, egl_config_placeholder, pbuffer_attribs);
	if (egl_pbuffer == EGL_NO_SURFACE) {
		XR_LOGE("eglCreatePbufferSurface failed: %d", eglGetError());
		return false;
	}

	if (!eglMakeCurrent(egl_display, egl_pbuffer, egl_pbuffer, egl_context)) {
		XR_LOGE("eglMakeCurrent failed: %d", eglGetError());
		return false;
	}
	return true;
}

bool NightfallXrRenderer::init_swapchain() {
	uint32_t format_count = 0;
	pfn_xrEnumerateSwapchainFormats(xr_session, 0, &format_count, nullptr);
	int64_t *formats = (int64_t *)calloc(format_count, sizeof(int64_t));
	pfn_xrEnumerateSwapchainFormats(xr_session, format_count, &format_count, formats);

	swapchain_format = 0;
	for (uint32_t i = 0; i < format_count; i++) {
		if (formats[i] == GL_SRGB8_ALPHA8) {
			swapchain_format = GL_SRGB8_ALPHA8;
			break;
		}
	}
	if (swapchain_format == 0 && format_count > 0) {
		swapchain_format = formats[0];
	}
	::free(formats);

	// Double-wide: both eyes render into one swapchain, split by
	// XrSwapchainSubImage.imageRect.offset.x in end_frame(). This is the
	// entire point of bypassing Godot's per-eye viewport layers.
	XrSwapchainCreateInfo swap_info = { XR_TYPE_SWAPCHAIN_CREATE_INFO };
	swap_info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
	swap_info.format = swapchain_format;
	swap_info.sampleCount = 1;
	swap_info.width = output_width * 2;
	swap_info.height = output_height;
	swap_info.faceCount = 1;
	swap_info.arraySize = 1;
	swap_info.mipCount = 1;
	if (!check_xr(pfn_xrCreateSwapchain(xr_session, &swap_info, &swapchain), "xrCreateSwapchain")) {
		return false;
	}

	pfn_xrEnumerateSwapchainImages(swapchain, 0, &swapchain_image_count, nullptr);
	swapchain_images = (XrSwapchainImageOpenGLESKHR *)calloc(swapchain_image_count, sizeof(XrSwapchainImageOpenGLESKHR));
	for (uint32_t i = 0; i < swapchain_image_count; i++) {
		swapchain_images[i].type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR;
	}
	if (!check_xr(pfn_xrEnumerateSwapchainImages(swapchain, swapchain_image_count, &swapchain_image_count, (XrSwapchainImageBaseHeader *)swapchain_images), "enumerate swapchain images")) {
		return false;
	}

	XrSwapchainCreateInfo overlay_info = swap_info;
	overlay_info.width = OVERLAY_WIDTH;
	overlay_info.height = OVERLAY_HEIGHT;
	if (check_xr(pfn_xrCreateSwapchain(xr_session, &overlay_info, &overlay_swapchain), "create overlay swapchain")) {
		pfn_xrEnumerateSwapchainImages(overlay_swapchain, 0, &overlay_image_count, nullptr);
		overlay_images = (XrSwapchainImageOpenGLESKHR *)calloc(overlay_image_count, sizeof(XrSwapchainImageOpenGLESKHR));
		for (uint32_t i = 0; i < overlay_image_count; i++) {
			overlay_images[i].type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR;
		}
		pfn_xrEnumerateSwapchainImages(overlay_swapchain, overlay_image_count, &overlay_image_count, (XrSwapchainImageBaseHeader *)overlay_images);
	} else {
		overlay_swapchain = XR_NULL_HANDLE;
	}

	return true;
}

bool NightfallXrRenderer::init_gl() {
	auto configure_warp_uniforms = [](GLuint program, WarpUniforms &uniforms, bool hdr, bool picture) {
		uniforms.texmatrix = glGetUniformLocation(program, "u_texmatrix");
		uniforms.disparity = glGetUniformLocation(program, "u_disparity");
		uniforms.occlusion = glGetUniformLocation(program, "u_occlusion");
		uniforms.eye_index = glGetUniformLocation(program, "u_eyeIndex");
		uniforms.convergence = glGetUniformLocation(program, "u_convergence");
		uniforms.disp_texels = glGetUniformLocation(program, "u_dispTexels");
		uniforms.low_res_width = glGetUniformLocation(program, "u_lowResWidth");
		uniforms.frame_width = glGetUniformLocation(program, "u_frameWidth");
		uniforms.debug_solid = glGetUniformLocation(program, "u_debugSolid");
		uniforms.stereo_mode = glGetUniformLocation(program, "u_stereoMode");
		glUseProgram(program);
		glUniform1i(glGetUniformLocation(program, "u_texture"), 0);
		glUniform1i(glGetUniformLocation(program, "u_depth"), 1);
		glUniform1i(glGetUniformLocation(program, "u_offsets"), 2);
		if (hdr) {
			uniforms.color_transfer = glGetUniformLocation(program, "u_colorTransfer");
			uniforms.hdr_lut = glGetUniformLocation(program, "u_hdrLut");
			glUniform1i(uniforms.hdr_lut, 3);
		}
		if (picture) {
			uniforms.brightness = glGetUniformLocation(program, "u_brightness");
			uniforms.contrast = glGetUniformLocation(program, "u_contrast");
			uniforms.gamma = glGetUniformLocation(program, "u_gamma");
		}
	};

	warp_program = link_program(FRAGMENT_SRC);
	if (warp_program == 0) {
		return false;
	}
	configure_warp_uniforms(warp_program, warp_uniforms, false, false);

	picture_warp_program = link_program(FRAGMENT_SRC, "#define NIGHTFALL_PICTURE 1\n");
	if (picture_warp_program == 0) {
		XR_LOGE("Failed to compile native Picture warp program");
		return false;
	}
	configure_warp_uniforms(picture_warp_program, picture_warp_uniforms, false, true);

	hdr_warp_program = link_program(HDR_FRAGMENT_SRC);
	if (hdr_warp_program == 0) {
		XR_LOGE("Failed to compile native HDR warp program");
		return false;
	}
	configure_warp_uniforms(hdr_warp_program, hdr_warp_uniforms, true, true);

	float hdr_lut_data[256 * 3];
	for (int x = 0; x < 256; x++) {
		float e = static_cast<float>(x) / 255.0f;
		hdr_lut_data[x] = pq_decode_lut(e);
		hdr_lut_data[256 + x] = hlg_decode_lut(e);
		hdr_lut_data[512 + x] = srgb_encode_lut(e);
	}
	// Discard a bounded number of earlier optional-driver state errors before
	// validating the LUT. Do not spin forever if a lost context reports a
	// persistent error.
	for (int i = 0; i < 8 && glGetError() != GL_NO_ERROR; i++) {
	}
	glGenTextures(1, &hdr_lut_texture);
	glBindTexture(GL_TEXTURE_2D, hdr_lut_texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, 256, 3, 0, GL_RED, GL_FLOAT, hdr_lut_data);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	GLenum lut_error = glGetError();
	if (hdr_lut_texture == 0 || lut_error != GL_NO_ERROR) {
		XR_LOGE("Failed to create native HDR LUT texture (GL error=0x%x)", lut_error);
		return false;
	}
	XR_LOG("Native HDR warp program and 256x3 LUT ready");

	upsample_program = link_program(UPSAMPLE_FRAGMENT_SRC);
	if (upsample_program == 0) {
		return false;
	}
	u_upsample_texmatrix = glGetUniformLocation(upsample_program, "u_texmatrix");
	u_upsample_sigma = glGetUniformLocation(upsample_program, "u_sigmaR");
	u_upsample_sharp = glGetUniformLocation(upsample_program, "u_sharp");
	u_upsample_depth_guide = glGetUniformLocation(upsample_program, "u_depthGuide");
	glUseProgram(upsample_program);
	glUniform1i(glGetUniformLocation(upsample_program, "u_texture"), 0);
	glUniform1i(glGetUniformLocation(upsample_program, "u_depth"), 1);
	glUniform1i(u_upsample_depth_guide, 2);

	offset_program = link_program(OFFSET_FRAGMENT_SRC);
	if (offset_program == 0) {
		return false;
	}
	u_offset_disp = glGetUniformLocation(offset_program, "u_dispTexels");
	u_offset_conv = glGetUniformLocation(offset_program, "u_convergence");
	glUseProgram(offset_program);
	glUniform1i(glGetUniformLocation(offset_program, "u_depth"), 0);

	upsample_width = video_width / UPSAMPLE_DIVISOR;
	upsample_height = video_height / UPSAMPLE_DIVISOR;
	glGenTextures(1, &upsample_texture);
	glBindTexture(GL_TEXTURE_2D, upsample_texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, upsample_width, upsample_height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glGenFramebuffers(1, &upsample_fbo);

	glGenTextures(1, &offset_texture);
	glBindTexture(GL_TEXTURE_2D, offset_texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, upsample_width, upsample_height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glGenFramebuffers(1, &offset_fbo);

	glGenFramebuffers(1, &warp_fbo);

	// Ambient lighting consumes only this 32x32 copy of the already-rendered
	// native image. The PBO ring keeps its readback off the critical draw path:
	// we map a buffer only after its fence reports completion on a later frame.
	glGenTextures(1, &ambient_sample_texture);
	glBindTexture(GL_TEXTURE_2D, ambient_sample_texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, AMBIENT_SAMPLE_WIDTH,
			AMBIENT_SAMPLE_HEIGHT, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glGenFramebuffers(1, &ambient_sample_fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, ambient_sample_fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
			ambient_sample_texture, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		XR_LOGE("Failed to create native ambient sample framebuffer");
		glBindFramebuffer(GL_FRAMEBUFFER, 0);
		return false;
	}
	glGenBuffers(AMBIENT_SAMPLE_PBO_COUNT, ambient_sample_pbos);
	for (int i = 0; i < AMBIENT_SAMPLE_PBO_COUNT; i++) {
		glBindBuffer(GL_PIXEL_PACK_BUFFER, ambient_sample_pbos[i]);
		glBufferData(GL_PIXEL_PACK_BUFFER,
				AMBIENT_SAMPLE_WIDTH * AMBIENT_SAMPLE_HEIGHT * 4,
				nullptr, GL_STREAM_READ);
	}
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);

	const char *gl_exts = (const char *)glGetString(GL_EXTENSIONS);
	srgb_write_control = gl_exts != nullptr && strstr(gl_exts, "GL_EXT_sRGB_write_control") != nullptr;

	return true;
}

void NightfallXrRenderer::stop_stream() {
	pending_new_frame = false;
	ever_rendered = false;
	ambient_sample_requested.store(false, std::memory_order_release);
	{
		std::lock_guard<std::mutex> lock(ambient_sample_result_mutex);
		ambient_sample_result.clear();
		ambient_sample_result_ready = false;
	}
	pending_color_transfer_type = 0;
	rendered_color_transfer_type = -1;
	pending_brightness = 0.0f;
	pending_contrast = 1.0f;
	pending_gamma = 1.0f;
	depth_cache_valid = false;
	rendered_depth_revision = UINT64_MAX;
	rendered_depth_separation = -1.0f;
	rendered_depth_convergence = -1.0f;
	layer_frame_counter = 0;
	eye_last_queried_frame[0] = 0;
	eye_last_queried_frame[1] = 0;
	if (swapchain != XR_NULL_HANDLE) {
		pfn_xrDestroySwapchain(swapchain);
		swapchain = XR_NULL_HANDLE;
	}
	::free(swapchain_images);
	swapchain_images = nullptr;
	if (overlay_swapchain != XR_NULL_HANDLE) {
		pfn_xrDestroySwapchain(overlay_swapchain);
		overlay_swapchain = XR_NULL_HANDLE;
	}
	::free(overlay_images);
	overlay_images = nullptr;
	overlay_has_content = false;
	overlay_visible = false;

	// xr_instance/xr_session/xr_space are Godot's, never destroyed here.

	if (egl_display != EGL_NO_DISPLAY) {
		EGLContext restore_context = eglGetCurrentContext();
		EGLSurface restore_draw = eglGetCurrentSurface(EGL_DRAW);
		EGLSurface restore_read = eglGetCurrentSurface(EGL_READ);
		if (egl_context != EGL_NO_CONTEXT && egl_pbuffer != EGL_NO_SURFACE) {
			eglMakeCurrent(egl_display, egl_pbuffer, egl_pbuffer, egl_context);
			for (int i = 0; i < AMBIENT_SAMPLE_PBO_COUNT; i++) {
				if (ambient_sample_fences[i] != nullptr) {
					glDeleteSync(ambient_sample_fences[i]);
					ambient_sample_fences[i] = nullptr;
				}
			}
			if (pending_oes_fence != 0) {
				glDeleteSync(reinterpret_cast<GLsync>(pending_oes_fence));
				pending_oes_fence = 0;
			}
			for (uint64_t fence : superseded_oes_fences) {
				glDeleteSync(reinterpret_cast<GLsync>(fence));
			}
			superseded_oes_fences.clear();
			if (warp_fbo) glDeleteFramebuffers(1, &warp_fbo);
			if (ambient_sample_fbo) glDeleteFramebuffers(1, &ambient_sample_fbo);
			if (upsample_fbo) glDeleteFramebuffers(1, &upsample_fbo);
			if (offset_fbo) glDeleteFramebuffers(1, &offset_fbo);
			if (ambient_sample_pbos[0] || ambient_sample_pbos[1]) {
				glDeleteBuffers(AMBIENT_SAMPLE_PBO_COUNT, ambient_sample_pbos);
			}
			if (ambient_sample_texture) glDeleteTextures(1, &ambient_sample_texture);
			if (upsample_texture) glDeleteTextures(1, &upsample_texture);
			if (offset_texture) glDeleteTextures(1, &offset_texture);
			if (hdr_lut_texture) glDeleteTextures(1, &hdr_lut_texture);
			if (warp_program) glDeleteProgram(warp_program);
			if (picture_warp_program) glDeleteProgram(picture_warp_program);
			if (hdr_warp_program) glDeleteProgram(hdr_warp_program);
			if (upsample_program) glDeleteProgram(upsample_program);
			if (offset_program) glDeleteProgram(offset_program);
		}
		warp_fbo = ambient_sample_fbo = upsample_fbo = offset_fbo = 0;
		ambient_sample_pbos[0] = ambient_sample_pbos[1] = 0;
		ambient_sample_next_pbo = 0;
		ambient_sample_texture = upsample_texture = offset_texture = hdr_lut_texture = 0;
		warp_program = picture_warp_program = hdr_warp_program = upsample_program = offset_program = 0;
		eglMakeCurrent(egl_display, restore_draw, restore_read, restore_context);
		if (egl_pbuffer != EGL_NO_SURFACE) {
			eglDestroySurface(egl_display, egl_pbuffer);
			egl_pbuffer = EGL_NO_SURFACE;
		}
		if (egl_context != EGL_NO_CONTEXT) {
			eglDestroyContext(egl_display, egl_context);
			egl_context = EGL_NO_CONTEXT;
		}
	}
	egl_display = EGL_NO_DISPLAY;
}

void NightfallXrRenderer::shutdown() {
	stop_stream();
	if (registered_as_layer_provider) {
		Ref<OpenXRAPIExtension> api = get_openxr_api();
		if (api.is_valid()) {
			api->unregister_composition_layer_provider(this);
		}
		registered_as_layer_provider = false;
	}
}

void NightfallXrRenderer::stop() {
	shutdown();
}

void NightfallXrRenderer::request_ambient_sample() {
	if (swapchain != XR_NULL_HANDLE) {
		ambient_sample_requested.store(true, std::memory_order_release);
	}
}

PackedByteArray NightfallXrRenderer::consume_ambient_sample() {
	PackedByteArray result;
	std::lock_guard<std::mutex> lock(ambient_sample_result_mutex);
	if (!ambient_sample_result_ready) {
		return result;
	}
	result.resize(static_cast<int64_t>(ambient_sample_result.size()));
	if (!ambient_sample_result.empty()) {
		memcpy(result.ptrw(), ambient_sample_result.data(), ambient_sample_result.size());
	}
	ambient_sample_result_ready = false;
	return result;
}

bool NightfallXrRenderer::is_started() const {
	return swapchain != XR_NULL_HANDLE;
}

bool NightfallXrRenderer::has_rendered_frame() const {
	return ever_rendered;
}

bool NightfallXrRenderer::has_stale_eye_layer() const {
	// Require enough history that both eyes have plausibly been queried at
	// least once (avoids a false positive during the first few frames after
	// start(), before layer_frame_counter has run past the threshold).
	if (layer_frame_counter < STALE_EYE_FRAME_THRESHOLD) {
		return false;
	}
	for (int eye = 0; eye < 2; eye++) {
		if (eye_last_queried_frame[eye] == 0) {
			// Never queried yet -- startup, not a stall.
			continue;
		}
		if (layer_frame_counter - eye_last_queried_frame[eye] > STALE_EYE_FRAME_THRESHOLD) {
			return true;
		}
	}
	return false;
}

bool NightfallXrRenderer::supports_cylinder() const {
	return cylinder_supported;
}

void NightfallXrRenderer::set_geometry(const Transform3D &p_transform, float p_width, float p_height,
		int p_curvature, float p_radius, float p_central_angle, int p_sort_order,
		bool p_bezel_enabled) {
	pending_transform = p_transform;
	pending_width = p_width;
	pending_height = p_height;
	pending_curvature = p_curvature;
	pending_radius = p_radius;
	pending_central_angle = p_central_angle;
	pending_sort_order = p_sort_order;
	pending_bezel_enabled = p_bezel_enabled;
}

void NightfallXrRenderer::run_upsample(uint32_t p_oes_texture_id, uint32_t p_depth_texture_id,
		uint32_t p_depth_guide_texture_id, const float *p_tex_matrix) {
	glBindFramebuffer(GL_FRAMEBUFFER, upsample_fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, upsample_texture, 0);
	glViewport(0, 0, upsample_width, upsample_height);
	glUseProgram(upsample_program);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_EXTERNAL_OES, p_oes_texture_id);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, p_depth_texture_id);
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, p_depth_guide_texture_id);
	glUniformMatrix4fv(u_upsample_texmatrix, 1, GL_FALSE, p_tex_matrix);
	glUniform1f(u_upsample_sigma, 0.25f);
	glUniform1f(u_upsample_sharp, 0.0f);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, VERTEX_DATA);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, VERTEX_DATA + 2);
	glEnableVertexAttribArray(1);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void NightfallXrRenderer::run_offset_search(float p_separation, float p_convergence) {
	glBindFramebuffer(GL_FRAMEBUFFER, offset_fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, offset_texture, 0);
	glViewport(0, 0, upsample_width, upsample_height);
	glUseProgram(offset_program);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, upsample_texture);
	glUniform1f(u_offset_disp, p_separation * upsample_width);
	glUniform1f(u_offset_conv, p_convergence);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, VERTEX_DATA);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, VERTEX_DATA + 2);
	glEnableVertexAttribArray(1);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void NightfallXrRenderer::poll_ambient_sample() {
	const size_t byte_count = AMBIENT_SAMPLE_WIDTH * AMBIENT_SAMPLE_HEIGHT * 4;
	for (int i = 0; i < AMBIENT_SAMPLE_PBO_COUNT; i++) {
		if (ambient_sample_fences[i] == nullptr) {
			continue;
		}
		GLenum status = glClientWaitSync(ambient_sample_fences[i], 0, 0);
		if (status == GL_WAIT_FAILED) {
			XR_LOGE("Native ambient readback fence wait failed: 0x%x", glGetError());
			glDeleteSync(ambient_sample_fences[i]);
			ambient_sample_fences[i] = nullptr;
			continue;
		}
		if (status != GL_ALREADY_SIGNALED && status != GL_CONDITION_SATISFIED) {
			continue;
		}
		glBindBuffer(GL_PIXEL_PACK_BUFFER, ambient_sample_pbos[i]);
		void *mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, byte_count, GL_MAP_READ_BIT);
		if (mapped != nullptr) {
			std::vector<uint8_t> sample(byte_count);
			memcpy(sample.data(), mapped, byte_count);
			glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
			std::lock_guard<std::mutex> lock(ambient_sample_result_mutex);
			ambient_sample_result = std::move(sample);
			ambient_sample_result_ready = true;
		}
		glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
		glDeleteSync(ambient_sample_fences[i]);
		ambient_sample_fences[i] = nullptr;
	}
}

bool NightfallXrRenderer::issue_ambient_sample() {
	int slot = -1;
	for (int offset = 0; offset < AMBIENT_SAMPLE_PBO_COUNT; offset++) {
		int candidate = (ambient_sample_next_pbo + offset) % AMBIENT_SAMPLE_PBO_COUNT;
		if (ambient_sample_fences[candidate] == nullptr) {
			slot = candidate;
			break;
		}
	}
	if (slot < 0) {
		return false;
	}

	// Exclude the fixed 8px native bezel so it cannot tint the edge sample.
	const int inset = pending_bezel_enabled ? 8 : 0;
	glBindFramebuffer(GL_READ_FRAMEBUFFER, warp_fbo);
	glReadBuffer(GL_COLOR_ATTACHMENT0);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, ambient_sample_fbo);
	glBlitFramebuffer(inset, inset, output_width - inset, output_height - inset,
			0, 0, AMBIENT_SAMPLE_WIDTH, AMBIENT_SAMPLE_HEIGHT,
			GL_COLOR_BUFFER_BIT, GL_LINEAR);

	glBindFramebuffer(GL_FRAMEBUFFER, ambient_sample_fbo);
	glReadBuffer(GL_COLOR_ATTACHMENT0);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, ambient_sample_pbos[slot]);
	glReadPixels(0, 0, AMBIENT_SAMPLE_WIDTH, AMBIENT_SAMPLE_HEIGHT,
			GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	ambient_sample_fences[slot] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	ambient_sample_next_pbo = (slot + 1) % AMBIENT_SAMPLE_PBO_COUNT;
	return ambient_sample_fences[slot] != nullptr;
}

void NightfallXrRenderer::render_video_frame(uint32_t p_oes_texture_id, uint32_t p_depth_texture_id,
		uint32_t p_depth_guide_texture_id, const float *p_tex_matrix, float p_separation,
		float p_convergence, bool p_occluding) {
	// Must run first, with egl_context already current (true here) and
	// before any sampling of p_oes_texture_id (run_upsample() below samples
	// it too): waits for TextureUploader's updateTexImage() write -- on
	// Godot's context -- to actually complete before we read the texture
	// from this, a different context. GPU-side wait, returns immediately on
	// the CPU.
	if (pending_oes_fence != 0) {
	#ifdef NIGHTFALL_DEBUG
		static int fence_waits_logged = 0;
		if (fence_waits_logged < 5) {
			fence_waits_logged++;
			XR_LOG("DEBUG waiting on OES ready fence %llu (count=%d)", (unsigned long long)pending_oes_fence, fence_waits_logged);
		}
	#endif
		glWaitSync(reinterpret_cast<GLsync>(pending_oes_fence), 0, GL_TIMEOUT_IGNORED);
		glDeleteSync(reinterpret_cast<GLsync>(pending_oes_fence));
		pending_oes_fence = 0;
	}
	poll_ambient_sample();

	bool has_depth = p_depth_texture_id != 0 && p_depth_guide_texture_id != 0;
	bool refresh_depth = has_depth && (!depth_cache_valid || pending_depth_revision != rendered_depth_revision);
	if (refresh_depth) {
		run_upsample(p_oes_texture_id, p_depth_texture_id, p_depth_guide_texture_id, p_tex_matrix);
		depth_cache_valid = true;
		rendered_depth_revision = pending_depth_revision;
	}
	bool upsampling = has_depth && depth_cache_valid;
	if (upsampling && p_occluding && (refresh_depth || p_separation != rendered_depth_separation ||
			p_convergence != rendered_depth_convergence)) {
		run_offset_search(p_separation, p_convergence);
		rendered_depth_separation = p_separation;
		rendered_depth_convergence = p_convergence;
	}

	uint32_t image_index = 0;
	XrSwapchainImageAcquireInfo acquire_info = { XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
	if (!check_xr(pfn_xrAcquireSwapchainImage(swapchain, &acquire_info, &image_index), "acquire image")) {
		return;
	}
	XrSwapchainImageWaitInfo wait_info = { XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
	wait_info.timeout = XR_INFINITE_DURATION;
	pfn_xrWaitSwapchainImage(swapchain, &wait_info);

	glBindFramebuffer(GL_FRAMEBUFFER, warp_fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, swapchain_images[image_index].image, 0);
	if (srgb_write_control) {
		glDisable(GL_FRAMEBUFFER_SRGB_EXT);
	}

	bool use_hdr = pending_color_transfer_type == 1 || pending_color_transfer_type == 2;
	bool use_picture = std::fabs(pending_brightness) > 0.0001f ||
			std::fabs(pending_contrast - 1.0f) > 0.0001f ||
			std::fabs(pending_gamma - 1.0f) > 0.0001f;
	GLuint active_warp_program = use_hdr ? hdr_warp_program
			: (use_picture ? picture_warp_program : warp_program);
	WarpUniforms &uniforms = use_hdr ? hdr_warp_uniforms
			: (use_picture ? picture_warp_uniforms : warp_uniforms);
	glUseProgram(active_warp_program);
	if (rendered_color_transfer_type != pending_color_transfer_type) {
		const char *transfer_name = pending_color_transfer_type == 1 ? "PQ"
				: (pending_color_transfer_type == 2 ? "HLG" : "SDR");
		XR_LOG("Video transfer changed: %s; native %s warp program active",
				transfer_name, use_hdr ? "HDR" : "SDR");
		rendered_color_transfer_type = pending_color_transfer_type;
	}
	if (pending_bezel_enabled) {
		glViewport(0, 0, output_width * 2, output_height);
		glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
	}
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_EXTERNAL_OES, p_oes_texture_id);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, upsampling ? upsample_texture : p_depth_texture_id);
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, offset_texture);
	if (use_hdr) {
		glActiveTexture(GL_TEXTURE3);
		glBindTexture(GL_TEXTURE_2D, hdr_lut_texture);
		glUniform1i(uniforms.color_transfer, pending_color_transfer_type);
	}
	if (use_hdr || use_picture) {
		glUniform1f(uniforms.brightness, pending_brightness);
		glUniform1f(uniforms.contrast, pending_contrast);
		glUniform1f(uniforms.gamma, pending_gamma);
	}
	glUniformMatrix4fv(uniforms.texmatrix, 1, GL_FALSE, p_tex_matrix);
	glUniform1f(uniforms.debug_solid, debug_solid_color ? 1.0f : 0.0f);
	glUniform1f(uniforms.occlusion, p_occluding ? 1.0f : 0.0f);
	glUniform1f(uniforms.convergence, p_convergence);
	glUniform1f(uniforms.disp_texels, p_separation * upsample_width);
	glUniform1f(uniforms.low_res_width, (float)upsample_width);
	glUniform1f(uniforms.frame_width, (float)video_width);
	glUniform1i(uniforms.stereo_mode, pending_stereo_mode);

	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, VERTEX_DATA);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, VERTEX_DATA + 2);
	glEnableVertexAttribArray(1);

	// Single draw call per eye into its half of the double-wide swapchain:
	// this replaces Godot's two full-res eye SubViewports.
	for (int eye = 0; eye < 2; eye++) {
		const int inset = pending_bezel_enabled ? 8 : 0;
		glViewport(eye * output_width + inset, inset,
				output_width - inset * 2, output_height - inset * 2);
		float disparity = (eye == 0) ? p_separation : -p_separation;
		glUniform1f(uniforms.disparity, disparity);
		glUniform1f(uniforms.eye_index, (float)eye);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	if (ambient_sample_requested.exchange(false, std::memory_order_acq_rel) &&
			!issue_ambient_sample()) {
		// Both readback buffers are still in flight. Retain one coalesced request
		// and retry after a later frame frees a slot.
		ambient_sample_requested.store(true, std::memory_order_release);
	}

	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	XrSwapchainImageReleaseInfo release_info = { XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
	pfn_xrReleaseSwapchainImage(swapchain, &release_info);
	ever_rendered = true;
}

// Just caches the frame's params; _on_pre_render() does the actual GL work
// once Godot has begun that frame, and _get_composition_layer() builds the
// XrCompositionLayerQuads from these same pose params on demand.
void NightfallXrRenderer::submit_frame(bool p_new_frame, uint32_t p_oes_texture_id, uint32_t p_depth_texture_id,
		uint32_t p_depth_guide_texture_id, PackedFloat32Array p_tex_matrix, float p_distance,
		float p_quad_width, bool p_head_locked, float p_separation, bool p_eye_swap,
		bool p_passthrough, uint64_t p_oes_fence, int p_stereo_mode, uint64_t p_depth_revision,
		int p_color_transfer_type, float p_convergence, float p_brightness,
		float p_contrast, float p_gamma) {
	pending_new_frame = p_new_frame;
	pending_oes_texture_id = p_oes_texture_id;
	pending_depth_texture_id = p_depth_texture_id;
	pending_depth_guide_texture_id = p_depth_guide_texture_id;
	int n = p_tex_matrix.size() < 16 ? p_tex_matrix.size() : 16;
	for (int i = 0; i < n; i++) {
		pending_tex_matrix[i] = p_tex_matrix[i];
	}
	pending_distance = p_distance;
	pending_quad_width = p_quad_width;
	pending_head_locked = p_head_locked;
	pending_separation = p_separation;
	pending_convergence = std::fmin(std::fmax(p_convergence, 0.0f), 1.0f);
	pending_eye_swap = p_eye_swap;
	pending_passthrough = p_passthrough;
	pending_stereo_mode = p_stereo_mode;
	pending_color_transfer_type = (p_color_transfer_type == 1 || p_color_transfer_type == 2)
			? p_color_transfer_type : 0;
	pending_brightness = std::fmin(std::fmax(p_brightness, -1.0f), 1.0f);
	pending_contrast = std::fmin(std::fmax(p_contrast, 0.01f), 4.0f);
	pending_gamma = std::fmin(std::fmax(p_gamma, 0.01f), 4.0f);
	pending_depth_revision = p_depth_revision;
	if (pending_oes_fence != 0) {
		// submit_frame() runs on the script thread, where no GL context is
		// guaranteed current. Retire replaced fences later from our EGL context.
		superseded_oes_fences.push_back(pending_oes_fence);
	}
	pending_oes_fence = p_oes_fence;
}

void NightfallXrRenderer::set_debug_solid_color(bool p_enabled) {
	debug_solid_color = p_enabled;
}

// _on_pre_render() is a dead letter for a normally-instantiated GDExtension:
// Godot only calls it for wrappers in registered_extension_wrappers
// (openxr_api.cpp: `for (wrapper : registered_extension_wrappers) wrapper->on_pre_render();`),
// a list populated exclusively by register_extension_wrapper() -- which has
// a hard guard against registering once the XrInstance exists (it always
// does by the time _ready() runs). composition_layer_providers (what
// register_provider() actually registers with, via register_composition_layer_provider())
// is a completely separate list, iterated only by end_frame()'s layer
// collection. So _get_composition_layer_count() -- confirmed reliably called
// every frame -- is where the actual render has to happen instead.
void NightfallXrRenderer::_on_pre_render() {
}

void NightfallXrRenderer::maybe_render_pending_frame() {
	if (!pending_new_frame) {
		return;
	}
	pending_new_frame = false;
	bool occluding = pending_depth_texture_id != 0 && pending_separation > 0.0f;

	// Query Godot's current context/surfaces fresh rather than reusing the
	// long-lived godot_context/godot_draw_surface/godot_read_surface members
	// -- those are only valid for the one immediate restore inside start().
	// Godot recreates its EGLSurface (though not its EGLContext, preserved
	// via setPreserveEGLContextOnPause(true)) on ordinary pause/resume-style
	// transitions a Quest headset can trigger mid-session; restoring to a
	// stale cached surface produces EGL_BAD_SURFACE on Godot's next
	// eglSwapBuffers.
	EGLContext restore_context = eglGetCurrentContext();
	EGLSurface restore_draw = eglGetCurrentSurface(EGL_DRAW);
	EGLSurface restore_read = eglGetCurrentSurface(EGL_READ);
	if (restore_context == EGL_NO_CONTEXT) {
		// Not called from inside Godot's own frame with its context current
		// (shouldn't normally happen -- we're only ever called from
		// _get_composition_layer_count()) -- skip rather than leave our own
		// context current with nothing valid to hand back.
		XR_LOGE("maybe_render_pending_frame: no current EGL context to restore, skipping render");
		return;
	}
	if (restore_draw != last_seen_draw_surface || restore_read != last_seen_read_surface) {
	#ifdef NIGHTFALL_DEBUG
		XR_LOG("DEBUG Godot's EGL surface changed: draw %p -> %p, read %p -> %p",
				(void *)last_seen_draw_surface, (void *)restore_draw,
				(void *)last_seen_read_surface, (void *)restore_read);
	#endif
		last_seen_draw_surface = restore_draw;
		last_seen_read_surface = restore_read;
	}

	// Switch to our context for the warp draw, then hand Godot's
	// context/surfaces straight back so its own subsequent GL calls this
	// frame (and every future call into us) keep working. See init_egl()'s
	// comment for why this matters.
	if (!eglMakeCurrent(egl_display, egl_pbuffer, egl_pbuffer, egl_context)) {
		XR_LOGE("maybe_render_pending_frame: activating native EGL context failed: %d", eglGetError());
		return;
	}
	for (uint64_t fence : superseded_oes_fences) {
		glDeleteSync(reinterpret_cast<GLsync>(fence));
	}
	superseded_oes_fences.clear();
	render_video_frame(pending_oes_texture_id, pending_depth_texture_id, pending_depth_guide_texture_id,
			pending_tex_matrix, pending_separation, pending_convergence, occluding);
	if (!eglMakeCurrent(egl_display, restore_draw, restore_read, restore_context)) {
		XR_LOGE("maybe_render_pending_frame: restoring Godot's EGL context/surface failed: %d", eglGetError());
	}
}

int32_t NightfallXrRenderer::_get_composition_layer_count() {
	maybe_render_pending_frame();
	++layer_frame_counter;
	int32_t count = ever_rendered ? ((overlay_visible && overlay_has_content && overlay_swapchain != XR_NULL_HANDLE) ? 3 : 2) : 0;
	#ifdef NIGHTFALL_DEBUG
	static int calls = 0;
	++calls;
	if (calls <= 10) {
		XR_LOG("DEBUG _get_composition_layer_count FIRST calls=%d ever_rendered=%d count=%d pending_new_frame=%d", calls, ever_rendered, count, pending_new_frame);
	}
	if (calls % 180 == 0) {
		XR_LOG("DEBUG _get_composition_layer_count calls=%d ever_rendered=%d count=%d", calls, ever_rendered, count);
	}
	#endif
	return count;
}

uint64_t NightfallXrRenderer::_get_composition_layer(int32_t p_index) {
	// Fetch fresh rather than using the xr_space member cached once in
	// register_provider(): Godot's play space is created lazily, INSIDE its
	// own per-frame OpenXRAPI::process() (gated by play_space_is_dirty,
	// true by default), a distinct and LATER point in the lifecycle than
	// instance/session creation -- unlike those, it is very likely still
	// XR_NULL_HANDLE at _ready() time, when register_provider() runs. A quad
	// referencing a null space submits without error but is never actually
	// visible -- exactly this bug's symptom.
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	XrSpace space = api.is_valid() ? (XrSpace)api->get_play_space() : xr_space;
	#ifdef NIGHTFALL_DEBUG
	static XrSpace last_logged_space = (XrSpace)0xdeadbeef; // never a real handle
	if (space != last_logged_space) {
		XR_LOG("DEBUG play space %s -> %p", last_logged_space == (XrSpace)0xdeadbeef ? "(first)" : "changed", (void *)space);
		last_logged_space = space;
	}
	#endif

	if (p_index < 2) {
		int eye = p_index;
		eye_last_queried_frame[eye] = layer_frame_counter;
		int half = pending_eye_swap ? (1 - eye) : eye;

		XrSwapchainSubImage sub_image{};
		sub_image.swapchain = swapchain;
		sub_image.imageRect.offset.x = half * output_width;
		sub_image.imageRect.offset.y = 0;
		sub_image.imageRect.extent.width = output_width;
		sub_image.imageRect.extent.height = output_height;
		sub_image.imageArrayIndex = 0;

		Transform3D xf = pending_transform;
		XRServer *xr_server = XRServer::get_singleton();
		if (xr_server != nullptr) {
			xf = xr_server->get_reference_frame().inverse() * xf;
		}
		Quaternion q(xf.basis.orthonormalized());
		if (q.length_squared() < 0.000001f) {
			q = Quaternion();
		}
		XrPosef pose{};
		pose.orientation = { (float)q.x, (float)q.y, (float)q.z, (float)q.w };
		pose.position = { (float)xf.origin.x, (float)xf.origin.y, (float)xf.origin.z };

		if (pending_curvature > 0 && cylinder_supported) {
			XrCompositionLayerCylinderKHR *cylinder = &cylinder_layers[eye];
			memset(cylinder, 0, sizeof(*cylinder));
			cylinder->type = XR_TYPE_COMPOSITION_LAYER_CYLINDER_KHR;
			cylinder->eyeVisibility = eye == 0 ? XR_EYE_VISIBILITY_LEFT : XR_EYE_VISIBILITY_RIGHT;
			cylinder->subImage = sub_image;
			cylinder->space = space;
			cylinder->pose = pose;
			cylinder->radius = pending_radius;
			cylinder->centralAngle = pending_central_angle;
			const float layer_w = pending_width * (pending_bezel_enabled ? (float)output_width / (float)video_width : 1.0f);
			const float layer_h = pending_height * (pending_bezel_enabled ? (float)output_height / (float)video_height : 1.0f);
			cylinder->aspectRatio = layer_w / layer_h;
			return (uint64_t)(void *)cylinder;
		}

		XrCompositionLayerQuad *quad = &quad_layers[eye];
		memset(quad, 0, sizeof(*quad));
		quad->type = XR_TYPE_COMPOSITION_LAYER_QUAD;
		quad->eyeVisibility = eye == 0 ? XR_EYE_VISIBILITY_LEFT : XR_EYE_VISIBILITY_RIGHT;
		quad->subImage = sub_image;
		quad->space = space;
		quad->pose = pose;
		quad->size.width = pending_width * (pending_bezel_enabled ? (float)output_width / (float)video_width : 1.0f);
		quad->size.height = pending_height * (pending_bezel_enabled ? (float)output_height / (float)video_height : 1.0f);
		return (uint64_t)(void *)quad;
	}

	// p_index == 2: overlay, only reachable when _get_composition_layer_count()
	// returned 3. Place it in the screen's local top-left rather than at a
	// hard-coded stage-space position so it follows screen moves and rotations.
	float quad_height = pending_height;
	float overlay_w = pending_quad_width * 0.30f;
	float overlay_h = overlay_w * (float)OVERLAY_HEIGHT / (float)OVERLAY_WIDTH;
	float margin = pending_quad_width * 0.02f;

	memset(&overlay_layer, 0, sizeof(overlay_layer));
	overlay_layer.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
	overlay_layer.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
	overlay_layer.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
	overlay_layer.subImage.swapchain = overlay_swapchain;
	overlay_layer.subImage.imageRect.extent.width = OVERLAY_WIDTH;
	overlay_layer.subImage.imageRect.extent.height = OVERLAY_HEIGHT;
	overlay_layer.subImage.imageArrayIndex = 0;
	overlay_layer.space = space;
	Transform3D overlay_xf = pending_transform;
	// For a cylinder pending_transform is its center of curvature, not the
	// visible screen surface. The overlay is a flat tangent quad, so recover
	// the screen-center transform before applying its local top-left offset.
	if (pending_curvature > 0 && cylinder_supported) {
		const Vector3 screen_forward = -overlay_xf.basis.get_column(2);
		overlay_xf.origin += screen_forward * pending_radius;
	}
	XRServer *overlay_xr_server = XRServer::get_singleton();
	if (overlay_xr_server != nullptr) {
		overlay_xf = overlay_xr_server->get_reference_frame().inverse() * overlay_xf;
	}
	Quaternion overlay_q(overlay_xf.basis.orthonormalized());
	Vector3 overlay_local(-pending_width * 0.5f + overlay_w * 0.5f + margin,
			quad_height * 0.5f - overlay_h * 0.5f - margin, 0.01f);
	Vector3 overlay_pos = overlay_xf.xform(overlay_local);
	overlay_layer.pose.orientation = { (float)overlay_q.x, (float)overlay_q.y, (float)overlay_q.z, (float)overlay_q.w };
	overlay_layer.pose.position = { (float)overlay_pos.x, (float)overlay_pos.y, (float)overlay_pos.z };
	overlay_layer.size.width = overlay_w;
	overlay_layer.size.height = overlay_h;
	return (uint64_t)(void *)&overlay_layer;
}

int32_t NightfallXrRenderer::_get_composition_layer_order(int32_t p_index) {
	// Order 0 is Godot's own reserved default (the projection layer, even
	// though we run projectionless -- see openxr_api.cpp:2720's warning);
	// a layer returning 0 risks being overwritten by it. Matches main.gd's
	// old OpenXRCompositionLayerQuad convention (sort_order 1 for video).
	return pending_sort_order + p_index;
}

void NightfallXrRenderer::upload_overlay(PackedByteArray p_pixels, int p_width, int p_height) {
	if (overlay_swapchain == XR_NULL_HANDLE || p_width != OVERLAY_WIDTH || p_height != OVERLAY_HEIGHT) {
		return;
	}
	// GDScript-callable directly, so (unlike maybe_render_pending_frame(),
	// only ever called from inside our own end_frame() callback) this can
	// run with Godot's context current -- same save/restore is needed here,
	// queried fresh rather than cached; see maybe_render_pending_frame()'s
	// comment for why.
	EGLContext restore_context = eglGetCurrentContext();
	EGLSurface restore_draw = eglGetCurrentSurface(EGL_DRAW);
	EGLSurface restore_read = eglGetCurrentSurface(EGL_READ);
	if (restore_context == EGL_NO_CONTEXT) {
		XR_LOGE("upload_overlay: no current EGL context to restore, skipping");
		return;
	}
	if (!eglMakeCurrent(egl_display, egl_pbuffer, egl_pbuffer, egl_context)) {
		XR_LOGE("upload_overlay: activating native EGL context failed: %d", eglGetError());
		return;
	}

	uint32_t image_index = 0;
	XrSwapchainImageAcquireInfo acquire_info = { XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
	if (check_xr(pfn_xrAcquireSwapchainImage(overlay_swapchain, &acquire_info, &image_index), "acquire overlay image")) {
		XrSwapchainImageWaitInfo wait_info = { XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
		wait_info.timeout = XR_INFINITE_DURATION;
		pfn_xrWaitSwapchainImage(overlay_swapchain, &wait_info);

		glBindTexture(GL_TEXTURE_2D, overlay_images[image_index].image);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, p_width, p_height, GL_RGBA, GL_UNSIGNED_BYTE, p_pixels.ptr());
		glBindTexture(GL_TEXTURE_2D, 0);

		XrSwapchainImageReleaseInfo release_info = { XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
		pfn_xrReleaseSwapchainImage(overlay_swapchain, &release_info);
		if (!overlay_has_content) {
			XR_LOG("Performance overlay texture uploaded");
		}
		overlay_has_content = true;
	}

	if (!eglMakeCurrent(egl_display, restore_draw, restore_read, restore_context)) {
		XR_LOGE("upload_overlay: restoring Godot's EGL context/surface failed: %d", eglGetError());
	}
}

void NightfallXrRenderer::set_overlay_visible(bool p_visible) {
	overlay_visible = p_visible;
}

float NightfallXrRenderer::get_warp_gpu_ms() {
	// GPU timer queries were dropped from this port (debug/tuning feature in
	// the reference, not required for the double-wide-swapchain fps win);
	// main.gd's existing stats overlay already measures app fps.
	return 0.0f;
}

#endif // __ANDROID__
