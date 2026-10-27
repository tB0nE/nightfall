#pragma once
#include "meteor_cipher.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <vector>

namespace godot {
// Portable client-side authenticated framing. Consumers MUST still use their
// existing pose/clock/codec validators after authentication. No sockets/threads.
class MeteorXrDataCipher {
public:
    enum class Kind : uint8_t { Video=1, HeadsetTracking=2, HostTracking=3, VideoFeedback=4, AttachVideo=5, AttachTracking=6 };
    static constexpr size_t HEADER=24;
    bool init(const std::array<uint8_t,32> &host, const std::array<uint8_t,32> &identity,
            const std::array<uint8_t,32> &server_nonce,const std::array<uint8_t,32> &client_nonce,
            const std::array<uint8_t,16> &session,Kind kind,const std::array<uint8_t,32> *binding=nullptr) {
        failed_=true;sequence_=0;kind_=kind;
        if (std::all_of(session.begin(),session.end(),[](uint8_t b){return b==0;}) || uint8_t(kind)<1 || uint8_t(kind)>6) return false;
        std::string info="nightfall-xr-data-v1/";info.push_back(char(kind));
        info.append(reinterpret_cast<const char *>(session.data()),session.size());
        info.append(reinterpret_cast<const char *>(server_nonce.data()),server_nonce.size());
        info.append(reinterpret_cast<const char *>(client_nonce.data()),client_nonce.size());
        if(binding)info.append(reinterpret_cast<const char *>(binding->data()),binding->size());
        failed_=!cipher_.init_bytes(host.data(),reinterpret_cast<const uint8_t *>(info.data()),info.size(),identity.data()).empty();
        return !failed_;
    }
    bool payload_length(const std::array<uint8_t,HEADER> &h,size_t &length) const {
        if(failed_ || sequence_==std::numeric_limits<uint64_t>::max() || memcmp(h.data(),"NFXD",4) ||
            h[4]!=1 || h[5]!=uint8_t(kind_) || h[6] || h[7] || get(h.data()+8,8)!=sequence_ || get(h.data()+20,4)) return false;
        length=size_t(get(h.data()+16,4));return length>=16 && length<=bound()+16;
    }
    bool seal(const std::vector<uint8_t> &plain,std::vector<uint8_t> &packet) {
        packet.clear();
        if(failed_ || !sending() || sequence_==std::numeric_limits<uint64_t>::max() || plain.empty() || plain.size()>bound()) return false;
        std::array<uint8_t,HEADER> header{};memcpy(header.data(),"NFXD",4);header[4]=1;header[5]=uint8_t(kind_);
        put(header.data()+8,sequence_,8);put(header.data()+16,plain.size()+16,4);
        std::vector<uint8_t> body=plain;body.resize(plain.size()+16);
        if(!cipher_.seal(sequence_,header.data(),header.size(),body.data(),plain.size())) {failed_=true;return false;}
        ++sequence_;packet.assign(header.begin(),header.end());packet.insert(packet.end(),body.begin(),body.end());return true;
    }
    bool open(const std::array<uint8_t,HEADER> &header,std::vector<uint8_t> body,std::vector<uint8_t> &plain) {
        plain.clear();size_t length=0;
        if(sending() || !payload_length(header,length) || length!=body.size() ||
            !cipher_.open(sequence_,header.data(),header.size(),body.data(),body.size())) {failed_=true;return false;}
        ++sequence_;body.resize(body.size()-16);plain=std::move(body);return true;
    }
private:
    MeteorCipher cipher_;
    Kind kind_=Kind::Video;
    uint64_t sequence_=0;
    bool failed_=true;
    bool sending() const {return kind_==Kind::HeadsetTracking || kind_==Kind::VideoFeedback || kind_==Kind::AttachVideo || kind_==Kind::AttachTracking;}
    size_t bound() const {switch(kind_) {case Kind::Video:return 152+8*1024*1024;
        case Kind::HeadsetTracking:return 192;case Kind::HostTracking:return 32;case Kind::VideoFeedback:return 20;
        case Kind::AttachVideo:case Kind::AttachTracking:return 32;}return 0;}
    static uint64_t get(const uint8_t *p,unsigned n) {uint64_t v=0;for(unsigned i=0;i<n;++i)v|=uint64_t(p[i])<<(i*8);return v;}
    static void put(uint8_t *p,uint64_t value,unsigned n) {for(unsigned i=0;i<n;++i)p[i]=uint8_t(value>>(i*8));}
};
} // namespace godot
