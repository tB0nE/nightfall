#include "stream_connection.h"
#include "ffmpeg_decoder.h"
#include "texture_uploader.h"
#include "audio/audio_renderer.h"
#include "input/input_bridge.h"
#include "video/depth_bridge.h"
#include "video/codec_defs.h"
#include "ycbcr_to_rgba_spirv.h"
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#ifdef __ANDROID__
#include "video/mediacodec_internal.h"
#include "video/mediacodec_native.h"
#include <jni.h>
#include <android/hardware_buffer.h>
#include <media/NdkImageReader.h>
#include <media/NdkImage.h>
AHardwareBuffer *mediacodec_get_ahb(jobject media_codec_obj, ssize_t buffer_index);
#endif

#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <algorithm>
#include <cstring>
#include <utility>

extern "C" {
#include <libavutil/pixdesc.h>
}

#include "nf_log.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/pixfmt.h>
#include <libavutil/frame.h>
}

#include <cstdarg>

using namespace godot;

StreamConnection *StreamConnection::active_instance_ = nullptr;

StreamConnection::StreamConnection() {
    decoder_.instantiate();
    uploader_.instantiate();
    audio_renderer_.instantiate();
    input_bridge_.instantiate();
    depth_bridge_.instantiate();
#ifdef __ANDROID__
    compute_pipeline_ready_.store(false);
    display_wired_ = false;
    native_video_width_ = 0;
    native_video_height_ = 0;
    native_color_range_ = 0;
    native_color_matrix_type_ = 0;
    pending_buffer_id_ = 0;
    pending_generation_ = 0;
    pending_uncached_buffer_ptr_ = 0;
    pending_width_ = 0;
    pending_height_ = 0;
    pending_dispatch_cached_ = false;
    pending_dispatch_ready_ = false;
#endif
}

StreamConnection::~StreamConnection() {
    stop();
#ifdef __ANDROID__
    RenderingDevice *rd = RenderingServer::get_singleton()
        ? RenderingServer::get_singleton()->get_rendering_device() : nullptr;
    _retire_all_ahb_imports();
    if (rd) {
        _render_free_pipeline_rt();
        if (compute_pipeline_.is_valid()) rd->free_rid(compute_pipeline_);
        if (compute_shader_.is_valid()) rd->free_rid(compute_shader_);
        if (dummy_sampler_.is_valid()) rd->free_rid(dummy_sampler_);
        if (rgba_output_tex_.is_valid()) rd->free_rid(rgba_output_tex_);
    }
    // Safe to retire now — decode thread is joined by stop(). The codec shuts
    // down when the last decode-thread reference is released.
    _replace_native_codec(nullptr);
#endif
    if (h264_extradata_) {
        av_freep(&h264_extradata_);
        h264_extradata_size_ = 0;
    }
}

#ifdef __ANDROID__
std::shared_ptr<AndroidMediaCodec> StreamConnection::_get_native_codec() const {
    std::lock_guard<std::mutex> lock(native_codec_mutex_);
    return native_codec_;
}

void StreamConnection::_replace_native_codec(
        std::shared_ptr<AndroidMediaCodec> replacement) {
    std::shared_ptr<AndroidMediaCodec> retired;
    {
        std::lock_guard<std::mutex> lock(native_codec_mutex_);
        retired = std::exchange(native_codec_, std::move(replacement));
    }
    // Destruction occurs outside the publication lock. If the decode thread
    // still owns the old codec, its shutdown is naturally deferred.
}

void StreamConnection::_ensure_compute_pipeline(RenderingDevice *rd, int width, int height,
                                                uint64_t generation) {
    std::lock_guard<std::mutex> state_lock(render_state_mutex_);
    if (generation != render_generation_.load()) return;

    static int ep_log = 0;
    if (++ep_log <= 3) NF_LOG("VCONN", "_ensure_compute_pipeline: ready=%d rd=%p w=%d h=%d",
        (int)compute_pipeline_ready_, (void*)rd, width, height);
    if (compute_pipeline_ready_) return;
    if (!rd) return;

    // Create RGBA8 output texture
    Ref<RDTextureFormat> tf;
    tf.instantiate();
    tf->set_width(width);
    tf->set_height(height);
    tf->set_depth(1);
    tf->set_array_layers(1);
    tf->set_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
    tf->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
    tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
                       RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
                       RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
    // Vulkan validation flagged VUID-VkImageViewCreateInfo-image-12397 here: the later
    // rs->texture_rd_create(rgba_output_tex_) call (display wiring, below) asks the driver
    // for an image view in a different-but-compatible format (sRGB, for the compositor's
    // gamma-correct sampling) than this texture was created with, which Vulkan only allows
    // when the image itself was created with VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT. Godot sets
    // that bit automatically once shareable formats are declared.
    tf->add_shareable_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
    tf->add_shareable_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_SRGB);

    Ref<RDTextureView> tv;
    tv.instantiate();

    rgba_output_tex_ = rd->texture_create(tf, tv);
    NF_LOG("VCONN", "RGBA output tex: %s", rgba_output_tex_.is_valid() ? "OK" : "FAIL");

    // Create dummy sampler (placeholder, engine patch will override with YCbCr sampler)
    Ref<RDSamplerState> sampler_state;
    sampler_state.instantiate();
    sampler_state->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sampler_state->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sampler_state->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    sampler_state->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    dummy_sampler_ = rd->sampler_create(sampler_state);
    NF_LOG("VCONN", "Dummy sampler: %s", dummy_sampler_.is_valid() ? "OK" : "FAIL");

    // Create compute shader from SPIRV
    PackedByteArray spirv;
    spirv.resize(YCBCR_TO_RGBA_SPIRV_LEN);
    memcpy(spirv.ptrw(), YCBCR_TO_RGBA_SPIRV, YCBCR_TO_RGBA_SPIRV_LEN);

    Ref<RDShaderSPIRV> spirv_data;
    spirv_data.instantiate();
    spirv_data->set_stage_bytecode(RenderingDevice::SHADER_STAGE_COMPUTE, spirv);

    compute_shader_ = rd->shader_create_from_spirv(spirv_data);
    NF_LOG("VCONN", "Compute shader: %s", compute_shader_.is_valid() ? "OK" : "FAIL");

    if (!compute_shader_.is_valid()) return;

    compute_pipeline_ = rd->compute_pipeline_create(compute_shader_);
    NF_LOG("VCONN", "Compute pipeline: %s", compute_pipeline_.is_valid() ? "OK" : "FAIL");

    if (!compute_pipeline_.is_valid()) return;

    // Wire up canvas display — deferred to render thread (rs->texture_rd_create needs render thread)
    uploader_->ensure_shader_material();

    compute_pipeline_ready_ = true;
    NF_LOG("VCONN", "Compute pipeline ready! %dx%d", width, height);
}

bool StreamConnection::_get_or_create_ahb_import(RenderingDevice *rd,
        uint64_t buffer_ptr, uint64_t buffer_id, int width, int height,
        uint64_t generation) {
    std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
    if (generation != render_generation_.load() || !compute_pipeline_ready_) return false;

    auto existing = std::find_if(ahb_import_cache_.begin(), ahb_import_cache_.end(),
        [buffer_id, generation](const CachedAhbImport &entry) {
            return entry.buffer_id == buffer_id && entry.generation == generation;
        });
    if (existing != ahb_import_cache_.end()) {
        ahb_cache_hits_++;
        return true;
    }

    int usage = (int)RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT;
    Variant texture_var = rd->call("texture_create_from_android_hardware_buffer",
        buffer_ptr, (int)RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM,
        width, height, usage);
    RID texture = texture_var;
    if (!texture.is_valid()) return false;

    Variant sampler_var = rd->call("texture_get_ycbcr_sampler", texture);
    RID sampler = sampler_var;
    if (!sampler.is_valid()) {
        rd->free_rid(texture);
        return false;
    }

    // Reconfiguration may have started while the driver import was executing.
    if (generation != render_generation_.load() || !compute_pipeline_ready_) {
        rd->free_rid(sampler);
        rd->free_rid(texture);
        return false;
    }

    CachedAhbImport entry;
    entry.buffer_id = buffer_id;
    entry.generation = generation;
    entry.texture = texture;
    entry.sampler = sampler;
    // Keep the opaque handle and pointer fallback key valid until the imported
    // Vulkan objects are retired, independent of the frame's AImage lifetime.
    AHardwareBuffer_acquire((AHardwareBuffer *)buffer_ptr);
    entry.owned_buffer_ptr = buffer_ptr;
    ahb_import_cache_.push_back(entry);
    ahb_cache_misses_++;

    NF_LOG("StreamConnection", "AHB import cache miss: id=%llu entries=%zu hits=%llu misses=%llu",
           (unsigned long long)buffer_id, ahb_import_cache_.size(),
           (unsigned long long)ahb_cache_hits_, (unsigned long long)ahb_cache_misses_);
    return true;
}

bool StreamConnection::_retire_removed_ahb_imports(const std::vector<uint64_t> &buffer_ids) {
    if (buffer_ids.empty()) return false;

    bool retired = false;
    {
        std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
        auto it = ahb_import_cache_.begin();
        while (it != ahb_import_cache_.end()) {
            if (std::find(buffer_ids.begin(), buffer_ids.end(), it->buffer_id) != buffer_ids.end()) {
                pending_free_ahb_imports_.push_back(*it);
                it = ahb_import_cache_.erase(it);
                retired = true;
            } else {
                ++it;
            }
        }
    }

    if (retired) {
        std::lock_guard<std::mutex> lock(pending_mutex_);
        if (pending_dispatch_cached_ &&
            std::find(buffer_ids.begin(), buffer_ids.end(), pending_buffer_id_) != buffer_ids.end()) {
            pending_dispatch_ready_ = false;
        }
    }
    return retired;
}

