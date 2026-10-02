#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

// pyrowave.h uses Vulkan types directly (VkQueue, VkInstance, etc.) without
// including the Vulkan headers itself - the NDK ships them, so this is the
// only extra include needed on Android.
#include <vulkan/vulkan.h>
#include <pyrowave.h>

#include "pyrowave_gpu_pipeline.h"

namespace godot {

class TextureUploader;

// Creates PyroWave's shared Vulkan device as early as possible - called once
// from register_types.cpp at MODULE_INITIALIZATION_LEVEL_CORE, before Godot's
// renderer creates its own GLES/EGL context. Quest 3's Adreno driver fails
// pyrowave_create_default_device() if it's called after a GLES context
// already exists in-process (confirmed: identical device-creation call
// succeeds in a standalone process, but fails every time once called from
// inside the running Godot/OpenXR app - see docs/plans/active/pyrowave-codec.md).
// Safe to call more than once; only the first call does anything.
void pyrowave_warmup_device();

// Wraps PyroWave's C API (addons/nightfall-stream/third_party/pyrowave) for
// the intra-only, GPU-compute PyroWave codec - see
// docs/plans/active/pyrowave-codec.md for the full integration plan and
// references. Unlike AndroidMediaCodec, this has no async/Surface pipeline:
// PyroWave owns its own self-contained, headless Vulkan device internally,
// and decode() below is a single synchronous call that reads the GPU result
// back to plain CPU YUV420p planes before returning - safe to call directly
// from the decode thread, same as it already blocks on dequeue_frame() for
// the MediaCodec path today.
//
// The Vulkan device itself is the long-lived, warmed-up one from
// pyrowave_warmup_device() above (device_ here is a non-owning reference to
// it) - only the per-connection pyrowave_decoder is created/destroyed here.
class PyrowaveDecoder {
public:
    PyrowaveDecoder() = default;
    ~PyrowaveDecoder();

    // With an uploader, tries the zero-copy GPU path first (pyrowave_gpu_pipeline.h)
    // and falls back to the CPU-readback path if it can't be set up. On the GPU path,
    // on_gpu_frame_complete(pts) fires (from another thread) when a frame's GPU work is
    // done; on the CPU path decode() itself returning true means the frame is done.
    bool init(int width, int height, TextureUploader *uploader = nullptr,
              std::function<void(int64_t)> on_gpu_frame_complete = nullptr);
    void destroy();

    // True when decode() delivers frames straight to the uploader's GPU output;
    // the y/u/v_data() planes below are then not filled.
    bool uses_gpu_output() const;

    // Decodes one full PyroWave-framed decode-unit payload: the 'PYW1'
    // magic + packet-count header + concatenated sub-packets, exactly as
    // the host's PyroWave encoder produces it (see zevro-ai/moonlight's
    // pyrowave.cpp, which this mirrors - moonlight-common-c's
    // VideoDepacketizer treats this payload as opaque, so the framing is
    // entirely ours to parse here). On success, the decoded Y/U/V planes
    // are left in the scratch buffers below (valid until the next decode()
    // call) and true is returned.
    bool decode(const uint8_t *payload, size_t len, int64_t pts = 0);

    int width() const { return width_; }
    int height() const { return height_; }
    const uint8_t *y_data() const { return output_y_.data(); }
    const uint8_t *u_data() const { return output_u_.data(); }
    const uint8_t *v_data() const { return output_v_.data(); }
    int y_stride() const { return width_; }
    int uv_stride() const { return width_ / 2; }

    // BT.709 limited-range YCbCr -> RGBA8, done on the CPU right after
    // decode() succeeds (see its own comment for why: sidesteps the
    // half-resolution dual-chroma-texture upload path, which - unlike this
    // single full-resolution RGBA texture - has never been exercised on
    // Android's gl_compatibility renderer before PyroWave). Matches the
    // composition shader's color_matrix_type==1 formula exactly, since the
    // shader is told color_matrix_type==3 (tex_y already RGB, no further
    // conversion) when fed through this path.
    const uint8_t *rgba_data() const { return output_rgba_.data(); }

    // Last-frame timing breakdown, for perf diagnosis - see decode()'s own
    // periodic [TIMING] log for the averaged version.
    double last_decode_ms() const { return last_decode_ms_; }
    double last_convert_ms() const { return last_convert_ms_; }

private:
    pyrowave_device device_ = nullptr;
    pyrowave_decoder decoder_ = nullptr;
    int width_ = 0;
    int height_ = 0;
    std::vector<uint8_t> output_y_;
    std::vector<uint8_t> output_u_;
    std::vector<uint8_t> output_v_;
    std::vector<uint8_t> output_rgba_;
    double last_decode_ms_ = 0.0;
    double last_convert_ms_ = 0.0;
#ifdef __ANDROID__
    std::unique_ptr<PyrowaveGpuPipeline> gpu_;
#endif

    void convert_to_rgba();

    PyrowaveDecoder(const PyrowaveDecoder &) = delete;
    PyrowaveDecoder &operator=(const PyrowaveDecoder &) = delete;
};

} // namespace godot
