#include "pcvr_meteor_wire.h"
#include <cassert>
#include <limits>
int main() {
    std::array<uint8_t,152> h{};
    std::memcpy(h.data(),"NFXR",4); meteor_xr_put(h.data()+4,1,2); meteor_xr_put(h.data()+6,152,2);
    for (int offset : {8,24,32}) meteor_xr_put(h.data()+offset,1,8);
    std::vector<uint8_t> payload{0,0,1,0x67,1,0,0,1,0x68,1,0,0,1,0x65,1};
    meteor_xr_put(h.data()+40,payload.size(),4); meteor_xr_put(h.data()+44,512,2); meteor_xr_put(h.data()+46,256,2); h[48]=h[49]=1;
    for (int eye=0; eye<2; ++eye) {
        float view[11]{0,0,0,0,0,0,1,-.8f,.8f,.8f,-.8f};
        for (int i=0;i<11;++i) { uint32_t bits; std::memcpy(&bits,view+i,4); meteor_xr_put(h.data()+64+(eye*11+i)*4,bits,4); }
    }
    MeteorXrWire sustained;
    MeteorXrFrame frame;
    auto sequence_header=h;
    for (uint64_t i=0;i<32768;++i) {
        meteor_xr_put(sequence_header.data()+16,i,8);
        meteor_xr_put(sequence_header.data()+24,i+1,8);
        meteor_xr_put(sequence_header.data()+32,i+1,8);
        assert(sustained.header(sequence_header,frame) && sustained.accept(frame,payload));
    }
    meteor_xr_put(sequence_header.data()+16,32768,8);
    assert(!sustained.header(sequence_header,frame));
    MeteorXrWire wire;
    auto rectangular=h;
    meteor_xr_put(rectangular.data()+44,4128,2); meteor_xr_put(rectangular.data()+46,2208,2);
    MeteorXrWire rectangle;
    assert(rectangle.header(rectangular,frame) && rectangle.accept(frame,payload));
    auto resized=rectangular;
    meteor_xr_put(resized.data()+16,1,8); meteor_xr_put(resized.data()+24,2,8); meteor_xr_put(resized.data()+32,2,8);
    meteor_xr_put(resized.data()+46,2224,2);
    assert(!rectangle.header(resized,frame));
    for (unsigned size : {1920u,2208u,2656u,3312u,4096u}) {
        auto scaled=h;
        meteor_xr_put(scaled.data()+44,size*2,2); meteor_xr_put(scaled.data()+46,size,2);
        assert(MeteorXrWire().header(scaled,frame));
    }
    for (unsigned size : {240u,2209u,4112u}) {
        auto invalid=h;
        meteor_xr_put(invalid.data()+44,size*2,2); meteor_xr_put(invalid.data()+46,size,2);
        assert(!MeteorXrWire().header(invalid,frame));
    }
    auto hevc_header=h;
    std::vector<uint8_t> hevc_payload{0,0,1,64,1,0,0,1,66,1,0,0,1,68,1,0,0,1,38,1};
    hevc_header[48]=2; hevc_header[51]=72;
    meteor_xr_put(hevc_header.data()+40,hevc_payload.size(),4);
    meteor_xr_put(hevc_header.data()+44,4096,2); meteor_xr_put(hevc_header.data()+46,2048,2);
    MeteorXrWire hevc;
    assert(hevc.header(hevc_header,frame) && frame.codec==2 && frame.fps==72);
    assert(hevc.accept(frame,hevc_payload));
    meteor_xr_put(hevc_header.data()+16,1,8);
    meteor_xr_put(hevc_header.data()+24,2,8); meteor_xr_put(hevc_header.data()+32,2,8);
    hevc_header[48]=1;
    assert(!hevc.header(hevc_header,frame)); // Mid-session codec changes are forbidden.
    hevc_header[48]=2; hevc_header[51]=60;
    assert(!hevc.header(hevc_header,frame));
    assert(wire.header(h,frame)); assert(wire.accept(frame,payload)); assert(!wire.header(h,frame));
    for (int offset : {0,4,6,40,44,48,49,50,51,88}) {
        auto bad=h; bad[offset]=255;
        if(offset==40) meteor_xr_put(bad.data()+40,0xffffffff,4);
        if(offset==88) { float nan=std::numeric_limits<float>::quiet_NaN(); std::memcpy(bad.data()+88,&nan,4); }
        assert(!MeteorXrWire().header(bad,frame));
    }
    MeteorXrWire truncated; assert(truncated.header(h,frame));
    auto short_payload=payload; short_payload.pop_back(); assert(!truncated.accept(frame,short_payload));
    auto wrong=payload; wrong[3]=0x61; assert(!truncated.accept(frame,wrong));
    auto end=h; meteor_xr_put(end.data()+16,1,8);
    for(int i=24;i<48;++i)end[i]=0;
    end[49]=0;end[50]=1;for(int i=64;i<152;++i)end[i]=0;
    assert(wire.header(end,frame)); assert(wire.accept(frame,{})); assert(!wire.header(h,frame));
    MeteorXrWire tracked;
    auto scene=h; scene[49]=3;
    assert(tracked.header(scene,frame) && frame.quest_local && frame.idr);
    assert(tracked.accept(frame,payload));
    meteor_xr_put(scene.data()+16,1,8);
    meteor_xr_put(scene.data()+24,2,8); meteor_xr_put(scene.data()+32,2,8);
    scene[49]=1; assert(!tracked.header(scene,frame)); // No origin-mode switch.
    auto bad_end=end; bad_end[49]=2; assert(!tracked.header(bad_end,frame));
    assert(tracked.header(end,frame) && tracked.accept(frame,{}));
    auto larger=h; meteor_xr_put(larger.data()+44,1024,2); meteor_xr_put(larger.data()+46,512,2);
    MeteorXrWire high;
    assert(high.header(larger,frame) && frame.width==1024 && frame.height==512);
    assert(high.accept(frame,payload));
    auto changed=h; meteor_xr_put(changed.data()+16,1,8); meteor_xr_put(changed.data()+24,2,8); meteor_xr_put(changed.data()+32,2,8);
    assert(!high.header(changed,frame));
    meteor_xr_put(larger.data()+44,2048,2); meteor_xr_put(larger.data()+46,1024,2);
    assert(MeteorXrWire().header(larger,frame));
    meteor_xr_put(larger.data()+44,4096,2); meteor_xr_put(larger.data()+46,2048,2);
    assert(MeteorXrWire().header(larger,frame));
    meteor_xr_put(larger.data()+44,5120,2); meteor_xr_put(larger.data()+46,2560,2);
    assert(MeteorXrWire().header(larger,frame));
    meteor_xr_put(larger.data()+44,8192,2); meteor_xr_put(larger.data()+46,4096,2);
    assert(MeteorXrWire().header(larger,frame));
    meteor_xr_put(larger.data()+44,8224,2); meteor_xr_put(larger.data()+46,4112,2);
    assert(!MeteorXrWire().header(larger,frame));
}
