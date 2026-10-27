#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
static inline bool meteor_eye_size_valid(uint32_t size) {
    return size>=256 && size<=4096 && size%16==0;
}
static inline uint32_t meteor_eye_dimension(const char *value,uint32_t fallback) {
    if(!value) return fallback;
    if(*value<'0' || *value>'9') return 0;
    char *end=NULL;
    unsigned long parsed=strtoul(value,&end,10);
    return *end || parsed>4096 || !meteor_eye_size_valid((uint32_t)parsed) ? 0 : (uint32_t)parsed;
}
static inline bool meteor_eye_slice_valid(uint32_t slice,uint32_t count,uint32_t samples) {
    return slice<count && samples==1;
}
// Fixed-output diagnostic: crop only, no scaling or implicit bounds clamping.
static inline bool meteor_eye_rect_valid(uint32_t width,uint32_t height,int32_t x,int32_t y,int32_t w,int32_t h) {
    return meteor_eye_size_valid((uint32_t)w) && meteor_eye_size_valid((uint32_t)h) && x>=0 && y>=0 &&
        (uint32_t)x<=width && (uint32_t)y<=height &&
        (uint32_t)w<=width-(uint32_t)x && (uint32_t)h<=height-(uint32_t)y;
}
