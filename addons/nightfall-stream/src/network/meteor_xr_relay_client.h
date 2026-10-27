#pragma once
#if defined(__linux__) || defined(__ANDROID__)
#include "meteor_xr_data.h"
#include <atomic>
#include <mutex>
#include <pthread.h>
#include <thread>

namespace godot {
// Native worker adapter; never decrypts large video buffers on the Godot
// thread. Local endpoints remain loopback-only. Explicit development use, not
// discovery.
class MeteorXrRelayClient {
public:
  struct Config {
    std::string address;
    uint16_t video = 0, tracking = 0, local_video = 49090,
             local_tracking = 49091;
    std::array<uint8_t, 32> host{}, identity{}, server_nonce{}, client_nonce{};
    std::array<uint8_t, 16> session{};
  };
  ~MeteorXrRelayClient() { stop(); }
  bool start(const Config &config);
  void stop();
  bool failed() const { return failure_.load(); }
  bool idle() const { return completed_.load() == 2; }
  unsigned connected_lanes() const { return connected_.load(); }

private:
  Config config_;
  std::atomic<bool> stopping_{true}, failure_{false};
  std::atomic<unsigned> completed_{2}, connected_{0};
  pthread_t video_{}, tracking_{};
  bool video_started_ = false, tracking_started_ = false;
  std::mutex mutex_;
  std::vector<int> sockets_;
  int connect(const std::string &address, uint16_t port);
  void close(int fd);
  void interrupt();
  bool io(int fd, uint8_t *bytes, size_t length, bool writing,
          int timeout_ms = 5000);
  void run(bool video);
};
} // namespace godot
#endif
