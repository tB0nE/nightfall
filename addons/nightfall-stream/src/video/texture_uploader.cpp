#include "texture_uploader.h"
#include "yuv_shader.h"
#include <godot_cpp/variant/utility_functions.hpp>

#include "nf_log.h"

#ifdef __ANDROID__
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>
#include <android/native_window_jni.h>
#include <chrono>
#include <jni.h>
#endif

using namespace godot;

static bool supports_android_hardware_buffer_import(RenderingDevice *rendering_device) {
#ifdef __ANDROID__
    if (!rendering_device || !rendering_device->has_method("texture_create_from_android_hardware_buffer")) {
        return false;
    }
    String rendering_method = RenderingServer::get_singleton()->get_current_rendering_method();
    return rendering_method != "gl_compatibility";
#else
    return rendering_device != nullptr;
#endif
}

TextureUploader::TextureUploader() {
    texture_mutex.instantiate();
    pending_native_width_ = 0;
    pending_native_height_ = 0;
}

TextureUploader::~TextureUploader() {
    cleanup();
}

void TextureUploader::set_active(bool nv12) {
    use_shader_conversion = true;
    is_nv12 = nv12;
}

void TextureUploader::set_texture_from_native_rid(RID p_tex_rid, int p_width, int p_height) {
    // Replaces the texture pipeline with a pre-existing GPU texture.
    // Used for zero-copy AHardwareBuffer import where the texture
    // is already on the GPU with YCbCr hardware conversion.
    use_shader_conversion = true;
    is_nv12 = false; // Single combined texture, not separate Y/UV planes

    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs) return;

    // Store pending state to avoid .bind(RID) issues with call_on_render_thread
    pending_native_rid_ = p_tex_rid;
    pending_native_width_ = p_width;
    pending_native_height_ = p_height;

    // Queue render thread setup to replace textures
    rs->call_on_render_thread(callable_mp(this, &TextureUploader::_render_thread_import_native_rt));
}

void TextureUploader::_render_thread_import_native(RID p_tex_rid, int p_width, int p_height) {
    // Original version with bound args - kept for reference
}

void TextureUploader::_render_thread_import_native_rt() {
    // Read pending state (avoids .bind(RID) issues with call_on_render_thread)
    RID p_tex_rid = pending_native_rid_;
    int p_width = pending_native_width_;
    int p_height = pending_native_height_;
    if (!p_tex_rid.is_valid()) return;

    std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));

    RenderingServer *rs = RenderingServer::get_singleton();
    rd = rs ? rs->get_rendering_device() : nullptr;
    if (!supports_android_hardware_buffer_import(rd)) {
        rd = nullptr;
    }

    if (!rd) return;

    // Retire the previous frame's texture into the delayed-free queue instead of
    // freeing it immediately (see NATIVE_TEX_FREE_DELAY_FRAMES comment in the header).
    // Indices 1/2 are unused by this path (leftover slots shared with the 3-plane
    // software YUV path) and are never populated here, so nothing to retire for them.
    if (rd_texture_rid[0].is_valid() && rd_texture_rid[0] != p_tex_rid) {
        pending_native_tex_free_.push_back({ rd_texture_rid[0], rs_texture_rid[0] });
    } else if (rs_texture_rid[0].is_valid()) {
        // rd_texture_rid[0] happened to match the new RID (shouldn't normally happen)
        // but we still hold a separate rs_texture_rid wrapper around it - retire that.
        pending_native_tex_free_.push_back({ RID(), rs_texture_rid[0] });
    }
    rd_texture_wrappers[0].unref();
    rd_texture_rid[0] = RID();
    rs_texture_rid[0] = RID();
    while ((int)pending_native_tex_free_.size() > NATIVE_TEX_FREE_DELAY_FRAMES) {
        PendingNativeTexFree oldest = pending_native_tex_free_.front();
        pending_native_tex_free_.pop_front();
        if (oldest.rs_tex.is_valid()) rs->free_rid(oldest.rs_tex);
        if (oldest.rd_tex.is_valid()) rd->free_rid(oldest.rd_tex);
    }

    // Use the imported texture directly
    rd_texture_rid[0] = p_tex_rid;
    rs_texture_rid[0] = rs->texture_rd_create(p_tex_rid);
#ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_INFO, "STRDEBG", "import_native_rt: rs_tex valid=%d",
        (int)rs_texture_rid[0].is_valid());
#endif

    if (rd_texture_wrappers[0].is_null())
        rd_texture_wrappers[0].instantiate();
    rd_texture_wrappers[0]->set_texture_rd_rid(p_tex_rid);

    ensure_shader_material();
    if (shader_material.is_valid()) {
        shader_material->set_shader_parameter("tex_y", rd_texture_wrappers[0]);
        shader_material->set_shader_parameter("is_semi_planar", false);
        shader_material->set_shader_parameter("is_nv12_rd", false);
        shader_material->set_shader_parameter("color_matrix_type", 3);
        shader_material->set_shader_parameter("color_range", 1);
        shader_material->set_shader_parameter("swap_uv", false);
    }

    new_frame_available_.store(true);
#ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_INFO, "STRDEBG", "import_native_rt: complete");
#endif

    current_width = p_width;
    current_height = p_height;

    // Clear pending state
    pending_native_rid_ = RID();
}

void TextureUploader::ensure_shader_material() {
    if (shader_material.is_null()) {
        yuv_shader.instantiate();
        yuv_shader->set_code(YUV_SHADER_CODE);
        shader_material.instantiate();
        shader_material->set_shader(yuv_shader);
        shader_material->set_shader_parameter("is_semi_planar", false);
        shader_material->set_shader_parameter("is_nv12_rd", false);
        shader_material->set_shader_parameter("color_matrix_type", 3);
        shader_material->set_shader_parameter("color_range", 1);
        shader_material->set_shader_parameter("swap_uv", false);
    }
}

