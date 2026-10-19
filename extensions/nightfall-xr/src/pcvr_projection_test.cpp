#include "pcvr_projection_test.h"
#include "pcvr_view_validation.h"
#include <godot_cpp/core/class_db.hpp>

#ifdef __ANDROID__
#include <android/log.h>
#include <cmath>
#include <time.h>
#include <android/hardware_buffer.h>
#define PCVR_LOG(...) __android_log_print(ANDROID_LOG_INFO, "NightfallPCVR", __VA_ARGS__)
#endif

namespace godot {
void NightfallXrProjectionTest::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start_test"), &NightfallXrProjectionTest::start_test);
	ClassDB::bind_method(D_METHOD("start_stream"), &NightfallXrProjectionTest::start_stream);
	ClassDB::bind_method(D_METHOD("start_meteor_test"), &NightfallXrProjectionTest::start_meteor_test);
	ClassDB::bind_method(D_METHOD("stream_available"), &NightfallXrProjectionTest::stream_available);
	ClassDB::bind_method(D_METHOD("stop_test"), &NightfallXrProjectionTest::stop_test);
	ClassDB::bind_method(D_METHOD("get_test_status"), &NightfallXrProjectionTest::get_test_status);
}

Dictionary NightfallXrProjectionTest::_get_requested_extensions(uint64_t version) {
	Dictionary requested = NightfallXrRenderer::_get_requested_extensions(version);
#ifdef __ANDROID__
	requested["XR_KHR_convert_timespec_time"] = reinterpret_cast<uint64_t>(&clock_extension);
#endif
	return requested;
}

bool NightfallXrProjectionTest::stream_available() const {
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
	return clock_extension;
#else
	return false;
#endif
}

bool NightfallXrProjectionTest::start_stream() {
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
	if (!stream_available() || state.load() != IDLE) return false;
	if (!remote) remote = std::make_unique<PCVRAlvrClient>();
	if (!remote->start()) return false;
	remote_mode = true; remote_draining = false;
	return start_test();
#else
	return false;
#endif
}

bool NightfallXrProjectionTest::start_test() {
#ifdef __ANDROID__
	int expected = IDLE;
	if (!state.compare_exchange_strong(expected, STARTING)) return false;
	{
		std::lock_guard<std::mutex> lock(error_mutex);
		error.clear();
	}
	frames.store(0);
	meteor_copy_waits=0; meteor_swapchain_waits=0; meteor_reuses=0;
	return true;
#else
	fail("Synthetic PCVR projection is Android/GLES only");
	return false;
#endif
}

bool NightfallXrProjectionTest::start_meteor_test() {
#ifdef __ANDROID__
	if (state.load() != IDLE) { PCVR_LOG("Meteor start rejected: projection test not idle"); return false; }
	if (!clock_extension) { PCVR_LOG("Meteor start rejected: XR_KHR_convert_timespec_time was not enabled at instance creation"); return false; }
	if (!tracking) tracking = std::make_unique<MeteorTrackingEndpoint>();
	if (!tracking->start()) return false;
	tracking_epoch = MeteorTrackingEndpoint::now_ns();
	if (!meteor) meteor = std::make_unique<PCVRMeteorReceiver>();
	if (!meteor->start()) { tracking->request_stop(); return false; }
	meteor_mode = true; meteor_draining = false;
	PCVR_LOG("Meteor projection receiver requested; local-pose USB diagnostic only");
	return start_test();
#else
	return false;
#endif
}

void NightfallXrProjectionTest::stop_test() {
	int current = state.load();
	while (current != IDLE && current != STOPPING && !state.compare_exchange_weak(current, STOPPING)) {}
}

Dictionary NightfallXrProjectionTest::get_test_status() const {
	static const char *names[] = {"idle", "starting", "running", "stopping", "failed"};
	Dictionary result;
	result["state"] = names[state.load()];
	result["frames"] = static_cast<int64_t>(frames.load());
	result["session"] = static_cast<int64_t>(session_id.load());
#ifdef __ANDROID__
	if (meteor) result["meteor_status"] = String(meteor->message().c_str());
	result["meteor_endpoints_ready"] = meteor && meteor->listening() && tracking && tracking->listening();
	if (meteor) {
		const auto &s=meteor->stats;
		Dictionary counts;
		counts["received"]=int64_t(s.received.load()); counts["queued"]=int64_t(s.queued.load());
		counts["codec_outputs"]=int64_t(s.output.load()); counts["selected"]=int64_t(s.selected.load());
		counts["superseded_before_selection"]=int64_t(s.superseded.load());
		counts["metadata_lock_busy_polls"]=int64_t(s.lock_busy.load());
		counts["no_image_polls"]=int64_t(s.no_image.load()); counts["acquire_fence_wait_polls"]=int64_t(s.acquire_wait.load());
		counts["copy_fence_wait_polls"]=int64_t(meteor_copy_waits.load());
		counts["swapchain_wait_polls"]=int64_t(meteor_swapchain_waits.load());
		counts["reuse_previous_projection_polls"]=int64_t(meteor_reuses.load());
		counts["projection_copies"]=int64_t(frames.load());
		result["meteor_device_counts"]=counts;
	}
#endif
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
	if (remote) result["remote_status"] = String(remote->message().c_str());
#endif
	std::lock_guard<std::mutex> lock(error_mutex);
	result["error"] = String(error.c_str());
	return result;
}

void NightfallXrProjectionTest::fail(const char *message) {
	{
		std::lock_guard<std::mutex> lock(error_mutex);
		error = message;
	}
	// Do not undo a concurrent user stop.
	int current = state.load();
	while (current != STOPPING && !state.compare_exchange_weak(current, FAILED)) {}
#ifdef __ANDROID__
	PCVR_LOG("projection test failed: %s", message);
#endif
}

