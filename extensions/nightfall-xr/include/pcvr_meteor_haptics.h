#pragma once
#include "pcvr_meteor_wire.h"
// USB diagnostic only: at most one short, moderate pulse per hand pending.
struct MeteorHaptic {
    uint64_t epoch=0,received_ns=0;
    uint32_t sequence=0,hand=0,duration_ms=0;
    float amplitude=0;
};
struct MeteorHapticWire {
    static std::array<uint8_t,32> encode(const MeteorHaptic &h) {
        std::array<uint8_t,32> p{};
        std::memcpy(p.data(),"NFXH",4); meteor_xr_put(p.data()+4,1,2); meteor_xr_put(p.data()+6,32,2);
        meteor_xr_put(p.data()+8,h.epoch,8); meteor_xr_put(p.data()+16,h.sequence,4);
        meteor_xr_put(p.data()+20,h.hand,4);
        uint32_t amplitude; std::memcpy(&amplitude,&h.amplitude,4);
        meteor_xr_put(p.data()+24,amplitude,4); meteor_xr_put(p.data()+28,h.duration_ms,4);
        return p;
    }
    static bool decode(const std::array<uint8_t,32> &p,MeteorHaptic &h) {
        if(std::memcmp(p.data(),"NFXH",4) || meteor_xr_le(p.data()+4,2)!=1 || meteor_xr_le(p.data()+6,2)!=32) return false;
        h.epoch=meteor_xr_le(p.data()+8,8); h.sequence=uint32_t(meteor_xr_le(p.data()+16,4));
        h.hand=uint32_t(meteor_xr_le(p.data()+20,4));
        uint32_t amplitude=uint32_t(meteor_xr_le(p.data()+24,4)); std::memcpy(&h.amplitude,&amplitude,4);
        h.duration_ms=uint32_t(meteor_xr_le(p.data()+28,4));
        return h.epoch && h.hand<2 && std::isfinite(h.amplitude) && h.amplitude>=0 && h.amplitude<=.5f &&
            h.duration_ms<=150 && ((h.amplitude==0)==(h.duration_ms==0));
    }
};