void TextureUploader::setup(int width, int height, int format, int colorspace, int color_range) {
    RenderingServer *rs = RenderingServer::get_singleton();
    if (rs) {
        rs->call_on_render_thread(callable_mp(this, &TextureUploader::_render_thread_setup).bind(width, height, format, colorspace, color_range));
    }
}

void TextureUploader::setup_bgra(int width, int height) {
    use_shader_conversion = true;
    is_nv12 = false;
    current_width = width;
    current_height = height;

    // Set shader params on main thread immediately so the ColorRect
    // (which shares this material) sees BGRA mode before first frame renders.
    if (shader_material.is_valid()) {
        shader_material->set_shader_parameter("is_semi_planar", false);
        shader_material->set_shader_parameter("is_nv12_rd", false);
        shader_material->set_shader_parameter("color_matrix_type", 3);
        shader_material->set_shader_parameter("color_range", 1);
        shader_material->set_shader_parameter("swap_uv", false);
    }

    RenderingServer *rs = RenderingServer::get_singleton();
    if (rs) {
        rs->call_on_render_thread(callable_mp(this, &TextureUploader::_render_thread_setup_bgra).bind(width, height));
    }
}

void TextureUploader::_render_thread_setup_bgra(int width, int height) {
    std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));

    RenderingServer *rs = RenderingServer::get_singleton();
    rd = rs ? rs->get_rendering_device() : nullptr;
    if (!supports_android_hardware_buffer_import(rd)) {
        rd = nullptr;
    }

    if (rd) {
        for (int i = 0; i < 3; i++) {
            rd_texture_wrappers[i].unref();
            if (rs_texture_rid[i].is_valid()) {
                rs->free_rid(rs_texture_rid[i]);
                rs_texture_rid[i] = RID();
            }
            if (rd_texture_rid[i].is_valid()) {
                rd->free_rid(rd_texture_rid[i]);
                rd_texture_rid[i] = RID();
            }
        }

        Ref<RDTextureFormat> tf;
        tf.instantiate();
        tf->set_width(width);
        tf->set_height(height);
        tf->set_depth(1);
        tf->set_array_layers(1);
        tf->set_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
        tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
        tf->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);

        Ref<RDTextureView> tv;
        tv.instantiate();

        PackedByteArray data;
        data.resize(width * height * 4);
        data.fill(0);

        TypedArray<PackedByteArray> data_array;
        data_array.push_back(data);

        rd_texture_rid[0] = rd->texture_create(tf, tv, data_array);
        rs_texture_rid[0] = rs->texture_rd_create(rd_texture_rid[0]);

        if (rd_texture_wrappers[0].is_null()) {
            rd_texture_wrappers[0].instantiate();
        }
        rd_texture_wrappers[0]->set_texture_rd_rid(rd_texture_rid[0]);
    } else {
        plane_images[0] = Image::create(width, height, false, Image::FORMAT_RGBA8);
        plane_images[0]->fill(Color(0, 0, 0, 1));
        plane_textures[0] = ImageTexture::create_from_image(plane_images[0]);
    }

    if (yuv_shader.is_null()) {
        yuv_shader.instantiate();
        yuv_shader->set_code(YUV_SHADER_CODE);
    }
    if (shader_material.is_null()) {
        shader_material.instantiate();
        shader_material->set_shader(yuv_shader);
    }

    if (shader_material.is_valid()) {
        shader_material->set_shader_parameter("is_semi_planar", false);
        shader_material->set_shader_parameter("is_nv12_rd", false);
        shader_material->set_shader_parameter("color_matrix_type", 3);
        shader_material->set_shader_parameter("color_range", 1);
        shader_material->set_shader_parameter("swap_uv", false);

        if (rd) {
            shader_material->set_shader_parameter("tex_y", rd_texture_wrappers[0]);
        } else {
            shader_material->set_shader_parameter("tex_y", plane_textures[0]);
        }
    }
}

