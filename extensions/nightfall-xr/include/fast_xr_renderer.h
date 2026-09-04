#pragma once

#include <godot_cpp/classes/open_xr_extension_wrapper_extension.hpp>
#include <godot_cpp/classes/open_xr_interaction_profile_metadata.hpp>
#include <godot_cpp/classes/open_xrapi_extension.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <vector>

#ifdef __ANDROID__
#include <jni.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#define XR_USE_PLATFORM_ANDROID
#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#endif

namespace godot {

// Bypasses Godot's OpenXRCompositionLayerQuad (one full-res eye viewport per
// layer, no sub_image offset control) and drives OpenXR directly, porting
// moonlight-xr's xr_renderer.c: one double-wide swapchain, two quad layers
// each reading half of it. See README.md.
//
// Godot's own OpenXR module calls xrWaitFrame/xrBeginFrame/xrEndFrame on the
// session every frame regardless (modules/openxr/openxr_api.cpp process()/
// pre_render()/end_frame()) -- a second, independent caller of those on the
// same session is a spec violation and was the actual reason an earlier
// version of this class (calling them itself) could never have worked. The
// correct hook is OpenXRExtensionWrapperExtension: _on_pre_render() runs
// before Godot collects composition layers (do the swapchain acquire/warp
// draw/release here), and _get_composition_layer_count()/_get_composition_layer()
// hand Godot our pre-built XrCompositionLayerQuads to fold into its own
// single xrEndFrame call. register_composition_layer_provider() (via
// get_openxr_api(), itself always available -- no registration precondition)
// is what actually wires those two virtuals into end_frame()'s layer
// collection; the separate register_extension_wrapper() call some GDExtension
// examples use is a different, unrelated list and NOT what feeds end_frame().
class NightfallXrRenderer : public OpenXRExtensionWrapperExtension {
	GDCLASS(NightfallXrRenderer, OpenXRExtensionWrapperExtension)

public:
	NightfallXrRenderer();
	~NightfallXrRenderer();

	// Fetches the handles, resolves swapchain function pointers, and calls
	// register_composition_layer_provider() -- must happen before the OpenXR
	// session starts running (OpenXRAPI::running goes true in on_state_ready(),
	// which fires the moment the app becomes the active XR app, well before
	// stream negotiation with the PC completes and video dimensions are known
	// -- register_composition_layer_provider() has a hard guard against
	// registering while running). Call this once, early, from _ready().
	bool register_provider();
	// Creates the double-wide swapchain once the stream has negotiated a
	// resolution; call once register_provider() has succeeded and actual
	// video dimensions are known (register_provider() itself doesn't need
	// them). OpenXR permits exactly one XrSession per application, so this
	// reuses Godot's already-created instance/session rather than creating
	// a second one.
	bool start(int p_video_width, int p_video_height);
	void stop_stream();
	void shutdown();
	void stop(); // Compatibility alias for shutdown().
	bool is_started() const;
	bool has_rendered_frame() const;
	bool supports_cylinder() const;
	void set_geometry(const Transform3D &p_transform, float p_width, float p_height,
			int p_curvature, float p_radius, float p_central_angle, int p_sort_order,
			bool p_bezel_enabled);

	// Called every GDScript _process() tick with the latest frame's
	// parameters; actual GL rendering happens later, in _on_pre_render().
	// oes_texture_id: the decoder's external OES texture (GL_TEXTURE_EXTERNAL_OES).
	// depth_texture_id: 0 disables the disparity shift (mono passthrough);
	// otherwise a GL_TEXTURE_2D holding pure depth in its RED channel, at the
	// depth model's native resolution (DepthEstimatorModule's raw MiDaS output --
	// Image.FORMAT_L8, single channel, NOT xr_renderer.c's combined
	// RGB-guide+alpha-depth layout, which our depth pipeline never produces).
	// depth_guide_texture_id: a same-resolution GL_TEXTURE_2D holding the
	// downscaled colour frame the depth model itself saw (TextureUploader's
	// native capture texture), sampled in .rgb for the joint-bilateral
	// upsample's edge-preserving weight -- see run_upsample().
	// oes_fence: a GLsync (cast to uint64_t) signaling that this frame's OES
	// texture write has completed on Godot's context, or 0 if none -- see
	// Ownership transfers in: consumed
	// (glWaitSync + glDeleteSync) exactly once, in render_video_frame().
	void submit_frame(bool p_new_frame, uint32_t p_oes_texture_id, uint32_t p_depth_texture_id,
			uint32_t p_depth_guide_texture_id, PackedFloat32Array p_tex_matrix, float p_distance,
			float p_quad_width, bool p_head_locked, float p_separation, bool p_eye_swap,
			bool p_passthrough, uint64_t p_oes_fence, int p_stereo_mode = 0,
			uint64_t p_depth_revision = 0);

