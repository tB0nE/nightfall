#pragma once
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <array>
#include <vector>
#include <map>
#include <mutex>
#include <thread>
#include <filesystem>
#include "transport.h"
#include "geometry.h"
using Microsoft::WRL::ComPtr;
static void check(HRESULT hr) {if(FAILED(hr)) {char message[96];std::snprintf(message,sizeof(message),"SteamVR D3D11 failure 0x%08lx",static_cast<unsigned long>(hr));throw std::runtime_error(message);}}
#include "encoder.h"

// The server owns shared swapchains; SteamVR renders layers into them. Present
// acquires SteamVR's synchronization texture before reading any submitted image.
// No mirror texture or independently sampled compositor pose participates.
class DirectCapture:public vr::IVRDriverDirectModeComponent {
    struct Image {ComPtr<ID3D11Texture2D> texture,resolved;ComPtr<ID3D11ShaderResourceView> srv;};
    struct Set {uint32_t pid=0,index=0;std::array<vr::SharedTextureHandle_t,3> handles{};Image images[3];};
    struct Submitted {SubmitLayerPerEye_t eyes[2];};
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    std::map<vr::SharedTextureHandle_t,std::pair<std::shared_ptr<Set>,unsigned>> images;
    std::map<vr::SharedTextureHandle_t,ComPtr<IDXGIKeyedMutex>> synchronization;
    std::vector<Submitted> layers;
    std::unique_ptr<MirrorEncoder> encoder;
    std::mutex mutex;
    uint64_t frame=0;uint32_t sync_misses=0,dropped_frames=0;
    uint64_t timing_count=0,timing_sum[4]{},timing_peak[4]{};
    uint64_t adapter_luid=0;
    bool failed=false,finished=false;
    std::chrono::steady_clock::time_point next_vsync=std::chrono::steady_clock::now();
    std::string marker=env("METEOR_WINDOWS_SESSION_MARKER");
    void mark(const char *suffix,const char *message="") {
        if(marker.empty())return;
        FILE *f=nullptr;fopen_s(&f,(marker+suffix).c_str(),"wb");
        if(!f)throw std::runtime_error("Cannot write SteamVR session marker");std::fputs(message,f);std::fclose(f);
    }
    void fail(const std::exception &error) noexcept {
        failed=true;vr::VRDriverLog()->Log(error.what());
        try {mark(".failed",error.what());}catch(...) {}
    }
    Image &lookup(vr::SharedTextureHandle_t handle) {
        auto it=images.find(handle);if(it==images.end())throw std::runtime_error("SteamVR submitted an unknown swapchain image");return it->second.first->images[it->second.second];
    }
    ID3D11ShaderResourceView *view(vr::SharedTextureHandle_t handle) {
        auto &image=lookup(handle);D3D11_TEXTURE2D_DESC desc{};image.texture->GetDesc(&desc);
        DXGI_FORMAT format=desc.Format;
        if(format==DXGI_FORMAT_R8G8B8A8_TYPELESS)format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
        if(format==DXGI_FORMAT_B8G8R8A8_TYPELESS)format=DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
        if(format!=DXGI_FORMAT_R8G8B8A8_UNORM && format!=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB &&
           format!=DXGI_FORMAT_B8G8R8A8_UNORM && format!=DXGI_FORMAT_B8G8R8A8_UNORM_SRGB && format!=DXGI_FORMAT_R16G16B16A16_FLOAT)
            throw std::runtime_error("Unsupported SteamVR colour swapchain format");
        ID3D11Texture2D *texture=image.texture.Get();
        if(desc.SampleDesc.Count>1) {
            if(!image.resolved) {desc.SampleDesc.Count=1;desc.SampleDesc.Quality=0;desc.MiscFlags=0;desc.Format=format;check(device->CreateTexture2D(&desc,nullptr,&image.resolved));}
            context->ResolveSubresource(image.resolved.Get(),0,image.texture.Get(),0,format);texture=image.resolved.Get();
        }
        if(!image.srv) {
            D3D11_SHADER_RESOURCE_VIEW_DESC sd{};sd.Format=format;sd.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D;sd.Texture2D.MipLevels=1;
            check(device->CreateShaderResourceView(texture,&sd,&image.srv));
        }
        return image.srv.Get();
    }
public:
    DirectCapture() {
        ComPtr<IDXGIFactory1> factory;check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        ComPtr<IDXGIAdapter1> selected;
        for(unsigned i=0;;++i) {ComPtr<IDXGIAdapter1> candidate;if(factory->EnumAdapters1(i,&candidate)==DXGI_ERROR_NOT_FOUND)break;
            DXGI_ADAPTER_DESC1 desc{};check(candidate->GetDesc1(&desc));
            if(!(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) && desc.VendorId==0x10de) {selected=candidate;std::memcpy(&adapter_luid,&desc.AdapterLuid,sizeof(adapter_luid));break;}}
        if(!selected)throw std::runtime_error("SteamVR direct capture currently requires an NVIDIA GPU with NVENC");
        check(D3D11CreateDevice(selected.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
        vr::VRDriverLog()->Log("METEOR_STEAMVR_DIRECT initialized");
    }
    void pause_session() {
        std::lock_guard<std::mutex> lock(mutex);
        if(!finished) {
            finished=true;layers.clear();encoder.reset();
            if(*env("METEOR_XR_DIRECT_PORT"))meteor_steamvr_finish();
        }
    }
    void resume_session() {
        std::lock_guard<std::mutex> lock(mutex);
        marker=env("METEOR_WINDOWS_SESSION_MARKER");frame=0;sync_misses=dropped_frames=0;
        timing_count=0;std::fill(std::begin(timing_sum),std::end(timing_sum),0);std::fill(std::begin(timing_peak),std::end(timing_peak),0);
        failed=finished=false;layers.clear();next_vsync=std::chrono::steady_clock::now();
    }
    uint64_t luid() const {return adapter_luid;}
    void CreateSwapTextureSet(uint32_t pid,const SwapTextureSetDesc_t *request,SwapTextureSet_t *out) override {
        std::lock_guard<std::mutex> lock(mutex);*out={};if(failed || finished)return;
        try {
            if(!request || !request->nWidth || request->nWidth>16384 || !request->nHeight || request->nHeight>16384 || images.size()>=384)throw std::runtime_error("Invalid/excessive SteamVR swapchain allocation");
            D3D11_TEXTURE2D_DESC desc{};desc.Width=request->nWidth;desc.Height=request->nHeight;desc.Format=static_cast<DXGI_FORMAT>(request->nFormat);
            desc.ArraySize=desc.MipLevels=1;desc.SampleDesc.Count=request->nSampleCount?request->nSampleCount:1;
            desc.Usage=D3D11_USAGE_DEFAULT;desc.MiscFlags=D3D11_RESOURCE_MISC_SHARED;
            desc.BindFlags=desc.Format==DXGI_FORMAT_R32_TYPELESS || desc.Format==DXGI_FORMAT_R32G8X24_TYPELESS || desc.Format==DXGI_FORMAT_R24G8_TYPELESS?D3D11_BIND_DEPTH_STENCIL:D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
            auto set=std::make_shared<Set>();set->pid=pid;
            for(unsigned i=0;i<3;++i) {
                check(device->CreateTexture2D(&desc,nullptr,&set->images[i].texture));
                ComPtr<IDXGIResource> shared;check(set->images[i].texture.As(&shared));HANDLE handle=nullptr;check(shared->GetSharedHandle(&handle));
                set->handles[i]=static_cast<vr::SharedTextureHandle_t>(reinterpret_cast<uintptr_t>(handle));
            }
            for(unsigned i=0;i<3;++i) {images.emplace(set->handles[i],std::make_pair(set,i));out->rSharedTextureHandles[i]=set->handles[i];}
            out->unTextureFlags=0;
        }catch(const std::exception &e) {fail(e);}
    }
    void DestroySwapTextureSet(vr::SharedTextureHandle_t handle) override {
        std::lock_guard<std::mutex> lock(mutex);auto it=images.find(handle);if(it==images.end())return;
        auto set=it->second.first;for(auto key:set->handles)images.erase(key);
    }
    void DestroyAllSwapTextureSets(uint32_t pid) override {
        std::lock_guard<std::mutex> lock(mutex);
        for(auto it=images.begin();it!=images.end();)if(it->second.first->pid==pid)it=images.erase(it);else ++it;
        synchronization.clear();
    }
    void GetNextSwapTextureSetIndex(vr::SharedTextureHandle_t handles[2],uint32_t (*indices)[2]) override {
        std::lock_guard<std::mutex> lock(mutex);if(!indices)return;
        Set *updated=nullptr;
        for(unsigned eye=0;eye<2;++eye) {auto it=images.find(handles[eye]);if(it==images.end())continue;auto *set=it->second.first.get();
            if(set!=updated) {set->index=(set->index+1)%3;updated=set;}(*indices)[eye]=set->index;}
    }
    void SubmitLayer(const SubmitLayerPerEye_t (&eyes)[2]) override {
        std::lock_guard<std::mutex> lock(mutex);if(failed || finished)return;
        if(layers.size()>=16) {fail(std::runtime_error("Too many SteamVR projection layers"));return;}
        Submitted layer{};layer.eyes[0]=eyes[0];layer.eyes[1]=eyes[1];layers.push_back(layer);
    }
    void Present(vr::SharedTextureHandle_t sync) override {
        const int64_t present_begin=now_ns();
        std::lock_guard<std::mutex> lock(mutex);auto submitted=std::move(layers);layers.clear();
        if(failed || finished || submitted.empty())return;
        ComPtr<IDXGIKeyedMutex> keyed;bool acquired=false;
        try {
            if(!sync)throw std::runtime_error("SteamVR omitted its GPU synchronization texture");
            auto it=synchronization.find(sync);
            if(it==synchronization.end()) {
                if(synchronization.size()>=32)throw std::runtime_error("Excessive SteamVR synchronization handles");
                ComPtr<ID3D11Texture2D> texture;check(device->OpenSharedResource(reinterpret_cast<HANDLE>(static_cast<uintptr_t>(sync)),IID_PPV_ARGS(&texture)));
                check(texture.As(&keyed));synchronization.emplace(sync,keyed);
            } else keyed=it->second;
            const int64_t sync_begin=now_ns();
            HRESULT ready=keyed->AcquireSync(0,100);
            if(ready==WAIT_TIMEOUT) {++dropped_frames;if(++sync_misses>30)throw std::runtime_error("SteamVR GPU synchronization repeatedly timed out");return;}
            if(ready!=S_OK)throw std::runtime_error("SteamVR GPU synchronization was abandoned or failed");acquired=true;sync_misses=0;
            const int64_t sync_end=now_ns();
            vr::HmdMatrix34_t heads[2]={submitted[0].eyes[0].mHmdPose,submitted[0].eyes[1].mHmdPose};
            if(!meteor_geometry::valid_pose(heads[0]) || !meteor_geometry::valid_pose(heads[1])) {keyed->ReleaseSync(0);return;}
            std::vector<MirrorEncoder::Layer> packed(submitted.size());
            for(size_t n=0;n<submitted.size();++n)for(unsigned eye=0;eye<2;++eye) {
                const auto &source=submitted[n].eyes[eye];
                // Do not silently combine layers rendered in different origins.
                for(int r=0;r<3;++r)for(int c=0;c<4;++c)if(std::abs(source.mHmdPose.m[r][c]-heads[eye].m[r][c])>.001f)
                    throw std::runtime_error("SteamVR layers require independent pose composition");
                auto b=source.bounds;float values[4]={b.uMin,b.vMin,b.uMax,b.vMax};
                for(float v:values)if(!std::isfinite(v) || v<0 || v>1)throw std::runtime_error("Invalid SteamVR source bounds");
                if(b.uMin==b.uMax || b.vMin==b.vMax)throw std::runtime_error("Empty SteamVR source bounds");
                packed[n].eyes[eye]=view(source.hTexture);std::memcpy(packed[n].bounds[eye],values,sizeof(values));
            }
            if(!encoder) {encoder=std::make_unique<MirrorEncoder>();encoder->initialize(device.Get(),width,height,hz);}
            const int64_t encode_begin=now_ns();
            auto bytes=encoder->encode_layers(context.Get(),packed.data(),packed.size(),frame+1);
            const int64_t encode_end=now_ns();
            check(keyed->ReleaseSync(0));acquired=false;
            float metadata[22]{};meteor_geometry::views(heads,optics,metadata);++frame;
            if(*env("METEOR_XR_DIRECT_PORT")) {
                if(!meteor_steamvr_deliver(frame,static_cast<uint64_t>(now_ns()),width,height,metadata,bytes.data(),static_cast<uint32_t>(bytes.size())))throw std::runtime_error("SteamVR encoded frame delivery failed");
            }
            const int64_t present_end=now_ns();
            const uint64_t times[]={uint64_t(sync_end-sync_begin)/1000,uint64_t(encode_end-encode_begin)/1000,
                uint64_t(present_end-encode_end)/1000,uint64_t(present_end-present_begin)/1000};
            ++timing_count;
            for(unsigned i=0;i<4;++i) {timing_sum[i]+=times[i];timing_peak[i]=std::max(timing_peak[i],times[i]);}
            if(frame==1 || frame%120==0) {
                char log[600];std::snprintf(log,sizeof(log),
                    "METEOR_STEAMVR_TIMING frame=%llu samples=%llu sync_us=%llu/%llu encode_us=%llu/%llu delivery_us=%llu/%llu present_us=%llu/%llu dropped=%u (mean/peak)",
                    static_cast<unsigned long long>(frame),static_cast<unsigned long long>(timing_count),
                    static_cast<unsigned long long>(timing_sum[0]/timing_count),static_cast<unsigned long long>(timing_peak[0]),
                    static_cast<unsigned long long>(timing_sum[1]/timing_count),static_cast<unsigned long long>(timing_peak[1]),
                    static_cast<unsigned long long>(timing_sum[2]/timing_count),static_cast<unsigned long long>(timing_peak[2]),
                    static_cast<unsigned long long>(timing_sum[3]/timing_count),static_cast<unsigned long long>(timing_peak[3]),dropped_frames);
                vr::VRDriverLog()->Log(log);
                timing_count=0;std::fill(std::begin(timing_sum),std::end(timing_sum),0);std::fill(std::begin(timing_peak),std::end(timing_peak),0);
            }
            if(frame==1)mark("");
            if(frame==1 || frame%120==0) {char log[200];std::snprintf(log,sizeof(log),"METEOR_STEAMVR_DIRECT frame=%llu layers=%zu head=%.5f,%.5f,%.5f",static_cast<unsigned long long>(frame),submitted.size(),heads[0].m[0][3],heads[0].m[1][3],heads[0].m[2][3]);vr::VRDriverLog()->Log(log);}
        }catch(const std::exception &e) {if(acquired)keyed->ReleaseSync(0);fail(e);}
    }
    void PostPresent(const Throttling_t *) override {
        std::unique_lock<std::mutex> lock(mutex);if(finished || failed)return;
        auto period=std::chrono::nanoseconds(1000000000/hz);next_vsync+=period;
        auto now=std::chrono::steady_clock::now();if(next_vsync<now)next_vsync=now+period;
        auto wake=next_vsync-std::chrono::milliseconds(2);lock.unlock();
        std::this_thread::sleep_until(wake);
        vr::VRServerDriverHost()->VsyncEvent(.002);
    }
    void GetFrameTiming(vr::DriverDirectMode_FrameTiming *timing) override {
        std::lock_guard<std::mutex> lock(mutex);timing->m_nReprojectionFlags=0;timing->m_nNumFramePresents=static_cast<uint32_t>(frame);
        timing->m_nNumDroppedFrames=dropped_frames;timing->m_nNumMisPresented=0;
    }
    void poll_stop() {
        std::lock_guard<std::mutex> lock(mutex);
        if(finished || marker.empty() || !std::filesystem::is_regular_file(marker+".stop"))return;
        finished=true;encoder.reset();
        if(*env("METEOR_XR_DIRECT_PORT") && !meteor_steamvr_finish()) {fail(std::runtime_error("SteamVR delivery END was not acknowledged"));return;}
        try {mark(".ended");}catch(const std::exception &e) {fail(e);}
    }
};
