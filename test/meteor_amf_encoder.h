// AMD AMF encoding for PCVR on Windows. AMF reads a D3D11 texture holding the packed stereo
// frame, converts it to NV12 and encodes it, all on the GPU. Monado's bridge fills that texture
// from Vulkan (meteor_amf_bridge.h); the SteamVR driver draws into it with D3D11 (encoder.h).
//
// Synchronous like the NVENC paths: a frame is converted and encoded before the next is drawn,
// so the texture never needs a keyed mutex.
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <type_traits>
#include "core/Factory.h"
#include "components/ComponentCaps.h"
#include "components/VideoConverter.h"
#include "components/VideoEncoderHEVC.h"
#include "components/VideoEncoderVCE.h"

struct MeteorAmfRuntime {
    HMODULE dll=nullptr;
    amf::AMFFactory *factory=nullptr;
    bool load() {
        if(factory) return true;
        dll=LoadLibraryW(AMF_DLL_NAME);
        if(!dll) return false;
        auto init=reinterpret_cast<AMFInit_Fn>(GetProcAddress(dll,AMF_INIT_FUNCTION_NAME));
        if(!init || init(AMF_FULL_VERSION,&factory)!=AMF_OK || !factory) {
            FreeLibrary(dll); dll=nullptr; factory=nullptr; return false;
        }
        return true;
    }
    ~MeteorAmfRuntime() { if(dll) FreeLibrary(dll); }
};

// The D3D11 device on the adapter with this LUID; nullptr when there is none.
static Microsoft::WRL::ComPtr<ID3D11Device> meteor_d3d11_on(const uint8_t *luid) {
    Microsoft::WRL::ComPtr<IDXGIFactory1> dxgi;
    if(FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&dxgi)))) return nullptr;
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    for(UINT i=0;dxgi->EnumAdapters1(i,&adapter)!=DXGI_ERROR_NOT_FOUND;++i) {
        DXGI_ADAPTER_DESC1 desc{};
        if(SUCCEEDED(adapter->GetDesc1(&desc)) && (!luid || !std::memcmp(&desc.AdapterLuid,luid,sizeof(LUID)))) {
            if(!luid && desc.VendorId!=0x1002) { adapter.Reset(); continue; }
            Microsoft::WRL::ComPtr<ID3D11Device> device;
            const D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_1,D3D_FEATURE_LEVEL_11_0};
            if(SUCCEEDED(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,levels,2,D3D11_SDK_VERSION,&device,nullptr,nullptr)))
                return device;
            return nullptr;
        }
        adapter.Reset();
    }
    return nullptr;
}

// The largest frame (width, height) the AMD encoder takes for this codec, from AMF's caps:
// the smaller of its input and output ranges. {0,0} when unknown.
static void meteor_amf_max_frame(bool hevc,uint32_t &max_width,uint32_t &max_height) {
    max_width=max_height=0;
    MeteorAmfRuntime runtime;
    if(!runtime.load()) return;
    auto device=meteor_d3d11_on(nullptr);
    if(!device) return;
    amf::AMFContextPtr context;
    if(runtime.factory->CreateContext(&context)!=AMF_OK || context->InitDX11(device.Get(),amf::AMF_DX11_1)!=AMF_OK) return;
    {
        amf::AMFComponentPtr encoder;
        amf::AMFCapsPtr caps;
        if(runtime.factory->CreateComponent(context,hevc ? AMFVideoEncoder_HEVC : AMFVideoEncoderVCE_AVC,&encoder)==AMF_OK &&
           encoder->GetCaps(&caps)==AMF_OK && caps) {
            for(int side=0;side<2;++side) {
                amf::AMFIOCapsPtr io;
                if((side ? caps->GetOutputCaps(&io) : caps->GetInputCaps(&io))!=AMF_OK || !io) continue;
                amf_int32 lo=0,w=0,h=0;
                io->GetWidthRange(&lo,&w); io->GetHeightRange(&lo,&h);
                if(w>0) max_width=max_width ? std::min<uint32_t>(max_width,w) : w;
                if(h>0) max_height=max_height ? std::min<uint32_t>(max_height,h) : h;
            }
        }
        if(encoder) encoder->Terminate();
    }
    context->Terminate();
}