	void upload_overlay(PackedByteArray p_pixels, int p_width, int p_height);
	void set_overlay_visible(bool p_visible);

	// Debug: force the warp shader to output solid magenta instead of
	// sampling the OES texture, to isolate "can the composition-layer
	// pipeline show anything at all" from "is the OES sample broken".
	void set_debug_solid_color(bool p_enabled);

	float get_warp_gpu_ms();

	// OpenXRExtensionWrapper virtuals (see openxr_extension_wrapper.h). Must
	// stay public -- godot-cpp's GDCLASS/register_virtuals machinery takes
	// their address via &T::method, which requires public access.
	//
	// OpenXRExtensionWrapperExtension itself declares none of these (it's an
	// empty GDEXTENSION_CLASS alias one level up from OpenXRExtensionWrapper),
	// and this generator's homemade override-detection (register_virtuals'
	// is_same_v<decltype(&B::x), decltype(&T::x)> check, not the usual
	// GDVIRTUAL-macro machinery most other extendable classes use) fails to
	// find real definitions for that middle class's inherited-but-unoverridden
	// slots when a third level (us) is added -- linker ends up looking for
	// symbols like OpenXRExtensionWrapperExtension::_get_requested_extensions()
	// that were never compiled anywhere. Explicitly declaring + defining every
	// virtual here (trivial pass-through to the real OpenXRExtensionWrapper
	// implementation) sidesteps the gap; only _on_pre_render/_get_composition_layer*
	// actually do anything of ours.
	Dictionary _get_requested_extensions(uint64_t p_xr_version) override;
	uint64_t _set_system_properties_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_instance_create_info_and_get_next_pointer(uint64_t p_xr_version, void *p_next_pointer) override;
	uint64_t _set_session_create_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_swapchain_create_info_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_hand_joint_locations_and_get_next_pointer(int32_t p_hand_index, void *p_next_pointer) override;
	uint64_t _set_projection_views_and_get_next_pointer(int32_t p_view_index, void *p_next_pointer) override;
	uint64_t _set_frame_wait_info_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_frame_end_info_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_projection_layer_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_view_locate_info_and_get_next_pointer(void *p_next_pointer) override;
	uint64_t _set_reference_space_create_info_and_get_next_pointer(int32_t p_reference_space_type, void *p_next_pointer) override;
	void _prepare_view_configuration(int32_t p_view_count) override;
	uint64_t _set_view_configuration_and_get_next_pointer(uint32_t p_view, void *p_next_pointer) override;
	void _print_view_configuration_info(int32_t p_view) const override;
	PackedStringArray _get_suggested_tracker_names() override;
	void _on_register_metadata(OpenXRInteractionProfileMetadata *p_interaction_profile_metadata) override;
	void _on_before_instance_created() override;
	void _on_instance_created(uint64_t p_instance) override;
	void _on_instance_destroyed() override;
	void _on_session_created(uint64_t p_session) override;
	void _on_process() override;
	void _on_sync_actions() override;
	void _on_main_swapchains_created() override;
	void _on_pre_draw_viewport(const RID &p_viewport) override;
	void _on_post_draw_viewport(const RID &p_viewport) override;
	void _on_session_destroyed() override;
	void _on_state_idle() override;
	void _on_state_ready() override;
	void _on_state_synchronized() override;
	void _on_state_visible() override;
	void _on_state_focused() override;
	void _on_state_stopping() override;
	void _on_state_loss_pending() override;
	void _on_state_exiting() override;
	bool _on_event_polled(const void *p_event) override;
	uint64_t _set_viewport_composition_layer_and_get_next_pointer(const void *p_layer, const Dictionary &p_property_values, void *p_next_pointer) override;
	TypedArray<Dictionary> _get_viewport_composition_layer_extension_properties() override;
	Dictionary _get_viewport_composition_layer_extension_property_defaults() override;
	void _on_viewport_composition_layer_destroyed(const void *p_layer) override;
	uint64_t _set_android_surface_swapchain_create_info_and_get_next_pointer(const Dictionary &p_property_values, void *p_next_pointer) override;

#ifdef __ANDROID__
	void _on_pre_render() override;
	int32_t _get_composition_layer_count() override;
	uint64_t _get_composition_layer(int32_t p_index) override;
	int32_t _get_composition_layer_order(int32_t p_index) override;
#else
	void _on_pre_render() override {}
	int32_t _get_composition_layer_count() override { return 0; }
	uint64_t _get_composition_layer(int32_t p_index) override { return 0; }
	int32_t _get_composition_layer_order(int32_t p_index) override { return 0; }
#endif

protected:
	static void _bind_methods();

private:
#ifdef __ANDROID__
	// Own EGL context, sharing Godot's GLES render-thread context's share
	// group (not a fully independent context): the OES decoder texture and
	// any Godot-created textures we sample (oes/depth ids passed into
	// submit_frame) must resolve in both contexts, which only holds within
	// one share group. See README.md.
	EGLDisplay egl_display = EGL_NO_DISPLAY;
	EGLContext egl_context = EGL_NO_CONTEXT;
	EGLSurface egl_pbuffer = EGL_NO_SURFACE;
	EGLConfig egl_config_placeholder = nullptr;