void TextureUploader::_render_thread_setup(int width, int height, int format, int colorspace, int color_range) {
    std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));
    AVPixelFormat av_format = (AVPixelFormat)format;
    AVColorSpace av_colorspace = (AVColorSpace)colorspace;
    AVColorRange av_color_range = (AVColorRange)color_range;

    RenderingServer *rs = RenderingServer::get_singleton();
    if (rd) {
        for (int i = 0; i < 3; i++) {
            rd_texture_wrappers[i].unref();
            if (rs_texture_rid[i].is_valid()) {
                rs->free_rid(rs_texture_rid[i]);
                rs_texture_rid[i] = RID();
            }
            if (rd_texture_rid[i].is_valid()) {
                rd->free_rid(rd_texture_rid[i]);
                rd_texture_rid[i] = RID();
            }
        }
    }

    is_nv12 = (av_format == AV_PIX_FMT_NV12);
    bool is_yuv420p = (av_format == AV_PIX_FMT_YUV420P);

    if (!is_nv12 && !is_yuv420p) {
        if (av_format == AV_PIX_FMT_NONE) {
            is_nv12 = true;
        } else {
            use_shader_conversion = false;
            return;
        }
    }

    use_shader_conversion = true;
    current_width = width;
    current_height = height;

    int y_w = width;
    int y_h = height;
    int uv_w = width / 2;
    int uv_h = height / 2;

    rd = rs->get_rendering_device();
    if (!supports_android_hardware_buffer_import(rd)) {
        rd = nullptr;
    }
    if (rd) {
        auto create_rd_texture = [&](int idx, int w, int h, RenderingDevice::DataFormat fmt) {
            Ref<RDTextureFormat> tf;
            tf.instantiate();
            tf->set_width(w);
            tf->set_height(h);
            tf->set_depth(1);
            tf->set_array_layers(1);
            tf->set_format(fmt);
            tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
            tf->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);

            Ref<RDTextureView> tv;
            tv.instantiate();

            PackedByteArray data;
            data.resize(w * h * (fmt == RenderingDevice::DATA_FORMAT_R8G8_UNORM ? 2 : 1));
            if (fmt == RenderingDevice::DATA_FORMAT_R8G8_UNORM || idx > 0)
                data.fill(128);
            else
                data.fill(0);

            TypedArray<PackedByteArray> data_array;
            data_array.push_back(data);

            rd_texture_rid[idx] = rd->texture_create(tf, tv, data_array);
            rs_texture_rid[idx] = rs->texture_rd_create(rd_texture_rid[idx]);

            if (rd_texture_wrappers[idx].is_null()) {
                rd_texture_wrappers[idx].instantiate();
            }
            rd_texture_wrappers[idx]->set_texture_rd_rid(rd_texture_rid[idx]);
        };

        create_rd_texture(0, y_w, y_h, RenderingDevice::DATA_FORMAT_R8_UNORM);
        create_rd_texture(1, is_nv12 ? y_w : uv_w, uv_h, RenderingDevice::DATA_FORMAT_R8_UNORM);
        create_rd_texture(2, uv_w, uv_h, RenderingDevice::DATA_FORMAT_R8_UNORM);
    } else {
        plane_images[0] = Image::create(y_w, y_h, false, Image::FORMAT_L8);
        plane_images[0]->fill(Color(0, 0, 0));
        plane_textures[0] = ImageTexture::create_from_image(plane_images[0]);

        plane_images[1] = Image::create(uv_w, uv_h, false, Image::FORMAT_L8);
        plane_images[1]->fill(Color(0.5, 0.5, 0.5));
        plane_textures[1] = ImageTexture::create_from_image(plane_images[1]);

        plane_images[2] = Image::create(uv_w, uv_h, false, Image::FORMAT_L8);
        plane_images[2]->fill(Color(0.5, 0.5, 0.5));
        plane_textures[2] = ImageTexture::create_from_image(plane_images[2]);
    }

    if (yuv_shader.is_null()) {
        yuv_shader.instantiate();
        yuv_shader->set_code(YUV_SHADER_CODE);
    }
    if (shader_material.is_null()) {
        shader_material.instantiate();
        shader_material->set_shader(yuv_shader);
    }

    int matrix_type = 1;
    if (av_colorspace == AVCOL_SPC_BT470BG || av_colorspace == AVCOL_SPC_SMPTE170M)
        matrix_type = 0;
    else if (av_colorspace == AVCOL_SPC_BT2020_NCL || av_colorspace == AVCOL_SPC_BT2020_CL)
        matrix_type = 2;
    else if (width < 1280 && height < 720)
        matrix_type = 0;

    int range_val = (av_color_range == AVCOL_RANGE_JPEG) ? 1 : 0;
    bool shader_semi = is_nv12 && !rd;

    if (shader_material.is_valid()) {
        shader_material->set_shader_parameter("is_semi_planar", shader_semi);
        shader_material->set_shader_parameter("is_nv12_rd", is_nv12 && rd);
        shader_material->set_shader_parameter("color_matrix_type", matrix_type);
        shader_material->set_shader_parameter("color_range", range_val);
        shader_material->set_shader_parameter("swap_uv", false);

        if (rd) {
            shader_material->set_shader_parameter("tex_y", rd_texture_wrappers[0]);
            shader_material->set_shader_parameter("tex_u", rd_texture_wrappers[1]);
            shader_material->set_shader_parameter("tex_v", rd_texture_wrappers[2]);
        } else {
            shader_material->set_shader_parameter("tex_y", plane_textures[0]);
            shader_material->set_shader_parameter("tex_u", plane_textures[1]);
            shader_material->set_shader_parameter("tex_v", plane_textures[2]);
        }
    }
}

void TextureUploader::update_colorspace(int colorspace, int color_range) {
    if (!shader_material.is_valid()) return;

    AVColorSpace av_cs = (AVColorSpace)colorspace;
    AVColorRange av_cr = (AVColorRange)color_range;

    int matrix_type = 1;
    if (av_cs == AVCOL_SPC_BT470BG || av_cs == AVCOL_SPC_SMPTE170M)
        matrix_type = 0;
    else if (av_cs == AVCOL_SPC_BT2020_NCL || av_cs == AVCOL_SPC_BT2020_CL)
        matrix_type = 2;

    int range_val = (av_cr == AVCOL_RANGE_JPEG) ? 1 : 0;

    shader_material->set_shader_parameter("color_matrix_type", matrix_type);
    shader_material->set_shader_parameter("color_range", range_val);
}