#ifdef __ANDROID__
namespace {
// Restore the GL state changed by this test before Godot resumes rendering.
struct ScopedGLState {
	GLint draw = 0, read = 0, viewport[4]{}, shader = 0, vertex_array = 0;
	GLint active_texture = 0, external_texture = 0;
	GLboolean blend, depth, cull, scissor, stencil, color[4]{};
	ScopedGLState() {
		glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
		glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
		glGetIntegerv(GL_VIEWPORT, viewport);
		glGetIntegerv(GL_CURRENT_PROGRAM, &shader);
		glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertex_array);
		glGetIntegerv(GL_ACTIVE_TEXTURE, &active_texture);
		glActiveTexture(GL_TEXTURE0); glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &external_texture);
		glGetBooleanv(GL_COLOR_WRITEMASK, color);
		blend = glIsEnabled(GL_BLEND); depth = glIsEnabled(GL_DEPTH_TEST);
		cull = glIsEnabled(GL_CULL_FACE); scissor = glIsEnabled(GL_SCISSOR_TEST);
		stencil = glIsEnabled(GL_STENCIL_TEST);
	}
	~ScopedGLState() {
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw);
		glBindFramebuffer(GL_READ_FRAMEBUFFER, read);
		glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
		glUseProgram(shader); glBindVertexArray(vertex_array);
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_EXTERNAL_OES, external_texture);
		glActiveTexture(active_texture);
		glColorMask(color[0], color[1], color[2], color[3]);
		set(GL_BLEND, blend); set(GL_DEPTH_TEST, depth);
		set(GL_CULL_FACE, cull); set(GL_SCISSOR_TEST, scissor);
		set(GL_STENCIL_TEST, stencil);
	}
	static void set(GLenum capability, GLboolean enabled) {
		if (enabled) glEnable(capability); else glDisable(capability);
	}
};

GLuint compile_shader(GLenum type, const char *source) {
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, nullptr); glCompileShader(shader);
	GLint ok = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512]{}; glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
		PCVR_LOG("synthetic shader: %s", log); glDeleteShader(shader); return 0;
	}
	return shader;
}

const char *VERTEX = R"GLSL(#version 300 es
out vec2 uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})GLSL";

const char *FRAGMENT = R"GLSL(#version 300 es
precision highp float;
in vec2 uv;
out vec4 color;
uniform vec4 fov_tangents;
uniform vec4 eye_rotation;
uniform vec3 eye_position;
vec3 rotate_eye(vec3 v) {
    return v + 2.0 * cross(eye_rotation.xyz, cross(eye_rotation.xyz, v) + eye_rotation.w * v);
}
void main() {
    vec3 rd = normalize(rotate_eye(vec3(mix(fov_tangents.x, fov_tangents.y, uv.x),
                                      mix(fov_tangents.z, fov_tangents.w, uv.y), -1.0)));
    vec3 ro = eye_position;
    vec3 rgb = mix(vec3(0.025, 0.035, 0.06), vec3(0.12, 0.20, 0.28), clamp(rd.y * 0.5 + 0.5, 0.0, 1.0));
    float nearest = 1000.0;
    if (rd.y < -0.001) {
        float t = -ro.y / rd.y;
        if (t > 0.0 && t < 80.0) {
            vec3 p = ro + rd * t;
            float check = mod(floor(p.x) + floor(p.z), 2.0);
            rgb = mix(vec3(0.06), vec3(0.16), check);
            vec2 grid = abs(fract(p.xz + 0.5) - 0.5);
            if (min(grid.x, grid.y) < 0.015) rgb += vec3(0.08);
            nearest = t;
        }
    }
    for (int i = 0; i < 3; ++i) {
        vec3 center = vec3(float(i - 1) * 1.4, 1.35, -3.0 - float(i) * 0.6);
        vec3 oc = ro - center;
        float b = dot(oc, rd);
        float d = b * b - dot(oc, oc) + 0.36;
        if (d > 0.0) {
            float t = -b - sqrt(d);
            if (t > 0.0 && t < nearest) {
                nearest = t;
                vec3 n = normalize(ro + rd * t - center);
                vec3 base = i == 0 ? vec3(0.7, 0.12, 0.08) : (i == 1 ? vec3(0.08, 0.6, 0.2) : vec3(0.08, 0.25, 0.75));
                rgb = base * (0.25 + 0.75 * max(dot(n, normalize(vec3(-0.5, 1.0, 0.5))), 0.0));
            }
        }
    }
    color = vec4(rgb, 1.0);
})GLSL";
const char *METEOR_FRAGMENT = R"GLSL(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES video;
uniform float eye_offset;
in vec2 uv;
out vec4 color;
void main() { color = vec4(texture(video, vec2(eye_offset + uv.x * 0.5, 1.0 - uv.y)).rgb, 1.0); }
)GLSL";
}

bool NightfallXrProjectionTest::initialize_render_resources() {
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null() || !api->get_instance() || !api->get_session() || eglGetCurrentContext() == EGL_NO_CONTEXT) {
		fail("No existing OpenXR session/current GLES context"); return false;
	}
	instance = reinterpret_cast<XrInstance>(api->get_instance());
	session = reinterpret_cast<XrSession>(api->get_session());
	session_id.store(api->get_session());
	creation_context = eglGetCurrentContext();
