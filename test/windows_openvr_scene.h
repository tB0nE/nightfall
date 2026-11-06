#pragma once
#include <d3dcompiler.h>
#include <cstring>

// A small world-space scene, rendered from OpenVR's actual eye/head poses.
// No game assets, engine, SteamVR service or OpenXR calls are used here.
class OpenVrScene {
    ComPtr<ID3D11VertexShader> vertex;
    ComPtr<ID3D11PixelShader> pixel;
    ComPtr<ID3D11Buffer> constants;
    struct Data {float rows[3][4]; float projection[4]; float hands[2][4];};
public:
    explicit OpenVrScene(ID3D11Device *device) {
        const char *shader=R"(
cbuffer Scene : register(b0) {float4 row0,row1,row2,projection,hand0,hand1;};
struct V {float4 position:SV_Position;float2 uv:TEXCOORD0;};
V vs(uint id:SV_VertexID) {
    V o;float2 p=float2((id<<1)&2,id&2);
    o.position=float4(p.x*2-1,1-p.y*2,0,1);o.uv=p;return o;
}
void sphere(float3 o,float3 d,float4 s,float3 colour,inout float t,inout float3 c) {
    if(s.w<=0)return;
    float3 q=o-s.xyz;float b=dot(q,d),disc=b*b-dot(q,q)+s.w*s.w;
    if(disc<0)return;
    float hit=-b-sqrt(disc);
    if(hit>.03 && hit<t) {
        t=hit;float3 n=normalize(o+d*hit-s.xyz);
        c=colour*(.3+.7*saturate(dot(n,normalize(float3(.3,.8,.4)))));
    }
}
float4 ps(V input):SV_Target {
    float3 o=float3(row0.w,row1.w,row2.w);
    float3 local=float3((input.uv.x*2-1+projection.z)/projection.x,
                       (1-input.uv.y*2+projection.w)/projection.y,-1);
    float3 d=normalize(float3(dot(row0.xyz,local),dot(row1.xyz,local),dot(row2.xyz,local)));
    float t=100;float3 c=float3(.065,.10,.17);
    if(d.y<-.001) {
        float hit=-o.y/d.y;
        if(hit>.03) {t=hit;float3 p=o+d*t;
            float checker=frac((floor(p.x)+floor(p.z))*.5);
            c=checker<.5?float3(.16,.20,.25):float3(.30,.36,.42);
            c=lerp(float3(.065,.10,.17),c,exp(-.015*t));
        }
    }
    sphere(o,d,float4(-.65,1,-2.4,.32),float3(.95,.25,.12),t,c);
    sphere(o,d,float4(.65,1,-2.4,.32),float3(.12,.7,.95),t,c);
    sphere(o,d,float4(0,1.6,-3.2,.32),float3(.4,.9,.3),t,c);
    sphere(o,d,hand0,float3(1,.65,.15),t,c);
    sphere(o,d,hand1,float3(.7,.25,1),t,c);
    return float4(c,1);
})";
        ComPtr<ID3DBlob> vs,ps,error;
        auto compile=[&](const char *entry,const char *profile,ID3DBlob **out) {
            HRESULT status=D3DCompile(shader,std::strlen(shader),"meteor-openvr-scene",nullptr,nullptr,
                entry,profile,D3DCOMPILE_ENABLE_STRICTNESS|D3DCOMPILE_OPTIMIZATION_LEVEL3,0,out,&error);
            if(FAILED(status) && error) std::fprintf(stderr,"%s\n",static_cast<const char *>(error->GetBufferPointer()));
            check(status);
        };
        compile("vs","vs_5_0",&vs);compile("ps","ps_5_0",&ps);
        check(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertex));
        check(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixel));
        D3D11_BUFFER_DESC desc{};desc.ByteWidth=sizeof(Data);desc.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        desc.Usage=D3D11_USAGE_DEFAULT;check(device->CreateBuffer(&desc,nullptr,&constants));
    }
    void render(ID3D11DeviceContext *context,ID3D11RenderTargetView *view,vr::IVRSystem *system,
                const vr::TrackedDevicePose_t *poses,vr::EVREye eye,uint32_t width,uint32_t height) {
        Data data{};
        auto head=poses[vr::k_unTrackedDeviceIndex_Hmd].mDeviceToAbsoluteTracking;
        if(!poses[vr::k_unTrackedDeviceIndex_Hmd].bPoseIsValid) {
            head={};head.m[0][0]=head.m[1][1]=head.m[2][2]=1;head.m[1][3]=1.5f;
        }
        auto offset=system->GetEyeToHeadTransform(eye);
        for(int r=0;r<3;++r) for(int c=0;c<4;++c) {
            data.rows[r][c]=c==3?head.m[r][3]:0;
            for(int k=0;k<3;++k) data.rows[r][c]+=head.m[r][k]*offset.m[k][c];
        }
        auto projection=system->GetProjectionMatrix(eye,.05f,100);
        data.projection[0]=projection.m[0][0];data.projection[1]=projection.m[1][1];
        data.projection[2]=projection.m[0][2];data.projection[3]=projection.m[1][2];
        for(uint32_t i=1;i<vr::k_unMaxTrackedDeviceCount;++i) {
            if(!poses[i].bPoseIsValid || system->GetTrackedDeviceClass(i)!=vr::TrackedDeviceClass_Controller) continue;
            auto role=system->GetControllerRoleForTrackedDeviceIndex(i);
            int hand=role==vr::TrackedControllerRole_LeftHand?0:role==vr::TrackedControllerRole_RightHand?1:-1;
            if(hand<0)continue;
            for(int axis=0;axis<3;++axis)data.hands[hand][axis]=poses[i].mDeviceToAbsoluteTracking.m[axis][3];
            data.hands[hand][3]=.065f;
        }
        context->UpdateSubresource(constants.Get(),0,nullptr,&data,0,0);
        D3D11_VIEWPORT viewport{0,0,static_cast<float>(width),static_cast<float>(height),0,1};context->RSSetViewports(1,&viewport);
        context->OMSetRenderTargets(1,&view,nullptr);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vertex.Get(),nullptr,0);context->PSSetShader(pixel.Get(),nullptr,0);
        auto buffer=constants.Get();context->PSSetConstantBuffers(0,1,&buffer);context->Draw(3,0);
    }
};
