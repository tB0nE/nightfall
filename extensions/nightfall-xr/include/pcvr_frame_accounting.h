#pragma once
#include <atomic>
#include <cstdint>

// Sequence accounting only; selection is NOT proof of compositor presentation.
struct PCVRFrameAccounting {
    std::atomic<uint64_t> received{0}, queued{0}, output{0}, selected{0}, superseded{0};
    std::atomic<uint64_t> lock_busy{0}, no_image{0}, acquire_wait{0};
    uint64_t next_sequence = 0; // Render thread only, reset before worker starts.
    void reset() {
        received=0; queued=0; output=0; selected=0; superseded=0;
        lock_busy=0; no_image=0; acquire_wait=0; next_sequence=0;
    }
    void select(uint64_t sequence) {
        if (sequence >= next_sequence) {
            superseded.fetch_add(sequence-next_sequence, std::memory_order_relaxed);
            next_sequence=sequence+1;
        }
        selected.fetch_add(1, std::memory_order_relaxed);
    }
};