bool StreamConnection::_retire_all_ahb_imports() {
    bool retired = false;
    {
        std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
        retired = !ahb_import_cache_.empty();
        pending_free_ahb_imports_.insert(pending_free_ahb_imports_.end(),
                                         ahb_import_cache_.begin(), ahb_import_cache_.end());
        ahb_import_cache_.clear();
        if (retired) {
            NF_LOG("StreamConnection", "Retiring AHB import cache: hits=%llu misses=%llu",
                   (unsigned long long)ahb_cache_hits_,
                   (unsigned long long)ahb_cache_misses_);
        }
        ahb_cache_hits_ = 0;
        ahb_cache_misses_ = 0;
    }

    CachedAhbImport pending_uncached;
    bool retire_pending_uncached = false;
    {
        std::lock_guard<std::mutex> lock(pending_mutex_);
        if (pending_dispatch_ready_ && !pending_dispatch_cached_) {
            pending_uncached.generation = pending_generation_;
            pending_uncached.texture = pending_uncached_texture_;
            pending_uncached.sampler = pending_uncached_sampler_;
            pending_uncached.owned_buffer_ptr = pending_uncached_buffer_ptr_;
            retire_pending_uncached = true;
        }
        pending_dispatch_ready_ = false;
        pending_dispatch_cached_ = false;
        pending_uncached_texture_ = RID();
        pending_uncached_sampler_ = RID();
        pending_uncached_buffer_ptr_ = 0;
    }
    if (retire_pending_uncached) {
        std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
        pending_free_ahb_imports_.push_back(pending_uncached);
        retired = true;
    }
    return retired;
}

void StreamConnection::_render_compute_dispatch_rt() {
    static int rt_enter = 0;
    if (++rt_enter == 1) NF_LOG("VCONN", "RT_ENTER");

    uint64_t buffer_id = 0;
    uint64_t generation = 0;
    RID uncached_texture;
    RID uncached_sampler;
    uint64_t uncached_buffer_ptr = 0;
    int width = 0;
    int height = 0;
    bool cached_dispatch = false;
    {
        std::lock_guard<std::mutex> lock(pending_mutex_);
        if (!pending_dispatch_ready_) return;
        buffer_id = pending_buffer_id_;
        generation = pending_generation_;
        uncached_texture = pending_uncached_texture_;
        uncached_sampler = pending_uncached_sampler_;
        uncached_buffer_ptr = pending_uncached_buffer_ptr_;
        width = pending_width_;
        height = pending_height_;
        cached_dispatch = pending_dispatch_cached_;
        pending_dispatch_ready_ = false;
        pending_uncached_texture_ = RID();
        pending_uncached_sampler_ = RID();
        pending_uncached_buffer_ptr_ = 0;
    }

    RenderingDevice *rd = RenderingServer::get_singleton()
        ? RenderingServer::get_singleton()->get_rendering_device() : nullptr;
    auto release_uncached = [&]() {
        if (cached_dispatch) return;
        if (rd && uncached_sampler.is_valid()) rd->free_rid(uncached_sampler);
        if (rd && uncached_texture.is_valid()) rd->free_rid(uncached_texture);
        if (uncached_buffer_ptr != 0) {
            AHardwareBuffer_release((AHardwareBuffer *)uncached_buffer_ptr);
            uncached_buffer_ptr = 0;
        }
    };
    if (!rd) {
        release_uncached();
        return;
    }

    // Keep reconfiguration from moving pipeline/output RIDs while this command
    // is being recorded. Cache retirement itself is queued after this callback.
    std::lock_guard<std::mutex> state_lock(render_state_mutex_);
    if (!compute_pipeline_ready_ || generation != render_generation_.load()) {
        release_uncached();
        return;
    }

    RID texture;
    RID sampler;
    RID uniform_set;
    bool uniform_set_owned = !cached_dispatch;
    if (cached_dispatch) {
        std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
        auto entry = std::find_if(ahb_import_cache_.begin(), ahb_import_cache_.end(),
            [buffer_id, generation](const CachedAhbImport &cached) {
                return cached.buffer_id == buffer_id && cached.generation == generation;
            });
        if (entry == ahb_import_cache_.end()) return;
        texture = entry->texture;
        sampler = entry->sampler;
        uniform_set = entry->uniform_set;
    } else {
        texture = uncached_texture;
        sampler = uncached_sampler;
    }

    if (!uniform_set.is_valid()) {
        Ref<RDUniform> u_sampler;
        u_sampler.instantiate();
        u_sampler->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
        u_sampler->set_binding(0);
        u_sampler->add_id(sampler);
        u_sampler->add_id(texture);

        Ref<RDUniform> u_output;
        u_output.instantiate();
        u_output->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
        u_output->set_binding(1);
        u_output->add_id(rgba_output_tex_);

        TypedArray<RDUniform> uniforms;
        uniforms.append(u_sampler);
        uniforms.append(u_output);
        uniform_set = rd->uniform_set_create(uniforms, compute_shader_, 0);
        if (cached_dispatch && uniform_set.is_valid()) {
            std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
            auto entry = std::find_if(ahb_import_cache_.begin(), ahb_import_cache_.end(),
                [buffer_id, generation](const CachedAhbImport &cached) {
                    return cached.buffer_id == buffer_id && cached.generation == generation;
                });
            if (entry != ahb_import_cache_.end()) {
                entry->uniform_set = uniform_set;
            } else {
                // A buffer-removed callback retired the entry while the uniform
                // was being built. Keep this set local to the current dispatch.
                uniform_set_owned = true;
            }
        }
    }
    if (!uniform_set.is_valid()) {
        release_uncached();
        return;
    }

    // Dispatch compute shader FIRST (so rgba_output_tex_ has valid data before display)
    {
        int64_t cmd = rd->compute_list_begin();
        rd->compute_list_bind_compute_pipeline(cmd, compute_pipeline_);
        rd->compute_list_bind_uniform_set(cmd, uniform_set, 0);

        uint32_t pc_data[4];
        pc_data[0] = (uint32_t)width;
        pc_data[1] = (uint32_t)height;

        uint32_t color_range = 0;
        if (stream_config_.colorRange == COLOR_RANGE_FULL) {
            color_range = 1;
        }
        uint32_t color_matrix = 1;
        if (stream_config_.colorSpace == COLORSPACE_REC_601) {
            color_matrix = 0;
        } else if (stream_config_.colorSpace == COLORSPACE_REC_2020) {
            color_matrix = 2;
        }
        pc_data[2] = color_range;
        pc_data[3] = color_matrix;

        PackedByteArray push_constants;
        push_constants.resize(16);
        memcpy(push_constants.ptrw(), pc_data, 16);
        rd->compute_list_set_push_constant(cmd, push_constants, 16);

        rd->compute_list_dispatch(cmd, (width + 15) / 16, (height + 15) / 16, 1);
        rd->compute_list_end();
    }

    // One-time per session AFTER first compute dispatch: wire display to rgba_output_tex_
    // (must be after dispatch so texture has valid video data, not uninitialized white)
    if (!display_wired_ && rgba_output_tex_.is_valid()) {
        RenderingServer *rs = RenderingServer::get_singleton();
        if (rs) {
            RID rs_tex = rs->texture_rd_create(rgba_output_tex_);
            NF_LOG("VCONN", "RT: rs_texture_rd_create valid=%d", (int)rs_tex.is_valid());
            uploader_->ensure_shader_material();
            Ref<ShaderMaterial> mat = uploader_->get_shader_material();
            if (mat.is_valid() && rs_tex.is_valid()) {
                mat->set_shader_parameter("tex_y", rs_tex);
                mat->set_shader_parameter("color_matrix_type", 3);
                mat->set_shader_parameter("color_range", 1);
                mat->set_shader_parameter("is_nv12_rd", false);
                mat->set_shader_parameter("is_semi_planar", false);
                // Only latch ready AFTER the bind above actually succeeded - setting
                // this unconditionally (as before) meant a single failed
                // texture_rd_create()/get_shader_material() on the first dispatch
                // (e.g. from a driver rejecting this texture's format) permanently
                // convinced is_display_ready() the stream was live, sending
                // GDScript's bind_yuv_textures() into its dead-end SubViewport
                // fallback for the rest of the session with no way to recover.
                // Leaving it false here lets the next dispatch retry instead.
                display_wired_ = true;
                NF_LOG("VCONN", "RT: tex_y set AFTER compute dispatch");
            }
        }
    }

    if (uniform_set_owned) rd->free_rid(uniform_set);
    if (!cached_dispatch) release_uncached();

    static int rt_done = 0;
    if (++rt_done <= 3) NF_LOG("VCONN", "RT: dispatch complete");
}

