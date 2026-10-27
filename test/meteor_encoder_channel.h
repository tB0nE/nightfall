#pragma once
#include <thread>
#include <mutex>
#include <condition_variable>
struct BridgeChannel {
    std::mutex mutex;
    std::condition_variable wake;
    bool pending = false, completed = false, stopping = false, busy = false;
    meteor_stereo_encode_v1 request{};
    std::thread worker;
};
static BridgeChannel channel;
static bool bridge_next(meteor_stereo_encode_v1 &request) {
    std::unique_lock<std::mutex> lock(channel.mutex);
    channel.wake.wait(lock, [] { return channel.pending || channel.stopping; });
    if (channel.stopping) return false;
    request = channel.request; channel.pending = false;
    return true;
}
static void bridge_complete() {
    std::lock_guard<std::mutex> lock(channel.mutex);
    channel.completed = true; channel.wake.notify_all();
}
