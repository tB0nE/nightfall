#include "meteor_mic.h"
#include "nf_log.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstring>

#ifdef __ANDROID__
#include <aaudio/AAudio.h>
#include <opus.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace godot {

namespace {
constexpr const char *TAG = "MeteorMic";
constexpr uint8_t VERSION = 2; // encrypted
constexpr uint8_t FLAG_MUTED = 1;
constexpr uint8_t FORMAT_PCM_S16LE_48K_MONO = 0;
constexpr uint8_t FORMAT_OPUS_48K_MONO = 1;
// Opus at 32 kbit/s fills about 40 bytes per 10 ms frame; room to spare.
constexpr int MAX_OPUS_BYTES = 400;
// How long one read waits for audio before checking whether to stop.
constexpr int64_t READ_TIMEOUT_NS = 100 * 1000 * 1000;

void put_u32(uint8_t *out, uint32_t value) {
    out[0] = value & 0xff;
    out[1] = (value >> 8) & 0xff;
    out[2] = (value >> 16) & 0xff;
    out[3] = (value >> 24) & 0xff;
}
} // namespace

MeteorMic::~MeteorMic() {
    stop();
}

std::string MeteorMic::error() const {
    std::lock_guard<std::mutex> lock(error_mutex_);
    return error_;
}

void MeteorMic::fail(const std::string &reason) {
    NF_LOGE(TAG, "%s", reason.c_str());
    std::lock_guard<std::mutex> lock(error_mutex_);
    error_ = reason;
}

#ifdef __ANDROID__

std::string MeteorMic::start(const std::string &host, int port, const std::string &meteor_key, bool opus) {
    stop();
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        error_.clear();
    }
    uint8_t meteor_public[MeteorCipher::KEY_BYTES];
    if (!parse_hex_key(meteor_key, meteor_public)) return "Meteor didn't send a valid microphone key";
    // A fresh key pair for every session.
    std::string cipher_error = cipher_.init(meteor_public, "nightfall-meteor mic v2");
    if (!cipher_error.empty()) return cipher_error;
    if (opus) {
        int err = 0;
        encoder_ = opus_encoder_create(SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &err);
        if (err != OPUS_OK || !encoder_) {
            encoder_ = nullptr;
            return std::string("can't create the Opus encoder: ") + opus_strerror(err);
        }
        opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(32000));
        opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(5));
        opus_encoder_ctl(encoder_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
        // Meteor rebuilds a lost frame from the next packet's FEC.
        opus_encoder_ctl(encoder_, OPUS_SET_INBAND_FEC(1));
        opus_encoder_ctl(encoder_, OPUS_SET_PACKET_LOSS_PERC(5));
    }

    // getaddrinfo handles IPv4, IPv6 and a zoned link-local address.
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo *found = nullptr;
    std::string port_text = std::to_string(port);
    if (getaddrinfo(host.c_str(), port_text.c_str(), &hints, &found) != 0 || !found) {
        return "can't resolve " + host;
    }
    socket_ = socket(found->ai_family, found->ai_socktype, found->ai_protocol);
    bool connected = socket_ >= 0 && connect(socket_, found->ai_addr, found->ai_addrlen) == 0;
    freeaddrinfo(found);
    if (!connected) {
        std::string reason = std::string("can't open a socket to Meteor: ") + strerror(errno);
        if (socket_ >= 0) close(socket_);
        socket_ = -1;
        return reason;
    }
    // A full send buffer drops a frame rather than holding up capture.
    fcntl(socket_, F_SETFL, fcntl(socket_, F_GETFL, 0) | O_NONBLOCK);

    AAudioStreamBuilder *builder = nullptr;
    aaudio_result_t result = AAudio_createStreamBuilder(&builder);
    if (result != AAUDIO_OK) {
        close(socket_);
        socket_ = -1;
        return std::string("AAudio: ") + AAudio_convertResultToText(result);
    }
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_INPUT);
    AAudioStreamBuilder_setSampleRate(builder, SAMPLE_RATE);
    AAudioStreamBuilder_setChannelCount(builder, 1);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setInputPreset(builder, AAUDIO_INPUT_PRESET_VOICE_COMMUNICATION);
    AAudioStream *stream = nullptr;
    result = AAudioStreamBuilder_openStream(builder, &stream);
    AAudioStreamBuilder_delete(builder);
    if (result != AAUDIO_OK) {
        close(socket_);
        socket_ = -1;
        // Without RECORD_AUDIO, opening fails here.
        return std::string("can't open the microphone: ") + AAudio_convertResultToText(result);
    }
    int32_t rate = AAudioStream_getSampleRate(stream);
    int32_t channels = AAudioStream_getChannelCount(stream);
    aaudio_format_t format = AAudioStream_getFormat(stream);
    if (rate != SAMPLE_RATE || channels != 1 || format != AAUDIO_FORMAT_PCM_I16) {
        AAudioStream_close(stream);
        close(socket_);
        socket_ = -1;
        return "the microphone opened as " + std::to_string(rate) + " Hz, " + std::to_string(channels) +
               " channel(s), format " + std::to_string(format) + "; Meteor needs 48 kHz mono 16-bit";
    }
    result = AAudioStream_requestStart(stream);
    if (result != AAUDIO_OK) {
        AAudioStream_close(stream);
        close(socket_);
        socket_ = -1;
        return std::string("can't start the microphone: ") + AAudio_convertResultToText(result);
    }
    stream_ = stream;
    packets_.store(0);
    level_.store(0.0f);
    running_.store(true);
    thread_ = std::thread(&MeteorMic::run, this);
    NF_LOG(TAG, "Sending the microphone to %s:%d as %s (AAudio %d Hz, burst %d frames, %s)", host.c_str(), port,
           encoder_ ? "Opus" : "PCM", rate,
           AAudioStream_getFramesPerBurst(stream),
           AAudioStream_getPerformanceMode(stream) == AAUDIO_PERFORMANCE_MODE_LOW_LATENCY ? "low latency" : "normal");
    return "";
}

