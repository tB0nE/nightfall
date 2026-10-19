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
    assert(meteor_eye_rect_valid(544,544,8,12,512,512));
    assert(meteor_eye_rect_valid(544,544,32,32,512,512));
    assert(!meteor_eye_rect_valid(544,544,33,0,512,512));
    assert(!meteor_eye_rect_valid(544,544,0,33,512,512));
    assert(!meteor_eye_rect_valid(544,544,-1,0,512,512));
    assert(!meteor_eye_rect_valid(544,544,0,-1,512,512));
    assert(!meteor_eye_rect_valid(544,544,INT_MAX,INT_MAX,512,512));
    assert(!meteor_eye_rect_valid(544,544,0,0,320,320));
    assert(!meteor_eye_rect_valid(544,544,0,0,512,256));
    assert(!meteor_eye_rect_valid(0,0,0,0,256,256));
}
