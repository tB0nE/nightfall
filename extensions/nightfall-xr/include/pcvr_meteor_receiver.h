#pragma once
#ifdef __ANDROID__
#include "pcvr_meteor_wire.h"
#include <android/hardware_buffer.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <atomic>
#include <map>
#include <mutex>
#include <thread>
#include <string>

// DEV-only listener on 127.0.0.1:49090; reached through an authorized ADB forward.
class PCVRMeteorReceiver {
public:
    ~PCVRMeteorReceiver();
    bool start();
    void stop_after_gpu_drain();
    bool idle() const { return done.load(); }
    bool failed() const { return failure.load(); }
    bool listening() const { return ready.load(); }
    std::string message() const;
    bool frame(AHardwareBuffer *&buffer, MeteorXrFrame &metadata);
    void release_frame(); // Render thread, only after its sampling fence signals.
private:
    std::atomic<bool> done{true}, stop{false}, failure{false};
    std::atomic<bool> ready{false};
    std::thread worker;
    mutable std::mutex mutex;
    std::mutex network_mutex;
    std::string text;
    std::map<int64_t, MeteorXrFrame> metadata;
    AImageReader *reader = nullptr;
    AImage *held = nullptr; // Render thread owns held image and acquire fence.
    int acquire_fence = -1;
    bool borrowed = false;
    AMediaCodec *codec = nullptr; // Worker only.
    bool codec_started = false, eos = false;
    int peer = -1; // Close/shutdown serialized to avoid FD reuse races.
    void status(const std::string &value, bool error = false);
    void run();
    bool io(int fd, void *data, size_t size, bool writing, int64_t deadline);
    bool decoder(uint16_t width, uint16_t height);
    bool drain();
    bool input(const std::vector<uint8_t> &bytes, int64_t pts, bool end);
};
#endif
