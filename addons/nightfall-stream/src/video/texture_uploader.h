#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/classes/mutex.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <vector>

#ifdef __ANDROID__
#include <media/NdkImage.h>
#include <android/native_window.h>
#endif

extern "C" {
#include <libavutil/pixfmt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/frame.h>
}

namespace godot {

class TextureUploader : public RefCounted {
    GDCLASS(TextureUploader, RefCounted);

public:
    TextureUploader();
    ~TextureUploader();

    void setup(int width, int height, int format, int colorspace, int color_range, int color_transfer = 0);
    void setup_bgra(int width, int height);
    void ensure_shader_material();
    void set_active(bool nv12); // Main-thread flags for shader conversion + NV12 mode
    // 0 = SDR, 1 = PQ/ST 2084, 2 = HLG. Atomic because decoder/protocol
    // callbacks update it while the main thread feeds the native XR renderer.
    int get_color_transfer_type() const { return current_color_transfer_type_.load(); }
    void set_texture_from_native_rid(RID p_tex_rid, int p_width, int p_height); // Zero-copy GPU texture import
    void cleanup();
    void update_from_frame(AVFrame *frame);
    void update_from_raw_nv12(int width, int height, const uint8_t *data, uint32_t y_size, uint32_t uv_size);
    void update_from_raw_bgra(int width, int height, const uint8_t *data, uint32_t data_size);
#ifdef __ANDROID__
    void update_from_android_image(AImage *image, int width, int height);
    void update_from_android_rgba_image(AImage *image, int width, int height);
    ANativeWindow *create_android_gles_decoder_surface(int width, int height);
    void update_android_gles_external_texture();
#endif
    bool supports_native_depth_capture();
    void request_native_depth_capture(int width, int height);
    PackedByteArray consume_native_depth_capture();
    void update_colorspace(int colorspace, int color_range, int color_transfer = 0);
    // Protocol-level transfer metadata for native Android decoder paths which
    // never expose an AVFrame (GLES SurfaceTexture and Vulkan AHB compute).
    // Persisted independently from the material so it survives setup races.
    void update_color_transfer(int color_transfer);
    void perform_gpu_update();

    Ref<ShaderMaterial> get_shader_material() const { return shader_material; }
    bool consume_new_frame();

#ifdef __ANDROID__
    // Raw decoder OES texture + its SurfaceTexture transform, for nightfall-xr's
    // native OpenXR swapchain path to sample directly (matching moonlight-xr)
    // instead of going through the RGBA blit this class does for the
    // SubViewport/CompositionLayerQuad path. Both textures live in the same
    // EGL share group, so the raw GLuint is valid across the GDExtension
    // boundary as long as the caller is on Godot's GL thread.
    unsigned int get_oes_texture_id() const { return gles_oes_texture_; }
    PackedFloat32Array get_oes_transform_matrix() const;

    // A GLsync (as uint64_t) signaling that this frame's updateTexImage()
    // write to gles_oes_texture_ has completed on Godot's context. Shared
    // objects' NAMES (textures, syncs) are valid across a share group, but
    // content visibility across contexts is not guaranteed without explicit
    // sync -- nightfall-xr samples gles_oes_texture_ from its own, different EGL
    // context, so it must wait on this before reading. Ownership transfers
    // out: caller consumes exactly once (glWaitSync + glDeleteSync). Returns
    // 0 if no fence is pending (e.g. not yet rendered a frame).
    uint64_t consume_oes_ready_fence();
    void set_native_direct_mode(bool enabled) { native_direct_mode_.store(enabled); }
    unsigned int get_native_depth_guide_texture_id() const { return gles_depth_texture_; }
#endif

protected:
    static void _bind_methods();

private:
    void _render_thread_setup(int width, int height, int format, int colorspace, int color_range, int color_transfer);
    void _render_thread_setup_bgra(int width, int height);
    void _render_thread_import_native(RID p_tex_rid, int p_width, int p_height);
    void _render_thread_cleanup();
    void _render_thread_apply_color_transfer();
    void _render_thread_import_native_rt(); // Zero-arg version for call_on_render_thread (no .bind RID issues)

