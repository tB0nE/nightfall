#include "pcvr_meteor_tracking_endpoint.h"
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <thread>
// Synthetic publisher for exercising the exact endpoint on Linux or Android.
// A real headset uses xrLocateSpace instead; this fixture is not tracking proof.
int main(int argc, char **argv) {
    if (argc!=2 && argc!=3) return 2;
    char *end=nullptr; long port=std::strtol(argv[1],&end,10);
    if (!*argv[1] || *end || port<1 || port>65535) return 2;
    MeteorTrackingEndpoint endpoint;
    if (!endpoint.start(uint16_t(port))) return 1;
    auto deadline=MeteorTrackingEndpoint::now_ns()+30000000000ULL;
    bool ready=false;
    while (!endpoint.idle() && MeteorTrackingEndpoint::now_ns()<deadline) {
        MeteorTrackingSample s; s.epoch=42; s.client_ns=MeteorTrackingEndpoint::now_ns();
        s.pose[0]=.25f;
        if (argc==3) s.pose[0]+=.05f*std::sin(double(s.client_ns)*1e-9*3.0);
        endpoint.publish(s);
        if (!ready && endpoint.listening()) { std::puts("READY synthetic tracking publisher"); std::fflush(stdout); ready=true; }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    bool passed=ready && endpoint.idle() && !endpoint.failed();
    endpoint.request_stop(); return passed ? 0 : 1;
}