void TextureUploader::update_from_frame(AVFrame *frame) {
    if (!frame || !use_shader_conversion) return;

    static int upload_count = 0;
    upload_count++;
    if (upload_count <= 3 || upload_count % 60 == 0) {
        NF_LOG("TextureUploader", "Update #%d: %dx%d fmt=%d(%s) nv12=%d linesize=%d,%d,%d",
               upload_count, frame->width, frame->height, frame->format,
               av_get_pix_fmt_name((AVPixelFormat)frame->format),
               is_nv12, frame->linesize[0], frame->linesize[1], frame->linesize[2]);
    }

    RenderingServer *rs = RenderingServer::get_singleton();

    if (rd) {
        std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));

        auto upload_rd = [&](int idx, int av_idx, int w, int h, int bpp) {
            int src_stride = frame->linesize[av_idx];
            int dst_stride = w * bpp;
            int required_size = dst_stride * h;

            if (rd_texture_buffers[idx].size() != required_size)
                rd_texture_buffers[idx].resize(required_size);

            uint8_t *dst = rd_texture_buffers[idx].ptrw();
            uint8_t *src = frame->data[av_idx];

            if (src_stride == dst_stride) {
                memcpy(dst, src, required_size);
            } else {
                for (int i = 0; i < h; i++)
                    memcpy(dst + i * dst_stride, src + i * src_stride, dst_stride);
            }
        };

        upload_rd(0, 0, frame->width, frame->height, 1);

        if (is_nv12) {
            upload_rd(1, 1, frame->width, frame->height / 2, 1);
        } else {
            upload_rd(1, 1, frame->width / 2, frame->height / 2, 1);
            upload_rd(2, 2, frame->width / 2, frame->height / 2, 1);
        }

        pending_gpu_update.store(true);
    }

    if (rd) {
        rs->call_on_render_thread(callable_mp(this, &TextureUploader::perform_gpu_update));
        return;
    }

    auto upload_plane = [&](int gl_idx, int av_idx, int w, int h, int bpp) {
        Ref<Image> img = plane_images[gl_idx];
        Ref<ImageTexture> tex = plane_textures[gl_idx];
        if (img.is_null() || img->is_empty() || tex.is_null()) return;

        int src_stride = frame->linesize[av_idx];
        int dst_stride = w * bpp;
        int required_size = dst_stride * h;

        if (plane_buffers[gl_idx].size() != required_size)
            plane_buffers[gl_idx].resize(required_size);

        uint8_t *dst = plane_buffers[gl_idx].ptrw();
        uint8_t *src = frame->data[av_idx];

        if (src_stride == dst_stride) {
            memcpy(dst, src, required_size);
        } else {
            for (int i = 0; i < h; i++)
                memcpy(dst + i * dst_stride, src + i * src_stride, dst_stride);
        }

        img->set_data(w, h, false, (bpp == 2) ? Image::FORMAT_RG8 : Image::FORMAT_L8, plane_buffers[gl_idx]);
        if (img->is_empty()) return;
        rs->texture_2d_update(tex->get_rid(), img, 0);
    };

    upload_plane(0, 0, frame->width, frame->height, 1);
    if (is_nv12) {
        upload_plane(1, 1, frame->width / 2, frame->height / 2, 2);
    } else {
        upload_plane(1, 1, frame->width / 2, frame->height / 2, 1);
        upload_plane(2, 2, frame->width / 2, frame->height / 2, 1);
    }
}

void TextureUploader::update_from_raw_nv12(int width, int height, const uint8_t *data, uint32_t y_size, uint32_t uv_size) {
    if (!data || !use_shader_conversion) return;

    const uint8_t *y_data = data;
    const uint8_t *uv_data = data + y_size;

    RenderingServer *rs = RenderingServer::get_singleton();

    if (rd) {
        std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));

        int y_stride = width;
        int required_y = y_stride * height;
        if (rd_texture_buffers[0].size() != required_y)
            rd_texture_buffers[0].resize(required_y);
        memcpy(rd_texture_buffers[0].ptrw(), y_data, required_y);

        if (is_nv12) {
            int uv_stride = width;
            int required_uv = uv_stride * (height / 2);
            if (rd_texture_buffers[1].size() != required_uv)
                rd_texture_buffers[1].resize(required_uv);
            memcpy(rd_texture_buffers[1].ptrw(), uv_data, required_uv);
        } else {
            int uv_w = width / 2;
            int uv_h = height / 2;
            int required_u = uv_w * uv_h;
            int required_v = uv_w * uv_h;
            if (rd_texture_buffers[1].size() != required_u)
                rd_texture_buffers[1].resize(required_u);
            if (rd_texture_buffers[2].size() != required_v)
                rd_texture_buffers[2].resize(required_v);
            uint8_t *u_dst = rd_texture_buffers[1].ptrw();
            uint8_t *v_dst = rd_texture_buffers[2].ptrw();
            for (int i = 0; i < uv_w * uv_h; i++) {
                u_dst[i] = uv_data[i * 2];
                v_dst[i] = uv_data[i * 2 + 1];
            }
        }

        pending_gpu_update.store(true);
        rs->call_on_render_thread(callable_mp(this, &TextureUploader::perform_gpu_update));
        return;
    }

    int y_stride = width;
    if (plane_buffers[0].size() != (int)y_size)
        plane_buffers[0].resize(y_size);
    memcpy(plane_buffers[0].ptrw(), y_data, y_size);
    plane_images[0]->set_data(width, height, false, Image::FORMAT_L8, plane_buffers[0]);
    rs->texture_2d_update(plane_textures[0]->get_rid(), plane_images[0], 0);

    if (is_nv12) {
        int uv_h = height / 2;
        PackedByteArray uv_buf;
        uv_buf.resize(uv_size);
        memcpy(uv_buf.ptrw(), uv_data, uv_size);
        plane_images[1]->set_data(width / 2, uv_h, false, Image::FORMAT_RG8, uv_buf);
        rs->texture_2d_update(plane_textures[1]->get_rid(), plane_images[1], 0);
    } else {
        int uv_w = width / 2;
        int uv_h = height / 2;
        PackedByteArray u_buf, v_buf;
        u_buf.resize(uv_w * uv_h);
        v_buf.resize(uv_w * uv_h);
        for (int i = 0; i < uv_w * uv_h; i++) {
            u_buf.ptrw()[i] = uv_data[i * 2];
            v_buf.ptrw()[i] = uv_data[i * 2 + 1];
        }
        plane_images[1]->set_data(uv_w, uv_h, false, Image::FORMAT_L8, u_buf);
        rs->texture_2d_update(plane_textures[1]->get_rid(), plane_images[1], 0);
        plane_images[2]->set_data(uv_w, uv_h, false, Image::FORMAT_L8, v_buf);
        rs->texture_2d_update(plane_textures[2]->get_rid(), plane_images[2], 0);
    }
}

