#pragma once
#include "pcvr_meteor_wire.h"
#include "pcvr_meteor_controllers.h"
#include <limits>

// Fixed session snapshot: each eye is pose xyz/xyzw relative to VIEW,
// then FOV left/right/up/down. No world-space/head motion in this payload.
struct MeteorHeadsetOptics {
    uint64_t epoch = 0;
    std::array<float,22> eyes{};
};
class MeteorOpticsWire {
public:
    static constexpr size_t size=112;
    static bool valid(const MeteorHeadsetOptics &o) {
        if(!o.epoch) return false;
        for(float v:o.eyes) if(!std::isfinite(v)) return false;
        for(size_t eye=0;eye<2;++eye) {
            const float *p=o.eyes.data()+eye*11;
            float norm=0;
            for(size_t i=3;i<7;++i) norm+=p[i]*p[i];
            if(std::abs(norm-1.f)>.001f) return false;
            for(size_t i=0;i<3;++i) if(std::abs(p[i])>.15f) return false;
            for(size_t i=7;i<11;++i) if(std::abs(p[i])>=1.56f) return false;
            if(!(p[7]<0 && p[8]>0 && p[9]>0 && p[10]<0)) return false;
        }
        float distance=0;
        for(size_t i=0;i<3;++i) { float d=o.eyes[i+11]-o.eyes[i]; distance+=d*d; }
        return distance>=.04f*.04f && distance<=.09f*.09f && o.eyes[0]<o.eyes[11];
    }
    static std::array<uint8_t,size> encode(const MeteorHeadsetOptics &o) {
        std::array<uint8_t,size> h{};
        std::memcpy(h.data(),"NFXO",4); meteor_xr_put(h.data()+4,1,2); meteor_xr_put(h.data()+6,size,2);
        meteor_xr_put(h.data()+8,o.epoch,8);
        for(size_t i=0;i<22;++i) {
            uint32_t bits; std::memcpy(&bits,&o.eyes[i],4); meteor_xr_put(h.data()+16+i*4,bits,4);
        }
        return h;
    }
    static bool decode(const std::array<uint8_t,size> &h,MeteorHeadsetOptics &out) {
        if(std::memcmp(h.data(),"NFXO",4) || meteor_xr_le(h.data()+4,2)!=1 || meteor_xr_le(h.data()+6,2)!=size) return false;
        for(size_t i=104;i<size;++i) if(h[i]) return false;
        MeteorHeadsetOptics o; o.epoch=meteor_xr_le(h.data()+8,8);
        for(size_t i=0;i<22;++i) { uint32_t bits=uint32_t(meteor_xr_le(h.data()+16+i*4,4)); std::memcpy(&o.eyes[i],&bits,4); }
        if(!valid(o)) return false;
        out=o; return true;
    }
};

// USB diagnostic protocol only. LOCAL space is shared by explicit session
// agreement, never inferred from clocks. No prediction or origin conversion.
struct MeteorTrackingSample {
    uint64_t epoch = 0, sequence = 0, client_ns = 0;
    // Position xyz, orientation xyzw; metres and right-handed OpenXR axes.
    std::array<float, 7> pose{0, 0, 0, 0, 0, 0, 1};
    MeteorHeadsetOptics optics;
    MeteorControllerSample controllers;
};
class MeteorTrackingWire {
    uint64_t epoch = 0, sequence = 0, last_ns = 0;
public:
    static constexpr size_t size = 64;
    static std::array<uint8_t, size> encode(const MeteorTrackingSample &s) {
        std::array<uint8_t, size> h{};
        std::memcpy(h.data(), "NFXT", 4);
        meteor_xr_put(h.data()+4, 1, 2); meteor_xr_put(h.data()+6, size, 2);
        meteor_xr_put(h.data()+8, s.epoch, 8);
        meteor_xr_put(h.data()+16, s.sequence, 8);
        meteor_xr_put(h.data()+24, s.client_ns, 8);
        for (size_t i = 0; i < s.pose.size(); ++i) {
            uint32_t bits; std::memcpy(&bits, &s.pose[i], 4);
            meteor_xr_put(h.data()+32+i*4, bits, 4);
        }
        return h;
    }
    bool accept(const std::array<uint8_t, size> &h, MeteorTrackingSample &out) {
        if (std::memcmp(h.data(), "NFXT", 4) || meteor_xr_le(h.data()+4,2) != 1 ||
            meteor_xr_le(h.data()+6,2) != size) return false;
        for (size_t i = 60; i < size; ++i) if (h[i]) return false;
        MeteorTrackingSample s;
        s.epoch = meteor_xr_le(h.data()+8,8);
        s.sequence = meteor_xr_le(h.data()+16,8);
        s.client_ns = meteor_xr_le(h.data()+24,8);
        if (!s.epoch || (epoch && epoch != s.epoch) || s.sequence != sequence ||
            sequence == UINT64_MAX || s.client_ns <= last_ns) return false;
        for (size_t i = 0; i < s.pose.size(); ++i) {
            uint32_t bits = uint32_t(meteor_xr_le(h.data()+32+i*4,4));
            std::memcpy(&s.pose[i], &bits, 4);
            if (!std::isfinite(s.pose[i])) return false;
        }
        float norm = 0;
        for (size_t i = 3; i < 7; ++i) norm += s.pose[i]*s.pose[i];
        if (std::abs(norm-1.f) > .001f) return false;
        epoch = s.epoch; ++sequence; last_ns = s.client_ns; out = s;
        return true;
    }
};

// Four-timestamp exchange: host send, client receive/send, host receive.
// Uses the lowest-delay sample; rejects long/asymmetric-by-construction invalid
// exchanges. Network asymmetry still contributes uncertainty (half the RTT).
class MeteorClockMapping {
    bool ready = false;
    int64_t offset = 0;
    uint64_t best_rtt = UINT64_MAX;
public:
    bool observe(uint64_t h0, uint64_t c1, uint64_t c2, uint64_t h3) {
        const uint64_t limit = uint64_t(std::numeric_limits<int64_t>::max());
        if (!h0 || !c1 || h0 > limit || c1 > limit || c2 > limit || h3 > limit ||
            h3 < h0 || c2 < c1 || h3-h0 < c2-c1) return false;
        uint64_t rtt = (h3-h0)-(c2-c1);
        if (rtt > 100000000) return false; // Diagnostic budget: 100 ms.
        if (!ready || rtt < best_rtt) {
            // Difference of midpoints avoids summing two large clock epochs.
            offset = int64_t(h0+(h3-h0)/2)-int64_t(c1+(c2-c1)/2);
            best_rtt = rtt; ready = true;
        }
        return true;
    }
    bool to_host(uint64_t client_ns, uint64_t &host_ns) const {
        if (!ready || client_ns > uint64_t(INT64_MAX)) return false;
        if (offset < 0 && client_ns < uint64_t(-offset)) return false;
        if (offset > 0 && client_ns > uint64_t(INT64_MAX-offset)) return false;
        host_ns = uint64_t(int64_t(client_ns)+offset); return true;
    }
    uint64_t uncertainty_ns() const { return best_rtt/2; }
};
