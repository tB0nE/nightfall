#pragma once

#ifdef __ANDROID__
#include <time.h>
#endif
#include "fast_xr_renderer.h"
#include <array>
#include <atomic>
#include <mutex>
#include <string>
#include "pcvr_alvr_client.h"
#include <memory>
#ifdef __ANDROID__
#include <EGL/eglext.h>
#include <GLES2/gl2ext.h>
#include <time.h>
#endif

namespace godot {

// Developer-only synthetic scene. Uses the inherited provider registration
// plumbing, never the video's quads and never a second OpenXR frame loop.
class NightfallXrProjectionTest : public NightfallXrRenderer {
	GDCLASS(NightfallXrProjectionTest, NightfallXrRenderer)
public:
	bool start_test();
	bool start_stream();
	bool stream_available() const;
	Dictionary _get_requested_extensions(uint64_t p_xr_version) override;
	void stop_test();
	Dictionary get_test_status() const;
	int32_t _get_composition_layer_count() override;
	uint64_t _get_composition_layer(int32_t p_index) override;
	int32_t _get_composition_layer_order(int32_t p_index) override;
protected:
	static void _bind_methods();
private:
	enum State { IDLE, STARTING, RUNNING, STOPPING, FAILED };
	std::atomic<int> state{IDLE};
	std::atomic<uint64_t> frames{0};
	std::atomic<uint64_t> session_id{0};
	mutable std::mutex error_mutex;
	std::string error;
	void fail(const char *message);
#ifdef __ANDROID__
	static constexpr int EYE_SIZE = 1024;
	XrInstance instance = XR_NULL_HANDLE;
	XrSession session = XR_NULL_HANDLE;
	XrSwapchain swapchain = XR_NULL_HANDLE;
	std::vector<XrSwapchainImageOpenGLESKHR> images;
	std::array<XrCompositionLayerProjectionView, 2> projection_views{};
	XrCompositionLayerProjection projection{};
	EGLContext creation_context = EGL_NO_CONTEXT;
	GLuint program = 0, framebuffer = 0, vao = 0;
	bool acquired = false, image_waited = false, rendered = false;
	uint32_t acquired_index = 0;
	int retire_frames = -1;
	PFN_xrEnumerateSwapchainFormats enum_formats = nullptr;
	PFN_xrCreateSwapchain create_swapchain = nullptr;
	PFN_xrDestroySwapchain destroy_swapchain = nullptr;
	PFN_xrEnumerateSwapchainImages enum_images = nullptr;
	PFN_xrAcquireSwapchainImage acquire_image = nullptr;
	PFN_xrWaitSwapchainImage wait_image = nullptr;
	PFN_xrReleaseSwapchainImage release_image = nullptr;
	PFN_xrLocateViews locate_views = nullptr;
	bool initialize_render_resources();
	bool render_scene();
	void release_render_resources();
#ifdef NIGHTFALL_PCVR_ALVR
	inline static bool clock_extension = false;
	std::unique_ptr<PCVRAlvrClient> remote;
	bool remote_mode = false, remote_draining = false;
	XrSpace head_space = XR_NULL_HANDLE;
	PFN_xrCreateReferenceSpace create_space = nullptr;
	PFN_xrDestroySpace destroy_space = nullptr;
	PFN_xrLocateSpace locate_space = nullptr;
	PFN_xrConvertTimespecTimeToTimeKHR clock_to_xr = nullptr;
	GLuint video_program = 0, video_texture = 0;
	EGLImageKHR video_image = EGL_NO_IMAGE_KHR;
	GLsync video_fence = nullptr;
	AlvrViewParams decoded_views[2]{};
	uint64_t decoded_timestamp = 0;
	PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC get_native_buffer = nullptr;
	PFNEGLCREATEIMAGEKHRPROC create_image = nullptr;
	PFNEGLDESTROYIMAGEKHRPROC destroy_image = nullptr;
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_to_texture = nullptr;
	bool render_remote();
	bool retire_video_image();
#endif
#endif
};
}
