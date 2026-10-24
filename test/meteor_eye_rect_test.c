#include "meteor_eye_rect.h"
#include <assert.h>
#include <limits.h>
int main(void) {
    assert(meteor_eye_slice_valid(0,1,1));
    assert(meteor_eye_slice_valid(1,2,1));
    assert(!meteor_eye_slice_valid(2,2,1));
    assert(!meteor_eye_slice_valid(0,0,1));
    assert(!meteor_eye_slice_valid(0,2,4));
    assert(meteor_eye_rect_valid(256,256,0,0,256,256));
    assert(meteor_eye_rect_valid(1024,1024,0,0,1024,1024));
    assert(meteor_eye_rect_valid(2048,2048,0,0,2048,2048));
    assert(meteor_eye_rect_valid(2560,2560,0,0,2560,2560));
    assert(meteor_eye_rect_valid(2656,2656,0,0,2656,2656));
    assert(meteor_eye_rect_valid(3312,3312,0,0,3312,3312));
    assert(meteor_eye_rect_valid(4096,4096,0,0,4096,4096));
    assert(!meteor_eye_rect_valid(4112,4112,0,0,4112,4112));
    assert(!meteor_eye_rect_valid(2657,2657,0,0,2657,2657));
    assert(!meteor_eye_rect_valid(2048,2048,1,0,2048,2048));
    assert(!meteor_eye_rect_valid(4096,4096,0,0,4112,4112));
    assert(!meteor_eye_rect_valid(1024,1024,1,0,1024,1024));
    assert(meteor_eye_rect_valid(544,544,8,12,512,512));
    assert(meteor_eye_rect_valid(544,544,32,32,512,512));
    assert(!meteor_eye_rect_valid(544,544,33,0,512,512));
    assert(!meteor_eye_rect_valid(544,544,0,33,512,512));
    assert(!meteor_eye_rect_valid(544,544,-1,0,512,512));
    assert(!meteor_eye_rect_valid(544,544,0,-1,512,512));
    assert(!meteor_eye_rect_valid(544,544,INT_MAX,INT_MAX,512,512));
    assert(!meteor_eye_rect_valid(544,544,0,0,321,321));
    assert(meteor_eye_rect_valid(544,544,0,0,512,256));
    assert(meteor_eye_rect_valid(2064,2208,0,0,2064,2208));
    assert(!meteor_eye_rect_valid(2064,2208,0,0,2208,2064));
    assert(!meteor_eye_rect_valid(0,0,0,0,256,256));
}