#define RESOLVE(field, name) field = reinterpret_cast<PFN_##name>(api->get_instance_proc_addr(#name)); if (!field) { fail("Missing " #name); return false; }
	RESOLVE(enum_formats, xrEnumerateSwapchainFormats)
	RESOLVE(create_swapchain, xrCreateSwapchain)
	RESOLVE(destroy_swapchain, xrDestroySwapchain)
	RESOLVE(enum_images, xrEnumerateSwapchainImages)
	RESOLVE(acquire_image, xrAcquireSwapchainImage)
	RESOLVE(wait_image, xrWaitSwapchainImage)
	RESOLVE(release_image, xrReleaseSwapchainImage)
	RESOLVE(locate_views, xrLocateViews)
#undef RESOLVE
	uint32_t count = 0;
	if (XR_FAILED(enum_formats(session, 0, &count, nullptr)) || count == 0) { fail("No swapchain formats"); return false; }
	std::vector<int64_t> formats(count);
	if (XR_FAILED(enum_formats(session, count, &count, formats.data()))) { fail("Cannot enumerate swapchain formats"); return false; }
	int64_t format = 0;
	for (int64_t candidate : formats) if (candidate == GL_SRGB8_ALPHA8) format = candidate;
	if (!format) for (int64_t candidate : formats) if (candidate == GL_RGBA8) format = candidate;
	if (!format) { fail("No supported RGBA swapchain format"); return false; }
	XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
	info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
	info.format = format; info.sampleCount = 1; info.width = EYE_SIZE * 2; info.height = EYE_SIZE;
	info.faceCount = 1; info.arraySize = 1; info.mipCount = 1;
	if (XR_FAILED(create_swapchain(session, &info, &swapchain))) { fail("Cannot create synthetic swapchain"); return false; }
	if (XR_FAILED(enum_images(swapchain, 0, &count, nullptr)) || count == 0) { fail("No swapchain images"); return false; }
	images.resize(count);
	for (auto &image : images) image = {XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR};
	if (XR_FAILED(enum_images(swapchain, count, &count, reinterpret_cast<XrSwapchainImageBaseHeader *>(images.data())))) { fail("Cannot enumerate swapchain images"); return false; }
	GLuint vertex = compile_shader(GL_VERTEX_SHADER, VERTEX), fragment = compile_shader(GL_FRAGMENT_SHADER, meteor_mode ? METEOR_FRAGMENT : FRAGMENT);
	if (!vertex || !fragment) {
		if (vertex) glDeleteShader(vertex); if (fragment) glDeleteShader(fragment);
		fail("Cannot compile synthetic scene"); return false;
	}
	program = glCreateProgram(); glAttachShader(program, vertex); glAttachShader(program, fragment); glLinkProgram(program);
	glDeleteShader(vertex); glDeleteShader(fragment);
	GLint linked = 0; glGetProgramiv(program, GL_LINK_STATUS, &linked);
	if (!linked) { fail("Cannot link synthetic scene"); return false; }
	glGenFramebuffers(1, &framebuffer); glGenVertexArrays(1, &vao);
	if (meteor_mode) {
		meteor_native_buffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
		meteor_create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
		meteor_destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
		meteor_image_to_texture = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
		if (!meteor_native_buffer || !meteor_create_image || !meteor_destroy_image || !meteor_image_to_texture) { fail("Missing Meteor hardware-buffer import functions"); return false; }
		glGenTextures(1, &meteor_texture);
	}
	bool needs_head_space = meteor_mode;
#ifdef NIGHTFALL_PCVR_ALVR
	needs_head_space |= remote_mode;
#endif
	if (needs_head_space) {
		create_space = reinterpret_cast<PFN_xrCreateReferenceSpace>(api->get_instance_proc_addr("xrCreateReferenceSpace"));
		destroy_space = reinterpret_cast<PFN_xrDestroySpace>(api->get_instance_proc_addr("xrDestroySpace"));
		locate_space = reinterpret_cast<PFN_xrLocateSpace>(api->get_instance_proc_addr("xrLocateSpace"));
		clock_to_xr = reinterpret_cast<PFN_xrConvertTimespecTimeToTimeKHR>(api->get_instance_proc_addr("xrConvertTimespecTimeToTimeKHR"));
		if (!create_space || !destroy_space || !locate_space || !clock_to_xr) { fail("Missing XR tracking/clock functions"); return false; }
		XrReferenceSpaceCreateInfo space_info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
		space_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW; space_info.poseInReferenceSpace.orientation.w = 1;
		if (XR_FAILED(create_space(session, &space_info, &head_space))) { fail("Cannot create head tracking space"); return false; }
		if (meteor_mode) {
			space_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
			if (XR_FAILED(create_space(session, &space_info, &tracking_space))) { fail("Cannot create Meteor LOCAL tracking space"); return false; }
			initialize_meteor_controllers();
		}
	}
	PCVR_LOG("synthetic projection initialized session=%p, %dx%d per eye; public predicted-time snapshot (synthetic only)", (void *)session, EYE_SIZE, EYE_SIZE);
	return true;
}

