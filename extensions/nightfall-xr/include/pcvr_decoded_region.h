#pragma once
#include <cstdint>
// AImage crop coordinates are exclusive. Imported AHardwareBuffer textures
// cover the padded allocation, not just the logical video rectangle.
struct PCVRDecodedRegion {
    float uv[4]{0,0,1,1}; // offset x/y, scale x/y
    float texel[2]{1,1};
};
inline bool pcvr_decoded_region(uint32_t storage_width,uint32_t storage_height,
        int32_t left,int32_t top,int32_t right,int32_t bottom,
        uint32_t video_width,uint32_t video_height,PCVRDecodedRegion &region) {
    if(!storage_width || !storage_height || storage_width>16384 || storage_height>8192 ||
       !video_width || !video_height || video_width>8192 || video_height>4096 ||
       left<0 || top<0 || right<=left || bottom<=top ||
       uint32_t(right)>storage_width || uint32_t(bottom)>storage_height ||
       uint32_t(right-left)!=video_width || uint32_t(bottom-top)!=video_height) return false;
    region.uv[0]=float(left)/storage_width; region.uv[1]=float(top)/storage_height;
    region.uv[2]=float(video_width)/storage_width; region.uv[3]=float(video_height)/storage_height;
    region.texel[0]=1.f/storage_width; region.texel[1]=1.f/storage_height;
    return true;
}
