#pragma once
#include "pcvr_meteor_wire.h"
struct MeteorControllerState {
    // Bit 0 grip pose valid, bit 1 aim pose valid, bit 2 analog inputs active.
    uint32_t flags=0;
    float trigger=0, squeeze=0;
    std::array<float,2> stick{};
    uint32_t buttons=0; // AX click, stick click, AX touch, stick touch, trigger touch.
    std::array<float,14> poses{0,0,0,0,0,0,1,0,0,0,0,0,0,1};
};
struct MeteorControllerSample {
    uint64_t epoch=0,sequence=0,client_ns=0;
    std::array<MeteorControllerState,2> hands;
};
class MeteorControllerWire {
    uint64_t epoch=0,sequence=0,last_ns=0;
    bool extended=false;
public:
    explicit MeteorControllerWire(bool version2=false):extended(version2) {}
    static constexpr size_t size=192;
    static bool valid(const MeteorControllerSample &s) {
        if(!s.epoch || !s.client_ns) return false;
        for(const auto &hand:s.hands) {
            if(hand.flags>15 || hand.buttons>31 || ((hand.flags&4) && !(hand.flags&1)) || !std::isfinite(hand.trigger) || !std::isfinite(hand.squeeze) ||
                hand.trigger<0 || hand.trigger>1 || hand.squeeze<0 || hand.squeeze>1 ||
                (!(hand.flags&4) && (hand.trigger!=0 || hand.squeeze!=0))) return false;
            for(float v:hand.stick) if(!std::isfinite(v) || v< -1 || v>1) return false;
            if((!(hand.flags&8) && (hand.stick[0]!=0 || hand.stick[1]!=0)) ||
                (!(hand.flags&4) && hand.buttons) || ((hand.flags&8) && !(hand.flags&1))) return false;
            for(float v:hand.poses) if(!std::isfinite(v)) return false;
            for(int pose=0;pose<2;++pose) {
                float norm=0; for(int i=3;i<7;++i) norm+=hand.poses[pose*7+i]*hand.poses[pose*7+i];
                if(std::abs(norm-1.f)>.001f) return false;
                for(int i=0;i<3;++i) if(std::abs(hand.poses[pose*7+i])>100) return false;
            }
        }
        return true;
    }
    static std::array<uint8_t,size> encode(const MeteorControllerSample &s,bool version2=false) {
        std::array<uint8_t,size> h{};
        std::memcpy(h.data(),version2 ? "NFXJ" : "NFXI",4); meteor_xr_put(h.data()+4,version2 ? 2 : 1,2); meteor_xr_put(h.data()+6,size,2);
        meteor_xr_put(h.data()+8,s.epoch,8); meteor_xr_put(h.data()+16,s.sequence,8); meteor_xr_put(h.data()+24,s.client_ns,8);
        for(size_t eye=0;eye<2;++eye) {
            uint8_t *p=h.data()+32+eye*80; const auto &hand=s.hands[eye]; meteor_xr_put(p,version2 ? hand.flags : hand.flags&7,4);
            auto put=[&](size_t offset,float value) { uint32_t bits; std::memcpy(&bits,&value,4); meteor_xr_put(p+offset,bits,4); };
            put(4,hand.trigger); put(8,hand.squeeze);
            for(size_t i=0;i<14;++i) put(16+i*4,hand.poses[i]);
            if(version2) { meteor_xr_put(p+12,hand.buttons,4); put(72,hand.stick[0]); put(76,hand.stick[1]); }
        }
        return h;
    }
    bool accept(const std::array<uint8_t,size> &h,MeteorControllerSample &out) {
        if(std::memcmp(h.data(),extended ? "NFXJ" : "NFXI",4) || meteor_xr_le(h.data()+4,2)!=(extended ? 2 : 1) || meteor_xr_le(h.data()+6,2)!=size) return false;
        MeteorControllerSample s;
        s.epoch=meteor_xr_le(h.data()+8,8); s.sequence=meteor_xr_le(h.data()+16,8); s.client_ns=meteor_xr_le(h.data()+24,8);
        if((epoch && s.epoch!=epoch) || s.sequence!=sequence || sequence==UINT64_MAX || s.client_ns<=last_ns) return false;
        for(size_t eye=0;eye<2;++eye) {
            const uint8_t *p=h.data()+32+eye*80; auto &hand=s.hands[eye]; hand.flags=uint32_t(meteor_xr_le(p,4));
            if(!extended) {
                if(hand.flags>7) return false;
                for(size_t i=12;i<16;++i) if(p[i]) return false;
                for(size_t i=72;i<80;++i) if(p[i]) return false;
            }
            auto get=[&](size_t offset) { uint32_t bits=uint32_t(meteor_xr_le(p+offset,4)); float v; std::memcpy(&v,&bits,4); return v; };
            hand.trigger=get(4); hand.squeeze=get(8);
            for(size_t i=0;i<14;++i) hand.poses[i]=get(16+i*4);
            if(extended) { hand.buttons=uint32_t(meteor_xr_le(p+12,4)); hand.stick={get(72),get(76)}; }
        }
        if(!valid(s)) return false;
        epoch=s.epoch; ++sequence; last_ns=s.client_ns; out=s; return true;
    }
};