bool NightfallXrProjectionTest::render_scene() {
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null() || api->get_session() != session_id.load() || eglGetCurrentContext() != creation_context) {
		fail("Session/GLES context changed; exit synthetic test"); return false;
	}
	XrSpace space = reinterpret_cast<XrSpace>(api->get_play_space());
	if (meteor_mode) publish_meteor_tracking();
	if (state.load() == FAILED) return false;
	XrTime time = api->get_predicted_display_time();
	if (!space || time <= 0) return false;
	XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
	locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO; locate.displayTime = time; locate.space = space;
	XrViewState view_state{XR_TYPE_VIEW_STATE};
	XrView views[2]{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
	uint32_t count = 0;
	if (XR_FAILED(locate_views(session, &locate, &view_state, 2, &count, views))) { fail("xrLocateViews failed"); return false; }
	if (count != 2 || !(view_state.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) || !(view_state.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT)) return false;
	if (meteor_mode && !prepare_meteor_image()) {
		if (rendered && state.load() == RUNNING) ++meteor_reuses;
		return rendered && state.load() == RUNNING;
	}
	if (!acquired) {
		XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
		if (XR_FAILED(acquire_image(swapchain, &acquire, &acquired_index))) { fail("Cannot acquire synthetic image"); return false; }
		acquired = true; image_waited = false;
	}
	XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = 1000000; // 1ms, never an unbounded render-thread wait.
	XrResult result = wait_image(swapchain, &wait);
	if (result == XR_TIMEOUT_EXPIRED) { if (meteor_mode) ++meteor_swapchain_waits; return false; } // Keep acquired image and retry next frame.
	if (result != XR_SUCCESS) {
		// A timed-out acquired image cannot be released before a successful wait.
		fail("Synthetic swapchain wait timed out/failed"); return false;
	}
	image_waited = true;
	uint32_t index = acquired_index;
	if (index >= images.size()) { fail("Invalid synthetic image index"); return false; }
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, images[index].image, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { fail("Incomplete synthetic framebuffer"); return false; }
	glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE); glDisable(GL_SCISSOR_TEST); glDisable(GL_STENCIL_TEST);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE); glUseProgram(program); glBindVertexArray(vao);
	if (meteor_mode) {
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_EXTERNAL_OES, meteor_texture);
		meteor_image_to_texture(GL_TEXTURE_EXTERNAL_OES, meteor_image);
		glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		glUniform1i(glGetUniformLocation(program, "video"), 0);
	}
	for (int eye = 0; eye < 2; ++eye) {
		const XrView &view = views[eye];
		glViewport(eye * EYE_SIZE, 0, EYE_SIZE, EYE_SIZE);
		if (meteor_mode) glUniform1f(glGetUniformLocation(program, "eye_offset"), eye * 0.5f);
		else {
			glUniform4f(glGetUniformLocation(program, "fov_tangents"), std::tan(view.fov.angleLeft), std::tan(view.fov.angleRight), std::tan(view.fov.angleDown), std::tan(view.fov.angleUp));
			glUniform4f(glGetUniformLocation(program, "eye_rotation"), view.pose.orientation.x, view.pose.orientation.y, view.pose.orientation.z, view.pose.orientation.w);
			glUniform3f(glGetUniformLocation(program, "eye_position"), view.pose.position.x, view.pose.position.y, view.pose.position.z);
		}
		glDrawArrays(GL_TRIANGLES, 0, 3);
		projection_views[eye] = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
		projection_views[eye].pose = view.pose; projection_views[eye].fov = view.fov;
		if (meteor_mode && meteor_frame.quest_local) {
			const float *v = meteor_frame.views.data()+eye*11;
			projection_views[eye].pose = {{v[3],v[4],v[5],v[6]}, {v[0],v[1],v[2]}};
			projection_views[eye].fov = {v[7],v[8],v[9],v[10]};
		}
		projection_views[eye].subImage = {swapchain, {{eye * EYE_SIZE, 0}, {EYE_SIZE, EYE_SIZE}}, 0};
	}
	if (meteor_mode) {
		meteor_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
		if (!meteor_fence) { glFinish(); fail("Cannot fence Meteor decoder image"); return false; }
	}
	glFlush();
	XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
	if (XR_FAILED(release_image(swapchain, &release))) { fail("Cannot release synthetic image"); return false; }
	acquired = false; image_waited = false;
	projection = {XR_TYPE_COMPOSITION_LAYER_PROJECTION}; projection.space = space;
	if (meteor_mode && meteor_frame.quest_local) projection.space = tracking_space;
	projection.viewCount = 2; projection.views = projection_views.data();
	frames.fetch_add(1); rendered = true;
	if (frames.load() == 1) PCVR_LOG("%s first frame: ONE projection layer, session=%p", meteor_mode ? "METEOR DECODED (local-pose diagnostic, not tracked PCVR)" : "synthetic", (void *)session);
	if (frames.load() == 1 && meteor_mode && meteor_frame.quest_local)
		PCVR_LOG("METEOR TRACKED SCENE: host render poses/FOV mapped through adopted Quest LOCAL; latest-only USB diagnostic");
	return true;
}