void TextureUploader::update_from_raw_bgra(int width, int height, const uint8_t *data, uint32_t data_size) {
    if (!data || !use_shader_conversion) return;

    RenderingServer *rs = RenderingServer::get_singleton();

    if (rd) {
        std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));

        int required = width * height * 4;
        if (rd_texture_buffers[0].size() != required)
            rd_texture_buffers[0].resize(required);

        int src_stride = width * 4;
        int dst_stride = width * 4;
        if (src_stride == dst_stride) {
            memcpy(rd_texture_buffers[0].ptrw(), data, required);
        } else {
            uint8_t *dst = rd_texture_buffers[0].ptrw();
            for (int i = 0; i < height; i++)
                memcpy(dst + i * dst_stride, data + i * src_stride, dst_stride);
        }

        pending_gpu_update.store(true);
        rs->call_on_render_thread(callable_mp(this, &TextureUploader::perform_gpu_update));
        return;
    }

    PackedByteArray bgra_buf;
    bgra_buf.resize(data_size);
    memcpy(bgra_buf.ptrw(), data, data_size);
    Ref<Image> img = Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, bgra_buf);
    if (img.is_valid() && !img->is_empty() && plane_textures[0].is_valid()) {
        rs->texture_2d_update(plane_textures[0]->get_rid(), img, 0);
    }
}

#ifdef __ANDROID__
extern JavaVM *nightfall_get_jvm();

namespace {
const char *GLES_EXTERNAL_VERTEX_SHADER = R"(
#version 300 es
uniform mat4 u_tex_matrix;
out vec2 v_uv;
void main() {
    vec2 position;
    vec2 uv;
    if (gl_VertexID == 0) {
        position = vec2(-1.0, -1.0); uv = vec2(0.0, 0.0);
    } else if (gl_VertexID == 1) {
        position = vec2(1.0, -1.0); uv = vec2(1.0, 0.0);
    } else if (gl_VertexID == 2) {
        position = vec2(-1.0, 1.0); uv = vec2(0.0, 1.0);
    } else {
        position = vec2(1.0, 1.0); uv = vec2(1.0, 1.0);
    }
    gl_Position = vec4(position, 0.0, 1.0);
    uv.y = 1.0 - uv.y;
    v_uv = (u_tex_matrix * vec4(uv, 0.0, 1.0)).xy;
}
)";

const char *GLES_EXTERNAL_FRAGMENT_SHADER = R"(
#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
uniform samplerExternalOES u_video;
in vec2 v_uv;
out vec4 frag_color;
void main() {
    frag_color = texture(u_video, v_uv);
}
)";

GLuint compile_gles_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled == GL_TRUE) return shader;
    char log[512]{};
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    NF_LOGE("TextureUploader", "GLES shader compile failed: %s", log);
    glDeleteShader(shader);
    return 0;
}

JNIEnv *get_gles_jni_env(JavaVM *&out_vm) {
    out_vm = nightfall_get_jvm();
    if (!out_vm) return nullptr;
    JNIEnv *env = nullptr;
    const jint status = out_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (out_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
    } else if (status != JNI_OK) {
        return nullptr;
    }
    return env;
}
} // namespace

ANativeWindow *TextureUploader::create_android_gles_decoder_surface(int width, int height) {
    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs) return nullptr;
    {
        std::lock_guard<std::mutex> lock(gles_surface_mutex_);
        if (gles_decoder_window_ && gles_surface_width_ == width && gles_surface_height_ == height) {
            return gles_decoder_window_;
        }
        gles_surface_width_ = width;
        gles_surface_height_ = height;
        gles_surface_ready_ = false;
        gles_surface_failed_ = false;
    }
    rs->call_on_render_thread(callable_mp(this, &TextureUploader::_render_thread_create_android_gles_surface));
    std::unique_lock<std::mutex> lock(gles_surface_mutex_);
    if (!gles_surface_cv_.wait_for(lock, std::chrono::seconds(5), [this] {
            return gles_surface_ready_ || gles_surface_failed_;
        })) {
        NF_LOGE("TextureUploader", "Timed out creating GLES decoder SurfaceTexture");
        return nullptr;
    }
    return gles_surface_ready_ ? gles_decoder_window_ : nullptr;
}

