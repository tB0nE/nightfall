// Use Valve's original loader, selected by VR_OVERRIDE, without modifying a game.
// Arguments: absolute path to an existing Valve openvr_api.dll; frame count.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <openvr-2.15.6.h>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <memory>
#include <chrono>
#include <thread>

using Microsoft::WRL::ComPtr;
static void check(HRESULT result) {
    if (FAILED(result)) throw std::runtime_error("D3D11 operation failed");
}
#include "windows_openvr_scene.h"
#include "steamvr-driver/geometry.h"
static void save_geometry_source(ID3D11Device *device,ID3D11DeviceContext *context,ID3D11Texture2D *texture,const char *prefix,int eye) {
    D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);
    desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;desc.MiscFlags=0;
    ComPtr<ID3D11Texture2D> staging;check(device->CreateTexture2D(&desc,nullptr,&staging));context->CopyResource(staging.Get(),texture);
    D3D11_MAPPED_SUBRESOURCE mapped{};check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
    std::string path=std::string(prefix)+(eye==0?"-left.ppm":"-right.ppm");FILE *file=nullptr;fopen_s(&file,path.c_str(),"wb");
    if(!file) {context->Unmap(staging.Get(),0);throw std::runtime_error("Cannot write source geometry image");}
    std::fprintf(file,"P6\n%u %u\n255\n",desc.Width,desc.Height);
    for(unsigned y=0;y<desc.Height;++y)for(unsigned x=0;x<desc.Width;++x)std::fwrite(static_cast<const uint8_t *>(mapped.pData)+y*mapped.RowPitch+x*4,1,3,file);
    std::fclose(file);context->Unmap(staging.Get(),0);
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 3 && argc != 4) { std::fprintf(stderr, "usage: meteor-openvr-probe <openvr_api.dll> <frames> [--scene]\n"); return 2; }
    const bool scene=argc==4 && std::wcscmp(argv[3],L"--scene")==0;
    if(argc==4 && !scene)return 2;
    const int frames = _wtoi(argv[2]);
    if (frames < 3 || frames > 7200) return 2;
    HMODULE loader = LoadLibraryExW(argv[1], nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!loader) { std::fprintf(stderr, "Valve loader error=%lu\n", GetLastError()); return 3; }
    using Init = uint32_t (__cdecl *)(vr::EVRInitError *, vr::EVRApplicationType, const char *);
    using Interface = void *(__cdecl *)(const char *, vr::EVRInitError *);
    using Shutdown = void (__cdecl *)();
    auto init = reinterpret_cast<Init>(GetProcAddress(loader, "VR_InitInternal2"));
    auto get_interface = reinterpret_cast<Interface>(GetProcAddress(loader, "VR_GetGenericInterface"));
    auto shutdown = reinterpret_cast<Shutdown>(GetProcAddress(loader, "VR_ShutdownInternal"));
    if (!init || !get_interface || !shutdown) { FreeLibrary(loader); return 4; }
    bool initialized = false;
    int result = 1;
    try {
        vr::EVRInitError error = vr::VRInitError_None;
        init(&error, vr::VRApplication_Scene, nullptr);
        if (error != vr::VRInitError_None) {
            std::fprintf(stderr, "OpenVR init error=%d\n", error);
            throw std::runtime_error("OpenVR init failed");
        }
        initialized = true;
        auto system = static_cast<vr::IVRSystem *>(get_interface(vr::IVRSystem_Version, &error));
        if (!system || error) throw std::runtime_error("OpenVR system unavailable");
        auto compositor = static_cast<vr::IVRCompositor *>(get_interface(vr::IVRCompositor_Version, &error));
        if (!compositor || error) throw std::runtime_error("OpenVR compositor unavailable");
        compositor->SetTrackingSpace(vr::TrackingUniverseStanding);
        int32_t adapter_index = -1;
        system->GetDXGIOutputInfo(&adapter_index);
        if (adapter_index < 0) throw std::runtime_error("No OpenXR-compatible DXGI adapter");
        ComPtr<IDXGIFactory1> factory;
        ComPtr<IDXGIAdapter1> adapter;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        check(factory->EnumAdapters1(adapter_index, &adapter));
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        check(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
            nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context));
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = desc.Height = 512;
        if(scene) {
            system->GetRecommendedRenderTargetSize(&desc.Width,&desc.Height);
            if(desc.Width<256 || desc.Height<256 || desc.Width>4096 || desc.Height>4096)
                throw std::runtime_error("Invalid recommended OpenVR scene size");
        }
        desc.MipLevels = desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET;
        ComPtr<ID3D11Texture2D> textures[2];
        ComPtr<ID3D11RenderTargetView> views[2];
        for (int eye = 0; eye < 2; ++eye) {
            check(device->CreateTexture2D(&desc, nullptr, &textures[eye]));
            check(device->CreateRenderTargetView(textures[eye].Get(), nullptr, &views[eye]));
            const float colour[4] = {eye == 0 ? 1.0f : 0.0f, 0.0f, eye == 1 ? 1.0f : 0.0f, 1.0f};
            context->ClearRenderTargetView(views[eye].Get(), colour);
        }
        auto renderer=scene?std::make_unique<OpenVrScene>(device.Get()):nullptr;
        const char *pace=std::getenv("METEOR_OPENVR_PROBE_FPS");
        const int fps=pace?std::atoi(pace):0;
        if(pace && (fps<20 || fps>240))throw std::runtime_error("Invalid probe pacing");
        auto start=std::chrono::steady_clock::now();
        for (int frame = 0; frame < frames; ++frame) {
            if(fps)std::this_thread::sleep_until(start+std::chrono::nanoseconds(int64_t(frame)*1000000000/fps));
            vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount]{};
            if (compositor->WaitGetPoses(poses, vr::k_unMaxTrackedDeviceCount, nullptr, 0))
                throw std::runtime_error("WaitGetPoses failed");
            for (int eye = 0; eye < 2; ++eye) {
                if(renderer) renderer->render(context.Get(),views[eye].Get(),system,poses,static_cast<vr::EVREye>(eye),desc.Width,desc.Height);
                if(frame==60)if(auto prefix=std::getenv("METEOR_OPENVR_PROBE_SNAPSHOT")) {
                    save_geometry_source(device.Get(),context.Get(),textures[eye].Get(),prefix,eye);
                    float l,r,t,b;system->GetProjectionRaw(static_cast<vr::EVREye>(eye),&l,&r,&t,&b);
                    std::printf("SOURCE_PROJECTION eye=%d tangents=%.8f,%.8f,%.8f,%.8f\n",eye,l,r,t,b);
                    auto projection=system->GetProjectionMatrix(static_cast<vr::EVREye>(eye),.05f,100);
                    float source_pose[7]{};
                    meteor_geometry::pose(meteor_geometry::compose(poses[vr::k_unTrackedDeviceIndex_Hmd].mDeviceToAbsoluteTracking,system->GetEyeToHeadTransform(static_cast<vr::EVREye>(eye))),source_pose);
                    std::string diagnostic=std::string(prefix)+(eye==0?"-left.json":"-right.json");FILE *geometry=nullptr;fopen_s(&geometry,diagnostic.c_str(),"wb");
                    if(!geometry)throw std::runtime_error("Cannot write source geometry metadata");
                    std::fprintf(geometry,"{\"pose\":[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g],\"projection\":[%.9g,%.9g,%.9g,%.9g]}",source_pose[0],source_pose[1],source_pose[2],source_pose[3],source_pose[4],source_pose[5],source_pose[6],projection.m[0][0],projection.m[0][2],projection.m[1][1],projection.m[1][2]);std::fclose(geometry);
                    std::printf("SOURCE_MATRIX eye=%d m00=%.8f m02=%.8f m11=%.8f m12=%.8f\n",eye,projection.m[0][0],projection.m[0][2],projection.m[1][1],projection.m[1][2]);
                    if(eye==0) {
                        auto &m=poses[vr::k_unTrackedDeviceIndex_Hmd].mDeviceToAbsoluteTracking;
                        std::printf("SOURCE_HEAD position=%.6f,%.6f,%.6f universe=%d\n",m.m[0][3],m.m[1][3],m.m[2][3],int(compositor->GetTrackingSpace()));std::fflush(stdout);
                    }
                }
                vr::Texture_t texture{textures[eye].Get(), vr::TextureType_DirectX, vr::ColorSpace_Gamma};
                auto submitted = compositor->Submit(static_cast<vr::EVREye>(eye), &texture);
                if (submitted) {
                    std::fprintf(stderr, "Submit eye=%d error=%d\n", eye, submitted);
                    throw std::runtime_error("OpenVR texture submission failed");
                }
            }
        }
        std::printf("OPENVR_PROBE frames=%d adapter=%d graphics=D3D11 scene=%d\n", frames, adapter_index,scene);
        result = 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "OPENVR_PROBE failed: %s\n", error.what());
    }
    if (initialized) shutdown();
    FreeLibrary(loader);
    return result;
}