struct MeteorAmfEncoder {
    MeteorAmfRuntime runtime;
    Microsoft::WRL::ComPtr<ID3D11Device> d3d;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;  // what each encode reads
    amf::AMF_SURFACE_FORMAT input_format=amf::AMF_SURFACE_RGBA;
    amf::AMFContextPtr context;
    amf::AMFComponentPtr converter,encoder;
    amf::AMFSurfacePtr input;
    uint32_t width=0,height=0,fps=60;
    bool hevc=false;
    std::string error;

    bool fail(const std::string &message) { error=message; return false; }

    // Encodes `frame` (8-bit RGBA or BGRA, full range) from `device`.
    void attach(ID3D11Device *device,ID3D11Texture2D *frame,uint32_t w,uint32_t h,amf::AMF_SURFACE_FORMAT format) {
        d3d=device; texture=frame; width=w; height=h; input_format=format;
    }

    template<class T> void set(amf::AMFComponent *component,const wchar_t *name,const T &value) {
        AMF_RESULT result;
        if constexpr(std::is_enum_v<T>) result=component->SetProperty(name,amf_int64(value));
        else result=component->SetProperty(name,value);
        if(result!=AMF_OK) std::fprintf(stderr,"METEOR_AMF property %ls not accepted (%d)\n",name,int(result));
    }

