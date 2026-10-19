#pragma once
// Authored diagnostic adapter only. Upstream owns renderer, action/session loop.
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <chrono>
#include "monado_probe_paths.h"
inline bool meteor_hello_enabled() { return std::getenv("METEOR_XR_HELLO_DIAGNOSTIC")!=nullptr; }
inline XrAction meteor_touch_actions[4]{};
inline XrPath meteor_touch_paths[2]{};
inline XrVector2f meteor_touch_sticks[2]{};
inline bool meteor_touch_ax[2]{},meteor_touch_click[2]{};
inline void meteor_hello_touch_bindings(XrInstance instance,XrActionSet set,std::vector<XrActionSuggestedBinding> &bindings) {
    if(!std::getenv("METEOR_XR_TOUCH_INPUTS")) return;
    CHECK_XRCMD(xrStringToPath(instance,"/user/hand/left",&meteor_touch_paths[0]));
    CHECK_XRCMD(xrStringToPath(instance,"/user/hand/right",&meteor_touch_paths[1]));
    const char *names[4]={"meteor_stick","meteor_ax","meteor_stick_click","meteor_trigger"};
    for(int i=0;i<4;++i) {
        XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
        std::strcpy(info.actionName,names[i]); std::strcpy(info.localizedActionName,names[i]);
        info.actionType=i==0 ? XR_ACTION_TYPE_VECTOR2F_INPUT : (i==3 ? XR_ACTION_TYPE_FLOAT_INPUT : XR_ACTION_TYPE_BOOLEAN_INPUT);
        info.countSubactionPaths=2; info.subactionPaths=meteor_touch_paths;
        CHECK_XRCMD(xrCreateAction(set,&info,&meteor_touch_actions[i]));
        for(int hand=0;hand<2;++hand) {
            const char *suffix=i==0 ? "/input/thumbstick" : i==1 ? (hand==0 ? "/input/x/click" : "/input/a/click") :
                i==2 ? "/input/thumbstick/click" : "/input/trigger/value";
            std::string path=(hand==0 ? "/user/hand/left" : "/user/hand/right")+std::string(suffix);
            XrPath binding; CHECK_XRCMD(xrStringToPath(instance,path.c_str(),&binding));
            bindings.push_back({meteor_touch_actions[i],binding});
        }
    }
}
inline void meteor_hello_touch_log(XrSession session) {
    if(!meteor_touch_actions[0]) return;
    for(int hand=0;hand<2;++hand) {
        XrActionStateGetInfo query{XR_TYPE_ACTION_STATE_GET_INFO}; query.subactionPath=meteor_touch_paths[hand];
        XrActionStateVector2f stick{XR_TYPE_ACTION_STATE_VECTOR2F};
        query.action=meteor_touch_actions[0]; CHECK_XRCMD(xrGetActionStateVector2f(session,&query,&stick));
        XrActionStateBoolean ax{XR_TYPE_ACTION_STATE_BOOLEAN},click{XR_TYPE_ACTION_STATE_BOOLEAN};
        query.action=meteor_touch_actions[1]; CHECK_XRCMD(xrGetActionStateBoolean(session,&query,&ax));
        query.action=meteor_touch_actions[2]; CHECK_XRCMD(xrGetActionStateBoolean(session,&query,&click));
        XrActionStateFloat trigger{XR_TYPE_ACTION_STATE_FLOAT};
        query.action=meteor_touch_actions[3]; CHECK_XRCMD(xrGetActionStateFloat(session,&query,&trigger));
        meteor_touch_sticks[hand]=stick.isActive ? stick.currentState : XrVector2f{};
        meteor_touch_ax[hand]=ax.isActive && ax.currentState;
        meteor_touch_click[hand]=click.isActive && click.currentState;
        std::printf("HELLO_XR_TOUCH hand=%d active=%u stick=%.3f,%.3f ax=%u click=%u trigger=%.3f\n",hand,
            unsigned(stick.isActive && ax.isActive && click.isActive && trigger.isActive),stick.currentState.x,stick.currentState.y,
            ax.currentState,click.currentState,trigger.currentState);
    }
}
inline void meteor_hello_submitted(XrInstance instance,XrSession session,XrTime display_time,bool rendered) {
    if(!meteor_hello_enabled() || !rendered) return;
    meteor_hello_touch_log(session);
    static unsigned submitted=0;
    PFN_xrConvertTimeToTimespecTimeKHR convert=nullptr;
    CHECK_XRCMD(xrGetInstanceProcAddr(instance,"xrConvertTimeToTimespecTimeKHR",reinterpret_cast<PFN_xrVoidFunction *>(&convert)));
    timespec stamp{}; CHECK_XRCMD(convert(instance,display_time,&stamp));
    long long host_ns=static_cast<long long>(stamp.tv_sec)*1000000000LL+stamp.tv_nsec;
    std::printf("Frame %u monotonic_ns=%lld\n",submitted,host_ns); std::fflush(stdout);
    const char *limit_text=std::getenv("METEOR_CONTINUOUS_FRAMES");
    unsigned limit=limit_text ? unsigned(std::atoi(limit_text)) : 32;
    if(!limit || limit>240) throw std::runtime_error("Invalid hello_xr diagnostic frame limit");
    if(++submitted!=limit) {
        const char *duration=std::getenv("METEOR_XR_INPUT_SECONDS");
        if(duration) {
            int seconds=std::atoi(duration);
            if(seconds<1 || seconds>30) throw std::runtime_error("Input diagnostic duration must be 1..30 seconds");
            static auto start=std::chrono::steady_clock::now();
            std::this_thread::sleep_until(start+std::chrono::microseconds(1000000LL*seconds*submitted/limit));
        }
        return;
    }
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