	// Godot's own context/surface, as seen once in init_egl() -- used only
	// for the immediate restore at the end of start() (contemporaneous, not
	// stale). Every OTHER place that switches to our own context and needs
	// to switch back (maybe_render_pending_frame(), upload_overlay()) must
	// re-query eglGetCurrentContext()/eglGetCurrentSurface() fresh instead of
	// reusing these -- Godot recreates its EGLSurface (though not its
	// EGLContext, preserved via GodotGLRenderView's
	// setPreserveEGLContextOnPause(true)) on ordinary pause/resume-style
	// transitions, which a Quest headset can trigger mid-session (proximity
	// sensor, Guardian, system overlays) even while continuously worn. A
	// cached surface handle restored after one of those goes stale and
	// produces EGL_BAD_SURFACE on Godot's next eglSwapBuffers -- confirmed
	// this exact failure on-device.
	EGLContext godot_context = EGL_NO_CONTEXT;
	EGLSurface godot_draw_surface = EGL_NO_SURFACE;
	EGLSurface godot_read_surface = EGL_NO_SURFACE;

	// Diagnostics only: last surface seen by maybe_render_pending_frame()'s
	// fresh query, to log when Godot's surface actually changes underneath
	// us.
	EGLSurface last_seen_draw_surface = EGL_NO_SURFACE;
	EGLSurface last_seen_read_surface = EGL_NO_SURFACE;

	// Reused from Godot, never created or destroyed by this class.
	XrInstance xr_instance = XR_NULL_HANDLE;
	XrSession xr_session = XR_NULL_HANDLE;
	XrSystemId xr_system_id = XR_NULL_SYSTEM_ID;
	XrSpace xr_space = XR_NULL_HANDLE;

	XrSwapchain swapchain = XR_NULL_HANDLE;
	uint32_t swapchain_image_count = 0;
	XrSwapchainImageOpenGLESKHR *swapchain_images = nullptr;
	int64_t swapchain_format = 0;

	XrSwapchain overlay_swapchain = XR_NULL_HANDLE;
	uint32_t overlay_image_count = 0;
	XrSwapchainImageOpenGLESKHR *overlay_images = nullptr;
	bool overlay_has_content = false;
	bool overlay_visible = false;

	int video_width = 0;
	int video_height = 0;
	int output_width = 0;
	int output_height = 0;

	GLuint warp_program = 0;
	GLint u_texmatrix = -1, u_disparity = -1, u_tint = -1, u_occlusion = -1;
	GLint u_eye_index = -1, u_convergence = -1, u_disp_texels = -1;
	GLint u_low_res_width = -1, u_frame_width = -1;
	GLint u_debug_solid = -1;
	GLint u_stereo_mode = -1;
	GLuint warp_fbo = 0;
	bool debug_solid_color = false;

