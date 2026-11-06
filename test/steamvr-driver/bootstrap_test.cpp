#include <windows.h>
#include "bootstrap.h"
#include <cassert>
static std::vector<unsigned char> setting(const std::string &key,const std::string &value) {
    std::vector<unsigned char> bytes={static_cast<unsigned char>(key.size()),0,
        static_cast<unsigned char>(value.size()),0};
    bytes.insert(bytes.end(),key.begin(),key.end());bytes.insert(bytes.end(),value.begin(),value.end());return bytes;
}
int wmain(int argc,wchar_t **argv) {
    meteor_bootstrap::SceneLifetime scene;
    assert(!scene.disconnected(12));
    scene.scene(12);
    assert(!scene.disconnected(34)); // Dashboard/helper exit cannot end the game.
    scene.scene(34);
    assert(!scene.disconnected(12)); // A superseded game cannot end its successor.
    assert(scene.disconnected(34));
    assert(!scene.disconnected(34)); // One END per application lifetime.
    meteor_bootstrap::Activation activation;
    assert(activation.requested(false,false,100));
    assert(!activation.requested(true,false,100));
    activation.application(100);
    assert(activation.requested(true,false,101));
    assert(!activation.requested(true,true,101));
    assert(!activation.requested(true,false,30100));
    activation.application(40000);
    activation.connected();
    assert(!activation.requested(true,false,40001));
    activation.application(50000);
    assert(activation.requested(true,false,50001));
    assert(!meteor_bootstrap::application_process(0));
    assert(!meteor_bootstrap::application_process(GetCurrentProcessId()));
    std::map<std::string,std::string> values;
    if(argc==3 && std::wstring(argv[1])==L"--pipe") {
        assert(meteor_bootstrap::read(values,argv[2]));
        assert(values.at("METEOR_XR_EYE_SIZE")=="2208");return 0;
    }
    auto valid=setting("METEOR_XR_EYE_SIZE","2208");
    assert(meteor_bootstrap::parse(valid,values) && values.at("METEOR_XR_EYE_SIZE")=="2208");
    auto duplicate=valid;duplicate.insert(duplicate.end(),valid.begin(),valid.end());
    assert(!meteor_bootstrap::parse(duplicate,values));
    auto truncated=valid;truncated.pop_back();assert(!meteor_bootstrap::parse(truncated,values));
    assert(!meteor_bootstrap::parse(setting("PATH","untrusted"),values));
    assert(!meteor_bootstrap::parse(setting("METEOR_XR_EYE_SIZE",std::string("1\0x",3)),values));
    assert(!meteor_bootstrap::sid(GetCurrentProcess()).empty());
}