void NightfallXrProjectionTest::initialize_meteor_controllers() {
	Ref<OpenXRAPIExtension> api=get_openxr_api();
	auto create_action_space=reinterpret_cast<PFN_xrCreateActionSpace>(api->get_instance_proc_addr("xrCreateActionSpace"));
	auto string_to_path=reinterpret_cast<PFN_xrStringToPath>(api->get_instance_proc_addr("xrStringToPath"));
	controller_float=reinterpret_cast<PFN_xrGetActionStateFloat>(api->get_instance_proc_addr("xrGetActionStateFloat"));
	if(!create_action_space || !string_to_path || !controller_float) { PCVR_LOG("Meteor controller capture unavailable: missing XR entry points"); return; }
	auto action=[&](const char *name) { RID rid=api->find_action(name,RID()); return rid.is_valid() ? reinterpret_cast<XrAction>(api->action_get_handle(rid)) : XR_NULL_HANDLE; };
	controller_trigger=action("trigger"); controller_squeeze=action("grip");
	controller_stick=action("primary");
	controller_haptic=action("haptic");
	controller_apply_haptic=reinterpret_cast<PFN_xrApplyHapticFeedback>(api->get_instance_proc_addr("xrApplyHapticFeedback"));
	controller_stop_haptic=reinterpret_cast<PFN_xrStopHapticFeedback>(api->get_instance_proc_addr("xrStopHapticFeedback"));
	const char *names[5]={"ax_button","primary_click","ax_touch","primary_touch","trigger_touch"};
	for(int i=0;i<5;++i) controller_buttons[i]=action(names[i]);
	controller_bool=reinterpret_cast<PFN_xrGetActionStateBoolean>(api->get_instance_proc_addr("xrGetActionStateBoolean"));
	controller_vector=reinterpret_cast<PFN_xrGetActionStateVector2f>(api->get_instance_proc_addr("xrGetActionStateVector2f"));
	XrAction poses[2]={action("grip_pose"),action("aim_pose")};
	if(!controller_trigger || !controller_squeeze || !poses[0] || !poses[1]) { PCVR_LOG("Meteor controller capture unavailable: expected Godot actions missing"); return; }
	for(int hand=0;hand<2;++hand) {
		if(XR_FAILED(string_to_path(instance,hand==0 ? "/user/hand/left" : "/user/hand/right",&controller_paths[hand]))) return;
		for(int pose=0;pose<2;++pose) {
			XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO}; info.action=poses[pose];
			info.subactionPath=controller_paths[hand]; info.poseInActionSpace.orientation.w=1;
			if(XR_FAILED(create_action_space(session,&info,&controller_spaces[hand][pose]))) {
				PCVR_LOG("Meteor controller capture unavailable: action-space creation failed"); return;
			}
		}
	}
	PCVR_LOG("Meteor controllers: existing Godot grip/aim/trigger/grip actions; no extra xrSyncActions");
}

void NightfallXrProjectionTest::publish_meteor_tracking() {
	if(tracking && controller_haptic && controller_apply_haptic && controller_stop_haptic) for(unsigned hand=0;hand<2;++hand) {
		MeteorHaptic pulse;
		if(!tracking->take_haptic(hand,pulse) || pulse.epoch!=tracking_epoch) continue;
		XrHapticActionInfo info{XR_TYPE_HAPTIC_ACTION_INFO}; info.action=controller_haptic; info.subactionPath=controller_paths[hand];
		XrResult result;
		if(pulse.duration_ms && pulse.amplitude>0) {
			XrHapticVibration vibration{XR_TYPE_HAPTIC_VIBRATION};
			vibration.amplitude=pulse.amplitude; vibration.duration=XrDuration(pulse.duration_ms)*1000000;
			vibration.frequency=XR_FREQUENCY_UNSPECIFIED;
			result=controller_apply_haptic(session,&info,reinterpret_cast<const XrHapticBaseHeader *>(&vibration));
		} else result=controller_stop_haptic(session,&info);
		PCVR_LOG("Meteor haptic hand=%u amplitude=%.3f duration_ms=%u result=%d",hand,pulse.amplitude,pulse.duration_ms,int(result));
	}
	if (!tracking || tracking->failed()) { fail("Meteor USB tracking endpoint failed"); return; }
	timespec now{}; clock_gettime(CLOCK_MONOTONIC, &now);
	XrTime xr_now = 0;
	if (!clock_to_xr || XR_FAILED(clock_to_xr(instance, &now, &xr_now))) {
		fail("Cannot map tracking sample time to OpenXR"); return;
	}
	XrSpaceLocation head{XR_TYPE_SPACE_LOCATION};
	if (XR_FAILED(locate_space(head_space, tracking_space, xr_now, &head)) ||
		!(head.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) ||
		!(head.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT)) return;
	MeteorTrackingSample sample;
	sample.epoch = tracking_epoch;
	sample.client_ns = uint64_t(now.tv_sec)*1000000000 + uint64_t(now.tv_nsec);
	sample.pose = {head.pose.position.x, head.pose.position.y, head.pose.position.z,
		head.pose.orientation.x, head.pose.orientation.y, head.pose.orientation.z, head.pose.orientation.w};
	XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
	locate.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	locate.displayTime=xr_now; locate.space=head_space;
	XrViewState state{XR_TYPE_VIEW_STATE};
	XrView eyes[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}}; uint32_t count=0;
	if(XR_SUCCEEDED(locate_views(session,&locate,&state,2,&count,eyes)) && count==2 &&
		(state.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) && (state.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT)) {
		sample.optics.epoch=tracking_epoch;
		for(size_t i=0;i<2;++i) {
			const auto &v=eyes[i]; const float values[11]={v.pose.position.x,v.pose.position.y,v.pose.position.z,
				v.pose.orientation.x,v.pose.orientation.y,v.pose.orientation.z,v.pose.orientation.w,
				v.fov.angleLeft,v.fov.angleRight,v.fov.angleUp,v.fov.angleDown};
			std::memcpy(sample.optics.eyes.data()+i*11,values,sizeof(values));
		}
	}
	sample.controllers.epoch=sample.epoch; sample.controllers.client_ns=sample.client_ns;
	for(int hand=0;hand<2;++hand) {
		auto &out=sample.controllers.hands[hand];
		for(int pose=0;pose<2;++pose) {
			XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
			if(controller_spaces[hand][pose] && XR_SUCCEEDED(locate_space(controller_spaces[hand][pose],tracking_space,xr_now,&location)) &&
				(location.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) && (location.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT)) {
				const auto &p=location.pose; float values[7]={p.position.x,p.position.y,p.position.z,p.orientation.x,p.orientation.y,p.orientation.z,p.orientation.w};
				std::memcpy(out.poses.data()+pose*7,values,sizeof(values)); out.flags|=1u<<pose;
			}
		}
		if((out.flags&1) && controller_float && controller_trigger && controller_squeeze) {
			XrActionStateGetInfo query{XR_TYPE_ACTION_STATE_GET_INFO}; query.subactionPath=controller_paths[hand];
			XrActionStateFloat trigger{XR_TYPE_ACTION_STATE_FLOAT},squeeze{XR_TYPE_ACTION_STATE_FLOAT};
			query.action=controller_trigger; XrResult t=controller_float(session,&query,&trigger);
			query.action=controller_squeeze; XrResult s=controller_float(session,&query,&squeeze);
			if(XR_SUCCEEDED(t) && XR_SUCCEEDED(s) && trigger.isActive && squeeze.isActive) {
				out.flags|=4; out.trigger=trigger.currentState; out.squeeze=squeeze.currentState;
				if(controller_stick && controller_vector) {
					query.action=controller_stick; XrActionStateVector2f stick{XR_TYPE_ACTION_STATE_VECTOR2F};
					if(XR_SUCCEEDED(controller_vector(session,&query,&stick)) && stick.isActive) {
						out.flags|=8; out.stick={stick.currentState.x,stick.currentState.y};
					}
				}
				if(controller_bool) for(int i=0;i<5;++i) if(controller_buttons[i]) {
					query.action=controller_buttons[i]; XrActionStateBoolean button{XR_TYPE_ACTION_STATE_BOOLEAN};
					if(XR_SUCCEEDED(controller_bool(session,&query,&button)) && button.isActive && button.currentState) out.buttons|=1u<<i;
				}
			}
		}
	}
	tracking->publish(sample);
}