void StreamConnection::_render_free_pipeline_rt() {
    RenderingDevice *rd = RenderingServer::get_singleton()
        ? RenderingServer::get_singleton()->get_rendering_device() : nullptr;
    if (!rd) return;

    std::vector<CachedAhbImport> retired_imports;
    {
        std::lock_guard<std::mutex> lock(ahb_cache_mutex_);
        retired_imports.swap(pending_free_ahb_imports_);
    }
    for (const CachedAhbImport &entry : retired_imports) {
        // Deliberately NOT freeing entry.uniform_set/sampler/texture - same
        // VUID-vkDestroyImage-image-01000 as the pipeline resources below, still firing
        // from here specifically for the _retire_all_ahb_imports() case (the bulk retirement
        // done at restart/generation-bump time, queued into pending_free_ahb_imports_ and
        // drained right here). The continuous per-buffer path (_retire_removed_ahb_imports,
        // driven by MediaCodec's own buffer-removed callbacks during normal playback) also
        // feeds this same queue/loop, so this now orphans those Vulkan objects too rather
        // than only the restart-time ones - a larger but still bounded leak (MediaCodec has a
        // small, fixed pool of output buffers) in exchange for not risking the same
        // compositor-timeline use-after-free. Releasing the AHardwareBuffer reference below is
        // NOT affected by this: importing it into Vulkan memory keeps the underlying memory
        // alive independent of this extra ref, so dropping our ref here is safe regardless of
        // whether the imported VkImage/sampler/uniform_set ever get destroyed.
        if (entry.owned_buffer_ptr != 0) {
            AHardwareBuffer_release((AHardwareBuffer *)entry.owned_buffer_ptr);
        }
    }

    // Can't free pending_free_pipeline_/_shader_/_sampler_/_tex_ immediately here.
    // Vulkan validation (VK_LAYER_KHRONOS_validation) confirmed VUID-vkDestroyImage-image-01000
    // firing right at this call: the OpenXR compositor submits composition layers on its own
    // frame timeline, decoupled from Godot's regular swapchain frame accounting, so this being
    // queued one render-thread tick after the generation bump (via call_on_render_thread) is
    // nowhere near enough of a grace period - free_rid() here was destroying rgba_output_tex_
    // (and its VkImageView, referenced by the composition layer cylinder's tex_y wrapper) while
    // the compositor still had in-flight GPU commands referencing it, which is exactly the
    // random-delay SIGSEGV seen after repeated resolution/codec changes (confirmed via tombstones
    // - crashed deep in libgodot_android.so's Vulkan/compositor path, not in this addon's code).
    //
    // Orphaning them forever (the previous fix for that crash) is safe but leaks one full
    // generation of GPU memory - pipeline+shader+sampler+a full-resolution RGBA texture - per
    // restart, unbounded: repeated codec/resolution/fps/bitrate changes during a single session
    // visibly degraded performance as this accumulated. Instead, defer freeing by a few retired
    // generations - each restart takes well over a second end to end (_schedule_stream_restart()'s
    // own 0.8s debounce, plus frame waits, plus a 0.5s reconnect timer, plus full decoder
    // teardown/setup), so by the time PIPELINE_FREE_DELAY_GENERATIONS more restarts have happened,
    // the compositor has had orders of magnitude more real time than the single tick that caused
    // the original crash. The AHB import cache above is NOT affected by this - it's freed via its
    // own retirement path (_retire_removed_ahb_imports/_retire_all_ahb_imports), tied to
    // MediaCodec's own buffer lifecycle notifications, and already naturally bounded by
    // MediaCodec's small, fixed output-buffer pool.
    if (pending_free_pipeline_.is_valid() || pending_free_shader_.is_valid() ||
        pending_free_sampler_.is_valid() || pending_free_tex_.is_valid()) {
        pending_free_pipeline_generations_.push_back({
            pending_free_pipeline_, pending_free_shader_, pending_free_sampler_, pending_free_tex_
        });
        pending_free_pipeline_ = RID();
        pending_free_shader_ = RID();
        pending_free_sampler_ = RID();
        pending_free_tex_ = RID();
    }
    while ((int)pending_free_pipeline_generations_.size() > PIPELINE_FREE_DELAY_GENERATIONS) {
        RetiredPipelineGeneration oldest = pending_free_pipeline_generations_.front();
        pending_free_pipeline_generations_.pop_front();
        if (oldest.pipeline.is_valid()) rd->free_rid(oldest.pipeline);
        if (oldest.shader.is_valid()) rd->free_rid(oldest.shader);
        if (oldest.sampler.is_valid()) rd->free_rid(oldest.sampler);
        if (oldest.tex.is_valid()) rd->free_rid(oldest.tex);
    }
}
#endif

bool StreamConnection::_extract_h264_sps_pps(const uint8_t *data, int size,
                                               uint8_t **sps, int *sps_size,
                                               uint8_t **pps, int *pps_size) {
    *sps = nullptr; *sps_size = 0;
    *pps = nullptr; *pps_size = 0;

    int i = 0;
    while (i < size - 3) {
        int sc_size = 0;
        if (i + 3 < size && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) {
            sc_size = 4;
        } else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            sc_size = 3;
        }

        if (sc_size > 0) {
            int nalu_start = i + sc_size;
            if (nalu_start >= size) break;

            int nalu_type = data[nalu_start] & 0x1f;

            int nalu_end = size;
            for (int j = nalu_start + 1; j < size - 2; j++) {
                if ((data[j] == 0 && data[j+1] == 0 && data[j+2] == 1) ||
                    (j + 3 < size && data[j] == 0 && data[j+1] == 0 && data[j+2] == 0 && data[j+3] == 1)) {
                    nalu_end = j;
                    while (nalu_end > nalu_start && data[nalu_end - 1] == 0) nalu_end--;
                    break;
                }
            }

            int nalu_len = nalu_end - nalu_start;

            if (nalu_type == 7 && !*sps) {
                *sps = (uint8_t *)av_malloc(nalu_len);
                memcpy(*sps, data + nalu_start, nalu_len);
                *sps_size = nalu_len;
            } else if (nalu_type == 8 && !*pps) {
                *pps = (uint8_t *)av_malloc(nalu_len);
                memcpy(*pps, data + nalu_start, nalu_len);
                *pps_size = nalu_len;
            }

            i = nalu_start;
            if (*sps && *pps) return true;
        } else {
            i++;
        }
    }

    return (*sps && *pps);
}

uint8_t *StreamConnection::_build_avcc_extradata(const uint8_t *sps, int sps_size,
                                                   const uint8_t *pps, int pps_size,
                                                   int *out_size) {
    int total = 8 + sps_size + 3 + pps_size;
    uint8_t *ed = (uint8_t *)av_mallocz(total + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!ed) return nullptr;

    int pos = 0;
    ed[pos++] = 0x01;
    ed[pos++] = sps[0];
    ed[pos++] = sps[1];
    ed[pos++] = sps[2];
    ed[pos++] = 0xFF;
    ed[pos++] = 0xE1;
    ed[pos++] = (sps_size >> 8) & 0xFF;
    ed[pos++] = sps_size & 0xFF;
    memcpy(ed + pos, sps, sps_size);
    pos += sps_size;
    ed[pos++] = 0x01;
    ed[pos++] = (pps_size >> 8) & 0xFF;
    ed[pos++] = pps_size & 0xFF;
    memcpy(ed + pos, pps, pps_size);
    pos += pps_size;

    *out_size = pos;
    return ed;
}

void StreamConnection::_try_h264_hw_upgrade() {
    if (!h264_hw_upgrade_pending_.load() || h264_hw_upgraded_.load()) return;
    if (!h264_extradata_ || h264_extradata_size_ == 0) return;

    h264_hw_upgrade_pending_.store(false);

    int ret = decoder_->upgrade_to_mediacodec(h264_extradata_, h264_extradata_size_);
    if (ret == 0) {
        h264_hw_upgraded_.store(true);

        uploader_->setup(decoder_->get_video_width(), decoder_->get_video_height(),
                         AV_PIX_FMT_NV12,
                         (int)AVCOL_SPC_BT709,
                         (int)AVCOL_RANGE_UNSPECIFIED);

        LiRequestIdrFrame();

        call_deferred("emit_signal", "h264_hw_upgraded");
    } else {
        NF_LOGE("StreamConnection", "H.264 HW upgrade failed (%d)", ret);
    }

    av_freep(&h264_extradata_);
    h264_extradata_size_ = 0;
}

int StreamConnection::_cb_decoder_setup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) {
    auto *self = active_instance_;
    if (!self) return -1;

    self->h264_hw_upgrade_pending_.store(false);
    self->h264_hw_upgraded_.store(false);
    if (self->h264_extradata_) {
        av_freep(&self->h264_extradata_);
        self->h264_extradata_size_ = 0;
    }

    self->active_video_format_ = videoFormat;
    NF_LOG("StreamConnection", "Decoder setup: format=0x%x %dx%d@%dfps local_capture=%d", videoFormat, width, height, redrawRate, self->local_capture_mode_);

    if (self->local_capture_mode_) {
        NF_LOG("StreamConnection", "Local capture mode: skipping Sunshine decoder/uploader setup");
        self->decoder_ready_.store(true);
        return 0;
    }

#ifdef __ANDROID__
    // Android: ONLY native NDK MediaCodec + ImageReader for zero-copy GPU decode.
    // No FFmpeg fallback. Must fail loudly if unavailable.

    // Prevent new decode work from entering this render generation. A decode
    // iteration keeps a shared reference, so replacement cannot destroy a codec
    // while feed/dequeue operations are still using it.
    self->decoder_ready_.store(false);
    self->_replace_native_codec(nullptr);

    // Start a new render generation before retiring cached imports. The state
    // lock serializes invalidation with pipeline creation and command recording.
    RenderingServer *rs = RenderingServer::get_singleton();
    RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
    {
        std::lock_guard<std::mutex> state_lock(self->render_state_mutex_);
        self->compute_pipeline_ready_ = false;
        self->display_wired_ = false;
        self->render_generation_.fetch_add(1);
        if (rd) {
            self->pending_free_pipeline_ = self->compute_pipeline_;
            self->pending_free_shader_ = self->compute_shader_;
            self->pending_free_sampler_ = self->dummy_sampler_;
            self->pending_free_tex_ = self->rgba_output_tex_;
            self->compute_pipeline_ = RID();
            self->compute_shader_ = RID();
            self->dummy_sampler_ = RID();
            self->rgba_output_tex_ = RID();
        }
    }
    self->_retire_all_ahb_imports();

    // Free old-generation GPU resources after previously queued dispatches.
    if (rd) {
        rs->call_on_render_thread(callable_mp(self, &StreamConnection::_render_free_pipeline_rt));
    }

    const char *mime = nullptr;
    if (videoFormat & VIDEO_FORMAT_MASK_H265) {
        mime = "video/hevc";
    } else if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        mime = "video/avc";
    }
    if (mime) {
        auto new_codec = std::make_shared<AndroidMediaCodec>();
        auto notify_decode_thread = [self] {
            {
                // Condition-variable predicate mutations use the same mutex as
                // the waiter so a callback cannot notify between its predicate
                // check and sleep transition.
                std::lock_guard<std::mutex> lock(self->queue_mutex_);
                self->native_codec_event_.store(true);
            }
            self->queue_cv_.notify_one();
        };
        if (new_codec->init(mime, width, height, notify_decode_thread)) {
            NF_LOG("StreamConnection", "Native MediaCodec created: %dx%d mime=%s", width, height, mime);
            self->_replace_native_codec(new_codec);
            self->native_video_width_ = width;
            self->native_video_height_ = height;
            // Only ensure shader material exists (no texture setup — compute pipeline handles it)
            self->uploader_->ensure_shader_material();
            self->uploader_->set_active(true); // NV12 mode
            self->decoder_ready_.store(true);
            return 0;
        }
        NF_LOGE("StreamConnection", "FATAL: Native MediaCodec init failed for %s", mime);
        return -1;
    }
    NF_LOGE("StreamConnection", "FATAL: Unsupported video format 0x%x on Android", videoFormat);
    return -1;
