#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

// Diagnostic NFXR v1, same layout as meteor/src/xr_wire.rs. No Android dependencies.
struct MeteorXrFrame {
    uint64_t epoch = 0, sequence = 0, id = 0, display_ns = 0;
    uint32_t bytes = 0;
    uint16_t width = 0, height = 0;
    bool idr = false, end = false, quest_local = false;
    std::array<float, 22> views{};
};
inline uint64_t meteor_xr_le(const uint8_t *p, unsigned size) {
    uint64_t v = 0; for (unsigned i = 0; i < size; ++i) v |= uint64_t(p[i]) << (8*i); return v;
}
inline void meteor_xr_put(uint8_t *p, uint64_t v, unsigned size) {
    for (unsigned i = 0; i < size; ++i) p[i] = uint8_t(v >> (8*i));
}
class MeteorXrWire {
    uint64_t epoch = 0, sequence = 0, last_id = 0, last_time = 0;
    bool ended = false;
    bool quest_local = false;
    uint16_t width = 0, height = 0;
public:
    bool header(const std::array<uint8_t, 152> &h, MeteorXrFrame &f) const {
        if (ended || std::memcmp(h.data(), "NFXR", 4) || meteor_xr_le(h.data()+4, 2) != 1 ||
            meteor_xr_le(h.data()+6, 2) != 152 || h[48] != 1 || h[49] > 3 || h[50] > 1) return false;
        for (unsigned i = 51; i < 64; ++i) if (h[i]) return false;
        f.epoch = meteor_xr_le(h.data()+8,8); f.sequence = meteor_xr_le(h.data()+16,8);
        f.id = meteor_xr_le(h.data()+24,8); f.display_ns = meteor_xr_le(h.data()+32,8);
        f.bytes = uint32_t(meteor_xr_le(h.data()+40,4)); f.width = uint16_t(meteor_xr_le(h.data()+44,2)); f.height = uint16_t(meteor_xr_le(h.data()+46,2));
        f.idr = (h[49] & 1) != 0; f.quest_local = (h[49] & 2) != 0; f.end = h[50] != 0;
        if (sequence && !f.end && f.quest_local != quest_local) return false;
        if (!f.epoch || (epoch && epoch != f.epoch) || f.sequence != sequence || f.bytes > 8*1024*1024) return false;
        if (f.end) {
            if (!sequence || f.id || f.display_ns || f.bytes || f.width || f.height || f.idr || f.quest_local) return false;
            for (unsigned i = 64; i < h.size(); ++i) if (h[i]) return false;
            return true;
        }
        // Two bounded SDR profiles; dimensions cannot change within a stream.
        if (sequence >= 240 || !f.bytes || (f.height != 256 && f.height != 512) || f.width != f.height*2 ||
            (sequence && (f.width != width || f.height != height)) || f.id <= last_id || f.display_ns <= last_time) return false;
        for (unsigned i = 0; i < 22; ++i) {
            uint32_t bits = uint32_t(meteor_xr_le(h.data()+64+i*4,4)); std::memcpy(&f.views[i], &bits,4);
            if (!std::isfinite(f.views[i])) return false;
        }
        for (unsigned eye = 0; eye < 2; ++eye) {
            const float *v = f.views.data() + eye*11;
            float norm = 0; for (int i = 3; i < 7; ++i) norm += v[i]*v[i];
            if (std::abs(norm-1.f) > 0.001f || v[7] >= v[8] || v[10] >= v[9]) return false;
            for (int i = 7; i < 11; ++i) if (std::abs(v[i]) >= 1.57079632679f) return false;
        }
        return true;
    }
    bool accept(const MeteorXrFrame &f, const std::vector<uint8_t> &payload) {
        if (f.end) { ended = true; return payload.empty(); }
        if (payload.size() != f.bytes || payload.size() < 4) return false;
        bool nals[32]{};
        if (!(payload[0] == 0 && payload[1] == 0 && (payload[2] == 1 || (payload[2] == 0 && payload[3] == 1)))) return false;
        for (size_t i = 0; i+3 < payload.size(); ++i)
            if (!payload[i] && !payload[i+1] && payload[i+2] == 1) nals[payload[i+3]&31] = true;
        if (nals[5] != f.idr || (!sequence && !(nals[5] && nals[7] && nals[8]))) return false;
        epoch = f.epoch; ++sequence; last_id = f.id; last_time = f.display_ns; quest_local = f.quest_local;
        width=f.width; height=f.height;
        return true;
    }
};
