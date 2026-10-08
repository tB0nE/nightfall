#pragma once

#include "mic_cipher.h"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace godot {

// Sends the headset's microphone to Nightfall Meteor, which plays it into a
// "Nightfall Microphone" input device on the PC
// (docs/plans/active/meteor-microphone.md).
//
// Android captures with AAudio: 48 kHz, mono, 16-bit, with the
// VOICE_COMMUNICATION preset so the platform's echo cancellation and noise
// suppression apply where the headset has them. Every 10 ms frame goes to
// Meteor's microphone port as one UDP datagram, encrypted (MicCipher), in
// the version 2 format meteor/src/mic.rs reads. Other platforms don't
// capture.
class MeteorMic {
public:
    MeteorMic() = default;
    ~MeteorMic();
    MeteorMic(const MeteorMic &) = delete;
    MeteorMic &operator=(const MeteorMic &) = delete;

    // Opens the microphone and starts sending to host:port, encrypted for
    // Meteor's public key (64 hex digits, from discovery). Returns an empty
    // string, or why it couldn't start.
    std::string start(const std::string &host, int port, const std::string &meteor_key);
    void stop();

    bool is_running() const { return running_.load(); }
    // Muted frames are sent as silence with the muted flag, so Meteor's
    // device stays live and unmuting has no restart delay.
    void set_muted(bool muted) { muted_.store(muted); }
    bool is_muted() const { return muted_.load(); }

    uint64_t packets_sent() const { return packets_.load(); }
    // Peak of the most recent frame, 0 to 1. Levels only, never audio.
    float level() const { return level_.load(); }
    // Why capture stopped by itself (the device went away), or empty.
    std::string error() const;

    static constexpr int SAMPLE_RATE = 48000;
    static constexpr int FRAME_SAMPLES = 480; // 10 ms
    static constexpr int HEADER_BYTES = 16 + MicCipher::KEY_BYTES;

private:
    void run();
    void fail(const std::string &reason);

    std::atomic<bool> running_{false};
    std::atomic<bool> muted_{false};
    std::atomic<uint64_t> packets_{0};
    std::atomic<float> level_{0.0f};
    std::thread thread_;
    mutable std::mutex error_mutex_;
    std::string error_;
    MicCipher cipher_;
    int socket_ = -1;
    void *stream_ = nullptr; // AAudioStream on Android
};

} // namespace godot
