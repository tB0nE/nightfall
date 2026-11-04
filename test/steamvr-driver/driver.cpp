// Experimental SteamVR device provider. Loaded by vrserver, never by the game.
// Explicit opt-in only; a synthetic pose is allowed only in local test mode.
#include <windows.h>
#include <openvr_driver.h>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <string>

static uint32_t width=512,height=512,hz=72;
static bool synthetic=false;
static bool direct_mode=false;
static float optics[22]={-.032f,0,0,0,0,0,1,-.785398f,.785398f,.785398f,-.785398f,
                         .032f,0,0,0,0,0,1,-.785398f,.785398f,.785398f,-.785398f};
static int64_t now_ns() {return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
static const char *env(const char *name) {const char *p=std::getenv(name);return p?p:"";}
static uint32_t dimension(const char *name,uint32_t fallback) {
    auto value=env(name);if(!*value)return fallback;char *end=nullptr;auto n=std::strtoul(value,&end,10);
    if(*end || n<256 || n>4096 || n%16)throw std::runtime_error("Invalid SteamVR eye dimension");return uint32_t(n);
}
struct Tracking {
    HMODULE module=nullptr;void *client=nullptr;
    void *(*start)(const char *)=nullptr;
    void (*stop)(void *)=nullptr;
    int (*head)(void *,int64_t,float *,uint64_t *)=nullptr;
    int (*controller)(unsigned,int64_t,float *,float *,uint32_t *,uint32_t *,uint64_t *)=nullptr;
    int (*haptic)(unsigned,float,int64_t)=nullptr;
    int (*eyes)(void *,float *)=nullptr;
    template<class T> void symbol(T &out,const char *name) {out=reinterpret_cast<T>(GetProcAddress(module,name));if(!out)throw std::runtime_error("Missing Meteor tracking export");}
    void initialize() {
        if(synthetic)return;
        module=LoadLibraryA(env("METEOR_TRACKING_BRIDGE"));if(!module)throw std::runtime_error("Missing Meteor tracking bridge");
        symbol(start,"meteor_tracking_start_v1");symbol(stop,"meteor_tracking_stop_v1");symbol(head,"meteor_tracking_pose_v1");
        symbol(controller,"meteor_tracking_controller_v2");symbol(haptic,"meteor_tracking_haptic_v1");symbol(eyes,"meteor_tracking_optics_v1");
        client=start(env("METEOR_TRACKING_PORT"));if(!client || !eyes(client,optics))throw std::runtime_error("Meteor tracking/optics not ready");
    }
    ~Tracking() {if(client && stop)stop(client);if(module)FreeLibrary(module);}
};
static std::unique_ptr<Tracking> tracking;
static vr::DriverPose_t make_pose(const float *p,bool valid) {
    vr::DriverPose_t out{};out.qWorldFromDriverRotation.w=out.qDriverFromHeadRotation.w=1;
    out.qRotation={p[6],p[3],p[4],p[5]};
    for(int i=0;i<3;++i)out.vecPosition[i]=p[i];
    out.poseIsValid=valid;out.deviceIsConnected=true;
    out.result=valid?vr::TrackingResult_Running_OK:vr::TrackingResult_Running_OutOfRange;
    return out;
}
static vr::HmdMatrix34_t eye_matrix(const float *p) {
    float x=p[3],y=p[4],z=p[5],w=p[6];
    return {{{1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w),p[0]},
             {2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w),p[1]},
             {2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y),p[2]}}};
}
#include "direct.h"
class Device:public vr::ITrackedDeviceServerDriver,public vr::IVRDisplayComponent {
    int hand;vr::TrackedDeviceIndex_t index=vr::k_unTrackedDeviceIndexInvalid;
    vr::VRInputComponentHandle_t trigger=0,squeeze=0,stick[2]{},buttons[9]{},vibration=0;
    vr::DriverPose_t pose{};
    std::unique_ptr<DirectCapture> capture;
public:
    explicit Device(int role):hand(role) {if(hand<0 && direct_mode)capture=std::make_unique<DirectCapture>();}
    void poll_stop() {if(capture)capture->poll_stop();}
    vr::EVRInitError Activate(uint32_t id) override {
        index=id;auto properties=vr::VRProperties();auto c=properties->TrackedDeviceToPropertyContainer(id);
        properties->SetStringProperty(c,vr::Prop_ManufacturerName_String,"Nightfall");
        properties->SetStringProperty(c,vr::Prop_TrackingSystemName_String,"meteor");
        properties->SetUint64Property(c,vr::Prop_CurrentUniverseId_Uint64,2);
        properties->SetStringProperty(c,vr::Prop_ModelNumber_String,hand<0?"Meteor trial HMD":"Meteor Touch");
        if(hand<0) {
            // Quest supplies floor-relative poses and retains its own boundary.
            // A nominal standing-only universe avoids SteamVR room setup; it
            // does not claim to describe the user's physical safe play area.
            properties->SetStringProperty(c,vr::Prop_DriverProvidedChaperoneJson_String,
                R"({"jsonid":"chaperone_info","version":5,"time":"2026-11-04T00:00:00Z","universes":[{"universeID":"2","collision_bounds":[],"play_area":[1,1],"standing":{"translation":[0,0,0],"yaw":0},"seated":{"translation":[0,0,0],"yaw":0}}]})");
            properties->SetFloatProperty(c,vr::Prop_DisplayFrequency_Float,float(hz));
            properties->SetFloatProperty(c,vr::Prop_UserIpdMeters_Float,optics[11]-optics[0]);
            properties->SetFloatProperty(c,vr::Prop_UserHeadToEyeDepthMeters_Float,0);
            properties->SetFloatProperty(c,vr::Prop_SecondsFromVsyncToPhotons_Float,.015f);
            properties->SetBoolProperty(c,vr::Prop_IsOnDesktop_Bool,false);
            properties->SetBoolProperty(c,vr::Prop_DisplayDebugMode_Bool,!direct_mode);
            properties->SetBoolProperty(c,vr::Prop_HasDisplayComponent_Bool,true);
            properties->SetBoolProperty(c,vr::Prop_HasDriverDirectModeComponent_Bool,direct_mode);
            properties->SetBoolProperty(c,vr::Prop_DriverDirectModeSendsVsyncEvents_Bool,direct_mode);
            if(capture)properties->SetUint64Property(c,vr::Prop_GraphicsAdapterLuid_Uint64,capture->luid());
            vr::VRServerDriverHost()->SetDisplayEyeToHead(id,eye_matrix(optics),eye_matrix(optics+11));
            if(*env("METEOR_STEAMVR_READY_FILE")) {
                FILE *ready=nullptr;fopen_s(&ready,env("METEOR_STEAMVR_READY_FILE"),"wb");
                if(!ready)return vr::VRInitError_Driver_Failed;std::fclose(ready);
            }
        } else {
            properties->SetInt32Property(c,vr::Prop_ControllerRoleHint_Int32,hand==0?vr::TrackedControllerRole_LeftHand:vr::TrackedControllerRole_RightHand);
            properties->SetStringProperty(c,vr::Prop_ControllerType_String,"oculus_touch");
            properties->SetStringProperty(c,vr::Prop_InputProfilePath_String,"{oculus}/input/touch_profile.json");
            properties->SetStringProperty(c,vr::Prop_RenderModelName_String,hand==0?"oculus_quest2_controller_left":"oculus_quest2_controller_right");
            auto input=vr::VRDriverInput();
            input->CreateScalarComponent(c,"/input/trigger/value",&trigger,vr::VRScalarType_Absolute,vr::VRScalarUnits_NormalizedOneSided);
            input->CreateScalarComponent(c,"/input/grip/value",&squeeze,vr::VRScalarType_Absolute,vr::VRScalarUnits_NormalizedOneSided);
            input->CreateScalarComponent(c,"/input/joystick/x",&stick[0],vr::VRScalarType_Absolute,vr::VRScalarUnits_NormalizedTwoSided);
            input->CreateScalarComponent(c,"/input/joystick/y",&stick[1],vr::VRScalarType_Absolute,vr::VRScalarUnits_NormalizedTwoSided);
            const char *names[]={hand==0?"/input/x/click":"/input/a/click","/input/joystick/click",
                hand==0?"/input/x/touch":"/input/a/touch","/input/joystick/touch","/input/trigger/touch",
                hand==0?"/input/y/click":"/input/b/click",hand==0?"/input/y/touch":"/input/b/touch",
                "/input/trigger/click","/input/grip/click"};
            for(int i=0;i<9;++i)input->CreateBooleanComponent(c,names[i],&buttons[i]);
            input->CreateHapticComponent(c,"/output/haptic",&vibration);
        }
        vr::VRDriverLog()->Log(hand<0?"METEOR_STEAMVR HMD activated":"METEOR_STEAMVR controller activated");
        return vr::VRInitError_None;
    }
    void update() {
        if(index==vr::k_unTrackedDeviceIndexInvalid)return;
        float p[14]={0,1.6f,0,0,0,0,1,0,0,0,0,0,0,1},values[4]{};
        uint32_t flags=0,pressed=0;uint64_t stamp=0;bool valid=synthetic;
        if(synthetic && hand>=0) {p[0]=hand==0?-.25f:.25f;p[1]=1.1f;p[2]=-.35f;}
        if(!synthetic) {
            if(hand<0)valid=tracking->head(tracking->client,now_ns(),p,&stamp)!=0;
            else valid=tracking->controller(unsigned(hand),now_ns(),p,values,&pressed,&flags,&stamp)!=0 && (flags&1);
        }
        if(hand>=0 && valid) {
            auto raw=meteor_geometry::touch_raw_from_grip(meteor_geometry::matrix(p),unsigned(hand));
            meteor_geometry::pose(raw,p);
        }
        pose=make_pose(p,valid);
        vr::VRServerDriverHost()->TrackedDevicePoseUpdated(index,pose,sizeof(pose));
        if(hand>=0) {
            auto input=vr::VRDriverInput();bool active=(flags&4)!=0;
            input->UpdateScalarComponent(trigger,active?values[0]:0,0);input->UpdateScalarComponent(squeeze,active?values[1]:0,0);
            for(int i=0;i<2;++i)input->UpdateScalarComponent(stick[i],(flags&8)?values[i+2]:0,0);
            for(int i=0;i<7;++i)input->UpdateBooleanComponent(buttons[i],active && ((pressed&(1u<<i))!=0),0);
            input->UpdateBooleanComponent(buttons[7],active && values[0]>.55f,0);
            input->UpdateBooleanComponent(buttons[8],active && values[1]>.55f,0);
        }
    }
    void haptic(const vr::VREvent_t &event) {
        if(hand>=0 && event.data.hapticVibration.componentHandle==vibration && tracking->haptic)
            tracking->haptic(unsigned(hand),event.data.hapticVibration.fAmplitude,int64_t(event.data.hapticVibration.fDurationSeconds*1e9));
    }
    void Deactivate() override {index=vr::k_unTrackedDeviceIndexInvalid;}
    void EnterStandby() override {}
    void *GetComponent(const char *name) override {
        if(hand<0 && !std::strcmp(name,vr::IVRDisplayComponent_Version))return static_cast<vr::IVRDisplayComponent *>(this);
        if(capture && !std::strcmp(name,vr::IVRDriverDirectModeComponent_Version))return static_cast<vr::IVRDriverDirectModeComponent *>(capture.get());
        return nullptr;
    }
    void DebugRequest(const char *,char *response,uint32_t n) override {if(n)response[0]=0;}
    vr::DriverPose_t GetPose() override {return pose;}
    void GetWindowBounds(int32_t *x,int32_t *y,uint32_t *w,uint32_t *h) override {*x=0;*y=0;*w=2*width;*h=height;}
    bool IsDisplayOnDesktop() override {return !direct_mode;}
    bool IsDisplayRealDisplay() override {return false;}
    void GetRecommendedRenderTargetSize(uint32_t *w,uint32_t *h) override {*w=width;*h=height;}
    void GetEyeOutputViewport(vr::EVREye eye,uint32_t *x,uint32_t *y,uint32_t *w,uint32_t *h) override {*x=eye==vr::Eye_Left?0:width;*y=0;*w=width;*h=height;}
    void GetProjectionRaw(vr::EVREye eye,float *left,float *right,float *top,float *bottom) override {
        meteor_geometry::projection_raw(optics+(eye==vr::Eye_Left?0:11),left,right,top,bottom);
    }
    vr::DistortionCoordinates_t ComputeDistortion(vr::EVREye,float u,float v) override {vr::DistortionCoordinates_t c{};c.rfRed[0]=c.rfGreen[0]=c.rfBlue[0]=u;c.rfRed[1]=c.rfGreen[1]=c.rfBlue[1]=v;return c;}
    bool ComputeInverseDistortion(vr::HmdVector2_t *out,vr::EVREye,uint32_t,float u,float v) override {out->v[0]=u;out->v[1]=v;return true;}
};
class Provider:public vr::IServerTrackedDeviceProvider {
    std::unique_ptr<Device> devices[3];
public:
    vr::EVRInitError Init(vr::IVRDriverContext *context) override {
        if(std::strcmp(env("METEOR_STEAMVR_TRIAL"),"1"))return vr::VRInitError_Driver_Failed;
        VR_INIT_SERVER_DRIVER_CONTEXT(context);
        try {
            width=dimension("METEOR_XR_EYE_SIZE",512);height=dimension("METEOR_XR_EYE_HEIGHT",width);
            if(*env("XRT_COMPOSITOR_NULL_FPS"))hz=uint32_t(std::atoi(env("XRT_COMPOSITOR_NULL_FPS")));
            if(hz!=20 && hz!=60 && hz!=72)throw std::runtime_error("Unsupported SteamVR display rate");
            synthetic=!std::strcmp(env("METEOR_STEAMVR_SYNTHETIC"),"1");
            direct_mode=!std::strcmp(env("METEOR_STEAMVR_DIRECT"),"1");
            tracking=std::make_unique<Tracking>();tracking->initialize();
            const char *serials[]={"nightfall-meteor-hmd","nightfall-meteor-left","nightfall-meteor-right"};
            for(int i=0;i<3;++i) {
                devices[i]=std::make_unique<Device>(i-1);
                if(!vr::VRServerDriverHost()->TrackedDeviceAdded(serials[i],i==0?vr::TrackedDeviceClass_HMD:vr::TrackedDeviceClass_Controller,devices[i].get()))throw std::runtime_error("SteamVR rejected Meteor device");
            }
            vr::VRDriverLog()->Log("METEOR_STEAMVR provider ready");return vr::VRInitError_None;
        } catch(const std::exception &e) {vr::VRDriverLog()->Log(e.what());Cleanup();return vr::VRInitError_Driver_Failed;}
    }
    void Cleanup() override {for(auto &d:devices)d.reset();tracking.reset();VR_CLEANUP_SERVER_DRIVER_CONTEXT();}
    const char *const *GetInterfaceVersions() override {return vr::k_InterfaceVersions;}
    void RunFrame() override {for(auto &d:devices)if(d) {d->update();d->poll_stop();}vr::VREvent_t event{};while(vr::VRServerDriverHost()->PollNextEvent(&event,sizeof(event)))if(event.eventType==vr::VREvent_Input_HapticVibration)for(auto &d:devices)if(d)d->haptic(event);}
    bool ShouldBlockStandbyMode() override {return true;}
    void EnterStandby() override {}
    void LeaveStandby() override {}
};
static Provider provider;
extern "C" __declspec(dllexport) void *HmdDriverFactory(const char *name,int *error) {
    if(!std::strcmp(name,vr::IServerTrackedDeviceProvider_Version)) {if(error)*error=vr::VRInitError_None;return &provider;}
    if(error)*error=vr::VRInitError_Init_InterfaceNotFound;return nullptr;
}