void TextureUploader::_render_thread_create_android_gles_surface() {
    const int width = gles_surface_width_;
    const int height = gles_surface_height_;
    auto fail = [this] {
        std::lock_guard<std::mutex> lock(gles_surface_mutex_);
        gles_surface_failed_ = true;
        gles_surface_cv_.notify_all();
    };

    if (gles_decoder_window_ || width <= 0 || height <= 0) {
        NF_LOGE("TextureUploader", "GLES decoder surface requested with invalid state");
        fail();
        return;
    }

    JavaVM *vm = nullptr;
    JNIEnv *env = get_gles_jni_env(vm);
    if (!env) {
        NF_LOGE("TextureUploader", "Unable to get JNIEnv on Godot GLES render thread");
        fail();
        return;
    }

    GLuint vertex = compile_gles_shader(GL_VERTEX_SHADER, GLES_EXTERNAL_VERTEX_SHADER);
    GLuint fragment = compile_gles_shader(GL_FRAGMENT_SHADER, GLES_EXTERNAL_FRAGMENT_SHADER);
    if (!vertex || !fragment) {
        if (vertex) glDeleteShader(vertex);
        if (fragment) glDeleteShader(fragment);
        fail();
        return;
    }
    gles_blit_program_ = glCreateProgram();
    glAttachShader(gles_blit_program_, vertex);
    glAttachShader(gles_blit_program_, fragment);
    glLinkProgram(gles_blit_program_);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    glGetProgramiv(gles_blit_program_, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        char log[512]{};
        glGetProgramInfoLog(gles_blit_program_, sizeof(log), nullptr, log);
        NF_LOGE("TextureUploader", "GLES external blit link failed: %s", log);
        glDeleteProgram(gles_blit_program_);
        gles_blit_program_ = 0;
        fail();
        return;
    }

    glGenTextures(1, &gles_oes_texture_);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, gles_oes_texture_);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    jclass surface_texture_class = env->FindClass("android/graphics/SurfaceTexture");
    jmethodID constructor = surface_texture_class ? env->GetMethodID(surface_texture_class, "<init>", "(I)V") : nullptr;
    jmethodID set_size = surface_texture_class ? env->GetMethodID(surface_texture_class, "setDefaultBufferSize", "(II)V") : nullptr;
    if (!surface_texture_class || !constructor || !set_size) {
        NF_LOGE("TextureUploader", "SurfaceTexture JNI methods unavailable");
        if (env->ExceptionCheck()) env->ExceptionClear();
        fail();
        return;
    }
    jobject local_surface_texture = env->NewObject(surface_texture_class, constructor, (jint)gles_oes_texture_);
    if (!local_surface_texture || env->ExceptionCheck()) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        NF_LOGE("TextureUploader", "SurfaceTexture construction failed");
        fail();
        return;
    }
    env->CallVoidMethod(local_surface_texture, set_size, width, height);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        NF_LOGE("TextureUploader", "SurfaceTexture setDefaultBufferSize failed");
        env->DeleteLocalRef(local_surface_texture);
        fail();
        return;
    }
    jclass surface_class = env->FindClass("android/view/Surface");
    jmethodID surface_constructor = surface_class
        ? env->GetMethodID(surface_class, "<init>", "(Landroid/graphics/SurfaceTexture;)V") : nullptr;
    jobject local_surface = surface_constructor
        ? env->NewObject(surface_class, surface_constructor, local_surface_texture) : nullptr;
    if (!local_surface || env->ExceptionCheck()) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        NF_LOGE("TextureUploader", "Surface construction failed");
        env->DeleteLocalRef(local_surface_texture);
        fail();
        return;
    }
    gles_decoder_window_ = ANativeWindow_fromSurface(env, local_surface);
    env->DeleteLocalRef(local_surface);
    gles_surface_texture_java_ = env->NewGlobalRef(local_surface_texture);
    env->DeleteLocalRef(local_surface_texture);
    if (!gles_decoder_window_) {
        NF_LOGE("TextureUploader", "ANativeWindow_fromSurface failed");
        fail();
        return;
    }

    glGenTextures(1, &gles_output_texture_);
    glBindTexture(GL_TEXTURE_2D, gles_output_texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &gles_fbo_);

    RenderingServer *rs = RenderingServer::get_singleton();
    PackedByteArray placeholder_data;
    placeholder_data.resize(width * height * 4);
    placeholder_data.fill(0);
    Ref<Image> placeholder = Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, placeholder_data);
    plane_textures[0] = ImageTexture::create_from_image(placeholder);
    RID native_texture = rs->texture_create_from_native_handle(
        RenderingServer::TEXTURE_TYPE_2D, Image::FORMAT_RGBA8,
        (uint64_t)gles_output_texture_, width, height, 1);
    if (!native_texture.is_valid() || plane_textures[0].is_null()) {
        NF_LOGE("TextureUploader", "Godot refused GLES native output texture");
        fail();
        return;
    }
    rs->texture_replace(plane_textures[0]->get_rid(), native_texture);
    use_shader_conversion = true;
    is_nv12 = false;
    current_width = width;
    current_height = height;
    ensure_shader_material();
    shader_material->set_shader_parameter("tex_y", plane_textures[0]);
    shader_material->set_shader_parameter("is_semi_planar", false);
    shader_material->set_shader_parameter("is_nv12_rd", false);
    shader_material->set_shader_parameter("color_matrix_type", 3);
    shader_material->set_shader_parameter("color_range", 1);
    shader_material->set_shader_parameter("swap_uv", false);

    NF_LOG("TextureUploader", "GLES external decoder surface ready: %dx%d", width, height);
    {
        std::lock_guard<std::mutex> lock(gles_surface_mutex_);
        gles_surface_ready_ = true;
        gles_surface_cv_.notify_all();
    }
}

void TextureUploader::update_android_gles_external_texture() {
    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs) return;
    std::lock_guard<std::mutex> lock(gles_surface_mutex_);
    if (!gles_surface_ready_ || gles_update_queued_) return;
    gles_update_queued_ = true;
    static int queued_updates = 0;
    if (++queued_updates <= 3 || queued_updates % 120 == 0) {
        NF_LOG("TextureUploader", "Queued GLES external frame #%d", queued_updates);
    }
    rs->call_on_render_thread(callable_mp(this, &TextureUploader::_render_thread_update_android_gles_texture));
}

