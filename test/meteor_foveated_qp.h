#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>
// Fixed-centre ROI encoding. Ordinary stereo video; no spatial remapping and
// no reduction in renderer/decoder resolution. QP deltas apply after CBR RC.
inline std::vector<int8_t> meteor_foveated_qp(uint32_t eye_width,uint32_t height,uint32_t block) {
    if(!eye_width || !height || (block!=16 && block!=32) || eye_width>4096 || height>4096) return {};
    const uint32_t columns=(eye_width*2+block-1)/block,rows=(height+block-1)/block;
    std::vector<int8_t> map(size_t(columns)*rows);
    for(uint32_t y=0;y<rows;++y) for(uint32_t x=0;x<columns;++x) {
        float px=std::min((x+.5f)*block,float(eye_width*2)-.5f);
        float py=std::min((y+.5f)*block,float(height)-.5f);
        float nx=std::abs(std::fmod(px,float(eye_width))/eye_width-.5f)*2;
        float ny=std::abs(py/height-.5f)*2;
        float t=std::clamp((std::max(nx,ny)-.5f)*2,0.f,1.f);
        t=t*t*(3-2*t);
        map[size_t(y)*columns+x]=int8_t(std::lround(-2+8*t));
    }
    return map;
}