	GLuint upsample_program = 0;
	GLint u_upsample_texmatrix = -1, u_upsample_sigma = -1, u_upsample_sharp = -1;
	GLint u_upsample_depth_guide = -1;
	GLuint upsample_texture = 0, upsample_fbo = 0;
	int upsample_width = 0, upsample_height = 0;

	GLuint offset_program = 0;
	GLint u_offset_disp = -1, u_offset_conv = -1;
	GLuint offset_texture = 0, offset_fbo = 0;

	bool srgb_write_control = false;
	bool cylinder_supported = false;
	bool ever_rendered = false;
	bool registered_as_layer_provider = false;

	// Latest params from submit_frame(), consumed by _on_pre_render().
	bool pending_new_frame = false;
	uint32_t pending_oes_texture_id = 0;
	uint32_t pending_depth_texture_id = 0;
	uint32_t pending_depth_guide_texture_id = 0;
	// GLsync (as uint64_t across the GDExtension boundary) signaling that
	// TextureUploader's updateTexImage() write to pending_oes_texture_id has
	// completed on Godot's context -- consumed (glWaitSync + glDeleteSync)
	// at the top of render_video_frame(), before sampling that texture from
	// our own, different EGL context.
	uint64_t pending_oes_fence = 0;
	std::vector<uint64_t> superseded_oes_fences;
	float pending_tex_matrix[16]{};
	float pending_distance = 3.0f;
	float pending_quad_width = 3.0f;
	bool pending_head_locked = false;
	float pending_separation = 0.0f;
	bool pending_eye_swap = false;
	bool pending_passthrough = false;
	int pending_stereo_mode = 0;
	uint64_t pending_depth_revision = 0;
	uint64_t rendered_depth_revision = UINT64_MAX;
	float rendered_depth_separation = -1.0f;
	bool depth_cache_valid = false;
	Transform3D pending_transform;
	float pending_width = 3.0f;
	float pending_height = 1.6875f;
	int pending_curvature = 0;
	float pending_radius = 4.0f;
	float pending_central_angle = 0.75f;
	int pending_sort_order = 1;
	bool pending_bezel_enabled = true;

	// Rebuilt each _get_composition_layer() call from the pending_* pose
	// params (cheap struct fills); must be member storage since Godot reads
	// the returned pointer back out after this call returns.
	XrCompositionLayerQuad quad_layers[2]{};
	XrCompositionLayerCylinderKHR cylinder_layers[2]{};
	XrCompositionLayerQuad overlay_layer{};

	// Resolved via get_openxr_api()->get_instance_proc_addr(), matching how
	// Godot's own OpenXR module resolves every entry point (never linking
	// libopenxr_loader.so directly) -- see modules/openxr/openxr_api.cpp.
	PFN_xrEnumerateInstanceExtensionProperties pfn_xrEnumerateInstanceExtensionProperties = nullptr;
	PFN_xrEnumerateSwapchainFormats pfn_xrEnumerateSwapchainFormats = nullptr;
	PFN_xrCreateSwapchain pfn_xrCreateSwapchain = nullptr;
	PFN_xrDestroySwapchain pfn_xrDestroySwapchain = nullptr;
	PFN_xrEnumerateSwapchainImages pfn_xrEnumerateSwapchainImages = nullptr;
	PFN_xrAcquireSwapchainImage pfn_xrAcquireSwapchainImage = nullptr;
	PFN_xrWaitSwapchainImage pfn_xrWaitSwapchainImage = nullptr;
	PFN_xrReleaseSwapchainImage pfn_xrReleaseSwapchainImage = nullptr;

	bool resolve_functions();
	bool init_egl();
	bool init_swapchain();
	bool init_gl();
	void maybe_render_pending_frame();
	void render_video_frame(uint32_t p_oes_texture_id, uint32_t p_depth_texture_id,
			uint32_t p_depth_guide_texture_id, const float *p_tex_matrix, float p_separation,
			bool p_occluding);
	void run_upsample(uint32_t p_oes_texture_id, uint32_t p_depth_texture_id,
			uint32_t p_depth_guide_texture_id, const float *p_tex_matrix);
	void run_offset_search(float p_separation);
#endif
};

} // namespace godot