void TextureUploader::_render_thread_update_android_gles_texture() {
    {
        std::lock_guard<std::mutex> lock(gles_surface_mutex_);
        gles_update_queued_ = false;
    }
    if (!gles_surface_texture_java_ || !gles_fbo_ || !gles_blit_program_) return;
    JavaVM *vm = nullptr;
    JNIEnv *env = get_gles_jni_env(vm);
    jclass surface_texture_class = env ? env->FindClass("android/graphics/SurfaceTexture") : nullptr;
    jmethodID update = surface_texture_class ? env->GetMethodID(surface_texture_class, "updateTexImage", "()V") : nullptr;
    jmethodID transform = surface_texture_class ? env->GetMethodID(surface_texture_class, "getTransformMatrix", "([F)V") : nullptr;
    if (!env || !update || !transform) return;
    env->CallVoidMethod((jobject)gles_surface_texture_java_, update);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        static int update_failures = 0;
        if (++update_failures <= 3) NF_LOGE("TextureUploader", "SurfaceTexture updateTexImage failed");
        return;
    }
    float matrix[16]{};
    jfloatArray java_matrix = env->NewFloatArray(16);
    env->CallVoidMethod((jobject)gles_surface_texture_java_, transform, java_matrix);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        env->DeleteLocalRef(java_matrix);
        return;
    }
    env->GetFloatArrayRegion(java_matrix, 0, 16, matrix);
    env->DeleteLocalRef(java_matrix);
    GLint old_fbo = 0;
    GLint old_viewport[4]{};
    GLint old_program = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &old_fbo);
    glGetIntegerv(GL_VIEWPORT, old_viewport);
    glGetIntegerv(GL_CURRENT_PROGRAM, &old_program);
    glBindFramebuffer(GL_FRAMEBUFFER, gles_fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gles_output_texture_, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        NF_LOGE("TextureUploader", "GLES external output framebuffer incomplete");
        glBindFramebuffer(GL_FRAMEBUFFER, old_fbo);
        return;
    }
    glViewport(0, 0, gles_surface_width_, gles_surface_height_);
    glUseProgram(gles_blit_program_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, gles_oes_texture_);
    glUniform1i(glGetUniformLocation(gles_blit_program_, "u_video"), 0);
    glUniformMatrix4fv(glGetUniformLocation(gles_blit_program_, "u_tex_matrix"), 1, GL_FALSE, matrix);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    const GLenum draw_error = glGetError();
    glUseProgram(old_program);
    glBindFramebuffer(GL_FRAMEBUFFER, old_fbo);
    glViewport(old_viewport[0], old_viewport[1], old_viewport[2], old_viewport[3]);
    if (draw_error != GL_NO_ERROR) {
        NF_LOGE("TextureUploader", "GLES external blit failed: 0x%x", draw_error);
        return;
    }
    static int completed_updates = 0;
    if (++completed_updates <= 3 || completed_updates % 120 == 0) {
        NF_LOG("TextureUploader", "Completed GLES external blit #%d", completed_updates);
    }
    new_frame_available_.store(true);
}

void TextureUploader::update_from_android_image(AImage *image, int width, int height) {
    static int gles_upload_count = 0;
    const int upload_attempt = ++gles_upload_count;
    if (!image || rd || !use_shader_conversion) {
        if (upload_attempt <= 3) {
            NF_LOG("TextureUploader", "GLES upload unavailable: image=%d rd=%d shader=%d",
                image != nullptr, rd != nullptr, use_shader_conversion);
        }
        return;
    }

    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs || plane_images[0].is_null() || plane_textures[0].is_null()) {
        if (upload_attempt <= 3) {
            NF_LOG("TextureUploader", "GLES textures unavailable: rs=%d image=%d texture=%d",
                rs != nullptr, plane_images[0].is_valid(), plane_textures[0].is_valid());
        }
        return;
    }

    int32_t plane_count = 0;
    if (AImage_getNumberOfPlanes(image, &plane_count) != AMEDIA_OK || plane_count < 3) {
        if (upload_attempt <= 3) {
            NF_LOG("TextureUploader", "GLES image has %d planes; expected YUV_420_888", plane_count);
        }
        return;
    }

    const int plane_widths[3] = { width, width / 2, width / 2 };
    const int plane_heights[3] = { height, height / 2, height / 2 };

    for (int plane = 0; plane < 3; ++plane) {
        uint8_t *source = nullptr;
        int source_length = 0;
        int row_stride = 0;
        int pixel_stride = 0;
        media_status_t data_status = AImage_getPlaneData(image, plane, &source, &source_length);
        media_status_t row_status = AImage_getPlaneRowStride(image, plane, &row_stride);
        media_status_t pixel_status = AImage_getPlanePixelStride(image, plane, &pixel_stride);
        if (data_status != AMEDIA_OK || row_status != AMEDIA_OK || pixel_status != AMEDIA_OK ||
            !source || row_stride <= 0 || pixel_stride <= 0) {
            if (upload_attempt <= 3) {
                NF_LOG("TextureUploader", "GLES plane %d unavailable: data=%d row=%d pixel=%d ptr=%d stride=%d/%d",
                    plane, data_status, row_status, pixel_status, source != nullptr, row_stride, pixel_stride);
            }
            return;
        }

        const int packed_size = plane_widths[plane] * plane_heights[plane];
        if (plane_buffers[plane].size() != packed_size) {
            plane_buffers[plane].resize(packed_size);
        }
        uint8_t *destination = plane_buffers[plane].ptrw();
        for (int row = 0; row < plane_heights[plane]; ++row) {
            const int source_offset = row * row_stride;
            if (source_offset >= source_length) return;
            for (int column = 0; column < plane_widths[plane]; ++column) {
                const int source_index = source_offset + column * pixel_stride;
                if (source_index >= source_length) return;
                destination[row * plane_widths[plane] + column] = source[source_index];
            }
        }

        plane_images[plane]->set_data(
            plane_widths[plane], plane_heights[plane], false, Image::FORMAT_L8, plane_buffers[plane]);
        rs->texture_2d_update(plane_textures[plane]->get_rid(), plane_images[plane], 0);
    }

    new_frame_available_.store(true);
    if (upload_attempt <= 3) {
        NF_LOG("TextureUploader", "GLES YUV upload #%d: %dx%d", upload_attempt, width, height);
    }
}

