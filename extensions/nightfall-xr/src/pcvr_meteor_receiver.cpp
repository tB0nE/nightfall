#include "pcvr_meteor_receiver.h"
#ifdef __ANDROID__
#include <android/log.h>
#include <media/NdkMediaFormat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>

namespace { int64_t millis() { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); } }
PCVRMeteorReceiver::~PCVRMeteorReceiver() { stop_after_gpu_drain(); if (worker.joinable()) worker.join(); }
std::string PCVRMeteorReceiver::message() const { std::lock_guard<std::mutex> lock(mutex); return text; }
void PCVRMeteorReceiver::status(const std::string &value, bool error) {
    { std::lock_guard<std::mutex> lock(mutex); text = value; }
    if (error && !stop.load()) failure.store(true);
    __android_log_print(error ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO, "NightfallPCVR", "Meteor: %s", value.c_str());
}
bool PCVRMeteorReceiver::start() {
    if (!done.load()) return false;
    if (worker.joinable()) worker.join();
    failure.store(false); stop.store(false); done.store(false); ready.store(false); eos = false;
    stats.reset();
    last_buffer_width=0; last_buffer_height=0;
    video_width=0; video_height=0; video_codec=0; video_fps=0; received_bytes=0;
    worker = std::thread(&PCVRMeteorReceiver::run, this); return true;
}
void PCVRMeteorReceiver::stop_after_gpu_drain() {
    stop.store(true);
    std::lock_guard<std::mutex> lock(network_mutex);
    if (peer >= 0) shutdown(peer, SHUT_RDWR);
}
bool PCVRMeteorReceiver::frame(AHardwareBuffer *&buffer, MeteorXrFrame &value, PCVRDecodedRegion &region) {
    std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
    if (!lock.owns_lock()) { ++stats.lock_busy; return false; }
    if (!reader || borrowed) return false;
    if (!held && AImageReader_acquireLatestImageAsync(reader, &held, &acquire_fence) != AMEDIA_OK) { ++stats.no_image; return false; }
    if (acquire_fence >= 0) {
        pollfd fd{acquire_fence, POLLIN, 0};
        if (poll(&fd, 1, 0) <= 0) { ++stats.acquire_wait; return false; }
        if (!(fd.revents & POLLIN)) { lock.unlock(); status("Decoder acquire fence failed", true); return false; }
        close(acquire_fence); acquire_fence = -1;
    }
    int64_t timestamp = 0;
    if (AImage_getTimestamp(held, &timestamp) != AMEDIA_OK || !metadata.count(timestamp) ||
        AImage_getHardwareBuffer(held, &buffer) != AMEDIA_OK || !buffer) {
        // Don't guess which frame a buffer belongs to.
        lock.unlock(); status("Decoded buffer timestamp has no matching frame metadata", true); return false;
    }
    value = metadata.at(timestamp);
    AHardwareBuffer_Desc desc{};
    AHardwareBuffer_describe(buffer,&desc);
    AImageCropRect crop{};
    if(AImage_getCropRect(held,&crop)!=AMEDIA_OK ||
       !pcvr_decoded_region(desc.width,desc.height,crop.left,crop.top,crop.right,crop.bottom,value.width,value.height,region)) {
        lock.unlock();
        status("Invalid decoded image region: video="+std::to_string(value.width)+"x"+std::to_string(value.height)+
            " buffer="+std::to_string(desc.width)+"x"+std::to_string(desc.height)+
            " crop="+std::to_string(crop.left)+","+std::to_string(crop.top)+","+std::to_string(crop.right)+","+std::to_string(crop.bottom),true);
        return false;
    }
    if(last_buffer_width!=desc.width || last_buffer_height!=desc.height) {
        __android_log_print(ANDROID_LOG_INFO,"NightfallPCVR","Meteor decoded region: video=%ux%u buffer=%ux%u crop=%d,%d,%d,%d",
            value.width,value.height,desc.width,desc.height,crop.left,crop.top,crop.right,crop.bottom);
        last_buffer_width=desc.width; last_buffer_height=desc.height;
    }
    metadata.erase(metadata.begin(), metadata.upper_bound(timestamp));
    stats.select(value.sequence);
    borrowed = true;
    __android_log_print(ANDROID_LOG_INFO, "NightfallPCVR", "Meteor decoded frame=%llu sequence=%llu host_ns=%llu image_ns=%lld",
        (unsigned long long)value.id, (unsigned long long)value.sequence, (unsigned long long)value.display_ns, (long long)timestamp);
    return true;
}
void PCVRMeteorReceiver::release_frame() {
    if (held) {
        if (acquire_fence >= 0) AImage_deleteAsync(held, acquire_fence);
        else AImage_delete(held);
    } else if (acquire_fence >= 0) close(acquire_fence);
    held = nullptr; acquire_fence = -1; borrowed = false;
}
bool PCVRMeteorReceiver::drain() {
    if (!codec_started) return true;
    for (int i = 0; i < 8; ++i) {
        AMediaCodecBufferInfo info{};
        ssize_t index = AMediaCodec_dequeueOutputBuffer(codec, &info, 0);
        if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) return true;
        if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat *format = AMediaCodec_getOutputFormat(codec);
            __android_log_print(ANDROID_LOG_INFO, "NightfallPCVR", "Meteor decoder format: %s", format ? AMediaFormat_toString(format) : "null");
            if (format) AMediaFormat_delete(format);
            continue;
        }
        if (index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) continue;
        if (index < 0) { status("MediaCodec output dequeue failed: " + std::to_string(index), true); return false; }
        bool render;
        { std::lock_guard<std::mutex> lock(mutex); render = metadata.count(info.presentationTimeUs * 1000) != 0; }
        if (AMediaCodec_releaseOutputBuffer(codec, size_t(index), render) != AMEDIA_OK) return false;
        if (render) ++stats.output;
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) eos = true;
    }
    return true;
}
bool PCVRMeteorReceiver::decoder(const MeteorXrFrame &frame) {
    const uint16_t width=frame.width, height=frame.height;
    const char *mime=frame.codec==2 ? "video/hevc" : "video/avc";
    AImageReader *created = nullptr;
    if (AImageReader_newWithUsage(width, height, AIMAGE_FORMAT_PRIVATE, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 4, &created) != AMEDIA_OK) return false;
    { std::lock_guard<std::mutex> lock(mutex); reader = created; }
    ANativeWindow *window = nullptr;
    if (AImageReader_getWindow(created, &window) != AMEDIA_OK) return false;
    codec = AMediaCodec_createDecoderByType(mime);
    if (!codec) return false;
    char *name = nullptr;
    if (AMediaCodec_getName(codec, &name) != AMEDIA_OK || !name) return false;
    std::string decoder_name(name); AMediaCodec_releaseName(codec, name);
    status("Decoder selected: " + decoder_name + " " + mime + " " + std::to_string(width) + "x" + std::to_string(height) + "@" + std::to_string(frame.fps));
    if (decoder_name.find("qti") == std::string::npos && decoder_name.find("qcom") == std::string::npos) {
        status("Expected Qualcomm hardware video decoder; no software fallback in this test", true); return false;
    }
    AMediaFormat *format = AMediaFormat_new();
    AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width); AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_FRAME_RATE, frame.fps);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_MAX_INPUT_SIZE, 8 * 1024 * 1024);
    AMediaFormat_setInt32(format, "low-latency", 1);
    media_status_t result = AMediaCodec_configure(codec, format, window, nullptr, 0);
    AMediaFormat_delete(format);
    if (result != AMEDIA_OK || AMediaCodec_start(codec) != AMEDIA_OK) return false;
    video_width=width; video_height=height; video_codec=frame.codec; video_fps=frame.fps;
    codec_started = true; return true;
}
bool PCVRMeteorReceiver::input(const std::vector<uint8_t> &bytes, int64_t pts, bool end) {
    const int64_t deadline = millis() + 2000;
    while (!stop.load() && millis() < deadline) {
        if (!drain()) return false;
        ssize_t index = AMediaCodec_dequeueInputBuffer(codec, 0);
        if (index >= 0) {
            size_t capacity = 0; uint8_t *buffer = AMediaCodec_getInputBuffer(codec, size_t(index), &capacity);
            if (!buffer || capacity < bytes.size()) return false;
            if (!bytes.empty()) std::memcpy(buffer, bytes.data(), bytes.size());
            return AMediaCodec_queueInputBuffer(codec, size_t(index), 0, bytes.size(), uint64_t(pts), end ? AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM : 0) == AMEDIA_OK;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}
bool PCVRMeteorReceiver::io(int fd, void *data, size_t size, bool writing, int64_t deadline) {
    auto *cursor = static_cast<uint8_t *>(data);
    while (size && !stop.load() && millis() < deadline) {
        if (!drain()) return false;
        pollfd poll_fd{fd, short(writing ? POLLOUT : POLLIN), 0};
        int ready = poll(&poll_fd, 1, 10);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) continue;
        ssize_t count = writing ? send(fd, cursor, size, MSG_NOSIGNAL) : recv(fd, cursor, size, 0);
        if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (count <= 0) return false;
        cursor += count; size -= size_t(count);
    }
    return size == 0;
}
void PCVRMeteorReceiver::run() {
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    int connected = -1;
    bool success = false;
    do {
        if (listener < 0) break;
        int enabled = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(49090); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) || listen(listener, 1)) break;
        ready.store(true);
        status("Listening on loopback :49090; USB diagnostic only, no remote tracking");
        while (!stop.load()) {
            pollfd fd{listener, POLLIN, 0};
            if (poll(&fd, 1, 50) <= 0) continue;
            connected = accept4(listener, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (connected >= 0) break;
        }
        if (connected < 0) break;
        { std::lock_guard<std::mutex> lock(network_mutex); peer = connected; }
        setsockopt(connected, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
        MeteorXrWire wire;
        for (;;) {
            std::array<uint8_t,152> header{}; MeteorXrFrame frame;
            int64_t deadline = millis() + 5000;
            if (!io(connected, header.data(), header.size(), false, deadline) || !wire.header(header, frame)) break;
            std::vector<uint8_t> payload(frame.bytes);
            if (!io(connected, payload.data(), payload.size(), false, deadline) || !wire.accept(frame, payload)) break;
            if (frame.end) {
                if (!codec_started || !input({}, int64_t(frame.sequence+1)*1000, true)) break;
                while (!eos && !stop.load() && millis() < deadline) {
                    if (!drain()) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if (!eos) break;
                uint8_t ack[12]{}; std::memcpy(ack, "NFXE",4); meteor_xr_put(ack+4,frame.sequence,8);
                if (!io(connected,ack,sizeof(ack),true,deadline)) break;
                status("Decoded test stream ended; holding final picture until local exit"); success = true; break;
            }
            if (!codec_started && !decoder(frame)) break;
            ++stats.received;
            received_bytes.fetch_add(payload.size());
            int64_t pts_us = int64_t(frame.sequence+1)*1000;
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (metadata.size() >= 8) break;
                metadata[pts_us * 1000] = frame;
            }
            if (!input(payload, pts_us, false)) break;
            ++stats.queued;
            uint8_t ack[20]{}; std::memcpy(ack,"NFXA",4); meteor_xr_put(ack+4,frame.sequence,8); meteor_xr_put(ack+12,frame.id,8);
            if (!io(connected,ack,sizeof(ack),true,deadline)) break;
        }
    } while (false);
    {
        std::lock_guard<std::mutex> lock(network_mutex);
        if (connected >= 0) close(connected);
        peer = -1;
    }
    ready.store(false);
    if (listener >= 0) close(listener);
    if (!success && !stop.load()) status("Receiver/decoder failed or stream truncated (no fallback)", true);
    // Even on failure keep codec/reader alive until render-thread GPU drain.
    while (!stop.load()) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    if (codec) { if (codec_started) AMediaCodec_stop(codec); AMediaCodec_delete(codec); codec = nullptr; codec_started = false; }
    { std::lock_guard<std::mutex> lock(mutex); if (reader) AImageReader_delete(reader); reader = nullptr; metadata.clear(); }
    done.store(true); status("Receiver and hardware decoder stopped");
}
#endif
