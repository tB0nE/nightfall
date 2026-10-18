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
    MeteorXrWire wire; MeteorXrFrame frame;
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
}