void TextureUploader::update_from_android_rgba_image(AImage *image, int width, int height) {
    if (!image || !use_shader_conversion) return;

    uint8_t *source = nullptr;
    int source_length = 0;
    int row_stride = 0;
    int pixel_stride = 0;
    if (AImage_getPlaneData(image, 0, &source, &source_length) != AMEDIA_OK ||
        AImage_getPlaneRowStride(image, 0, &row_stride) != AMEDIA_OK ||
        AImage_getPlanePixelStride(image, 0, &pixel_stride) != AMEDIA_OK ||
        !source || row_stride < width * 4 || pixel_stride != 4) {
        return;
    }

    PackedByteArray rgba;
    rgba.resize(width * height * 4);
    uint8_t *destination = rgba.ptrw();
    for (int row = 0; row < height; ++row) {
        const int source_offset = row * row_stride;
        if (source_offset + width * 4 > source_length) return;
        memcpy(destination + row * width * 4, source + source_offset, width * 4);
    }
    update_from_raw_bgra(width, height, rgba.ptr(), rgba.size());
    new_frame_available_.store(true);
}
#endif

void TextureUploader::perform_gpu_update() {
    if (!rd) return;
    std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));
    if (pending_gpu_update.exchange(false)) {
        static int gpu_update_count = 0;
        if (++gpu_update_count <= 3) {
            NF_LOG("TextureUploader",
                "perform_gpu_update #%d: tex0=%d tex1=%d tex2=%d",
                gpu_update_count,
                rd_texture_rid[0].is_valid(), rd_texture_rid[1].is_valid(), rd_texture_rid[2].is_valid());
        }
        if (rd_texture_rid[0].is_valid())
            rd->texture_update(rd_texture_rid[0], 0, rd_texture_buffers[0]);
        if (rd_texture_rid[1].is_valid())
            rd->texture_update(rd_texture_rid[1], 0, rd_texture_buffers[1]);
        if (!is_nv12 && rd_texture_rid[2].is_valid())
            rd->texture_update(rd_texture_rid[2], 0, rd_texture_buffers[2]);
        new_frame_available_.store(true);
    }
}

void TextureUploader::cleanup() {
    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs) return;
    rs->call_on_render_thread(callable_mp(this, &TextureUploader::_render_thread_cleanup));
}

void TextureUploader::_render_thread_cleanup() {
    std::lock_guard<godot::Mutex> lock(*(texture_mutex.ptr()));
#ifdef __ANDROID__
    _render_thread_destroy_android_gles_surface();
#endif
    if (rd) {
        // Deliberately NOT freeing rd_texture_rid[i]/rs_texture_rid[i] here - this runs
        // on every restart (called from StreamConnection::_cb_decoder_cleanup(), not just
        // final teardown), and unconditionally destroying them with no grace period hits
        // the same compositor-timeline use-after-free as _render_thread_import_native_rt()'s
        // per-frame case above (confirmed via VK_LAYER_KHRONOS_validation,
        // VUID-vkDestroyImage-image-01000). pending_native_tex_free_ is deliberately left
        // untouched too - the next session's frame imports will keep draining it normally,
        // generation doesn't matter to that queue.
        for (int i = 0; i < 3; i++) {
            rd_texture_wrappers[i].unref();
            rs_texture_rid[i] = RID();
            rd_texture_rid[i] = RID();
        }
        rd = nullptr;
    }
    use_shader_conversion = false;
}

#ifdef __ANDROID__
void TextureUploader::_render_thread_destroy_android_gles_surface() {
    if (!gles_decoder_window_ && !gles_surface_texture_java_ && !gles_blit_program_) return;
    JavaVM *vm = nullptr;
    JNIEnv *env = get_gles_jni_env(vm);
    if (gles_decoder_window_) {
        ANativeWindow_release(gles_decoder_window_);
        gles_decoder_window_ = nullptr;
    }
    if (env && gles_surface_texture_java_) {
        jclass surface_texture_class = env->FindClass("android/graphics/SurfaceTexture");
        jmethodID release = surface_texture_class ? env->GetMethodID(surface_texture_class, "release", "()V") : nullptr;
        if (release) env->CallVoidMethod((jobject)gles_surface_texture_java_, release);
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteGlobalRef((jobject)gles_surface_texture_java_);
    }
    gles_surface_texture_java_ = nullptr;
    if (gles_fbo_) glDeleteFramebuffers(1, &gles_fbo_);
    if (gles_output_texture_) glDeleteTextures(1, &gles_output_texture_);
    if (gles_oes_texture_) glDeleteTextures(1, &gles_oes_texture_);
    if (gles_blit_program_) glDeleteProgram(gles_blit_program_);
    gles_fbo_ = 0;
    gles_output_texture_ = 0;
    gles_oes_texture_ = 0;
    gles_blit_program_ = 0;
    std::lock_guard<std::mutex> surface_lock(gles_surface_mutex_);
    gles_surface_ready_ = false;
    gles_surface_failed_ = false;
    gles_update_queued_ = false;
}
#endif

void TextureUploader::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "width", "height", "format", "colorspace", "color_range"), &TextureUploader::setup);
    ClassDB::bind_method(D_METHOD("cleanup"), &TextureUploader::cleanup);
    ClassDB::bind_method(D_METHOD("get_shader_material"), &TextureUploader::get_shader_material);
    ClassDB::bind_method(D_METHOD("perform_gpu_update"), &TextureUploader::perform_gpu_update);
    ClassDB::bind_method(D_METHOD("consume_new_frame"), &TextureUploader::consume_new_frame);
}

bool TextureUploader::consume_new_frame() {
    return new_frame_available_.exchange(false);
}