#else
    int ret = self->decoder_->setup(videoFormat, width, height, false);
    if (ret != 0) {
        NF_LOGE("StreamConnection", "Decoder setup FAILED: ret=%d", ret);
        return ret;
    }

    NF_LOG("StreamConnection", "Decoder opened: name=%s hw=%s raw=%s", 
           self->decoder_->get_decoder_name().utf8().get_data(),
           self->decoder_->is_hw_decode() ? "yes" : "no",
           self->decoder_->is_raw_decode() ? "yes" : "no");

    int pix_fmt = AV_PIX_FMT_YUV420P;
    if (self->decoder_->is_raw_decode()) {
        pix_fmt = AV_PIX_FMT_NV12;
    } else if (self->decoder_->is_hw_decode()) {
        pix_fmt = AV_PIX_FMT_NV12;
    }
    NF_LOG("StreamConnection", "Uploader setup: %dx%d pix_fmt=%d", width, height, pix_fmt);

    self->uploader_->setup(width, height,
                           pix_fmt,
                           (int)AVCOL_SPC_BT709,
                           (int)AVCOL_RANGE_UNSPECIFIED);

    self->decoder_ready_.store(true);
    return 0;
#endif
}

void StreamConnection::_cb_decoder_start() {
    NF_LOG("StreamConnection", "Decoder start");
}

void StreamConnection::_cb_decoder_stop() {
    NF_LOG("StreamConnection", "Decoder stop");
    auto *self = active_instance_;
    if (self) {
        self->decoder_ready_.store(false);
    }
}

void StreamConnection::_cb_decoder_cleanup() {
    NF_LOG("StreamConnection", "Decoder cleanup");
    auto *self = active_instance_;
    if (!self) return;

#ifdef __ANDROID__
    // Invalidate render state before uploader cleanup so no queued dispatch can
    // pass its generation guard and then touch an uploader being torn down.
    self->decoder_ready_.store(false);
    self->_replace_native_codec(nullptr);

    RenderingServer *rs = RenderingServer::get_singleton();
    RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
    {
        std::lock_guard<std::mutex> state_lock(self->render_state_mutex_);
        self->compute_pipeline_ready_ = false;
        self->display_wired_ = false;
        self->render_generation_.fetch_add(1);
        if (rd) {
            self->pending_free_pipeline_ = self->compute_pipeline_;
            self->pending_free_shader_ = self->compute_shader_;
            self->pending_free_sampler_ = self->dummy_sampler_;
            self->pending_free_tex_ = self->rgba_output_tex_;
            self->compute_pipeline_ = RID();
            self->compute_shader_ = RID();
            self->dummy_sampler_ = RID();
            self->rgba_output_tex_ = RID();
        }
    }
    self->_retire_all_ahb_imports();
#endif

    if (!self->local_capture_mode_) {
        self->decoder_->cleanup();
        self->uploader_->cleanup();
    }

#ifdef __ANDROID__
    // Cleanup may be followed immediately by destruction. Avoid adding a new
    // member callback that could outlive StreamConnection; the original path
    // also released these resources synchronously here.
    if (rd) self->_render_free_pipeline_rt();
#endif

    self->decoder_ready_.store(false);
    self->h264_hw_upgrade_pending_.store(false);
    self->h264_hw_upgraded_.store(false);
    if (self->h264_extradata_) {
        av_freep(&self->h264_extradata_);
        self->h264_extradata_size_ = 0;
    }
}

int StreamConnection::_cb_submit_decode_unit(PDECODE_UNIT decodeUnit) {
    auto *self = active_instance_;
    if (!self || !self->is_streaming_.load()) return DR_OK;

    static int submit_count = 0;
    submit_count++;
    if (submit_count <= 3) {
        NF_LOG("StreamConnection", "Submit DU #%d: size=%d type=%d frame=%d",
               submit_count, decodeUnit->fullLength, decodeUnit->frameType,
               decodeUnit->frameNumber);
    }

    if (self->local_capture_mode_) {
        return DR_OK;
    }

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return DR_OK;

    int ret = av_new_packet(pkt, decodeUnit->fullLength);
    if (ret < 0) {
        av_packet_free(&pkt);
        return DR_OK;
    }

    int offset = 0;
    PLENTRY entry = decodeUnit->bufferList;
    while (entry != nullptr) {
        if (offset + entry->length <= decodeUnit->fullLength) {
            memcpy(pkt->data + offset, entry->data, entry->length);
            offset += entry->length;
        }
        entry = entry->next;
    }

    pkt->pts = decodeUnit->presentationTimeUs;

#if defined(__ANDROID__)
    {
        auto *self = active_instance_;
        if (self && !self->h264_extradata_ && self->active_video_format_ == 0x1) {
            uint8_t *sps = nullptr, *pps = nullptr;
            int sps_size = 0, pps_size = 0;
            if (_extract_h264_sps_pps(pkt->data, pkt->size, &sps, &sps_size, &pps, &pps_size)) {
                self->h264_extradata_ = _build_avcc_extradata(sps, sps_size, pps, pps_size, &self->h264_extradata_size_);
                if (self->h264_extradata_) {
                    self->h264_hw_upgrade_pending_.store(true);
                }
                av_freep(&sps);
                av_freep(&pps);
            }
        }
    }
#endif

    auto now = std::chrono::steady_clock::now();
    auto now_us = std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count();
    self->last_submit_time_us_.store(now_us);

    DecodeUnitQueue::DecodeUnit queued_unit;
    queued_unit.packet.reset(pkt);
    queued_unit.is_idr = decodeUnit->frameType == FRAME_TYPE_IDR;
    queued_unit.frame_number = decodeUnit->frameNumber;
    queued_unit.presentation_time_us = decodeUnit->presentationTimeUs;

    DecodeUnitQueue::PushResult enqueue_result;
    {
        std::lock_guard<std::mutex> lock(self->queue_mutex_);
        enqueue_result = self->packet_queue_.push(std::move(queued_unit));
    }

    if (enqueue_result.dropped != 0) {
        self->frames_dropped_.fetch_add((int)enqueue_result.dropped);
    }
    if (enqueue_result.request_idr) {
        LiRequestIdrFrame();
        return DR_NEED_IDR;
    }
    if (enqueue_result.accepted) {
        self->queue_cv_.notify_one();
    }

    return DR_OK;
}

void StreamConnection::_cb_connection_started() {
    NF_LOG("StreamConnection", "Connection started");
    auto *self = active_instance_;
    if (self) {
        self->is_streaming_.store(true);
        self->call_deferred("emit_signal", "stream_started");
    }
}

void StreamConnection::_cb_connection_terminated(int errorCode) {
    NF_LOG("StreamConnection", "Connection terminated: %d", errorCode);
    auto *self = active_instance_;
    if (self) {
        if (self->local_capture_mode_ && (errorCode == ML_ERROR_NO_VIDEO_TRAFFIC || errorCode == ML_ERROR_NO_VIDEO_FRAME)) {
            NF_LOG("StreamConnection", "Bypassing video watchdog timeout in local capture mode");
            return;
        }
        self->is_streaming_.store(false);
        self->queue_cv_.notify_all();
        self->call_deferred("emit_signal", "stream_terminated", errorCode, get_error_string(errorCode));
    }
}

void StreamConnection::_cb_stage_starting(int stage) {
    NF_LOG("StreamConnection", "Stage starting: %s", LiGetStageName(stage));
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "stage_starting", String(LiGetStageName(stage)));
    }
}

void StreamConnection::_cb_stage_complete(int stage) {
    NF_LOG("StreamConnection", "Stage complete: %s", LiGetStageName(stage));
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "stage_complete", String(LiGetStageName(stage)));
    }
}

void StreamConnection::_cb_stage_failed(int stage, int errorCode) {
    NF_LOG("StreamConnection", "Stage failed: %s (error %d)", LiGetStageName(stage), errorCode);
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "stage_failed", String(LiGetStageName(stage)), errorCode);
    }
}

void StreamConnection::_cb_rumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor) {
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "controller_rumble", (int)controllerNumber, (int)lowFreqMotor, (int)highFreqMotor);
    }
}

void StreamConnection::_cb_connection_status_update(int connectionStatus) {
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "connection_status_update", connectionStatus);
    }
}

