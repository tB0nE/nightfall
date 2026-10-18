#pragma once
#include "pcvr_meteor_tracking.h"
#include <atomic>
#include <mutex>
#include <thread>

// Loopback-only USB diagnostic endpoint. Render thread publishes a latest sample;
// all socket waits happen on the worker. No unbounded sample queue.
class MeteorTrackingEndpoint {
public:
    ~MeteorTrackingEndpoint();
    bool start(uint16_t port = 49091);
    void request_stop() { stopping.store(true); }
    bool idle() const { return done.load(); }
    bool failed() const { return error.load(); }
    bool listening() const { return ready.load(); }
    void publish(const MeteorTrackingSample &sample);
    static uint64_t now_ns();
private:
    std::atomic<bool> stopping{false}, done{true}, error{false}, ready{false};
    std::thread worker;
    std::mutex mutex;
    MeteorTrackingSample latest;
    void run(uint16_t port);
    bool io(int fd, void *bytes, size_t size, bool writing, uint64_t deadline);
};
