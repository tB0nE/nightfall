// Exercise the installed xrizer with VRChat's real, unmodified action manifest.
#include <openvr.h>
#include <ivrclientcore.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <thread>
#include <chrono>
#include <vector>
static void require(bool ok,const char *message) {
    if(!ok) {std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1);}
}
#include "meteor_openvr_probe_texture.h"
int main() {
    void *lib=dlopen(std::getenv("METEOR_XRIZER_LIBRARY"),RTLD_NOW|RTLD_LOCAL);
    require(lib!=nullptr,dlerror());
    auto factory=reinterpret_cast<void *(*)(const char *,int *)>(dlsym(lib,"VRClientCoreFactory"));
    require(factory!=nullptr,"VRClientCoreFactory"); int code=0;
    auto core=static_cast<vr::IVRClientCore *>(factory(vr::IVRClientCore_Version,&code));
    require(core!=nullptr,"client core");
    require(core->Init(vr::VRApplication_Scene,nullptr)==vr::VRInitError_None,"initialize xrizer");
    vr::EVRInitError error{};
    auto input=static_cast<vr::IVRInput *>(core->GetGenericInterface(vr::IVRInput_Version,&error));
    require(input!=nullptr,"IVRInput");
    auto compositor=static_cast<vr::IVRCompositor *>(core->GetGenericInterface(vr::IVRCompositor_Version,&error));
    auto system=static_cast<vr::IVRSystem *>(core->GetGenericInterface(vr::IVRSystem_Version,&error));
    require(compositor && system,"compositor/system interfaces");
    ProbeTexture texture(compositor);
    require(input->SetActionManifestPath(std::getenv("METEOR_VRCHAT_MANIFEST"))==vr::VRInputError_None,"VRChat action manifest");
    vr::VRActionSetHandle_t set;
    require(input->GetActionSetHandle("/actions/global",&set)==vr::VRInputError_None,"global set");
    vr::VRActionHandle_t actions[2]; vr::VRInputValueHandle_t hands[2];
    require(input->GetActionHandle("/actions/global/in/stick_click",actions)==vr::VRInputError_None,"stick action");
    require(input->GetActionHandle("/actions/global/in/menu",actions+1)==vr::VRInputError_None,"menu action");
    require(input->GetInputSourceHandle("/user/hand/left",hands)==vr::VRInputError_None,"left source");
    require(input->GetInputSourceHandle("/user/hand/right",hands+1)==vr::VRInputError_None,"right source");
    const unsigned phases[][2]={{0,0},{2,0},{0,0},{0,2},{0,0},{32,0},{0,32},{32,32},{2,2},{0,0}};
    for(const auto &phase:phases) {
        {std::ofstream file(std::getenv("METEOR_CONTROLLER_FIXTURE")); file<<phase[0]<<" "<<phase[1]<<"\n";}
        bool matched=false;
        for(int attempt=0;attempt<100 && !matched;++attempt) {
            vr::VREvent_t event{};
            while(system->PollNextEvent(&event,sizeof(event))) {}
            vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount]{};
            compositor->WaitGetPoses(poses,vr::k_unMaxTrackedDeviceCount,nullptr,0);
            texture.submit(compositor);
            vr::VRActiveActionSet_t active{}; active.ulActionSet=set;
            require(input->UpdateActionState(&active,sizeof(active),1)==vr::VRInputError_None,"update action state");
            matched=true;
            for(int h=0;h<2;++h) for(int a=0;a<2;++a) {
                vr::InputDigitalActionData_t data{};
                require(input->GetDigitalActionData(actions[a],&data,sizeof(data),hands[h])==vr::VRInputError_None,"read action");
                bool expected=(phase[h]&(a ? 32 : 2))!=0;
                matched=matched && data.bActive && data.bState==expected;
                if(attempt==99) std::printf("OPENVR_INPUT hand=%d action=%d active=%d value=%d expected=%d\n",h,a,data.bActive,data.bState,expected);
            }
            compositor->PostPresentHandoff();
            if(!matched) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        require(matched,"xrizer per-hand action mismatch");
        std::printf("PASS: xrizer/VRChat per-hand phase left=%u right=%u\n",phase[0],phase[1]);
    }
    core->Cleanup();
}