void StreamConnection::_cb_set_hdr_mode(bool hdrEnabled) {
    auto *self = active_instance_;
    if (self) {
        Dictionary metadata;
        if (hdrEnabled) {
            SS_HDR_METADATA hdr_data;
            if (LiGetHdrMetadata(&hdr_data)) {
                Array primaries_x, primaries_y;
                primaries_x.push_back(hdr_data.displayPrimaries[0].x);
                primaries_x.push_back(hdr_data.displayPrimaries[1].x);
                primaries_x.push_back(hdr_data.displayPrimaries[2].x);
                primaries_y.push_back(hdr_data.displayPrimaries[0].y);
                primaries_y.push_back(hdr_data.displayPrimaries[1].y);
                primaries_y.push_back(hdr_data.displayPrimaries[2].y);
                metadata["display_primaries_x"] = primaries_x;
                metadata["display_primaries_y"] = primaries_y;
                metadata["white_point_x"] = hdr_data.whitePoint.x;
                metadata["white_point_y"] = hdr_data.whitePoint.y;
                metadata["min_display_luminance"] = hdr_data.minDisplayLuminance;
                metadata["max_display_luminance"] = hdr_data.maxDisplayLuminance;
                metadata["max_content_light_level"] = hdr_data.maxContentLightLevel;
                metadata["max_frame_average_light_level"] = hdr_data.maxFrameAverageLightLevel;
            }
        }
        self->call_deferred("emit_signal", "hdr_mode_changed", hdrEnabled, metadata);
    }
}

void StreamConnection::_cb_rumble_triggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor) {
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "controller_trigger_rumble", (int)controllerNumber, (int)leftTriggerMotor, (int)rightTriggerMotor);
    }
}

void StreamConnection::_cb_set_motion_event_state(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz) {
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "motion_event_requested", (int)controllerNumber, (int)motionType, (int)reportRateHz);
    }
}

void StreamConnection::_cb_set_controller_led(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b) {
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "controller_led_set", (int)controllerNumber, (int)r, (int)g, (int)b);
    }
}

void StreamConnection::_cb_log_message(const char *format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[2048];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    auto *self = active_instance_;
    if (self) {
        self->call_deferred("emit_signal", "log_message", String(buffer));
    }
}

AVColorSpace StreamConnection::_resolve_frame_colorspace(AVFrame *frame) const {
    if (!frame) return AVCOL_SPC_BT709;

    bool hdr_trc = frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67;
    bool hdr_primaries = frame->color_primaries == AVCOL_PRI_BT2020;
    if (hdr_trc || hdr_primaries) {
        return AVCOL_SPC_BT2020_NCL;
    }

    AVColorSpace declared = (AVColorSpace)frame->colorspace;
    if (declared == AVCOL_SPC_UNSPECIFIED || declared == AVCOL_SPC_RGB) {
        if (active_video_format_ & VIDEO_FORMAT_MASK_RAW) {
            return AVCOL_SPC_BT709;
        }
        bool is_h264 = (active_video_format_ & VIDEO_FORMAT_MASK_H264) && !(active_video_format_ & (VIDEO_FORMAT_MASK_H265 | VIDEO_FORMAT_MASK_AV1));
#ifdef __ANDROID__
        if (is_h264) {
            return AVCOL_SPC_BT470BG;
        }
        return (frame->width >= 1280 || frame->height >= 720) ? AVCOL_SPC_BT709 : AVCOL_SPC_BT470BG;
#else
        if (is_h264) {
            return AVCOL_SPC_BT470BG;
        }
        return (frame->width <= 1024 && frame->height <= 576) ? AVCOL_SPC_BT470BG : AVCOL_SPC_BT709;
#endif
    }

    return declared;
}

void StreamConnection::_connection_thread_func() {
    DECODER_RENDERER_CALLBACKS drCallbacks{};
    LiInitializeVideoCallbacks(&drCallbacks);
    drCallbacks.setup = _cb_decoder_setup;
    drCallbacks.start = _cb_decoder_start;
    drCallbacks.stop = _cb_decoder_stop;
    drCallbacks.cleanup = _cb_decoder_cleanup;
    drCallbacks.submitDecodeUnit = _cb_submit_decode_unit;
    drCallbacks.capabilities = 0;

    AUDIO_RENDERER_CALLBACKS arCallbacks{};
    LiInitializeAudioCallbacks(&arCallbacks);
    arCallbacks.init = AudioRenderer::_cb_init;
    arCallbacks.start = AudioRenderer::_cb_start;
    arCallbacks.stop = AudioRenderer::_cb_stop;
    arCallbacks.cleanup = AudioRenderer::_cb_cleanup;
    arCallbacks.decodeAndPlaySample = AudioRenderer::_cb_decode_and_play_sample;
    arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    CONNECTION_LISTENER_CALLBACKS clCallbacks{};
    LiInitializeConnectionCallbacks(&clCallbacks);
    clCallbacks.stageStarting = _cb_stage_starting;
    clCallbacks.stageComplete = _cb_stage_complete;
    clCallbacks.stageFailed = _cb_stage_failed;
    clCallbacks.connectionStarted = _cb_connection_started;
    clCallbacks.connectionTerminated = _cb_connection_terminated;
    clCallbacks.rumble = _cb_rumble;
    clCallbacks.connectionStatusUpdate = _cb_connection_status_update;
    clCallbacks.setHdrMode = _cb_set_hdr_mode;
    clCallbacks.rumbleTriggers = _cb_rumble_triggers;
    clCallbacks.setMotionEventState = _cb_set_motion_event_state;
    clCallbacks.setControllerLED = _cb_set_controller_led;
    clCallbacks.logMessage = _cb_log_message;

    // In local capture mode, skip audio entirely - audio is already on the machine
    PAUDIO_RENDERER_CALLBACKS arPtr = local_capture_mode_ ? nullptr : &arCallbacks;

    int ret = LiStartConnection(&server_info_, &stream_config_, &clCallbacks, &drCallbacks, arPtr, nullptr, 0, nullptr, 0);

    if (ret != 0) {
        is_streaming_.store(false);
        queue_cv_.notify_all();
        call_deferred("emit_signal", "stream_terminated", ret, get_error_string(ret));
    }
}