bool NightfallXrProjectionTest::retire_meteor_image() {
	if (meteor_fence) {
		GLenum result = glClientWaitSync(meteor_fence, 0, 0);
		if (result == GL_TIMEOUT_EXPIRED) { ++meteor_copy_waits; return false; }
		if (result == GL_WAIT_FAILED) { glFinish(); fail("Meteor image sampling fence failed"); }
		glDeleteSync(meteor_fence); meteor_fence = nullptr;
	}
	if (meteor_image != EGL_NO_IMAGE_KHR && meteor_destroy_image) {
		meteor_destroy_image(eglGetCurrentDisplay(), meteor_image); meteor_image = EGL_NO_IMAGE_KHR;
	}
	if (meteor) meteor->release_frame();
	return true;
}

bool NightfallXrProjectionTest::prepare_meteor_image() {
	if (meteor->failed()) { fail(meteor->message().c_str()); return false; }
	if (meteor_fence && !retire_meteor_image()) return false;
	if (meteor_image != EGL_NO_IMAGE_KHR) return true;
	AHardwareBuffer *buffer = nullptr;
	if (!meteor->frame(buffer, meteor_frame)) return false;
	AHardwareBuffer_Desc desc{}; AHardwareBuffer_describe(buffer, &desc);
	if (desc.width != meteor_frame.width || desc.height != meteor_frame.height) { fail("Unexpected Meteor decoded buffer size"); return false; }
	const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
	meteor_image = meteor_create_image(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, meteor_native_buffer(buffer), attrs);
	if (meteor_image == EGL_NO_IMAGE_KHR) { fail("Cannot import Meteor decoded image"); return false; }
	return true;
}

#ifdef NIGHTFALL_PCVR_ALVR
bool NightfallXrProjectionTest::retire_video_image() {
	if (video_fence) {
		GLenum result = glClientWaitSync(video_fence, 0, 0);
		if (result == GL_TIMEOUT_EXPIRED) return false;
		if (result == GL_WAIT_FAILED) {
			// Exceptional recovery only: never permit decoder reuse with unknown GPU ownership.
			glFinish();
			fail("Decoder-copy GPU fence failed");
		}
		glDeleteSync(video_fence); video_fence = nullptr;
	}
	if (video_image != EGL_NO_IMAGE_KHR && destroy_image) {
		destroy_image(eglGetCurrentDisplay(), video_image); video_image = EGL_NO_IMAGE_KHR;
	}
	return true;
}

