#include "pyrowave_decoder.h"

#include "nf_log.h"

namespace {
// Matches zevro-ai/moonlight's pyrowave.cpp - the private PyroWave framing
// the host's encoder wraps each decode unit's payload in ('PYW1', then a
// u32 packet count, then that many u32 packet sizes, then the concatenated
// packet data).
constexpr uint32_t kPayloadMagic = 0x31575950u; // 'PYW1'
constexpr uint32_t kMaxPacketCount = 4096;

uint32_t read_u32(const uint8_t *data) {
    return (uint32_t)data[0] |
           ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}
} // namespace

namespace godot {

PyrowaveDecoder::~PyrowaveDecoder() {
    destroy();
}

bool PyrowaveDecoder::init(int width, int height) {
    destroy();

    if (pyrowave_create_default_device(&device_) != PYROWAVE_SUCCESS || !device_) {
        NF_LOGE("PyrowaveDecoder", "Device creation failed");
        device_ = nullptr;
        return false;
    }

    pyrowave_decoder_create_info info = {};
    info.device = device_;
    info.width = width;
    info.height = height;
    info.chroma = PYROWAVE_CHROMA_SUBSAMPLING_420;

    if (pyrowave_decoder_create(&info, &decoder_) != PYROWAVE_SUCCESS || !decoder_) {
        NF_LOGE("PyrowaveDecoder", "Decoder creation failed (%dx%d)", width, height);
        pyrowave_device_destroy(device_);
        device_ = nullptr;
        decoder_ = nullptr;
        return false;
    }

    width_ = width;
    height_ = height;
    output_y_.assign((size_t)width * (size_t)height, 0);
    output_u_.assign((size_t)(width / 2) * (size_t)(height / 2), 0);
    output_v_.assign((size_t)(width / 2) * (size_t)(height / 2), 0);
    NF_LOG("PyrowaveDecoder", "Initialized %dx%d", width, height);
    return true;
}

void PyrowaveDecoder::destroy() {
    if (decoder_) {
        pyrowave_decoder_destroy(decoder_);
        decoder_ = nullptr;
    }
    if (device_) {
        pyrowave_device_destroy(device_);
        device_ = nullptr;
    }
    width_ = 0;
    height_ = 0;
}

bool PyrowaveDecoder::decode(const uint8_t *payload, size_t len) {
    if (!decoder_ || !payload || len < 8) {
        return false;
    }
    if (read_u32(payload) != kPayloadMagic) {
        NF_LOGE("PyrowaveDecoder", "Payload magic mismatch");
        return false;
    }

    uint32_t packet_count = read_u32(payload + 4);
    size_t header_bytes = 8 + (size_t)packet_count * 4;
    if (packet_count == 0 || packet_count > kMaxPacketCount || len < header_bytes) {
        NF_LOGE("PyrowaveDecoder", "Bad packet header (count=%u len=%zu)", packet_count, len);
        return false;
    }

    pyrowave_decoder_clear(decoder_);

    size_t offset = header_bytes;
    for (uint32_t i = 0; i < packet_count; i++) {
        uint32_t packet_size = read_u32(payload + 8 + i * 4);
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

    if (pyrowave_decoder_decode_cpu_buffer_synchronous(decoder_, &buffer) != PYROWAVE_SUCCESS) {
        NF_LOGE("PyrowaveDecoder", "decode_cpu_buffer_synchronous failed");
        return false;
    }
    return true;
}

} // namespace godot
