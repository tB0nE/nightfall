#pragma once
// Authored diagnostic adapter only. Upstream owns renderer, action/session loop.
#include <cstdlib>
#include <fstream>
#include <chrono>
#include "monado_probe_paths.h"
inline bool meteor_hello_enabled() { return std::getenv("METEOR_XR_HELLO_DIAGNOSTIC")!=nullptr; }
inline void meteor_hello_submitted(XrInstance instance,XrSession session,XrTime display_time,bool rendered) {
    if(!meteor_hello_enabled() || !rendered) return;
    static unsigned submitted=0;
    PFN_xrConvertTimeToTimespecTimeKHR convert=nullptr;
    CHECK_XRCMD(xrGetInstanceProcAddr(instance,"xrConvertTimeToTimespecTimeKHR",reinterpret_cast<PFN_xrVoidFunction *>(&convert)));
    timespec stamp{}; CHECK_XRCMD(convert(instance,display_time,&stamp));
    long long host_ns=static_cast<long long>(stamp.tv_sec)*1000000000LL+stamp.tv_nsec;
    std::printf("Frame %u monotonic_ns=%lld\n",submitted,host_ns); std::fflush(stdout);
    const char *limit_text=std::getenv("METEOR_CONTINUOUS_FRAMES");
    unsigned limit=limit_text ? unsigned(std::atoi(limit_text)) : 32;
    if(!limit || limit>240) throw std::runtime_error("Invalid hello_xr diagnostic frame limit");
    if(++submitted!=limit) return;
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    bool captured=false;
    while(std::chrono::steady_clock::now()<deadline) {
        std::ifstream ack(meteor_probe_path("capture-complete")); long long received=0;
        if((ack>>received) && received==host_ns) { captured=true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if(!captured) throw std::runtime_error("hello_xr final frame did not drain");
    std::printf("HELLO_XR_FINAL_DRAIN frames=%u\n",submitted); std::fflush(stdout);
    CHECK_XRCMD(xrRequestExitSession(session));
}