bool NightfallXrProjectionTest::render_remote() {
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null() || api->get_session() != session_id.load() || eglGetCurrentContext() != creation_context) {
		fail("PCVR session/GLES context changed"); return false;
	}
	if (remote->failed()) { fail(remote->message().c_str()); return false; }
	XrSpace space = reinterpret_cast<XrSpace>(api->get_play_space());
	if (!space) return false;
	// Convert the monotonic clock explicitly; never assume its epoch equals XrTime.
	timespec now{}; clock_gettime(CLOCK_MONOTONIC, &now);
	XrTime xr_now = 0;
	if (XR_FAILED(clock_to_xr(instance, &now, &xr_now)) || xr_now <= 0) { fail("XR clock conversion failed"); return false; }
	XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY};
	XrSpaceLocation head{XR_TYPE_SPACE_LOCATION}; head.next = &velocity;
	XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO}; locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	locate.displayTime = xr_now; locate.space = head_space;
	XrViewState view_state{XR_TYPE_VIEW_STATE}; XrView eyes[2]{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
	uint32_t eye_count = 0;
	if (XR_SUCCEEDED(locate_space(head_space, space, xr_now, &head)) &&
		(head.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) && (head.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) &&
		XR_SUCCEEDED(locate_views(session, &locate, &view_state, 2, &eye_count, eyes)) && eye_count == 2 &&
		(view_state.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) && (view_state.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT)) {
		AlvrDeviceMotion motion{};
		motion.device_id = alvr_path_string_to_id("/user/head");
		motion.pose = {{head.pose.orientation.x, head.pose.orientation.y, head.pose.orientation.z, head.pose.orientation.w},
			{head.pose.position.x, head.pose.position.y, head.pose.position.z}};
		if (velocity.velocityFlags & XR_SPACE_VELOCITY_LINEAR_VALID_BIT) {
			motion.linear_velocity[0] = velocity.linearVelocity.x; motion.linear_velocity[1] = velocity.linearVelocity.y; motion.linear_velocity[2] = velocity.linearVelocity.z;
		}
		if (velocity.velocityFlags & XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) {
			motion.angular_velocity[0] = velocity.angularVelocity.x; motion.angular_velocity[1] = velocity.angularVelocity.y; motion.angular_velocity[2] = velocity.angularVelocity.z;
		}
		AlvrViewParams local[2]{};
		for (int eye = 0; eye < 2; ++eye) {
			const auto &v = eyes[eye];
			local[eye] = {{{v.pose.orientation.x, v.pose.orientation.y, v.pose.orientation.z, v.pose.orientation.w}, {v.pose.position.x, v.pose.position.y, v.pose.position.z}},
				{v.fov.angleLeft, v.fov.angleRight, v.fov.angleUp, v.fov.angleDown}};
		}
		remote->tracking(static_cast<uint64_t>(xr_now), motion, local);
	}
	if (video_fence && !retire_video_image()) return rendered;
	if (video_image == EGL_NO_IMAGE_KHR) {
		void *buffer = nullptr;
		if (!remote->frame(decoded_timestamp, buffer, decoded_views)) return rendered;
		if (!decoded_timestamp || !pcvr_valid_view(decoded_views[0]) || !pcvr_valid_view(decoded_views[1])) {
			fail("Invalid decoded eye pose/FOV metadata"); return false;
		}
		AHardwareBuffer_Desc desc{}; AHardwareBuffer_describe(static_cast<AHardwareBuffer *>(buffer), &desc);
		if (desc.width == 0 || desc.height == 0 || desc.width > 8192 || desc.height > 4096) { fail("Invalid decoded buffer dimensions"); return false; }
		if (!video_program) {
			get_native_buffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
			create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
			destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
			image_to_texture = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
			if (!get_native_buffer || !create_image || !destroy_image || !image_to_texture) { fail("Missing decoder EGL image import functions"); return false; }
			const char *fragment_source = R"GLSL(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES video;
uniform float eye_offset;
in vec2 uv;
out vec4 color;
void main() { color = vec4(texture(video, vec2(eye_offset + uv.x * 0.5, 1.0 - uv.y)).rgb, 1.0); }
)GLSL";
			GLuint vertex = compile_shader(GL_VERTEX_SHADER, VERTEX), fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
			if (!vertex || !fragment) { if (vertex) glDeleteShader(vertex); if (fragment) glDeleteShader(fragment); fail("Cannot compile decoder-copy shader"); return false; }
			video_program = glCreateProgram(); glAttachShader(video_program, vertex); glAttachShader(video_program, fragment); glLinkProgram(video_program);
			glDeleteShader(vertex); glDeleteShader(fragment);
			GLint linked = 0; glGetProgramiv(video_program, GL_LINK_STATUS, &linked);
			if (!linked) { fail("Cannot link decoder-copy shader"); return false; }
			glGenTextures(1, &video_texture);
		}
		const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
		video_image = create_image(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
			get_native_buffer(static_cast<AHardwareBuffer *>(buffer)), attrs);
		if (video_image == EGL_NO_IMAGE_KHR) { fail("Cannot import decoded hardware buffer"); return false; }
	}
	if (!acquired) {
		XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
		if (XR_FAILED(acquire_image(swapchain, &acquire, &acquired_index))) { fail("Cannot acquire remote projection image"); return false; }
		acquired = true; image_waited = false;
	}
	if (!image_waited) {
		XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = 1000000;
		XrResult result = wait_image(swapchain, &wait);
		if (result == XR_TIMEOUT_EXPIRED) return rendered;
		if (result != XR_SUCCESS) { fail("Remote swapchain wait failed"); return false; }
		image_waited = true;
	}
	if (acquired_index >= images.size()) { fail("Invalid remote image index"); return false; }
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, images[acquired_index].image, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { fail("Remote framebuffer incomplete"); return false; }
	glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE); glDisable(GL_SCISSOR_TEST); glDisable(GL_STENCIL_TEST);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE); glUseProgram(video_program); glBindVertexArray(vao);
	glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_EXTERNAL_OES, video_texture);
	image_to_texture(GL_TEXTURE_EXTERNAL_OES, video_image);
	glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glUniform1i(glGetUniformLocation(video_program, "video"), 0);
	for (int eye = 0; eye < 2; ++eye) {
		glViewport(eye * EYE_SIZE, 0, EYE_SIZE, EYE_SIZE);
		glUniform1f(glGetUniformLocation(video_program, "eye_offset"), eye * 0.5f);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		const auto &view = decoded_views[eye];
		projection_views[eye] = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
		projection_views[eye].pose = {{view.pose.orientation.x, view.pose.orientation.y, view.pose.orientation.z, view.pose.orientation.w},
			{view.pose.position[0], view.pose.position[1], view.pose.position[2]}};
		projection_views[eye].fov = {view.fov.left, view.fov.right, view.fov.up, view.fov.down};
		projection_views[eye].subImage = {swapchain, {{eye * EYE_SIZE, 0}, {EYE_SIZE, EYE_SIZE}}, 0};
	}
	video_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	if (!video_fence) { glFinish(); fail("Cannot fence decoded frame copy"); return false; }
	glFlush();
	XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
	if (XR_FAILED(release_image(swapchain, &release))) { fail("Cannot release remote projection image"); return false; }
	acquired = image_waited = false;
	projection = {XR_TYPE_COMPOSITION_LAYER_PROJECTION}; projection.space = space; projection.viewCount = 2; projection.views = projection_views.data();
	remote->submitted(decoded_timestamp, 0); // Queue estimate deliberately omitted until render-frame timing is exposed.
	frames.fetch_add(1); rendered = true;
	if (frames.load() == 1) PCVR_LOG("REMOTE first decoded stereo projection: session=%p buffer=%llu", (void *)session, static_cast<unsigned long long>(decoded_timestamp));
	return true;
}
#endif

