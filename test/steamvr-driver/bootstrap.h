#pragma once
#include <sddl.h>
#include <map>
#include <string>
#include <vector>

// The installed driver can be loaded by ordinary SteamVR. Its private pipe
// supplies only a prepared session; absence of Meteor leaves the provider idle.
namespace meteor_bootstrap {
// A new application connection may re-arm an already initialized provider.
// Bound retries so returning to the desktop does not immediately reopen XR.
struct Activation {
    ULONGLONG until=0;
    void application(ULONGLONG now) {until=now+30000;}
    bool requested(bool initialized, bool connected, ULONGLONG now) const {
        return !initialized || (!connected && now<until);
    }
    void connected() {until=0;}
};
struct SceneLifetime {
    DWORD pid=0;
    void scene(DWORD next) {if(next)pid=next;}
    bool disconnected(DWORD next) {
        if(!pid || next!=pid)return false;
        pid=0;return true;
    }
};
inline bool application_process(DWORD pid) {
    if(!pid || pid==GetCurrentProcessId())return false;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if(!process)return false;
    wchar_t path[32768];DWORD length=32768;
    bool ok=QueryFullProcessImageNameW(process,0,path,&length)!=0;
    CloseHandle(process);if(!ok)return false;
    auto name=wcsrchr(path,L'\\');name=name?name+1:path;
    const wchar_t *runtime[]={L"vrserver.exe",L"vrcompositor.exe",L"vrmonitor.exe",
        L"vrdashboard.exe",L"vrwebhelper.exe",L"vrstartup.exe",L"steamtours.exe",
        L"steam.exe",L"steamwebhelper.exe",L"meteor-steamvr-mirror.exe"};
    for(auto value:runtime)if(!_wcsicmp(name,value))return false;
    return true;
}
inline std::wstring sid(HANDLE process) {
    HANDLE token=nullptr;if(!OpenProcessToken(process,TOKEN_QUERY,&token))return {};
    DWORD length=0;GetTokenInformation(token,TokenUser,nullptr,0,&length);
    std::vector<uintptr_t> words((length+sizeof(uintptr_t)-1)/sizeof(uintptr_t));
    bool ok=GetTokenInformation(token,TokenUser,words.data(),length,&length)!=0;CloseHandle(token);
    if(!ok)return {};LPWSTR text=nullptr;
    if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(words.data())->User.Sid,&text))return {};
    std::wstring result(text);LocalFree(text);return result;
}
inline bool io(HANDLE pipe,void *data,DWORD size,bool write,ULONGLONG deadline) {
    auto bytes=static_cast<unsigned char *>(data);
    while(size) {
        OVERLAPPED ov{};ov.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);if(!ov.hEvent)return false;
        DWORD done=0;BOOL ok=write?WriteFile(pipe,bytes,size,&done,&ov):ReadFile(pipe,bytes,size,&done,&ov);
        if(!ok && GetLastError()==ERROR_IO_PENDING) {
            auto now=GetTickCount64();DWORD wait=now<deadline?DWORD(deadline-now):0;
            if(WaitForSingleObject(ov.hEvent,wait)==WAIT_OBJECT_0)ok=GetOverlappedResult(pipe,&ov,&done,FALSE);
            else {CancelIoEx(pipe,&ov);GetOverlappedResult(pipe,&ov,&done,TRUE);ok=FALSE;}
        }
        CloseHandle(ov.hEvent);if(!ok || !done)return false;
        bytes+=done;size-=done;
    }
    return true;
}
inline bool allowed(const std::string &key) {
    static const char *keys[]={"METEOR_TRACKING_BRIDGE","METEOR_TRACKING_PORT","METEOR_XR_DIRECT_PORT",
        "METEOR_XR_EYE_SIZE","METEOR_XR_EYE_HEIGHT","XRT_COMPOSITOR_NULL_FPS","METEOR_XR_CODEC",
        "METEOR_XR_BITRATE_MBPS","METEOR_XR_ASYNC_DELIVERY","METEOR_XR_TRACKED_SCENE",
        "METEOR_WINDOWS_SESSION_MARKER","METEOR_STEAMVR_READY_FILE","METEOR_STEAMVR_DIRECT",
        "METEOR_XR_HEADSET_OPTICS","METEOR_XR_CONTROLLERS","METEOR_XR_TOUCH_INPUTS","METEOR_XR_HAPTICS"};
    for(auto value:keys)if(key==value)return true;return false;
}
inline bool parse(const std::vector<unsigned char> &bytes,std::map<std::string,std::string> &out) {
    std::map<std::string,std::string> parsed;
    size_t offset=0;
    while(offset<bytes.size()) {
        if(bytes.size()-offset<4)return false;
        size_t key=bytes[offset]|size_t(bytes[offset+1])<<8,value=bytes[offset+2]|size_t(bytes[offset+3])<<8;
        offset+=4;if(!key || value>4096 || key+value>bytes.size()-offset)return false;
        std::string name(reinterpret_cast<const char *>(bytes.data()+offset),key);offset+=key;
        std::string text(reinterpret_cast<const char *>(bytes.data()+offset),value);offset+=value;
        if(!allowed(name) || text.find('\0')!=std::string::npos || !parsed.emplace(name,text).second)return false;
    }
    out=std::move(parsed);return true;
}
inline bool read(std::map<std::string,std::string> &settings,const std::wstring &test_pipe={},bool activate=false,bool *available=nullptr) {
    if(available)*available=false;
    auto user=sid(GetCurrentProcess());if(user.empty())return false;
    auto name=test_pipe.empty()?L"\\\\.\\pipe\\Nightfall.Meteor.SteamVR."+user:test_pipe;
    HANDLE pipe=CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
    if(pipe==INVALID_HANDLE_VALUE)return false;
    ULONG pid=0;bool trusted=false;
    if(GetNamedPipeServerProcessId(pipe,&pid)) {
        HANDLE server=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
        if(server) {trusted=sid(server)==user;CloseHandle(server);}
    }
    bool ok=false;auto deadline=GetTickCount64()+40;
    if(trusted) {
        char request[]={'M','D','S',activate?'2':'1'};DWORD length=0;
        if(io(pipe,request,4,true,deadline) && io(pipe,&length,4,false,deadline) && length<=16384) {
            std::vector<unsigned char> bytes(length);char ack='!';
            ok=(!length || io(pipe,bytes.data(),length,false,deadline)) && parse(bytes,settings);
            if(ok)ok=io(pipe,&ack,1,true,deadline);
        }
    }
    CloseHandle(pipe);if(available)*available=ok;return ok && !settings.empty();
}
}