    bool configure_encoder(uint32_t bitrate,bool srgb,bool ultra_low_latency) {
        const auto rate=AMFConstructRate(fps,1);
        const auto size=AMFConstructSize(int(width),int(height));
        const auto transfer=srgb ? AMF_COLOR_TRANSFER_CHARACTERISTIC_IEC61966_2_1 : AMF_COLOR_TRANSFER_CHARACTERISTIC_BT709;
        if(hevc) {
            set(encoder,AMF_VIDEO_ENCODER_HEVC_USAGE,ultra_low_latency ? AMF_VIDEO_ENCODER_HEVC_USAGE_ULTRA_LOW_LATENCY : AMF_VIDEO_ENCODER_HEVC_USAGE_LOW_LATENCY);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_PROFILE,AMF_VIDEO_ENCODER_HEVC_PROFILE_MAIN);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_QUALITY_PRESET,AMF_VIDEO_ENCODER_HEVC_QUALITY_PRESET_SPEED);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_RATE_CONTROL_METHOD,AMF_VIDEO_ENCODER_HEVC_RATE_CONTROL_METHOD_CBR);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_TARGET_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_PEAK_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_VBV_BUFFER_SIZE,amf_int64(bitrate/fps));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_FRAMESIZE,size);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_FRAMERATE,rate);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_GOP_SIZE,amf_int64(fps));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_NUM_GOPS_PER_IDR,amf_int64(1));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_HEADER_INSERTION_MODE,AMF_VIDEO_ENCODER_HEVC_HEADER_INSERTION_MODE_IDR_ALIGNED);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_LOWLATENCY_MODE,true);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_NOMINAL_RANGE,AMF_VIDEO_ENCODER_HEVC_NOMINAL_RANGE_STUDIO);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_OUTPUT_COLOR_PROFILE,AMF_VIDEO_CONVERTER_COLOR_PROFILE_709);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_OUTPUT_COLOR_PRIMARIES,AMF_COLOR_PRIMARIES_BT709);
            set(encoder,AMF_VIDEO_ENCODER_HEVC_OUTPUT_TRANSFER_CHARACTERISTIC,transfer);
        } else {
            set(encoder,AMF_VIDEO_ENCODER_USAGE,ultra_low_latency ? AMF_VIDEO_ENCODER_USAGE_ULTRA_LOW_LATENCY : AMF_VIDEO_ENCODER_USAGE_LOW_LATENCY);
            set(encoder,AMF_VIDEO_ENCODER_PROFILE,AMF_VIDEO_ENCODER_PROFILE_HIGH);
            set(encoder,AMF_VIDEO_ENCODER_QUALITY_PRESET,AMF_VIDEO_ENCODER_QUALITY_PRESET_SPEED);
            set(encoder,AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD,AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD_CBR);
            set(encoder,AMF_VIDEO_ENCODER_TARGET_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_PEAK_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_VBV_BUFFER_SIZE,amf_int64(bitrate/fps));
            set(encoder,AMF_VIDEO_ENCODER_FRAMESIZE,size);
            set(encoder,AMF_VIDEO_ENCODER_FRAMERATE,rate);
            set(encoder,AMF_VIDEO_ENCODER_IDR_PERIOD,amf_int64(fps));
            set(encoder,AMF_VIDEO_ENCODER_B_PIC_PATTERN,amf_int64(0));
            set(encoder,AMF_VIDEO_ENCODER_HEADER_INSERTION_SPACING,amf_int64(fps));
            set(encoder,AMF_VIDEO_ENCODER_LOWLATENCY_MODE,true);
            set(encoder,AMF_VIDEO_ENCODER_FULL_RANGE_COLOR,false);
            set(encoder,AMF_VIDEO_ENCODER_OUTPUT_COLOR_PROFILE,AMF_VIDEO_CONVERTER_COLOR_PROFILE_709);
            set(encoder,AMF_VIDEO_ENCODER_OUTPUT_COLOR_PRIMARIES,AMF_COLOR_PRIMARIES_BT709);
            set(encoder,AMF_VIDEO_ENCODER_OUTPUT_TRANSFER_CHARACTERISTIC,transfer);
        }
        return encoder->Init(amf::AMF_SURFACE_NV12,int(width),int(height))==AMF_OK;
    }

    // RGBA (the packed stereo frame, full range) to NV12 BT.709 limited range, then H.264/HEVC.
    bool start(bool use_hevc,uint32_t rate,uint32_t bitrate,bool srgb) {
        hevc=use_hevc; fps=rate;
        if(!runtime.load()) return fail("AMF runtime (amfrt64.dll) unavailable");
        if(runtime.factory->CreateContext(&context)!=AMF_OK || context->InitDX11(d3d.Get(),amf::AMF_DX11_1)!=AMF_OK)
            return fail("AMF cannot use the D3D11 device");
        if(context->CreateSurfaceFromDX11Native(texture.Get(),&input,nullptr)!=AMF_OK || !input)
            return fail("AMF cannot wrap the shared texture");
        if(runtime.factory->CreateComponent(context,AMFVideoConverter,&converter)!=AMF_OK) return fail("AMF video converter unavailable");
        set(converter,AMF_VIDEO_CONVERTER_OUTPUT_FORMAT,amf_int64(amf::AMF_SURFACE_NV12));
        set(converter,AMF_VIDEO_CONVERTER_MEMORY_TYPE,amf_int64(amf::AMF_MEMORY_DX11));
        set(converter,AMF_VIDEO_CONVERTER_OUTPUT_SIZE,AMFConstructSize(int(width),int(height)));
        set(converter,AMF_VIDEO_CONVERTER_COLOR_PROFILE,amf_int64(AMF_VIDEO_CONVERTER_COLOR_PROFILE_709));
        set(converter,AMF_VIDEO_CONVERTER_INPUT_COLOR_RANGE,amf_int64(AMF_COLOR_RANGE_FULL));
        set(converter,AMF_VIDEO_CONVERTER_OUTPUT_COLOR_RANGE,amf_int64(AMF_COLOR_RANGE_STUDIO));
        if(converter->Init(input_format,int(width),int(height))!=AMF_OK) return fail("AMF video converter refused the frame size");
        // Pre-RDNA drivers can refuse ULTRA_LOW_LATENCY (GPUOpen AMF#410); LOW_LATENCY is close.
        for(int attempt=0;attempt<2;++attempt) {
            if(runtime.factory->CreateComponent(context,hevc ? AMFVideoEncoder_HEVC : AMFVideoEncoderVCE_AVC,&encoder)!=AMF_OK)
                return fail(hevc ? "AMF HEVC encoder unavailable" : "AMF H.264 encoder unavailable");
            if(configure_encoder(bitrate,srgb,attempt==0)) return true;
            encoder->Terminate(); encoder=nullptr;
        }
        return fail("AMF encoder refused the configuration");
    }

    void set_bitrate(uint32_t bitrate) {
        if(hevc) {
            set(encoder,AMF_VIDEO_ENCODER_HEVC_TARGET_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_PEAK_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_HEVC_VBV_BUFFER_SIZE,amf_int64(bitrate/fps));
        } else {
            set(encoder,AMF_VIDEO_ENCODER_TARGET_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_PEAK_BITRATE,amf_int64(bitrate));
            set(encoder,AMF_VIDEO_ENCODER_VBV_BUFFER_SIZE,amf_int64(bitrate/fps));
        }
    }

    // Encodes the shared texture's current contents; `deliver` gets the packet.
    template<class Deliver> bool encode(bool idr,uint64_t timestamp,Deliver deliver) {
        input->SetPts(amf_pts(timestamp));
        if(converter->SubmitInput(input)!=AMF_OK) return fail("AMF converter rejected the frame");
        amf::AMFDataPtr converted;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(1);
        for(;;) {
            const AMF_RESULT result=converter->QueryOutput(&converted);
            if(result==AMF_OK && converted) break;
            if(result!=AMF_REPEAT && result!=AMF_OK) return fail("AMF converter failed");
            if(std::chrono::steady_clock::now()>deadline) return fail("AMF converter timed out");
            std::this_thread::yield();
        }
        if(idr) {
            if(hevc) {
                converted->SetProperty(AMF_VIDEO_ENCODER_HEVC_FORCE_PICTURE_TYPE,amf_int64(AMF_VIDEO_ENCODER_HEVC_PICTURE_TYPE_IDR));
                converted->SetProperty(AMF_VIDEO_ENCODER_HEVC_INSERT_HEADER,true);
            } else {
                converted->SetProperty(AMF_VIDEO_ENCODER_FORCE_PICTURE_TYPE,amf_int64(AMF_VIDEO_ENCODER_PICTURE_TYPE_IDR));
                converted->SetProperty(AMF_VIDEO_ENCODER_INSERT_SPS,true);
                converted->SetProperty(AMF_VIDEO_ENCODER_INSERT_PPS,true);
            }
        }
        AMF_RESULT submitted=encoder->SubmitInput(converted);
        if(submitted!=AMF_OK && submitted!=AMF_NEED_MORE_INPUT) return fail("AMF encoder rejected the frame");
        for(;;) {
            amf::AMFDataPtr data;
            const AMF_RESULT result=encoder->QueryOutput(&data);
            if(result==AMF_OK && data) {
                amf::AMFBufferPtr buffer(data);
                if(!buffer) return fail("AMF returned no bitstream");
                return deliver(static_cast<const uint8_t *>(buffer->GetNative()),uint32_t(buffer->GetSize()));
            }
            if(result!=AMF_REPEAT && result!=AMF_OK) return fail("AMF encoder failed");
            if(std::chrono::steady_clock::now()>deadline) return fail("AMF encoder timed out");
            std::this_thread::yield();
        }
    }

    void destroy() {
        input=nullptr;
        if(encoder) { encoder->Terminate(); encoder=nullptr; }
        if(converter) { converter->Terminate(); converter=nullptr; }
        if(context) { context->Terminate(); context=nullptr; }
        texture.Reset(); d3d.Reset();
    }
};