void StreamConnection::_decode_thread_func() {
    std::optional<DecodeUnitQueue::DecodeUnit> queued_unit;
    AVPacket *pkt = nullptr;
#ifdef __ANDROID__
    bool native_input_blocked = false;
#endif

    {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        queue_cv_.wait_for(lock, std::chrono::milliseconds(10000), [this] {
            return is_streaming_.load() || !packet_queue_.empty();
        });
        if (!is_streaming_.load()) return;
    }

    while (true) {
        queued_unit.reset();
        pkt = nullptr;
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            queue_cv_.wait(lock, [this
#ifdef __ANDROID__
                                  , &native_input_blocked
#endif
            ] {
#ifdef __ANDROID__
                return (!packet_queue_.empty() && !native_input_blocked) ||
                       native_codec_event_.load() || !is_streaming_.load();
#else
                return !packet_queue_.empty() || !is_streaming_.load();
#endif
            });

            if (!is_streaming_.load()) break;

#ifdef __ANDROID__
            if (native_codec_event_.exchange(false)) {
                native_input_blocked = false;
            }
#endif
            if (!packet_queue_.empty()
#ifdef __ANDROID__
                && !native_input_blocked
#endif
            ) {
                queued_unit = packet_queue_.pop();
                if (queued_unit) {
                    pkt = queued_unit->packet.get();
                }
            }
        }

#ifdef __ANDROID__
        uint64_t decode_generation = render_generation_.load();
        std::shared_ptr<AndroidMediaCodec> codec = _get_native_codec();
        if (codec && decoder_ready_.load()) {
            std::vector<uint64_t> removed_buffer_ids;
            codec->take_removed_buffer_ids(removed_buffer_ids);
            if (_retire_removed_ahb_imports(removed_buffer_ids)) {
                RenderingServer *rs = RenderingServer::get_singleton();
                if (rs) {
                    rs->call_on_render_thread(callable_mp(this, &StreamConnection::_render_free_pipeline_rt));
                }
            }

            // Feed input when present, but drain callback-produced output even
            // when input backpressure temporarily leaves no buffer available.
            if (pkt) {
                AndroidMediaCodec::FeedResult feed_result;
                bool stale_codec = false;
                {
                    // Keep publication stable across the non-blocking queue
                    // operation so a packet cannot enter a retired generation.
                    std::lock_guard<std::mutex> codec_lock(native_codec_mutex_);
                    stale_codec = native_codec_ != codec || !decoder_ready_.load() ||
                                  decode_generation != render_generation_.load();
                    feed_result = stale_codec
                        ? AndroidMediaCodec::FeedResult::BACKPRESSURE
                        : codec->feed_packet(pkt->data, (size_t)pkt->size, pkt->pts);
                }

                if (feed_result == AndroidMediaCodec::FeedResult::QUEUED) {
                    native_input_blocked = false;
                    queued_unit.reset();
                    pkt = nullptr;
                } else if (feed_result == AndroidMediaCodec::FeedResult::BACKPRESSURE) {
                    native_input_blocked = !stale_codec;
                    DecodeUnitQueue::PushResult requeue_result;
                    {
                        std::lock_guard<std::mutex> lock(queue_mutex_);
                        requeue_result = packet_queue_.return_front(std::move(*queued_unit));
                    }
                    queued_unit.reset();
                    pkt = nullptr;
                    if (requeue_result.dropped != 0) {
                        frames_dropped_.fetch_add((int)requeue_result.dropped);
                    }
                    if (requeue_result.request_idr) {
                        LiRequestIdrFrame();
                    }
                } else {
                    NF_LOGE("StreamConnection", "Native MediaCodec input failed; terminating stream");
                    decoder_ready_.store(false);
                    is_streaming_.store(false);
                    queued_unit.reset();
                    pkt = nullptr;
                    queue_cv_.notify_all();
                    LiInterruptConnection();
                }
            }

            // Output indices and image availability arrive via callbacks. A
            // zero timeout drains all work already ready without stalling input.
            NativeDecodedFrame frame;
            while (codec->dequeue_frame(frame, 0)) {
                RenderingDevice *rd = RenderingServer::get_singleton()
                    ? RenderingServer::get_singleton()->get_rendering_device() : nullptr;

                if (!(rd && rd->has_method("texture_create_from_android_hardware_buffer") && frame.buffer)) {
                    NF_LOGE("VCONN", "SKIP: rd=%p has=%d buf=%p",
                        (void*)rd, rd ? (int)rd->has_method("texture_create_from_android_hardware_buffer") : -1,
                        (void*)frame.buffer);
                    codec->release_frame(frame);
                    continue;
                }

                if (!decoder_ready_.load() || decode_generation != render_generation_.load()) {
                    codec->release_frame(frame);
                    continue;
                }

                // One-time compute pipeline setup for the generation that fed
                // this frame. Old-codec frames cannot initialize new resources.
                _ensure_compute_pipeline(rd, frame.width, frame.height, decode_generation);

                if (!decoder_ready_.load() || !compute_pipeline_ready_ ||
                    decode_generation != render_generation_.load()) {
                    codec->release_frame(frame);
                    continue;
                }

                bool cache_enabled = codec->is_import_cache_enabled();
                uint64_t buffer_id = 0;
                RID uncached_texture;
                RID uncached_sampler;
                uint64_t uncached_buffer_ptr = 0;

                if (cache_enabled) {
                    if (!codec->get_buffer_id(frame.buffer, buffer_id)) {
                        // API 31 introduced the documented stable ID. The
                        // buffer-removed listener supplies matching handle keys
                        // on older Quest OS releases.
                        buffer_id = (uint64_t)frame.buffer;
                        static bool warned_pointer_key = false;
                        if (!warned_pointer_key) {
                            warned_pointer_key = true;
                            NF_LOG("StreamConnection", "Using AHardwareBuffer handle cache keys below API 31");
                        }
                    }

                    if (!_get_or_create_ahb_import(rd, (uint64_t)frame.buffer,
                                                   buffer_id, frame.width, frame.height,
                                                   decode_generation)) {
                        codec->release_frame(frame);
                        continue;
                    }
                } else {
                    int usage = (int)RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT;
                    Variant texture_var = rd->call("texture_create_from_android_hardware_buffer",
                        (uint64_t)frame.buffer,
                        (int)RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM,
                        frame.width, frame.height, usage);
                    uncached_texture = texture_var;
                    if (!uncached_texture.is_valid()) {
                        codec->release_frame(frame);
                        continue;
                    }

                    Variant sampler_var = rd->call("texture_get_ycbcr_sampler", uncached_texture);
                    uncached_sampler = sampler_var;
                    if (!uncached_sampler.is_valid()) {
                        rd->free_rid(uncached_texture);
                        codec->release_frame(frame);
                        continue;
                    }

                    AHardwareBuffer_acquire(frame.buffer);
                    uncached_buffer_ptr = (uint64_t)frame.buffer;
                }

                RenderingServer *rs = RenderingServer::get_singleton();
                if (!rs) {
                    if (!cache_enabled) {
                        rd->free_rid(uncached_sampler);
                        rd->free_rid(uncached_texture);
                        AHardwareBuffer_release(frame.buffer);
                    }
                    codec->release_frame(frame);
                    continue;
                }

                RID replaced_texture;
                RID replaced_sampler;
                uint64_t replaced_buffer_ptr = 0;
                {
                    std::lock_guard<std::mutex> lock(pending_mutex_);
                    if (pending_dispatch_ready_ && !pending_dispatch_cached_) {
                        replaced_texture = pending_uncached_texture_;
                        replaced_sampler = pending_uncached_sampler_;
                        replaced_buffer_ptr = pending_uncached_buffer_ptr_;
                    }
                    pending_buffer_id_ = buffer_id;
                    pending_generation_ = decode_generation;
                    pending_uncached_texture_ = uncached_texture;
                    pending_uncached_sampler_ = uncached_sampler;
                    pending_uncached_buffer_ptr_ = uncached_buffer_ptr;
                    pending_width_ = frame.width;
                    pending_height_ = frame.height;
                    pending_dispatch_cached_ = cache_enabled;
                    pending_dispatch_ready_ = true;
                }
                if (replaced_sampler.is_valid()) rd->free_rid(replaced_sampler);
                if (replaced_texture.is_valid()) rd->free_rid(replaced_texture);
                if (replaced_buffer_ptr != 0) {
                    AHardwareBuffer_release((AHardwareBuffer *)replaced_buffer_ptr);
                }

                rs->call_on_render_thread(callable_mp(this, &StreamConnection::_render_compute_dispatch_rt));
                static int q_log = 0;
                if (++q_log <= 3) NF_LOG("VCONN", "CALL queued rt=%d", q_log);

                frames_decoded_.fetch_add(1);
                static int log_count = 0;
                if (++log_count <= 10)
                    NF_LOG("VCONN", "Queued compute dispatch %dx%d frame=%d", frame.width, frame.height, log_count);

                auto decode_done = std::chrono::steady_clock::now();
                auto decode_done_us = std::chrono::duration_cast<std::chrono::microseconds>(decode_done.time_since_epoch()).count();
                int64_t submit_us = last_submit_time_us_.load();
                if (submit_us > 0 && decode_done_us > submit_us)
                    last_frame_latency_us_.store((int)(decode_done_us - submit_us));

                codec->release_frame(frame);
            }
            if (codec->has_error()) {
                NF_LOGE("StreamConnection", "Native MediaCodec reported an asynchronous error; terminating stream");
                decoder_ready_.store(false);
                is_streaming_.store(false);
                queue_cv_.notify_all();
                LiInterruptConnection();
            }
            continue; // Skip FFmpeg path
        }
#endif

        if (!pkt) continue;

        if (decoder_->is_raw_decode()) {
            if (pkt->size >= (int)sizeof(RawFrameHeader)) {
                RawFrameHeader hdr;
                memcpy(&hdr, pkt->data, sizeof(hdr));
                if (hdr.magic[0] == 'R' && hdr.magic[1] == 'A' && hdr.magic[2] == 'W' && hdr.magic[3] == 'F') {
                    int w = hdr.width;
                    int h = hdr.height;
                    uint32_t expected_y = (uint32_t)w * h;
                    uint32_t expected_uv = (uint32_t)w * (h / 2);
                    if (hdr.y_size == expected_y && hdr.uv_size == expected_uv &&
                        pkt->size >= (int)(sizeof(RawFrameHeader) + expected_y + expected_uv)) {
                        frames_decoded_.fetch_add(1);

                        auto decode_done = std::chrono::steady_clock::now();
                        auto decode_done_us = std::chrono::duration_cast<std::chrono::microseconds>(decode_done.time_since_epoch()).count();
                        int64_t submit_us = last_submit_time_us_.load();
                        if (submit_us > 0 && decode_done_us > submit_us) {
                            last_frame_latency_us_.store((int)(decode_done_us - submit_us));
                        }

                        if (current_colorspace_ != AVCOL_SPC_BT709) {
                            current_colorspace_ = AVCOL_SPC_BT709;
                            current_color_range_ = AVCOL_RANGE_UNSPECIFIED;
                            uploader_->update_colorspace((int)AVCOL_SPC_BT709, (int)AVCOL_RANGE_UNSPECIFIED);
                        }

                        const uint8_t *payload = pkt->data + sizeof(RawFrameHeader);
                        uploader_->update_from_raw_nv12(w, h, payload, hdr.y_size, hdr.uv_size);
                    }
                }
            }
            queued_unit.reset();
            pkt = nullptr;
            continue;
        }

        {
            AVCodecContext *ctx = decoder_->get_codec_context();
            if (!ctx) {
                queued_unit.reset();
                pkt = nullptr;
                continue;
            }

            if (decoder_->is_hw_decode() && ctx->codec_id == AV_CODEC_ID_H264) {
                int out_size = pkt->size + 1024;
                uint8_t *out = (uint8_t *)av_malloc(out_size + AV_INPUT_BUFFER_PADDING_SIZE);
                if (out) {
                    int out_pos = 0;
                    int i = 0;
                    while (i < pkt->size - 3) {
                        int sc_len = 0;
                        if (i + 3 < pkt->size && pkt->data[i] == 0 && pkt->data[i+1] == 0 && pkt->data[i+2] == 0 && pkt->data[i+3] == 1) {
                            sc_len = 4;
                        } else if (pkt->data[i] == 0 && pkt->data[i+1] == 0 && pkt->data[i+2] == 1) {
                            sc_len = 3;
                        }

                        if (sc_len == 0) { i++; continue; }

                        int nalu_start = i + sc_len;
                        int nalu_end = pkt->size;
                        for (int j = nalu_start + 1; j < pkt->size - 2; j++) {
                            if ((pkt->data[j] == 0 && pkt->data[j+1] == 0 && pkt->data[j+2] == 1) ||
                                (j + 3 < pkt->size && pkt->data[j] == 0 && pkt->data[j+1] == 0 && pkt->data[j+2] == 0 && pkt->data[j+3] == 1)) {
                                nalu_end = j;
                                break;
                            }
                        }

                        int nalu_len = nalu_end - nalu_start;
                        if (out_pos + 4 + nalu_len > out_size) break;

                        out[out_pos++] = (nalu_len >> 24) & 0xFF;
                        out[out_pos++] = (nalu_len >> 16) & 0xFF;
                        out[out_pos++] = (nalu_len >> 8) & 0xFF;
                        out[out_pos++] = nalu_len & 0xFF;
                        memcpy(out + out_pos, pkt->data + nalu_start, nalu_len);
                        out_pos += nalu_len;

                        i = nalu_end;
                    }

                    av_packet_unref(pkt);
                    av_new_packet(pkt, out_pos);
                    memcpy(pkt->data, out, out_pos);
                    av_freep(&out);
                }
            }

            int send_ret = avcodec_send_packet(ctx, pkt);

            queued_unit.reset();
            pkt = nullptr;

            if (send_ret < 0 && send_ret != AVERROR(EAGAIN) && send_ret != AVERROR_EOF) {
                continue;
            }

            while (true) {
                AVFrame *tmp = av_frame_alloc();
                int recv_ret = avcodec_receive_frame(ctx, tmp);

                if (recv_ret == AVERROR(EAGAIN) || recv_ret == AVERROR_EOF) {
                    av_frame_free(&tmp);
                    break;
                }
                if (recv_ret < 0) {
                    av_frame_free(&tmp);
                    break;
                }

                if (h264_hw_upgrade_pending_.load() && !h264_hw_upgraded_.load()) {
                    _try_h264_hw_upgrade();
                    if (h264_hw_upgraded_.load()) {
                        av_frame_free(&tmp);
                        break;
                    }
                }

                auto frame_count = frames_decoded_.fetch_add(1) + 1;

                auto decode_done = std::chrono::steady_clock::now();
                auto decode_done_us = std::chrono::duration_cast<std::chrono::microseconds>(decode_done.time_since_epoch()).count();
                int64_t submit_us = last_submit_time_us_.load();
                if (submit_us > 0 && decode_done_us > submit_us) {
                    last_frame_latency_us_.store((int)(decode_done_us - submit_us));
                }

                AVFrame *final_frame = tmp;
                AVFrame *sw_frame = nullptr;
                bool used_ahb = false;
                if (tmp->hw_frames_ctx) {
                    // AHardwareBuffer GPU-only path (Android, custom Godot build).
                    // No fallback — must succeed or frame is discarded.
#ifdef __ANDROID__
                    if (decoder_->get_codec_context()) {
                        jobject codec_obj = (jobject)mediacodec_get_codec_object(
                            decoder_->get_codec_context());
                        ssize_t buf_idx = mediacodec_get_buffer_index(tmp);
                        if (codec_obj && buf_idx >= 0) {
                            AHardwareBuffer *ahb = mediacodec_get_ahb(codec_obj, buf_idx);
                            if (ahb) {
                                AHardwareBuffer_Desc desc;
                                AHardwareBuffer_describe(ahb, &desc);
                                int w = desc.width;
                                int h = desc.height;

                                RenderingDevice *rd = RenderingServer::get_singleton()
                                    ? RenderingServer::get_singleton()->get_rendering_device()
                                    : nullptr;

                                if (rd && rd->has_method("texture_create_from_android_hardware_buffer")) {
                                    int usage = (int)(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
                                    Variant tex_rid_var = rd->call("texture_create_from_android_hardware_buffer",
                                        (uint64_t)ahb, (int)RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, w, h, usage);
                                    RID tex_rid = tex_rid_var;
                                    if (tex_rid.is_valid()) {
                                        uploader_->ensure_shader_material();
                                        uploader_->set_texture_from_native_rid(tex_rid, w, h);
                                        used_ahb = true;
                                    } else {
                                        NF_LOGE("StreamConnection", "Tier1: texture_create_from_android_hardware_buffer returned invalid RID!");
                                    }
                                } else {
                                    NF_LOGE("StreamConnection", "Tier1: Godot API texture_create_from_android_hardware_buffer not available. Custom engine build required.");
                                }
                                AHardwareBuffer_release(ahb);
                            } else {
                                NF_LOGE("StreamConnection", "Tier1: mediacodec_get_ahb returned null");
                            }
                        } else {
                            NF_LOGE("StreamConnection", "Tier1: cannot get MediaCodec object or buffer index");
                        }
                    }
#endif
                    if (!used_ahb) {
                        // Fallback: av_hwframe_map/transfer (legacy path)
                        sw_frame = av_frame_alloc();
                        int transfer_ret = av_hwframe_map(sw_frame, tmp, AV_HWFRAME_MAP_READ);
                        if (transfer_ret < 0) {
                            transfer_ret = av_hwframe_transfer_data(sw_frame, tmp, 0);
                        }
                        if (transfer_ret >= 0) {
                            av_frame_copy_props(sw_frame, tmp);
                            final_frame = sw_frame;
                        } else {
                            av_frame_free(&sw_frame);
                            sw_frame = nullptr;
                        }
                    }
                }

                if (frame_count <= 5 || frame_count % 60 == 0) {
                    NF_LOG("StreamConnection", "Frame #%d: pix_fmt=%d(%s) %dx%d colorspace=%d range=%d hw=%s",
                           frame_count, final_frame->format,
                           av_get_pix_fmt_name((AVPixelFormat)final_frame->format),
                           final_frame->width, final_frame->height,
                           (int)final_frame->colorspace, (int)final_frame->color_range,
                           final_frame->hw_frames_ctx ? "yes" : "no");
                }

                AVColorSpace frame_cs = _resolve_frame_colorspace(final_frame);
                AVColorRange frame_cr = (AVColorRange)final_frame->color_range;
                if (frame_cs != current_colorspace_ || frame_cr != current_color_range_) {
                    current_colorspace_ = frame_cs;
                    current_color_range_ = frame_cr;
                    uploader_->update_colorspace((int)frame_cs, (int)frame_cr);
                }

                if (!used_ahb) {
                    uploader_->update_from_frame(final_frame);
                }

                if (sw_frame) {
                    av_frame_free(&sw_frame);
                }
                av_frame_free(&tmp);
            }
        }
    }

    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        _clear_packet_queue();
    }
}

