#pragma once
#include "vda_settings.h"
#include <array>
#include <cstdlib>
struct VdaFrameShape {
    int width=518,height=294;
    bool valid() const { return width>=14 && height>=14 && width<=2048 && height<=2048 && width%14==0 && height%14==0; }
    std::array<int,8> tokens() const {
        int x=width/14,y=height/14,base=x*y,small=((x+1)/2)*((y+1)/2);
        return {base,base,small,small,base,base,base*4,base*4};
    }
};
inline VdaFrameShape vda_frame_shape() {
    auto dimension=[](const char* key,int fallback) {
        const char* value=vda_setting(key);if (!value) return fallback;
        char* end=nullptr;long result=std::strtol(value,&end,10);
        return *value && end && !*end && result>=14 && result<=2048 ? int(result) : -1;
    };
    return {dimension("VDA_PROBE_WIDTH",518),dimension("VDA_PROBE_HEIGHT",294)};
}