void MeteorMic::stop() {
    running_.store(false);
    if (thread_.joinable()) thread_.join();
    if (stream_) {
        AAudioStream *stream = static_cast<AAudioStream *>(stream_);
        AAudioStream_requestStop(stream);
        AAudioStream_close(stream);
        stream_ = nullptr;
        NF_LOG(TAG, "Microphone stopped after %llu packets", static_cast<unsigned long long>(packets_.load()));
    }
    if (socket_ >= 0) {
        close(socket_);
        socket_ = -1;
    }
    if (encoder_) {
        opus_encoder_destroy(encoder_);
        encoder_ = nullptr;
    }
}

void MeteorMic::run() {
    AAudioStream *stream = static_cast<AAudioStream *>(stream_);
    uint8_t packet[HEADER_BYTES + FRAME_SAMPLES * 2 + MeteorCipher::TAG_BYTES];
    std::memcpy(packet, "NFMC", 4);
    packet[4] = VERSION;
    packet[6] = encoder_ ? FORMAT_OPUS_48K_MONO : FORMAT_PCM_S16LE_48K_MONO;
    packet[7] = 0;
    std::memcpy(packet + 16, cipher_.public_key(), MeteorCipher::KEY_BYTES);
    int16_t samples[FRAME_SAMPLES];
    int filled = 0;
    uint32_t seq = 0;
    uint64_t send_errors = 0;
    while (running_.load()) {
        aaudio_result_t got = AAudioStream_read(stream, samples + filled, FRAME_SAMPLES - filled, READ_TIMEOUT_NS);
        if (got < 0) {
            fail(std::string("microphone capture stopped: ") + AAudio_convertResultToText(got));
            running_.store(false);
            break;
        }
        filled += got;
        if (filled < FRAME_SAMPLES) continue;
        filled = 0;

        bool muted = muted_.load();
        int peak = 0;
        for (int16_t s : samples) peak = std::max(peak, std::abs(static_cast<int>(s)));
        level_.store(muted ? 0.0f : peak / 32768.0f);
        packet[5] = muted ? FLAG_MUTED : 0;
        put_u32(packet + 8, seq);
        put_u32(packet + 12, seq * FRAME_SAMPLES);
        int body = FRAME_SAMPLES * 2;
        if (encoder_) {
            // A muted Opus frame is empty; Meteor plays silence for it.
            body = muted ? 0 : opus_encode(encoder_, samples, FRAME_SAMPLES, packet + HEADER_BYTES, MAX_OPUS_BYTES);
            if (body < 0) {
                fail(std::string("Opus encoding failed: ") + opus_strerror(body));
                running_.store(false);
                break;
            }
        } else if (muted) {
            std::memset(packet + HEADER_BYTES, 0, body);
        } else {
            // Little-endian on every Android ABI, as the format wants.
            std::memcpy(packet + HEADER_BYTES, samples, body);
        }
        if (!cipher_.seal(seq, packet, HEADER_BYTES, packet + HEADER_BYTES, body)) {
            fail("microphone encryption failed");
            running_.store(false);
            break;
        }
        seq++;
        // ECONNREFUSED (Meteor not listening yet) and EAGAIN only drop a frame.
        ssize_t size = HEADER_BYTES + body + MeteorCipher::TAG_BYTES;
        if (send(socket_, packet, size, 0) == size) {
            packets_.fetch_add(1);
        } else if (send_errors++ % 500 == 0) {
            NF_LOGE(TAG, "send failed (%s); %llu so far", strerror(errno), static_cast<unsigned long long>(send_errors));
        }
    }
}

#else

std::string MeteorMic::start(const std::string &, int, const std::string &, bool) {
    return "this platform doesn't capture the microphone for Meteor";
}

void MeteorMic::stop() {
    running_.store(false);
}

void MeteorMic::run() {}

#endif

} // namespace godot