void StreamConnection::_clear_packet_queue() {
    packet_queue_.clear();
}

void StreamConnection::start(const String &host, const Dictionary &server_info, const Dictionary &stream_config, bool disable_hw) {
    if (connection_thread_.joinable()) {
        is_streaming_.store(false);
        decoder_ready_.store(false);
        queue_cv_.notify_all();
        LiInterruptConnection();
        connection_thread_.join();
        LiStopConnection();
    }

    if (decode_thread_.joinable()) {
        decode_thread_.join();
    }

#ifdef __ANDROID__
    _replace_native_codec(nullptr);
    native_codec_event_.store(false);
#endif

    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        _clear_packet_queue();
    }

    host_address_ = host;

    LiInitializeServerInformation(&server_info_);
    host_address_std_ = host.utf8().get_data();
    server_info_.address = host_address_std_.c_str();

    if (server_info.has("rtsp_session_url")) {
        rtsp_url_std_ = String(server_info["rtsp_session_url"]).utf8().get_data();
        server_info_.rtspSessionUrl = rtsp_url_std_.c_str();
    }
    if (server_info.has("server_app_version")) {
        app_version_std_ = String(server_info["server_app_version"]).utf8().get_data();
        server_info_.serverInfoAppVersion = app_version_std_.c_str();
    }
    if (server_info.has("server_gfe_version")) {
        gfe_version_std_ = String(server_info["server_gfe_version"]).utf8().get_data();
        server_info_.serverInfoGfeVersion = gfe_version_std_.c_str();
    }
    if (server_info.has("server_codec_mode_support")) {
        server_info_.serverCodecModeSupport = (int)server_info["server_codec_mode_support"];
    }

    LiInitializeStreamConfiguration(&stream_config_);
    stream_config_.width = (int)stream_config.get("width", 1920);
    stream_config_.height = (int)stream_config.get("height", 1080);
    stream_config_.fps = (int)stream_config.get("fps", 60);
    stream_config_.bitrate = (int)stream_config.get("bitrate", 20000);
    stream_config_.packetSize = (int)stream_config.get("packet_size", 1024);
    stream_config_.streamingRemotely = (int)stream_config.get("streaming_remotely", STREAM_CFG_AUTO);
    stream_config_.audioConfiguration = (int)stream_config.get("audio_configuration", AUDIO_CONFIGURATION_STEREO);
    stream_config_.supportedVideoFormats = (int)stream_config.get("supported_video_formats", VIDEO_FORMAT_MASK_H264);
    stream_config_.clientRefreshRateX100 = (int)stream_config.get("client_refresh_rate_x100", 0);
    stream_config_.colorSpace = (int)stream_config.get("color_space", COLORSPACE_REC_709);
    stream_config_.colorRange = (int)stream_config.get("color_range", COLOR_RANGE_LIMITED);
    stream_config_.encryptionFlags = (int)stream_config.get("encryption_flags", ENCFLG_ALL);

    NF_LOG("StreamConnection", "Starting stream: %dx%d@%d %dkbps fmt=0x%x colorspace=%d range=%d pkt=%d",
           stream_config_.width, stream_config_.height, stream_config_.fps,
           stream_config_.bitrate, stream_config_.supportedVideoFormats,
           stream_config_.colorSpace, stream_config_.colorRange,
           stream_config_.packetSize);

    if (stream_config.has("remote_input_aes_key")) {
        PackedByteArray key = stream_config["remote_input_aes_key"];
        if (key.size() == 16) {
            memcpy(stream_config_.remoteInputAesKey, key.ptr(), 16);
        }
    }
    if (stream_config.has("remote_input_aes_iv")) {
        PackedByteArray iv = stream_config["remote_input_aes_iv"];
        if (iv.size() == 16) {
            memcpy(stream_config_.remoteInputAesIv, iv.ptr(), 16);
        }
    }

    active_instance_ = this;
    AudioRenderer::active_instance_ = audio_renderer_.ptr();

    connection_thread_ = std::thread(&StreamConnection::_connection_thread_func, this);
    decode_thread_ = std::thread(&StreamConnection::_decode_thread_func, this);
}

