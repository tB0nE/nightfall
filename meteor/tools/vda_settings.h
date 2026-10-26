// Probe defaults use the environment; production uses an isolated thread-local scope.
#pragma once
#include <cstdlib>
#include <map>
#include <string>
using VdaSettings=std::map<std::string,std::string>;
inline thread_local const VdaSettings* vda_settings_override=nullptr;
inline const char* vda_setting(const char* key) {
    if (!vda_settings_override) return std::getenv(key);
    auto i=vda_settings_override->find(key);
    return i==vda_settings_override->end() ? nullptr : i->second.c_str();
}
struct VdaSettingsScope {
    const VdaSettings* previous;
    explicit VdaSettingsScope(const VdaSettings& settings):previous(vda_settings_override) {vda_settings_override=&settings;}
    ~VdaSettingsScope() {vda_settings_override=previous;}
};
