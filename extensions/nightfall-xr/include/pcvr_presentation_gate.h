#pragma once
#include <atomic>

// A decoded/copied frame permits activation, but never activates standby itself.
// The workspace coordinator must retire conflicting layers before enabling it.
class PCVRPresentationGate {
    std::atomic<bool> enabled{false}, ready{false};
public:
    void begin(bool present_immediately) { ready.store(false); enabled.store(present_immediately); }
    void frame_ready() { ready.store(true); }
    bool activate() {
        if (!ready.load()) return false;
        enabled.store(true);
        return true;
    }
    bool is_ready() const { return ready.load(); }
    bool input_enabled() const { return enabled.load(); }
    bool present() const { return ready.load() && enabled.load(); }
    void reset() { enabled.store(false); ready.store(false); }
};
