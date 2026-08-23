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
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>

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

    void setup(int width, int height, int format, int colorspace, int color_range);
    void setup_bgra(int width, int height);
    void ensure_shader_material();
    void set_active(bool nv12); // Main-thread flags for shader conversion + NV12 mode
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
    void update_colorspace(int colorspace, int color_range);
    void perform_gpu_update();

    Ref<ShaderMaterial> get_shader_material() const { return shader_material; }
    bool consume_new_frame();

protected:
    static void _bind_methods();

private:
    void _render_thread_setup(int width, int height, int format, int colorspace, int color_range);
    void _render_thread_setup_bgra(int width, int height);
    void _render_thread_import_native(RID p_tex_rid, int p_width, int p_height);
    void _render_thread_cleanup();
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
    Ref<Mutex> texture_mutex;

    int current_width = 0;
    int current_height = 0;

#ifdef __ANDROID__
    void _render_thread_create_android_gles_surface();
    void _render_thread_update_android_gles_texture();
    void _render_thread_destroy_android_gles_surface();
    std::mutex gles_surface_mutex_;
    std::condition_variable gles_surface_cv_;
    bool gles_surface_ready_ = false;
    bool gles_surface_failed_ = false;
    int gles_surface_width_ = 0;
    int gles_surface_height_ = 0;
    ANativeWindow *gles_decoder_window_ = nullptr;
    void *gles_surface_texture_java_ = nullptr;
    unsigned int gles_oes_texture_ = 0;
    unsigned int gles_output_texture_ = 0;
    unsigned int gles_fbo_ = 0;
    unsigned int gles_blit_program_ = 0;
    bool gles_update_queued_ = false;
#endif
};

} // namespace godot