void NightfallXrProjectionTest::release_render_resources() {
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (swapchain && api.is_valid() && api->get_session() == session_id.load() && destroy_swapchain) {
		if (acquired && wait_image && release_image) {
			if (!image_waited) {
				XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = 1000000;
				if (wait_image(swapchain, &wait) != XR_SUCCESS) return; // Retry next frame; do not destroy an unwaited image.
				image_waited = true;
			}
			XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
			if (XR_FAILED(release_image(swapchain, &release))) return;
			acquired = false;
		}
		if (XR_FAILED(destroy_swapchain(swapchain))) return;
	}
	swapchain = XR_NULL_HANDLE; images.clear(); acquired = false; image_waited = false; rendered = false;
	if (eglGetCurrentContext() == creation_context) {
		if (meteor_texture) glDeleteTextures(1, &meteor_texture);
		meteor_texture = 0;
#ifdef NIGHTFALL_PCVR_ALVR
		if (video_texture) glDeleteTextures(1, &video_texture);
		if (video_program) glDeleteProgram(video_program);
		video_texture = video_program = 0;
#endif
		if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
		if (vao) glDeleteVertexArrays(1, &vao);
		if (program) glDeleteProgram(program);
	}
	framebuffer = vao = program = 0; creation_context = EGL_NO_CONTEXT;
	for(auto &hand:controller_spaces) for(auto &controller_space:hand) {
		if(controller_space && api.is_valid() && api->get_session()==session_id.load() && destroy_space) destroy_space(controller_space);
		controller_space=XR_NULL_HANDLE;
	}
	controller_trigger=controller_squeeze=XR_NULL_HANDLE; controller_float=nullptr;
	if(controller_haptic && controller_stop_haptic && api.is_valid() && api->get_session()==session_id.load()) for(unsigned hand=0;hand<2;++hand) {
		XrHapticActionInfo info{XR_TYPE_HAPTIC_ACTION_INFO}; info.action=controller_haptic; info.subactionPath=controller_paths[hand];
		controller_stop_haptic(session,&info);
	}
	controller_haptic=XR_NULL_HANDLE; controller_apply_haptic=nullptr; controller_stop_haptic=nullptr;
	controller_stick=XR_NULL_HANDLE; controller_bool=nullptr; controller_vector=nullptr;
	for(auto &button:controller_buttons) button=XR_NULL_HANDLE;
	if (head_space && api.is_valid() && api->get_session() == session_id.load() && destroy_space) destroy_space(head_space);
	head_space = XR_NULL_HANDLE;
	if (tracking_space && api.is_valid() && api->get_session() == session_id.load() && destroy_space) destroy_space(tracking_space);
	tracking_space = XR_NULL_HANDLE;
	PCVR_LOG("synthetic resources retired; session unchanged=%p", (void *)session);
}
#endif

int32_t NightfallXrProjectionTest::_get_composition_layer_count() {
#ifdef __ANDROID__
	int current = state.load();
	if (current == IDLE || current == FAILED) return 0;
	ScopedGLState saved;
	if (current == STOPPING) {
		rendered = false;
		if (meteor_mode && !retire_meteor_image()) return 0;
#ifdef NIGHTFALL_PCVR_ALVR
		if (remote_mode && !retire_video_image()) return 0;
#endif
		if (retire_frames < 0) retire_frames = 3;
		if (retire_frames-- > 0) return 0;
		release_render_resources();
		if (!swapchain) {
			if (meteor_mode) {
				if (!meteor_draining) { meteor->stop_after_gpu_drain(); tracking->request_stop(); meteor_draining = true; }
				if (!meteor->idle() || !tracking->idle()) return 0;
				meteor_mode = false;
			}
#ifdef NIGHTFALL_PCVR_ALVR
			if (remote_mode) {
				if (!remote_draining) { remote->stop_after_gpu_drain(); remote_draining = true; }
				if (!remote->idle()) return 0;
				remote_mode = false;
			}
#endif
			retire_frames = -1; state.store(IDLE);
		}
		return 0;
	}
	if (current == STARTING) {
		if (!initialize_render_resources()) return 0;
		int expected = STARTING;
		state.compare_exchange_strong(expected, RUNNING);
	}
	if (state.load() != RUNNING) return 0;
#ifdef NIGHTFALL_PCVR_ALVR
	if (remote_mode) return render_remote() ? 1 : 0;
#endif
	return render_scene() ? 1 : 0;
#else
	return 0;
#endif
}

uint64_t NightfallXrProjectionTest::_get_composition_layer(int32_t p_index) {
#ifdef __ANDROID__
	if (p_index == 0 && rendered && state.load() == RUNNING) return reinterpret_cast<uint64_t>(&projection);
#endif
	return 0;
}

int32_t NightfallXrProjectionTest::_get_composition_layer_order(int32_t p_index) { return 0; }
}