    RenderingDevice *rd = nullptr;
    RID rd_texture_rid[3];
    RID rs_texture_rid[3];
    Ref<Texture2DRD> rd_texture_wrappers[3];
    // Pending state for _render_thread_import_native_rt
    RID pending_native_rid_;
    int pending_native_width_ = 0, pending_native_height_ = 0;
    // _render_thread_import_native_rt() runs once per decoded frame (the H264
    // hw_frames_ctx/"Tier1" AHardwareBuffer path) and used to free the PREVIOUS
    // frame's imported texture/wrapper immediately upon importing the next one.
    // The OpenXR compositor reads tex_y on its own frame timeline, decoupled from
    // when we happen to re-point the shader parameter, so freeing that
    // immediately-superseded texture had no guarantee the compositor was actually
    // done with it yet - confirmed via Vulkan validation (VUID-vkDestroyImage-image-01000)
    // firing continuously during normal H264 playback, eventually stalling decode
    // entirely. Deferring the free until a texture has been superseded by several
    // newer frames (not just the very next one) gives the compositor real slack
    // without leaking unboundedly on this per-frame path.
    struct PendingNativeTexFree {
        RID rd_tex;
        RID rs_tex;
    };
    std::deque<PendingNativeTexFree> pending_native_tex_free_;
    static const int NATIVE_TEX_FREE_DELAY_FRAMES = 3;
    PackedByteArray rd_texture_buffers[3];

    Ref<Image> plane_images[3];
    Ref<ImageTexture> plane_textures[3];
    PackedByteArray plane_buffers[3];

    Ref<ShaderMaterial> shader_material;
    Ref<Shader> yuv_shader;
    bool use_shader_conversion = false;
    bool is_nv12 = false;
    std::atomic<bool> pending_gpu_update{false};
    std::atomic<bool> new_frame_available_{false};
    std::atomic<int> current_color_transfer_type_{0};
    Ref<Mutex> texture_mutex;

    int current_width = 0;
    int current_height = 0;

#ifdef __ANDROID__
    void _render_thread_create_android_gles_surface();
    void _render_thread_update_android_gles_texture();
    void _render_thread_destroy_android_gles_surface();
    bool _render_thread_ensure_depth_capture(int width, int height);
    void _render_thread_poll_depth_capture();
    void _render_thread_issue_depth_capture(const float *matrix, int width, int height);
    mutable std::mutex gles_surface_mutex_;
    std::condition_variable gles_surface_cv_;
    bool gles_surface_ready_ = false;
    bool gles_surface_failed_ = false;
    int gles_surface_width_ = 0;
    int gles_surface_height_ = 0;
    ANativeWindow *gles_decoder_window_ = nullptr;
    void *gles_surface_texture_java_ = nullptr;
    void *gles_transform_matrix_java_ = nullptr;
    void *gles_update_method_ = nullptr;
    void *gles_transform_method_ = nullptr;
    void *gles_release_method_ = nullptr;
    unsigned int gles_oes_texture_ = 0;
    // Cached every render-thread blit (texture_uploader.cpp), read back by
    // get_oes_transform_matrix() from GDScript. gles_surface_mutex_ already
    // guards the surface's readiness/lifetime; reuse it for this too rather
    // than adding a second lock around a single 16-float array.
    float gles_last_transform_matrix_[16]{};
    // Set right after updateTexImage() succeeds; consumed (and cleared) by
    // consume_oes_ready_fence(). Guarded by gles_surface_mutex_ like the
    // transform matrix above.
    void *gles_oes_ready_fence_ = nullptr;
    // When the native OpenXR composition provider is presenting the OES
    // decoder texture directly, do not also pay for the legacy full-size
    // OES->RGBA copy. The small depth-capture draw/PBO remains active.
    std::atomic<bool> native_direct_mode_{false};
    unsigned int gles_output_texture_ = 0;
    unsigned int gles_fbo_ = 0;
    unsigned int gles_blit_program_ = 0;
    int gles_video_uniform_ = -1;
    int gles_matrix_uniform_ = -1;
    bool gles_update_queued_ = false;

    // The Godot Image::get_data()/Texture2D::get_image() route flushes the
    // entire GLES render queue before returning. At a 20 Hz depth cadence it
    // was blocking the XR frame loop for 13-21 ms per capture. Capture the
    // decoder's external texture on the render thread instead and stage the
    // readback through a small ring of pixel-buffer objects. Fences are
    // polled with a zero timeout on later decoded frames, so XR submission is
    // never made to wait for the depth pixels.
    static constexpr int GLES_DEPTH_PBO_COUNT = 3;
    unsigned int gles_depth_texture_ = 0;
    unsigned int gles_depth_fbo_ = 0;
    unsigned int gles_depth_pbos_[GLES_DEPTH_PBO_COUNT]{};
    void *gles_depth_fences_[GLES_DEPTH_PBO_COUNT]{};
    int gles_depth_capture_width_ = 0;
    int gles_depth_capture_height_ = 0;
    int gles_depth_next_pbo_ = 0;
    std::atomic<bool> gles_depth_capture_requested_{false};
    std::atomic<int> gles_depth_requested_width_{256};
    std::atomic<int> gles_depth_requested_height_{256};
    mutable std::mutex gles_depth_result_mutex_;
    std::vector<uint8_t> gles_depth_result_;
    bool gles_depth_result_ready_ = false;
#endif
};

} // namespace godot
