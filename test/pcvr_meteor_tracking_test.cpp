#include "pcvr_meteor_tracking.h"
#include <cassert>
int main() {
    MeteorTrackingSample s; s.epoch=42; s.client_ns=1000; s.pose[0]=.25f;
    auto packet=MeteorTrackingWire::encode(s);
    MeteorTrackingWire wire; MeteorTrackingSample out;
    assert(wire.accept(packet,out)); assert(out.pose==s.pose);
    assert(!wire.accept(packet,out)); // Replay must not mutate state.
    s.sequence=1; s.client_ns=1001; packet=MeteorTrackingWire::encode(s);
    for (int offset : {0,4,6,8,16,60}) {
        auto bad=packet; bad[offset]=255; assert(!wire.accept(bad,out));
    }
    auto bad=packet; float nan=std::numeric_limits<float>::quiet_NaN();
    meteor_xr_put(bad.data()+24,1000,8); assert(!wire.accept(bad,out));
    bad=packet;
    std::memcpy(bad.data()+32,&nan,4); assert(!wire.accept(bad,out));
    s.pose[6]=0; assert(!wire.accept(MeteorTrackingWire::encode(s),out));
    assert(wire.accept(packet,out));
    MeteorClockMapping clock; uint64_t mapped=0;
    assert(!clock.to_host(1000,mapped));
    assert(clock.observe(10000,1000,1020,10060)); // Offset +9020, RTT 40.
    assert(clock.to_host(2000,mapped) && mapped==11020);
    assert(clock.uncertainty_ns()==20);
    assert(clock.observe(10000,1000,1020,10100)); // Worse sample ignored.
    assert(clock.to_host(2000,mapped) && mapped==11020);
    assert(!clock.observe(10000,1000,1100,10060));
    assert(!clock.observe(10000,1000,999,10060));
    assert(!clock.observe(10000,1000,1000,200000000));
    assert(!clock.to_host(UINT64_MAX,mapped));
    MeteorClockMapping negative;
    assert(negative.observe(1000,10000,10020,1060));
    assert(!negative.to_host(1,mapped));
    assert(negative.to_host(11000,mapped) && mapped==2020);
}
