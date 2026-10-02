#include "pyrowave_decoder.h"

#include "nf_log.h"

#include <chrono>
#include <string>

namespace {
// vibepollo's "length-prefixed framing" (docs/pyrowave-protocol.md on the
// host) - used whenever the client's ANNOUNCE doesn't negotiate
// pyrowaveAdaptiveFec/pyrowaveFeatures (ours doesn't). No magic: a u32
// packet count, then that many interleaved [u32 size][size bytes] pairs -
// NOT a single up-front size table followed by concatenated data (that's
// zevro-ai/moonlight's own host convention, which this host doesn't use).
// Packet 0 is always the sequence header.
constexpr uint32_t kMaxPacketCount = 4096;

uint32_t read_u32(const uint8_t *data) {
    return (uint32_t)data[0] |
           ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}

pyrowave_device g_warm_device = nullptr;
bool g_warmup_attempted = false;
} // namespace

namespace godot {

void pyrowave_warmup_device() {
    if (g_warmup_attempted) {
        return;
    }
    g_warmup_attempted = true;
#ifdef __ANDROID__
    // Our own VkDevice enables the zero-copy GPU output path; the default device
    // below only supports the CPU-readback path.
    g_warm_device = pyrowave_gpu_create_device();
    if (g_warm_device) {
        NF_LOG("PyrowaveDecoder", "Warmup device created (own VkDevice, zero-copy capable)");
        return;
    }
#endif
    if (pyrowave_create_default_device(&g_warm_device) != PYROWAVE_SUCCESS || !g_warm_device) {
        NF_LOGE("PyrowaveDecoder", "Warmup device creation failed");
        g_warm_device = nullptr;
    } else {
        NF_LOG("PyrowaveDecoder", "Warmup device created");
    }
}

PyrowaveDecoder::~PyrowaveDecoder() {
    destroy();
}

bool PyrowaveDecoder::uses_gpu_output() const {
#ifdef __ANDROID__
    return gpu_ != nullptr;
#else
    return false;
#endif
}

bool PyrowaveDecoder::init(int width, int height, TextureUploader *uploader,
                           std::function<void(int64_t)> on_gpu_frame_complete) {
    destroy();

    // Falls back to a late attempt if warmup didn't run or failed, but the
    // whole point is that this should already have succeeded at startup -
    // see pyrowave_warmup_device()'s comment in the header.
    if (!g_warm_device) {
        pyrowave_warmup_device();
    }
    if (!g_warm_device) {
        NF_LOGE("PyrowaveDecoder", "No warm device available");
        return false;
    }
    device_ = g_warm_device;

    pyrowave_decoder_create_info info = {};
    info.device = device_;
    info.width = width;
    info.height = height;
    info.chroma = PYROWAVE_CHROMA_SUBSAMPLING_420;
#ifdef __ANDROID__
    const bool try_gpu = uploader && pyrowave_gpu_available();
    // The fragment path is PyroWave's recommendation for mobile GPUs (true on Adreno).
    // The CPU-readback path keeps its long-standing compute-path default.
    info.fragment_path = try_gpu && pyrowave_decoder_device_prefers_fragment_path(device_);
#endif

    if (pyrowave_decoder_create(&info, &decoder_) != PYROWAVE_SUCCESS || !decoder_) {
        NF_LOGE("PyrowaveDecoder", "Decoder creation failed (%dx%d)", width, height);
        device_ = nullptr;
        decoder_ = nullptr;
        return false;
    }

    width_ = width;
    height_ = height;

#ifdef __ANDROID__
    if (try_gpu) {
        gpu_ = std::make_unique<PyrowaveGpuPipeline>();
        if (gpu_->init(device_, decoder_, info.fragment_path, width, height, uploader,
                       std::move(on_gpu_frame_complete))) {
            NF_LOG("PyrowaveDecoder", "Initialized %dx%d (zero-copy GPU output)", width, height);
            return true;
        }
        NF_LOGE("PyrowaveDecoder", "Zero-copy GPU output unavailable, falling back to CPU readback");
        gpu_.reset();
    }
#endif
    output_y_.assign((size_t)width * (size_t)height, 0);
    output_u_.assign((size_t)(width / 2) * (size_t)(height / 2), 0);
    output_v_.assign((size_t)(width / 2) * (size_t)(height / 2), 0);
    output_rgba_.assign((size_t)width * (size_t)height * 4, 0);
    NF_LOG("PyrowaveDecoder", "Initialized %dx%d", width, height);
    return true;
}

namespace {
inline uint8_t clamp_u8(float v) {
    return (uint8_t)(v < 0.0f ? 0.0f : (v > 255.0f ? 255.0f : v));
}
} // namespace

void PyrowaveDecoder::convert_to_rgba() {
    int uv_w = width_ / 2;
    const uint8_t *y_plane = output_y_.data();
    const uint8_t *u_plane = output_u_.data();
    const uint8_t *v_plane = output_v_.data();
    uint8_t *dst = output_rgba_.data();

    for (int row = 0; row < height_; row++) {
        const uint8_t *y_row = y_plane + (size_t)row * width_;
        const uint8_t *u_row = u_plane + (size_t)(row / 2) * uv_w;
        const uint8_t *v_row = v_plane + (size_t)(row / 2) * uv_w;
        uint8_t *dst_row = dst + (size_t)row * width_ * 4;
        for (int col = 0; col < width_; col++) {
            float y_raw = y_row[col];
            float u_raw = u_row[col / 2];
            float v_raw = v_row[col / 2];
            // BT.709 limited range, matching the composition shader's
            // color_matrix_type==1 formula exactly.
            float y = (y_raw - 16.0f) * (255.0f / 219.0f);
            float u = (u_raw - 128.0f) * (255.0f / 224.0f);
            float v = (v_raw - 128.0f) * (255.0f / 224.0f);
            uint8_t *px = dst_row + col * 4;
            px[0] = clamp_u8(y + 1.5748f * v);
            px[1] = clamp_u8(y - 0.1873f * u - 0.4681f * v);
            px[2] = clamp_u8(y + 1.8556f * u);
            px[3] = 255;
        }
    }
}

void PyrowaveDecoder::destroy() {
#ifdef __ANDROID__
    // Before the decoder: the pipeline idles the queue that still references it.
    gpu_.reset();
#endif
    if (decoder_) {
        pyrowave_decoder_destroy(decoder_);
        decoder_ = nullptr;
    }
    // device_ is a non-owning reference to the shared warm device - never
    // destroyed here, it lives for the whole app lifetime.
    device_ = nullptr;
    width_ = 0;
    height_ = 0;
}

bool PyrowaveDecoder::decode(const uint8_t *payload, size_t len, int64_t pts) {
    if (!decoder_ || !payload || len < 4) {
        return false;
    }

    uint32_t packet_count = read_u32(payload);
    if (packet_count == 0 || packet_count > kMaxPacketCount) {
        NF_LOGE("PyrowaveDecoder", "Bad packet count (count=%u len=%zu)", packet_count, len);
        return false;
    }

    pyrowave_decoder_clear(decoder_);

    size_t offset = 4;
    for (uint32_t i = 0; i < packet_count; i++) {
        if (offset + 4 > len) {
            NF_LOGE("PyrowaveDecoder", "Packet %u size field overruns payload", i);
            return false;
        }
        uint32_t packet_size = read_u32(payload + offset);
        offset += 4;
        if (offset + packet_size > len) {
            NF_LOGE("PyrowaveDecoder", "Packet %u overruns payload", i);
            return false;
        }
        if (pyrowave_decoder_push_packet(decoder_, payload + offset, packet_size) != PYROWAVE_SUCCESS) {
            NF_LOGE("PyrowaveDecoder", "push_packet failed at %u/%u", i, packet_count);
            return false;
        }
        offset += packet_size;
    }

    if (!pyrowave_decoder_decode_is_ready(decoder_, false)) {
        NF_LOGE("PyrowaveDecoder", "Frame incomplete after %u packets", packet_count);
        return false;
    }

#ifdef __ANDROID__
    if (gpu_) {
        auto t0 = std::chrono::steady_clock::now();
        bool ok = gpu_->decode_frame(pts);
        double submit_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        last_decode_ms_ = submit_ms;
        last_convert_ms_ = 0.0;
        static double sum_submit_ms = 0;
        static int submit_count = 0;
        sum_submit_ms += submit_ms;
        if (++submit_count >= 120) {
            NF_LOG("PyrowaveDecoder", "[TIMING] zero-copy decode-thread cost=%.2fms (record+submit, avg over %d frames)",
                   sum_submit_ms / submit_count, submit_count);
            sum_submit_ms = 0;
            submit_count = 0;
        }
        return ok;
    }
#endif

    pyrowave_cpu_buffer buffer = {};
    buffer.format = PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;
    buffer.width = width_;
    buffer.height = height_;
    buffer.data[0] = output_y_.data();
    buffer.data[1] = output_u_.data();
    buffer.data[2] = output_v_.data();
    buffer.row_stride_in_bytes[0] = (size_t)width_;
    buffer.row_stride_in_bytes[1] = (size_t)(width_ / 2);
    buffer.row_stride_in_bytes[2] = (size_t)(width_ / 2);
    buffer.plane_size_in_bytes[0] = output_y_.size();
    buffer.plane_size_in_bytes[1] = output_u_.size();
    buffer.plane_size_in_bytes[2] = output_v_.size();

    auto t0 = std::chrono::steady_clock::now();
    if (pyrowave_decoder_decode_cpu_buffer_synchronous(decoder_, &buffer) != PYROWAVE_SUCCESS) {
        NF_LOGE("PyrowaveDecoder", "decode_cpu_buffer_synchronous failed");
        return false;
    }
    auto t1 = std::chrono::steady_clock::now();
    // Skipped while retrying the GPU-shader conversion path - no need to
    // waste CPU computing output_rgba_ when stream_connection.cpp isn't
    // consuming it right now.
    auto t2 = std::chrono::steady_clock::now();

    double decode_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    double convert_ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
    last_decode_ms_ = decode_ms;
    last_convert_ms_ = convert_ms;

    static double sum_decode_ms = 0, sum_convert_ms = 0;
    static int perf_count = 0;
    sum_decode_ms += decode_ms;
    sum_convert_ms += convert_ms;
    perf_count++;
    if (perf_count >= 120) {
        NF_LOG("PyrowaveDecoder", "[TIMING] GPU decode+readback=%.2fms convert_to_rgba=%.2fms (avg over %d frames)",
               sum_decode_ms / perf_count, sum_convert_ms / perf_count, perf_count);
        sum_decode_ms = 0;
        sum_convert_ms = 0;
        perf_count = 0;
    }
    return true;
}

} // namespace godot
