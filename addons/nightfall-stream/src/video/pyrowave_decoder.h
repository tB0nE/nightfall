#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// pyrowave.h uses Vulkan types directly (VkQueue, VkInstance, etc.) without
// including the Vulkan headers itself - the NDK ships them, so this is the
// only extra include needed on Android.
#include <vulkan/vulkan.h>
#include <pyrowave.h>

// Wraps PyroWave's C API (addons/nightfall-stream/third_party/pyrowave) for
// the intra-only, GPU-compute PyroWave codec - see
// docs/plans/active/pyrowave-codec.md for the full integration plan and
// references. Unlike AndroidMediaCodec, this has no async/Surface pipeline:
// PyroWave owns its own self-contained, headless Vulkan device internally,
// and decode() below is a single synchronous call that reads the GPU result
// back to plain CPU YUV420p planes before returning - safe to call directly
// from the decode thread, same as it already blocks on dequeue_frame() for
// the MediaCodec path today.
class PyrowaveDecoder {
public:
    PyrowaveDecoder() = default;
    ~PyrowaveDecoder();

    bool init(int width, int height);
    void destroy();

    // Decodes one full PyroWave-framed decode-unit payload: the 'PYW1'
    // magic + packet-count header + concatenated sub-packets, exactly as
    // the host's PyroWave encoder produces it (see zevro-ai/moonlight's
    // pyrowave.cpp, which this mirrors - moonlight-common-c's
    // VideoDepacketizer treats this payload as opaque, so the framing is
    // entirely ours to parse here). On success, the decoded Y/U/V planes
    // are left in the scratch buffers below (valid until the next decode()
    // call) and true is returned.
    bool decode(const uint8_t *payload, size_t len);

    int width() const { return width_; }
    int height() const { return height_; }
    const uint8_t *y_data() const { return output_y_.data(); }
    const uint8_t *u_data() const { return output_u_.data(); }
    const uint8_t *v_data() const { return output_v_.data(); }
    int y_stride() const { return width_; }
    int uv_stride() const { return width_ / 2; }

private:
    pyrowave_device device_ = nullptr;
    pyrowave_decoder decoder_ = nullptr;
    int width_ = 0;
    int height_ = 0;
    std::vector<uint8_t> output_y_;
    std::vector<uint8_t> output_u_;
    std::vector<uint8_t> output_v_;

    PyrowaveDecoder(const PyrowaveDecoder &) = delete;
    PyrowaveDecoder &operator=(const PyrowaveDecoder &) = delete;
};