void StreamConnection::stop() {
    if (!is_streaming_.load() && !connection_thread_.joinable()) return;

    is_streaming_.store(false);
    decoder_ready_.store(false);
    queue_cv_.notify_all();

    LiInterruptConnection();

    if (connection_thread_.joinable()) {
        connection_thread_.join();
    }

    LiStopConnection();

    if (decode_thread_.joinable()) {
        decode_thread_.join();
    }

#ifdef __ANDROID__
    // No callback may retain the StreamConnection wakeup after stop returns.
    _replace_native_codec(nullptr);
    native_codec_event_.store(false);
#endif

    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        _clear_packet_queue();
    }

    if (audio_renderer_.is_valid()) {
        audio_renderer_->cleanup();
    }

    active_instance_ = nullptr;
    AudioRenderer::active_instance_ = nullptr;
}

bool StreamConnection::is_streaming() const {
    return is_streaming_.load();
}

void StreamConnection::set_local_capture_mode(bool enabled) {
    local_capture_mode_ = enabled;
}

bool StreamConnection::get_local_capture_mode() const {
    return local_capture_mode_;
}

int StreamConnection::probe_video_format(int codec_preference, bool disable_hw) {
    if (!decoder_.is_valid()) return VIDEO_FORMAT_MASK_H264;
    return decoder_->probe_video_format(codec_preference, disable_hw);
}

Dictionary StreamConnection::probe_all_video_formats() {
    Dictionary result;
    if (!decoder_.is_valid()) {
        result["h264"] = true;
        result["hevc"] = false;
        result["av1"] = false;
        result["raw"] = true;
        return result;
    }
    int h264_mask = decoder_->probe_video_format(FfmpegDecoder::CODEC_FAMILY_H264, false);
    result["h264"] = (h264_mask & VIDEO_FORMAT_MASK_H264) != 0;

    int hevc_mask = decoder_->probe_video_format(FfmpegDecoder::CODEC_FAMILY_H265, false);
    result["hevc"] = (hevc_mask & VIDEO_FORMAT_MASK_H265) != 0;

    int av1_mask = decoder_->probe_video_format(FfmpegDecoder::CODEC_FAMILY_AV1, false);
    result["av1"] = (av1_mask & VIDEO_FORMAT_MASK_AV1) != 0;

    result["raw"] = true;
    return result;
}

int StreamConnection::get_server_codec_mode_support() const {
    return server_info_.serverCodecModeSupport;
}

Ref<FfmpegDecoder> StreamConnection::get_decoder() const {
    return decoder_;
}

Ref<TextureUploader> StreamConnection::get_texture_uploader() const {
    return uploader_;
}

Ref<ShaderMaterial> StreamConnection::get_shader_material() const {
    if (uploader_.is_valid()) {
        return uploader_->get_shader_material();
    }
    return nullptr;
}

Ref<AudioRenderer> StreamConnection::get_audio_renderer() const {
    return audio_renderer_;
}

Ref<InputBridge> StreamConnection::get_input_bridge() const {
    return input_bridge_;
}

Ref<DepthBridge> StreamConnection::get_depth_bridge() const {
    return depth_bridge_;
}

int StreamConnection::get_frames_dropped() const {
    return frames_dropped_.load();
}

int StreamConnection::get_frames_decoded() const {
    return frames_decoded_.load();
}

int StreamConnection::get_decode_queue_size() const {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    return (int)packet_queue_.size();
}

int StreamConnection::get_last_frame_latency_us() const {
    return last_frame_latency_us_.load();
}

bool StreamConnection::is_display_ready() const {
#ifdef __ANDROID__
    return display_wired_.load();
#else
    return true;
#endif
}

String StreamConnection::get_decoder_name() const {
    if (decoder_.is_valid()) return decoder_->get_decoder_name();
    return "";
}

int StreamConnection::get_video_width() const {
    if (decoder_.is_valid() && decoder_->get_video_width() > 0) return decoder_->get_video_width();
#ifdef __ANDROID__
    if (native_video_width_ > 0) return native_video_width_;
#endif
    return 0;
}

int StreamConnection::get_video_height() const {
    if (decoder_.is_valid() && decoder_->get_video_height() > 0) return decoder_->get_video_height();
#ifdef __ANDROID__
    if (native_video_height_ > 0) return native_video_height_;
#endif
    return 0;
}

bool StreamConnection::is_hw_decode() const {
#ifdef __ANDROID__
    if (_get_native_codec()) return true; // Native MediaCodec is always HW
#endif
    if (decoder_.is_valid()) return decoder_->is_hw_decode();
    return false;
}

String StreamConnection::get_error_string(int error_code) {
    switch (error_code) {
        case ML_ERROR_GRACEFUL_TERMINATION:
            return "Connection terminated gracefully";
        case ML_ERROR_NO_VIDEO_TRAFFIC:
            return "Terminating connection due to lack of video traffic";
        case ML_ERROR_NO_VIDEO_FRAME:
            return "No video frame received";
        case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
            return "Unexpected early termination";
        case ML_ERROR_PROTECTED_CONTENT:
            return "Protected content detected";
        case ML_ERROR_FRAME_CONVERSION:
            return "Frame conversion error";
        default:
            if (error_code > 0)
                return "Connection error: " + String::num_int64(error_code);
            return "Unknown error (" + String::num_int64(error_code) + ")";
    }
}

void StreamConnection::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start", "host", "server_info", "stream_config", "disable_hw"), &StreamConnection::start, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop"), &StreamConnection::stop);
    ClassDB::bind_method(D_METHOD("is_streaming"), &StreamConnection::is_streaming);
    ClassDB::bind_method(D_METHOD("set_local_capture_mode", "enabled"), &StreamConnection::set_local_capture_mode);
    ClassDB::bind_method(D_METHOD("get_local_capture_mode"), &StreamConnection::get_local_capture_mode);
    ClassDB::bind_method(D_METHOD("probe_video_format", "codec_preference", "disable_hw"), &StreamConnection::probe_video_format);
    ClassDB::bind_method(D_METHOD("probe_all_video_formats"), &StreamConnection::probe_all_video_formats);
    ClassDB::bind_method(D_METHOD("get_server_codec_mode_support"), &StreamConnection::get_server_codec_mode_support);
    ClassDB::bind_method(D_METHOD("get_decoder"), &StreamConnection::get_decoder);
    ClassDB::bind_method(D_METHOD("get_texture_uploader"), &StreamConnection::get_texture_uploader);
    ClassDB::bind_method(D_METHOD("get_shader_material"), &StreamConnection::get_shader_material);
    ClassDB::bind_method(D_METHOD("get_audio_renderer"), &StreamConnection::get_audio_renderer);
    ClassDB::bind_method(D_METHOD("get_input_bridge"), &StreamConnection::get_input_bridge);
    ClassDB::bind_method(D_METHOD("get_depth_bridge"), &StreamConnection::get_depth_bridge);
    ClassDB::bind_method(D_METHOD("get_frames_dropped"), &StreamConnection::get_frames_dropped);
    ClassDB::bind_method(D_METHOD("get_frames_decoded"), &StreamConnection::get_frames_decoded);
    ClassDB::bind_method(D_METHOD("get_decode_queue_size"), &StreamConnection::get_decode_queue_size);
    ClassDB::bind_method(D_METHOD("get_last_frame_latency_us"), &StreamConnection::get_last_frame_latency_us);
    ClassDB::bind_method(D_METHOD("is_display_ready"), &StreamConnection::is_display_ready);
    ClassDB::bind_method(D_METHOD("get_decoder_name"), &StreamConnection::get_decoder_name);
    ClassDB::bind_method(D_METHOD("get_video_width"), &StreamConnection::get_video_width);
    ClassDB::bind_method(D_METHOD("get_video_height"), &StreamConnection::get_video_height);
    ClassDB::bind_method(D_METHOD("is_hw_decode"), &StreamConnection::is_hw_decode);
    ClassDB::bind_static_method("StreamConnection", D_METHOD("get_error_string", "error_code"), &StreamConnection::get_error_string);

    ADD_SIGNAL(MethodInfo("stream_started"));
    ADD_SIGNAL(MethodInfo("stream_terminated", PropertyInfo(Variant::INT, "error_code"), PropertyInfo(Variant::STRING, "error_message")));
    ADD_SIGNAL(MethodInfo("stage_starting", PropertyInfo(Variant::STRING, "stage_name")));
    ADD_SIGNAL(MethodInfo("stage_complete", PropertyInfo(Variant::STRING, "stage_name")));
    ADD_SIGNAL(MethodInfo("stage_failed", PropertyInfo(Variant::STRING, "stage_name"), PropertyInfo(Variant::INT, "error_code")));
    ADD_SIGNAL(MethodInfo("controller_rumble", PropertyInfo(Variant::INT, "controller"), PropertyInfo(Variant::INT, "low_freq"), PropertyInfo(Variant::INT, "high_freq")));
    ADD_SIGNAL(MethodInfo("controller_trigger_rumble", PropertyInfo(Variant::INT, "controller"), PropertyInfo(Variant::INT, "left_motor"), PropertyInfo(Variant::INT, "right_motor")));
    ADD_SIGNAL(MethodInfo("motion_event_requested", PropertyInfo(Variant::INT, "controller"), PropertyInfo(Variant::INT, "motion_type"), PropertyInfo(Variant::INT, "rate_hz")));
    ADD_SIGNAL(MethodInfo("controller_led_set", PropertyInfo(Variant::INT, "controller"), PropertyInfo(Variant::INT, "r"), PropertyInfo(Variant::INT, "g"), PropertyInfo(Variant::INT, "b")));
    ADD_SIGNAL(MethodInfo("connection_status_update", PropertyInfo(Variant::INT, "status")));
    ADD_SIGNAL(MethodInfo("hdr_mode_changed", PropertyInfo(Variant::BOOL, "hdr_enabled"), PropertyInfo(Variant::DICTIONARY, "metadata")));
    ADD_SIGNAL(MethodInfo("log_message", PropertyInfo(Variant::STRING, "message")));
    ADD_SIGNAL(MethodInfo("h264_hw_upgraded"));
}
