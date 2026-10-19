#include "pcvr_meteor_tracking_endpoint.h"
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <thread>
#include <poll.h>
#include <unistd.h>
// Synthetic publisher for exercising the exact endpoint on Linux or Android.
// A real headset uses xrLocateSpace instead; this fixture is not tracking proof.
int main(int argc, char **argv) {
    if (argc!=2 && argc!=3) return 2;
    char *end=nullptr; long port=std::strtol(argv[1],&end,10);
    if (!*argv[1] || *end || port<1 || port>65535) return 2;
    MeteorTrackingEndpoint endpoint;
    if (!endpoint.start(uint16_t(port))) return 1;
    auto deadline=MeteorTrackingEndpoint::now_ns()+45000000000ULL;
    bool ready=false;
    bool interrupted=false;
    while (!endpoint.idle() && MeteorTrackingEndpoint::now_ns()<deadline) {
        if(argc==3 && !std::strcmp(argv[2],"disconnect")) {
            pollfd input{STDIN_FILENO,POLLIN,0};
            if(poll(&input,1,0)>0 && (input.revents&POLLIN)) {
                char command=0;
                if(read(STDIN_FILENO,&command,1)==1 && command=='q') { interrupted=true; break; }
            }
        }
        MeteorTrackingSample s; s.epoch=42; s.client_ns=MeteorTrackingEndpoint::now_ns();
        s.pose[0]=.25f;
        s.optics.epoch=s.epoch;
        s.optics.eyes={-.032f,0,0,0,0,0,1,-.8f,.7f,.75f,-.65f,
                       .032f,0,0,0,0,0,1,-.7f,.8f,.75f,-.65f};
        s.controllers.epoch=s.epoch; s.controllers.client_ns=s.client_ns;
        for(int hand=0;hand<2;++hand) {
            auto &state=s.controllers.hands[hand]; state.flags=7; state.trigger=.25f; state.squeeze=.75f;
            state.poses[0]=hand==0 ? .05f : .45f; state.poses[1]=-.3f; state.poses[2]=-.5f;
            if(argc==3) { state.poses[0]+=.03f*std::sin(double(s.client_ns)*1e-9*7); state.squeeze=float((s.client_ns/100000000)%3)*.5f; }
            std::copy(state.poses.begin(),state.poses.begin()+7,state.poses.begin()+7);
            state.flags|=8; state.stick={hand==0 ? -.5f : .5f,.25f}; state.buttons=31;
            if(argc==3) { state.stick[0]=float(std::sin(double(s.client_ns)*1e-9*6))*(hand==0 ? -1.f : 1.f); state.buttons=((s.client_ns/100000000)%2) ? 31 : 0; }
        }
        if (argc==3) s.pose[0]+=.05f*std::sin(double(s.client_ns)*1e-9*3.0);
        endpoint.publish(s);
        for(unsigned hand=0;hand<2;++hand) {
            MeteorHaptic h;
            if(endpoint.take_haptic(hand,h)) {
                std::printf("HAPTIC hand=%u amplitude=%.3f duration_ms=%u\n",hand,h.amplitude,h.duration_ms);
                std::fflush(stdout);
            }
        }
        if (!ready && endpoint.listening()) { std::puts("READY synthetic tracking publisher"); std::fflush(stdout); ready=true; }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    bool passed=ready && (interrupted || (endpoint.idle() && !endpoint.failed()));
    endpoint.request_stop(); return passed ? 0 : 1;
}
