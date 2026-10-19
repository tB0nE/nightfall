#include "pcvr_meteor_tracking.h"
#include "pcvr_meteor_haptics.h"
#include <cassert>
int main() {
    MeteorHaptic pulse; pulse.epoch=42; pulse.hand=1; pulse.amplitude=.5f; pulse.duration_ms=150;
    MeteorHaptic decoded_pulse;
    assert(MeteorHapticWire::decode(MeteorHapticWire::encode(pulse),decoded_pulse));
    assert(decoded_pulse.hand==1 && decoded_pulse.duration_ms==150 && decoded_pulse.amplitude==.5f);
    for(int field=0;field<6;++field) {
        auto bad=pulse;
        if(field==0) bad.epoch=0;
        if(field==1) bad.hand=2;
        if(field==2) bad.amplitude=std::numeric_limits<float>::quiet_NaN();
        if(field==3) bad.amplitude=.6f;
        if(field==4) bad.duration_ms=151;
        if(field==5) bad.duration_ms=0;
        assert(!MeteorHapticWire::decode(MeteorHapticWire::encode(bad),decoded_pulse));
    }
    pulse.amplitude=0; pulse.duration_ms=0;
    assert(MeteorHapticWire::decode(MeteorHapticWire::encode(pulse),decoded_pulse));
    MeteorControllerSample controllers; controllers.epoch=42; controllers.client_ns=1000;
    controllers.hands[0].flags=7; controllers.hands[0].trigger=.25f; controllers.hands[0].squeeze=.75f;
    controllers.hands[0].poses[0]=-.2f;
    MeteorControllerWire control_wire; MeteorControllerSample control_out;
    auto controls=MeteorControllerWire::encode(controllers);
    assert(control_wire.accept(controls,control_out)); assert(control_out.hands[0].trigger==.25f);
    assert(!control_wire.accept(controls,control_out));
    controllers.sequence=1; controllers.client_ns=1001; controls=MeteorControllerWire::encode(controllers);
    for(int offset:{0,4,6,8,16,44,104,184}) {
        auto bad=controls; bad[offset]=255; assert(!control_wire.accept(bad,control_out));
    }
    auto invalid_controls=controllers; invalid_controls.hands[0].trigger=1.1f;
    assert(!control_wire.accept(MeteorControllerWire::encode(invalid_controls),control_out));
    invalid_controls=controllers; invalid_controls.hands[0].flags=0;
    assert(!MeteorControllerWire::valid(invalid_controls));
    invalid_controls=controllers; invalid_controls.hands[0].flags=4;
    assert(!MeteorControllerWire::valid(invalid_controls));
    invalid_controls=controllers; invalid_controls.hands[0].poses[6]=0;
    assert(!MeteorControllerWire::valid(invalid_controls));
    invalid_controls=controllers; invalid_controls.hands[1].poses[0]=std::numeric_limits<float>::quiet_NaN();
    assert(!MeteorControllerWire::valid(invalid_controls));
    assert(control_wire.accept(controls,control_out));
    controllers.sequence=0; controllers.client_ns=1002;
    controllers.hands[0].flags=15; controllers.hands[0].stick={-.5f,.25f};
    controllers.hands[0].buttons=31;
    MeteorControllerWire extended(true);
    auto v2=MeteorControllerWire::encode(controllers,true);
    assert(extended.accept(v2,control_out));
    assert(control_out.hands[0].stick==controllers.hands[0].stick);
    assert(control_out.hands[0].buttons==31 && control_out.hands[0].flags==15);
    assert(!extended.accept(v2,control_out));
    assert(!control_wire.accept(v2,control_out));
    MeteorControllerWire legacy;
    assert(legacy.accept(MeteorControllerWire::encode(controllers),control_out));
    assert(control_out.hands[0].flags==7 && control_out.hands[0].buttons==0);
    assert(control_out.hands[0].stick[0]==0);
    for(int field=0;field<4;++field) {
        auto invalid=controllers;
        if(field==0) invalid.hands[0].stick[0]=1.1f;
        if(field==1) invalid.hands[0].stick[1]=std::numeric_limits<float>::quiet_NaN();
        if(field==2) invalid.hands[0].buttons=32;
        if(field==3) invalid.hands[0].flags=7;
        assert(!MeteorControllerWire::valid(invalid));
    }
    MeteorHeadsetOptics optics;
    optics.epoch=42;
    optics.eyes={-.032f,0,0,0,0,0,1,-.8f,.7f,.75f,-.65f,
                  .032f,0,0,0,0,0,1,-.7f,.8f,.75f,-.65f};
    MeteorHeadsetOptics decoded;
    auto optics_packet=MeteorOpticsWire::encode(optics);
    assert(MeteorOpticsWire::decode(optics_packet,decoded));
    assert(decoded.eyes==optics.eyes && decoded.epoch==42);
    for(int offset:{0,4,6,104,111}) {
        auto bad=optics_packet; bad[offset]=255;
        assert(!MeteorOpticsWire::decode(bad,decoded));
    }
    for(int component:{0,3,7,8,9,10,11,14,18,19,20,21}) {
        auto bad=optics; bad.eyes[component]=std::numeric_limits<float>::quiet_NaN();
        assert(!MeteorOpticsWire::decode(MeteorOpticsWire::encode(bad),decoded));
    }
    auto invalid=optics; invalid.epoch=0; assert(!MeteorOpticsWire::valid(invalid));
    invalid=optics; invalid.eyes[6]=0; assert(!MeteorOpticsWire::valid(invalid));
    invalid=optics; invalid.eyes[11]=invalid.eyes[0]; assert(!MeteorOpticsWire::valid(invalid));
    invalid=optics; invalid.eyes[11]=.15f; assert(!MeteorOpticsWire::valid(invalid));
    invalid=optics; invalid.eyes[7]=.5f; assert(!MeteorOpticsWire::valid(invalid));
    invalid=optics; invalid.eyes[9]=1.57f; assert(!MeteorOpticsWire::valid(invalid));
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
