#pragma once
#include <stdbool.h>
#include <stdint.h>
static inline bool meteor_eye_slice_valid(uint32_t slice,uint32_t count,uint32_t samples) {
    return slice<count && samples==1;
}
// Fixed-output diagnostic: crop only, no scaling or implicit bounds clamping.
static inline bool meteor_eye_rect_valid(uint32_t width,uint32_t height,int32_t x,int32_t y,int32_t w,int32_t h) {
    return (w==256 || w==512 || w==1024) && h==w && x>=0 && y>=0 &&
        (uint32_t)x<=width && (uint32_t)y<=height &&
        (uint32_t)w<=width-(uint32_t)x && (uint32_t)h<=height-(uint32_t)y;
}
