// External compositor capture proof; this executable never loads into a game.
#include <windows.h>
#include <tlhelp32.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <openvr.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <cmath>
#include <cstring>
#include <filesystem>
#include "transport.h"
using Microsoft::WRL::ComPtr;
static void check(HRESULT hr) {if(FAILED(hr))throw std::runtime_error("D3D11 operation failed");}
#include "encoder.h"
static void pose_values(const vr::HmdMatrix34_t &m,float *p) {
    for(int r=0;r<3;++r)p[r]=m.m[r][3];
    const float trace=m.m[0][0]+m.m[1][1]+m.m[2][2];
    if(trace>0) {float s=std::sqrt(trace+1)*2;p[6]=.25f*s;p[3]=(m.m[2][1]-m.m[1][2])/s;p[4]=(m.m[0][2]-m.m[2][0])/s;p[5]=(m.m[1][0]-m.m[0][1])/s;}
    else {
        int i=m.m[1][1]>m.m[0][0]?1:0;if(m.m[2][2]>m.m[i][i])i=2;int j=(i+1)%3,k=(i+2)%3;
        float s=std::sqrt(1+m.m[i][i]-m.m[j][j]-m.m[k][k])*2;
        p[3+i]=.25f*s;p[3+j]=(m.m[j][i]+m.m[i][j])/s;p[3+k]=(m.m[k][i]+m.m[i][k])/s;p[6]=(m.m[k][j]-m.m[j][k])/s;
    }
}
static void frame_views(vr::IVRSystem *system,const vr::HmdMatrix34_t &head,float out[22]) {
    for(int eye=0;eye<2;++eye) {
        auto local=system->GetEyeToHeadTransform(static_cast<vr::EVREye>(eye));vr::HmdMatrix34_t world{};
        for(int r=0;r<3;++r)for(int c=0;c<4;++c) {world.m[r][c]=c==3?head.m[r][3]:0;for(int k=0;k<3;++k)world.m[r][c]+=head.m[r][k]*local.m[k][c];}
        float *p=out+eye*11;pose_values(world,p);float l,r,t,b;system->GetProjectionRaw(static_cast<vr::EVREye>(eye),&l,&r,&t,&b);
        p[7]=std::atan(l);p[8]=std::atan(r);p[9]=std::atan(b);p[10]=std::atan(t);
    }
}
static void snapshot(ID3D11Device *device,ID3D11DeviceContext *context,
                     ID3D11ShaderResourceView *view,const std::wstring &path) {
    ComPtr<ID3D11Resource> resource;view->GetResource(&resource);
    ComPtr<ID3D11Texture2D> texture;check(resource.As(&texture));
    D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);
    std::printf("MIRROR_TEXTURE width=%u height=%u format=%u slices=%u samples=%u\n",desc.Width,desc.Height,desc.Format,desc.ArraySize,desc.SampleDesc.Count);
    if(desc.ArraySize!=1 || desc.SampleDesc.Count!=1)throw std::runtime_error("Unsupported mirror texture layout");
    bool bgra=desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB || desc.Format==DXGI_FORMAT_B8G8R8A8_TYPELESS;
    bool rgba=desc.Format==DXGI_FORMAT_R8G8B8A8_UNORM || desc.Format==DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || desc.Format==DXGI_FORMAT_R8G8B8A8_TYPELESS;
    if(!bgra && !rgba)throw std::runtime_error("Unsupported mirror pixel format");
    desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;desc.MiscFlags=0;
    ComPtr<ID3D11Texture2D> staging;check(device->CreateTexture2D(&desc,nullptr,&staging));
    context->CopyResource(staging.Get(),texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
    FILE *file=nullptr;_wfopen_s(&file,path.c_str(),L"wb");
    if(!file) {context->Unmap(staging.Get(),0);throw std::runtime_error("Cannot write mirror image");}
    std::fprintf(file,"P6\n%u %u\n255\n",desc.Width,desc.Height);
    for(unsigned y=0;y<desc.Height;++y)for(unsigned x=0;x<desc.Width;++x) {
        auto p=static_cast<const unsigned char *>(mapped.pData)+y*mapped.RowPitch+x*4;
        unsigned char rgb[]={p[bgra?2:0],p[1],p[bgra?0:2]};std::fwrite(rgb,1,3,file);
    }
    std::fclose(file);context->Unmap(staging.Get(),0);
}
static std::wstring environment(const wchar_t *name) {
    DWORD n=GetEnvironmentVariableW(name,nullptr,0);if(!n)return {};
    std::wstring value(n,L'\0');GetEnvironmentVariableW(name,value.data(),n);value.resize(n-1);return value;
}
static void start_runtime() {
    HANDLE processes=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(processes==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot inspect SteamVR processes");
    PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);bool existing=false;
    if(Process32FirstW(processes,&entry))do {if(!_wcsicmp(entry.szExeFile,L"vrserver.exe") || !_wcsicmp(entry.szExeFile,L"vrcompositor.exe"))existing=true;}while(Process32NextW(processes,&entry));
    CloseHandle(processes);if(existing)throw std::runtime_error("An existing SteamVR session must be left untouched");
    auto root=environment(L"METEOR_STEAMVR_ROOT");if(root.empty())throw std::runtime_error("SteamVR runtime root missing");
    std::wstring command=L"\""+root+L"\\bin\\win64\\vrstartup.exe\"";
    STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
    if(!CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,0,nullptr,nullptr,&startup,&process))throw std::runtime_error("Cannot start owned SteamVR runtime");
    CloseHandle(process.hThread);CloseHandle(process.hProcess);
    auto ready=environment(L"METEOR_STEAMVR_READY_FILE");if(ready.empty())throw std::runtime_error("SteamVR ready marker missing");
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    while(!std::filesystem::is_regular_file(ready)) {if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("SteamVR device did not become ready");Sleep(25);}
}
int wmain(int argc,wchar_t **argv) {
    const bool service=argc==2 && !std::wcscmp(argv[1],L"--service");
    if(!service && argc!=4)return 2;
    int seconds=service?60:_wtoi(argv[2]);if(seconds<1 || seconds>60)return 2;
    std::wstring loader_path=service?environment(L"METEOR_STEAMVR_ROOT")+L"\\bin\\win64\\openvr_api.dll":argv[1];
    std::wstring prefix=service?environment(L"METEOR_WINDOWS_SESSION_MARKER"):argv[3];
    if(service) {try {Sleep(250);start_runtime();}catch(const std::exception &e) {std::fprintf(stderr,"STEAMVR_START failed: %s\n",e.what());return 3;}}
    HMODULE loader=LoadLibraryExW(loader_path.c_str(),nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);if(!loader)return 3;
    auto init=reinterpret_cast<uint32_t (*)(vr::EVRInitError *,vr::EVRApplicationType,const char *)>(GetProcAddress(loader,"VR_InitInternal2"));
    auto api=reinterpret_cast<void *(*)(const char *,vr::EVRInitError *)>(GetProcAddress(loader,"VR_GetGenericInterface"));
    auto shutdown=reinterpret_cast<void (*)()>(GetProcAddress(loader,"VR_ShutdownInternal"));
    if(!init || !api || !shutdown) {FreeLibrary(loader);return 4;}
    bool initialized=false;vr::IVRCompositor *compositor=nullptr;ID3D11ShaderResourceView *views[2]{};int result=1;
    try {
        vr::EVRInitError error=vr::VRInitError_None;init(&error,vr::VRApplication_Background,nullptr);
        if(error)throw std::runtime_error("Background OpenVR initialization failed");initialized=true;
        auto system=static_cast<vr::IVRSystem *>(api(vr::IVRSystem_Version,&error));
        if(!system || error)throw std::runtime_error("OpenVR system unavailable");
        compositor=static_cast<vr::IVRCompositor *>(api(vr::IVRCompositor_Version,&error));
        if(!compositor || error)throw std::runtime_error("OpenVR compositor unavailable");
        if(service)compositor->FadeGrid(0,false);
        if(service && std::getenv("METEOR_STEAMVR_DIRECT")) {
            vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount]{};
            if(compositor->GetLastPoses(poses,vr::k_unMaxTrackedDeviceCount,nullptr,0))throw std::runtime_error("SteamVR direct compositor did not become ready");
            auto ready=environment(L"METEOR_STEAMVR_VIDEO_READY_FILE");FILE *file=nullptr;
            _wfopen_s(&file,ready.c_str(),L"wb");if(!file)throw std::runtime_error("Cannot mark direct compositor readiness");std::fclose(file);
            while(!std::filesystem::is_regular_file(prefix+L".ended")) {
                if(std::filesystem::is_regular_file(prefix+L".failed"))throw std::runtime_error("SteamVR direct capture failed; inspect the driver failure marker and vrserver log");
                Sleep(20);
            }
            shutdown();FreeLibrary(loader);Sleep(INFINITE);return 0;
        }
        int32_t adapter_index=-1;system->GetDXGIOutputInfo(&adapter_index);
        ComPtr<IDXGIFactory1> factory;ComPtr<IDXGIAdapter1> adapter;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));check(factory->EnumAdapters1(adapter_index,&adapter));
        ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
        check(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
        for(int eye=0;eye<2;++eye) {
            auto status=compositor->GetMirrorTextureD3D11(static_cast<vr::EVREye>(eye),device.Get(),reinterpret_cast<void **>(&views[eye]));
            if(status) {std::fprintf(stderr,"mirror eye=%d error=%d\n",eye,status);throw std::runtime_error("Compositor mirror unavailable");}
        }
        if(service) {
            auto ready=environment(L"METEOR_STEAMVR_VIDEO_READY_FILE");FILE *file=nullptr;
            _wfopen_s(&file,ready.c_str(),L"wb");if(!file)throw std::runtime_error("Cannot mark compositor readiness");std::fclose(file);
        }
        const bool encode=std::getenv("METEOR_STEAMVR_ENCODE") || std::getenv("METEOR_XR_DIRECT_PORT");
        unsigned w=512,h=512;system->GetRecommendedRenderTargetSize(&w,&h);
        if(auto text=std::getenv("METEOR_XR_EYE_SIZE"))w=unsigned(std::atoi(text));
        if(auto text=std::getenv("METEOR_XR_EYE_HEIGHT"))h=unsigned(std::atoi(text));
        unsigned fps=72;if(auto text=std::getenv("XRT_COMPOSITOR_NULL_FPS"))fps=unsigned(std::atoi(text));
        if(w<256 || w>4096 || w%16 || h<256 || h>4096 || h%16 || (fps!=20 && fps!=60 && fps!=72))throw std::runtime_error("Unsupported SteamVR video dimensions/rate");
        MirrorEncoder encoder;FILE *recording=nullptr;
        if(encode) {
            encoder.initialize(device.Get(),w,h,fps);
            if(!std::getenv("METEOR_XR_DIRECT_PORT"))_wfopen_s(&recording,(prefix+L".h264").c_str(),L"wb");
        }
        uint32_t last=0,unique=0,encoded=0;bool snapped=false;auto next=std::chrono::steady_clock::now();auto deadline=next+std::chrono::seconds(seconds);
        vr::Compositor_FrameTiming timing{};
        while(service?!std::filesystem::is_regular_file(prefix+L".stop"):std::chrono::steady_clock::now()<deadline) {
            vr::Compositor_FrameTiming candidate{};candidate.m_nSize=sizeof(candidate);
            if(compositor->GetFrameTiming(&candidate) && candidate.m_HmdPose.bPoseIsValid)timing=candidate;
            // Loading can temporarily remove the application's valid timing.
            // Keep the last rendered source pose while streaming compositor
            // loading overlays, instead of starving the receiver's video lane.
            if(timing.m_HmdPose.bPoseIsValid) {
                if(timing.m_nFrameIndex!=last) {last=timing.m_nFrameIndex;++unique;}
                auto now=std::chrono::steady_clock::now();
                if(encode && timing.m_HmdPose.bPoseIsValid && now>=next) {
                    auto period=std::chrono::nanoseconds(1000000000/fps);
                    next+=period;if(next+period<now)next=now+period;
                    auto packet=encoder.encode(context.Get(),views,encoded+1);++encoded;
                    if(encoded==1 && std::getenv("METEOR_STEAMVR_GEOMETRY_PROBE")) {
                        auto &m=timing.m_HmdPose.mDeviceToAbsoluteTracking;
                        vr::TrackedDevicePose_t live[vr::k_unMaxTrackedDeviceCount]{};
                        system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding,0,live,vr::k_unMaxTrackedDeviceCount);
                        auto &p=live[vr::k_unTrackedDeviceIndex_Hmd].mDeviceToAbsoluteTracking;
                        std::printf("MIRROR_HEAD render=%.6f,%.6f,%.6f live_standing=%.6f,%.6f,%.6f tracking_space=%d\n",m.m[0][3],m.m[1][3],m.m[2][3],p.m[0][3],p.m[1][3],p.m[2][3],int(compositor->GetTrackingSpace()));std::fflush(stdout);
                    }
                    if(recording)std::fwrite(packet.data(),1,packet.size(),recording);
                    if(std::getenv("METEOR_XR_DIRECT_PORT")) {
                        float eye_poses[22]{};frame_views(system,timing.m_HmdPose.mDeviceToAbsoluteTracking,eye_poses);
                        uint64_t ns=std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
                        if(!meteor_steamvr_deliver(encoded,ns,w,h,eye_poses,packet.data(),uint32_t(packet.size())))throw std::runtime_error("Meteor delivery failed");
                        if(service && encoded==1) {FILE *marker=nullptr;_wfopen_s(&marker,prefix.c_str(),L"wb");if(!marker)throw std::runtime_error("Cannot mark first frame");std::fclose(marker);}
                    }
                }
                if((!service || std::getenv("METEOR_STEAMVR_GEOMETRY_PROBE")) && !snapped && unique>=60) {
                    snapped=true;for(int eye=0;eye<2;++eye)snapshot(device.Get(),context.Get(),views[eye],prefix+(eye==0?L"-left.ppm":L"-right.ppm"));
                }
            }
            Sleep(2);
        }
        if(recording)std::fclose(recording);
        if(std::getenv("METEOR_XR_DIRECT_PORT") && !meteor_steamvr_finish())throw std::runtime_error("Meteor END acknowledgement failed");
        std::printf("STEAMVR_MIRROR unique_frames=%u encoded_frames=%u seconds=%d adapter=%d\n",unique,encoded,seconds,adapter_index);
        if(unique<3)throw std::runtime_error("Compositor frame clock did not advance");result=0;
    } catch(const std::exception &e) {std::fprintf(stderr,"STEAMVR_MIRROR failed: %s\n",e.what());}
    for(auto view:views)if(view && compositor)compositor->ReleaseMirrorTextureD3D11(view);
    if(initialized)shutdown();FreeLibrary(loader);
    if(service && result==0) {
        FILE *marker=nullptr;_wfopen_s(&marker,(prefix+L".ended").c_str(),L"wb");if(!marker)return 1;std::fclose(marker);
        // The Rust supervisor owns the process tree and closes it after END.
        Sleep(INFINITE);
    }
    return result;
}
