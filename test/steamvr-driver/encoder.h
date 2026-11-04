#pragma once
#include <d3dcompiler.h>
#include <nvEncodeAPI.h>
#include <vector>
#include "../meteor_encoder_bitrate.h"
// D3D11 eye SRVs -> one negotiated-size stereo GPU surface -> NVENC.
// CPU readback is used only by the separate diagnostic screenshot routine.
class MirrorEncoder {
    HMODULE module=nullptr;
    NV_ENCODE_API_FUNCTION_LIST api{};
    void *session=nullptr;
    NV_ENC_REGISTERED_PTR resource=nullptr;
    NV_ENC_OUTPUT_PTR output=nullptr;
    ComPtr<ID3D11Texture2D> packed;
    ComPtr<ID3D11RenderTargetView> target;
    ComPtr<ID3D11VertexShader> vertex;
    ComPtr<ID3D11PixelShader> pixel;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11Buffer> constants;
    ComPtr<ID3D11BlendState> alpha_blend;
    unsigned width=0,height=0;
    static void nv(NVENCSTATUS status) {if(status!=NV_ENC_SUCCESS) {std::fprintf(stderr,"STEAMVR_NVENC status=%d\n",status);throw std::runtime_error("NVENC operation failed");}}
public:
    struct Layer {
        ID3D11ShaderResourceView *eyes[2]{};
        float bounds[2][4]={{0,0,1,1},{0,0,1,1}};
    };
    void initialize(ID3D11Device *device,unsigned w,unsigned h,unsigned fps) {
        width=w;height=h;
        D3D11_TEXTURE2D_DESC desc{};desc.Width=w*2;desc.Height=h;desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
        desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
        check(device->CreateTexture2D(&desc,nullptr,&packed));check(device->CreateRenderTargetView(packed.Get(),nullptr,&target));
        const char *shader=R"(
Texture2D eye:register(t0);SamplerState linearClamp:register(s0);cbuffer Colour:register(b0){float4 flags,bounds;};
struct V {float4 position:SV_Position;float2 uv:TEXCOORD0;};
V vs(uint id:SV_VertexID){V o;float2 p=float2((id<<1)&2,id&2);o.position=float4(p.x*2-1,1-p.y*2,0,1);o.uv=p;return o;}
float4 ps(V i):SV_Target {float4 sample=eye.Sample(linearClamp,lerp(bounds.xy,bounds.zw,i.uv));float3 c=sample.rgb;
if(flags.x>0)c=lerp(12.92*c,1.055*pow(max(c,0),1.0/2.4)-.055,step(.0031308,c));return float4(c,flags.y>0?sample.a:1);}
)";
        ComPtr<ID3DBlob> vs,ps,error;
        auto compile=[&](const char *entry,const char *profile,ID3DBlob **out) {
            auto hr=D3DCompile(shader,std::strlen(shader),"meteor-steamvr-pack",nullptr,nullptr,entry,profile,D3DCOMPILE_ENABLE_STRICTNESS|D3DCOMPILE_OPTIMIZATION_LEVEL3,0,out,&error);
            if(FAILED(hr) && error)std::fprintf(stderr,"%s",static_cast<const char *>(error->GetBufferPointer()));check(hr);
        };
        compile("vs","vs_5_0",&vs);compile("ps","ps_5_0",&ps);
        check(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertex));
        check(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixel));
        D3D11_SAMPLER_DESC sd{};sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;sd.MaxLOD=D3D11_FLOAT32_MAX;
        check(device->CreateSamplerState(&sd,&sampler));
        D3D11_BUFFER_DESC bd{};bd.ByteWidth=32;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;bd.Usage=D3D11_USAGE_DEFAULT;
        check(device->CreateBuffer(&bd,nullptr,&constants));
        D3D11_BLEND_DESC blend{};auto &rt=blend.RenderTarget[0];rt.BlendEnable=TRUE;
        rt.SrcBlend=D3D11_BLEND_SRC_ALPHA;rt.DestBlend=D3D11_BLEND_INV_SRC_ALPHA;rt.BlendOp=D3D11_BLEND_OP_ADD;
        rt.SrcBlendAlpha=D3D11_BLEND_ONE;rt.DestBlendAlpha=D3D11_BLEND_INV_SRC_ALPHA;rt.BlendOpAlpha=D3D11_BLEND_OP_ADD;
        rt.RenderTargetWriteMask=D3D11_COLOR_WRITE_ENABLE_ALL;check(device->CreateBlendState(&blend,&alpha_blend));
        module=LoadLibraryW(L"nvEncodeAPI64.dll");if(!module)throw std::runtime_error("NVIDIA encoder driver missing");
        auto create=reinterpret_cast<NVENCSTATUS (NVENCAPI *)(NV_ENCODE_API_FUNCTION_LIST *)>(GetProcAddress(module,"NvEncodeAPICreateInstance"));
        if(!create)throw std::runtime_error("NVENC entry point missing");api.version=NV_ENCODE_API_FUNCTION_LIST_VER;nv(create(&api));
        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open{};open.version=NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        open.apiVersion=NVENCAPI_VERSION;open.deviceType=NV_ENC_DEVICE_TYPE_DIRECTX;open.device=device;nv(api.nvEncOpenEncodeSessionEx(&open,&session));
        auto capability=[&](NV_ENC_CAPS which) {NV_ENC_CAPS_PARAM request{};request.version=NV_ENC_CAPS_PARAM_VER;request.capsToQuery=which;int value=0;
            nv(api.nvEncGetEncodeCaps(session,NV_ENC_CODEC_H264_GUID,&request,&value));return value;};
        int max_width=capability(NV_ENC_CAPS_WIDTH_MAX),max_height=capability(NV_ENC_CAPS_HEIGHT_MAX);
        std::printf("STEAMVR_NVENC_LIMITS codec=h264 max_width=%d max_height=%d requested=%ux%u\n",max_width,max_height,w*2,h);std::fflush(stdout);
        if(w*2>static_cast<unsigned>(max_width) || h>static_cast<unsigned>(max_height))
            throw std::runtime_error("Requested stereo resolution exceeds this GPU's H.264 encoder limits; select a smaller eye resolution");
        NV_ENC_PRESET_CONFIG preset{};preset.version=NV_ENC_PRESET_CONFIG_VER;preset.presetCfg.version=NV_ENC_CONFIG_VER;
        nv(api.nvEncGetEncodePresetConfigEx(session,NV_ENC_CODEC_H264_GUID,NV_ENC_PRESET_P1_GUID,NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY,&preset));
        auto &cfg=preset.presetCfg;cfg.profileGUID=NV_ENC_H264_PROFILE_HIGH_GUID;cfg.gopLength=fps;cfg.frameIntervalP=1;
        uint32_t bitrate=0;if(!meteor_encoder_bitrate(std::getenv("METEOR_XR_BITRATE_MBPS"),32000000,&bitrate))throw std::runtime_error("Invalid encoder bitrate");
        cfg.rcParams.rateControlMode=NV_ENC_PARAMS_RC_CBR;cfg.rcParams.averageBitRate=cfg.rcParams.maxBitRate=bitrate;
        cfg.rcParams.enableLookahead=0;cfg.rcParams.zeroReorderDelay=1;
        cfg.encodeCodecConfig.h264Config.repeatSPSPPS=1;cfg.encodeCodecConfig.h264Config.idrPeriod=fps;
        auto &vui=cfg.encodeCodecConfig.h264Config.h264VUIParameters;
        vui.videoSignalTypePresentFlag=1;vui.videoFormat=NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;vui.videoFullRangeFlag=0;
        vui.colourDescriptionPresentFlag=1;vui.colourPrimaries=NV_ENC_VUI_COLOR_PRIMARIES_BT709;
        vui.transferCharacteristics=NV_ENC_VUI_TRANSFER_CHARACTERISTIC_SRGB;vui.colourMatrix=NV_ENC_VUI_MATRIX_COEFFS_BT709;
        NV_ENC_INITIALIZE_PARAMS init{};init.version=NV_ENC_INITIALIZE_PARAMS_VER;init.encodeGUID=NV_ENC_CODEC_H264_GUID;
        init.presetGUID=NV_ENC_PRESET_P1_GUID;init.tuningInfo=NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
        init.encodeWidth=init.darWidth=w*2;init.encodeHeight=init.darHeight=h;init.frameRateNum=fps;init.frameRateDen=1;init.enablePTD=1;init.encodeConfig=&cfg;
        nv(api.nvEncInitializeEncoder(session,&init));
        NV_ENC_REGISTER_RESOURCE reg{};reg.version=NV_ENC_REGISTER_RESOURCE_VER;reg.resourceType=NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
        reg.resourceToRegister=packed.Get();reg.width=w*2;reg.height=h;reg.bufferFormat=NV_ENC_BUFFER_FORMAT_ARGB;reg.bufferUsage=NV_ENC_INPUT_IMAGE;
        nv(api.nvEncRegisterResource(session,&reg));resource=reg.registeredResource;
        NV_ENC_CREATE_BITSTREAM_BUFFER bs{};bs.version=NV_ENC_CREATE_BITSTREAM_BUFFER_VER;nv(api.nvEncCreateBitstreamBuffer(session,&bs));output=bs.bitstreamBuffer;
        std::printf("STEAMVR_ENCODER per_eye=%ux%u fps=%u bitrate=%u graphics=D3D11 codec=h264\n",w,h,fps,bitrate);std::fflush(stdout);
    }
    std::vector<uint8_t> encode(ID3D11DeviceContext *context,ID3D11ShaderResourceView *const eyes[2],uint64_t frame) {
        Layer layer;layer.eyes[0]=eyes[0];layer.eyes[1]=eyes[1];return encode_layers(context,&layer,1,frame);
    }
    std::vector<uint8_t> encode_layers(ID3D11DeviceContext *context,const Layer *layers,size_t count,uint64_t frame) {
        if(!layers || !count || count>16)throw std::runtime_error("Invalid stereo layer count");
        auto rt=target.Get();context->OMSetRenderTargets(1,&rt,nullptr);
        const float black[4]={0,0,0,1};context->ClearRenderTargetView(rt,black);
        context->VSSetShader(vertex.Get(),nullptr,0);context->PSSetShader(pixel.Get(),nullptr,0);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        auto s=sampler.Get();context->PSSetSamplers(0,1,&s);auto cb=constants.Get();context->PSSetConstantBuffers(0,1,&cb);
        for(size_t n=0;n<count;++n)for(unsigned eye=0;eye<2;++eye) {
            auto view=layers[n].eyes[eye];if(!view)throw std::runtime_error("Missing eye layer SRV");
            D3D11_SHADER_RESOURCE_VIEW_DESC sd{};view->GetDesc(&sd);
            float flags[8]={sd.Format==DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || sd.Format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB || sd.Format==DXGI_FORMAT_R16G16B16A16_FLOAT?1.f:0.f,n?1.f:0.f,0,0};
            std::memcpy(flags+4,layers[n].bounds[eye],sizeof(float)*4);
            context->UpdateSubresource(constants.Get(),0,nullptr,flags,0,0);
            context->OMSetBlendState(n?alpha_blend.Get():nullptr,nullptr,~0u);
            D3D11_VIEWPORT vp{float(eye*width),0,float(width),float(height),0,1};context->RSSetViewports(1,&vp);
            context->PSSetShaderResources(0,1,&view);context->Draw(3,0);
        }
        ID3D11ShaderResourceView *none=nullptr;context->PSSetShaderResources(0,1,&none);context->OMSetRenderTargets(0,nullptr,nullptr);context->Flush();
        NV_ENC_MAP_INPUT_RESOURCE map{};map.version=NV_ENC_MAP_INPUT_RESOURCE_VER;map.registeredResource=resource;nv(api.nvEncMapInputResource(session,&map));
        NV_ENC_PIC_PARAMS pic{};pic.version=NV_ENC_PIC_PARAMS_VER;pic.inputBuffer=map.mappedResource;pic.bufferFmt=map.mappedBufferFmt;
        pic.inputWidth=width*2;pic.inputHeight=height;pic.outputBitstream=output;pic.pictureStruct=NV_ENC_PIC_STRUCT_FRAME;pic.inputTimeStamp=frame;
        auto status=api.nvEncEncodePicture(session,&pic);
        if(status!=NV_ENC_SUCCESS) {api.nvEncUnmapInputResource(session,map.mappedResource);nv(status);}
        NV_ENC_LOCK_BITSTREAM lock{};lock.version=NV_ENC_LOCK_BITSTREAM_VER;lock.outputBitstream=output;
        status=api.nvEncLockBitstream(session,&lock);
        if(status!=NV_ENC_SUCCESS) {api.nvEncUnmapInputResource(session,map.mappedResource);nv(status);}
        auto bytes=static_cast<const uint8_t *>(lock.bitstreamBufferPtr);std::vector<uint8_t> packet(bytes,bytes+lock.bitstreamSizeInBytes);
        api.nvEncUnlockBitstream(session,output);api.nvEncUnmapInputResource(session,map.mappedResource);return packet;
    }
    ~MirrorEncoder() {
        if(session) {
            if(output)api.nvEncDestroyBitstreamBuffer(session,output);
            if(resource)api.nvEncUnregisterResource(session,resource);
            api.nvEncDestroyEncoder(session);
        }
        if(module)FreeLibrary(module);
    }
};
