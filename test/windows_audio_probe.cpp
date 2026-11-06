// Read-only endpoint/session diagnostics. Never changes default devices or volume.
#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <wrl/client.h>
#include <cstdio>
#include <stdexcept>
#include <vector>
using Microsoft::WRL::ComPtr;
static void checked(HRESULT result) {if(FAILED(result))throw std::runtime_error("Windows audio query failed");}
int main() {
    if(FAILED(CoInitializeEx(nullptr,COINIT_MULTITHREADED)))return 1;
    int result=0;
    try {
        ComPtr<IMMDeviceEnumerator> enumerator;
        checked(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&enumerator)));
        LPWSTR defaults[3]{};
        for(int role=0;role<3;++role) {ComPtr<IMMDevice> device;if(SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender,ERole(role),&device)))device->GetId(&defaults[role]);}
        ComPtr<IMMDeviceCollection> devices;checked(enumerator->EnumAudioEndpoints(eRender,DEVICE_STATE_ACTIVE,&devices));
        UINT count=0;checked(devices->GetCount(&count));
        for(UINT n=0;n<count;++n) {
            ComPtr<IMMDevice> device;checked(devices->Item(n,&device));LPWSTR id=nullptr;checked(device->GetId(&id));
            ComPtr<IPropertyStore> properties;checked(device->OpenPropertyStore(STGM_READ,&properties));
            PROPVARIANT name;PropVariantInit(&name);checked(properties->GetValue(PKEY_Device_FriendlyName,&name));
            std::wprintf(L"ENDPOINT name=%ls id=%ls default_console=%d default_media=%d default_comms=%d\n",name.vt==VT_LPWSTR?name.pwszVal:L"?",id,
                defaults[0]&&!wcscmp(id,defaults[0]),defaults[1]&&!wcscmp(id,defaults[1]),defaults[2]&&!wcscmp(id,defaults[2]));
            PropVariantClear(&name);CoTaskMemFree(id);
            ComPtr<IAudioEndpointVolume> volume;
            if(SUCCEEDED(device->Activate(__uuidof(IAudioEndpointVolume),CLSCTX_ALL,nullptr,&volume))) {
                BOOL mute=FALSE;float level=0;volume->GetMute(&mute);volume->GetMasterVolumeLevelScalar(&level);
                std::printf("  VOLUME muted=%d level=%.3f\n",mute,level);
            }
            ComPtr<IAudioMeterInformation> meter;
            if(SUCCEEDED(device->Activate(__uuidof(IAudioMeterInformation),CLSCTX_ALL,nullptr,&meter))) {
                float maximum=0;for(int sample=0;sample<20;++sample){float peak=0;meter->GetPeakValue(&peak);if(peak>maximum)maximum=peak;Sleep(25);}
                std::printf("  METER peak=%.6f\n",maximum);
            }
            ComPtr<IAudioSessionManager2> manager;
            if(FAILED(device->Activate(__uuidof(IAudioSessionManager2),CLSCTX_ALL,nullptr,&manager)))continue;
            ComPtr<IAudioSessionEnumerator> sessions;checked(manager->GetSessionEnumerator(&sessions));int size=0;checked(sessions->GetCount(&size));
            for(int i=0;i<size;++i) {
                ComPtr<IAudioSessionControl> control;checked(sessions->GetSession(i,&control));ComPtr<IAudioSessionControl2> session;checked(control.As(&session));
                DWORD pid=0;AudioSessionState state{};session->GetProcessId(&pid);session->GetState(&state);
                ComPtr<ISimpleAudioVolume> gain;BOOL mute=FALSE;float level=0;
                if(SUCCEEDED(session.As(&gain))){gain->GetMute(&mute);gain->GetMasterVolume(&level);}
                ComPtr<IAudioMeterInformation> session_meter;float session_peak=0;
                if(SUCCEEDED(session.As(&session_meter)))for(int sample=0;sample<20;++sample) {
                    float peak=0;session_meter->GetPeakValue(&peak);if(peak>session_peak)session_peak=peak;Sleep(25);
                }
                wchar_t path[2048]=L"system";DWORD chars=2048;HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
                if(process){QueryFullProcessImageNameW(process,0,path,&chars);CloseHandle(process);}
                std::wprintf(L"  SESSION pid=%lu state=%d muted=%d volume=%.3f peak=%.6f process=%ls\n",pid,int(state),mute,level,session_peak,path);
            }
        }
        for(auto id:defaults)CoTaskMemFree(id);
    }catch(const std::exception &error){std::fprintf(stderr,"%s\n",error.what());result=1;}
    CoUninitialize();return result;
}
