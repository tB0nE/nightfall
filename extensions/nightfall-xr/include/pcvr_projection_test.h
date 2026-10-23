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
#include "pcvr_meteor_receiver.h"
#include "pcvr_meteor_tracking_endpoint.h"
#include "pcvr_presentation_gate.h"
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
	bool start_meteor_test();
	bool start_meteor_standby();
	bool activate_meteor_projection();
	bool stream_available() const;
	Dictionary _get_requested_extensions(uint64_t p_xr_version) override;
	void _on_instance_created(uint64_t p_instance) override;
	void _on_instance_destroyed() override;
	void stop_test();
	Dictionary get_test_status() const;
	void set_wristwatch(PackedFloat32Array p_state);
	void set_workspace_input_focus(bool p_focused);
	bool set_meteor_eye_size(int p_size);
	void set_pcvr_post_processing(int p_sharpen, int p_sampling);
	PackedFloat32Array get_wristwatch_tracking();
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
	std::atomic<int> requested_eye_size{1024}, projection_eye_size{1024};
	std::atomic<int> pcvr_sharpen{0}, pcvr_sampling{0};
	// Godot writes this through the CORE wrapper's extension-request pointer.
	// The later scene-owned projection provider must read the same storage.
	inline static bool pcvr_layer_settings_supported=false;
	std::atomic<uint64_t> meteor_copy_waits{0}, meteor_swapchain_waits{0}, meteor_reuses{0};
	mutable std::mutex error_mutex;
	std::string error;
	void fail(const char *message);
	bool start_meteor_mode(bool present_immediately);
	PCVRPresentationGate meteor_presentation;
	std::mutex watch_mutex;
	std::array<float, 15> watch_state{};
	std::array<float, 22> watch_tracking{};
	bool watch_tracking_valid=false;
	std::atomic<bool> workspace_focus{false}, workspace_wait_release{false};
#ifdef __ANDROID__
	static constexpr int EYE_SIZE = 1024;
	XrInstance instance = XR_NULL_HANDLE;
	XrSession session = XR_NULL_HANDLE;
	XrSwapchain swapchain = XR_NULL_HANDLE;
	std::vector<XrSwapchainImageOpenGLESKHR> images;
	std::array<XrCompositionLayerProjectionView, 2> projection_views{};
	XrCompositionLayerProjection projection{};
	XrCompositionLayerSettingsFB pcvr_layer_settings{XR_TYPE_COMPOSITION_LAYER_SETTINGS_FB};
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
	std::unique_ptr<PCVRMeteorReceiver> meteor;
	bool meteor_mode = false, meteor_draining = false;
	GLuint meteor_texture = 0;
	EGLImageKHR meteor_image = EGL_NO_IMAGE_KHR;
	GLsync meteor_fence = nullptr;
	MeteorXrFrame meteor_frame;
	PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC meteor_native_buffer = nullptr;
	PFNEGLCREATEIMAGEKHRPROC meteor_create_image = nullptr;
	PFNEGLDESTROYIMAGEKHRPROC meteor_destroy_image = nullptr;
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC meteor_image_to_texture = nullptr;
	bool prepare_meteor_image();
	bool retire_meteor_image();
	inline static bool clock_extension = false;
	XrSpace head_space = XR_NULL_HANDLE;
	PFN_xrCreateReferenceSpace create_space = nullptr;
	PFN_xrDestroySpace destroy_space = nullptr;
	PFN_xrLocateSpace locate_space = nullptr;
	PFN_xrConvertTimespecTimeToTimeKHR clock_to_xr = nullptr;
	std::unique_ptr<MeteorTrackingEndpoint> tracking;
	uint64_t tracking_epoch = 0;
	XrSpace tracking_space = XR_NULL_HANDLE;
	void publish_meteor_tracking();
	XrSpace controller_spaces[2][2]{};
	XrPath controller_paths[2]{};
	XrAction controller_trigger=XR_NULL_HANDLE,controller_squeeze=XR_NULL_HANDLE;
	PFN_xrGetActionStateFloat controller_float=nullptr;
	PFN_xrGetActionStateBoolean controller_bool=nullptr;
	PFN_xrGetActionStateVector2f controller_vector=nullptr;
	XrAction controller_stick=XR_NULL_HANDLE;
	XrAction controller_buttons[7]{};
	XrAction controller_haptic=XR_NULL_HANDLE;
	PFN_xrApplyHapticFeedback controller_apply_haptic=nullptr;
	PFN_xrStopHapticFeedback controller_stop_haptic=nullptr;
	void initialize_meteor_controllers();
#ifdef NIGHTFALL_PCVR_ALVR
	std::unique_ptr<PCVRAlvrClient> remote;
	bool remote_mode = false, remote_draining = false;
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
