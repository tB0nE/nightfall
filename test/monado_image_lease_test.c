#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef int xrt_result_t;
enum { XRT_SUCCESS, XRT_LAYER_PROJECTION=1, XRT_LAYER_PROJECTION_DEPTH=2, XRT_LAYER_QUAD=3, XRT_LAYER_EQUIRECT2=6, XRT_LAYER_CYLINDER=4 };
struct xrt_swapchain {
    uint32_t image_count;
    xrt_result_t (*inc_image_use)(struct xrt_swapchain *,uint32_t);
    xrt_result_t (*dec_image_use)(struct xrt_swapchain *,uint32_t);
    int uses[3];
};
struct xrt_layer_data {
    int type;
    uint32_t view_count;
    struct { struct { struct { uint32_t image_index; } sub; } v[2]; } proj;
    struct { struct { struct { uint32_t image_index; } sub; } v[2]; } depth;
    struct { struct { uint32_t image_index; } sub; } quad, equirect2, cylinder;
};
#include "monado_image_lease.h"
static int inc(struct xrt_swapchain *sc,uint32_t index) { ++sc->uses[index]; return 0; }
static int dec(struct xrt_swapchain *sc,uint32_t index) { assert(sc->uses[index]>0); --sc->uses[index]; return 0; }
int main(void) {
    struct xrt_swapchain left={.image_count=3,.inc_image_use=inc,.dec_image_use=dec};
    struct xrt_swapchain right=left;
    struct xrt_swapchain *sc[]={&left,&right};
    struct xrt_layer_data data={.type=XRT_LAYER_PROJECTION,.view_count=2};
    data.proj.v[0].sub.image_index=1; data.proj.v[1].sub.image_index=2;
    unsetenv("METEOR_NVENC_BRIDGE");
    meteor_projection_image_lease(&data,sc,true); assert(!left.uses[1] && !right.uses[2]);
    setenv("METEOR_NVENC_BRIDGE","diagnostic",1);
    meteor_projection_image_lease(&data,sc,true);
    assert(left.uses[1]==1 && right.uses[2]==1);
    // Same image can be referenced by multiple queued slots; dropping one must
    // not make it writable while a delivered slot still owns it.
    meteor_projection_image_lease(&data,sc,true);
    meteor_projection_image_lease(&data,sc,false);
    assert(left.uses[1]==1 && right.uses[2]==1);
    meteor_projection_image_lease(&data,sc,false);
    assert(!left.uses[1] && !right.uses[2]);
    // Stereo may share one swapchain image: two balanced references are needed.
    sc[1]=&left; data.proj.v[1].sub.image_index=1;
    meteor_projection_image_lease(&data,sc,true); assert(left.uses[1]==2);
    meteor_projection_image_lease(&data,sc,false); assert(!left.uses[1]);
    // Depth-bearing projection keeps the colour images leased too. Deliberately
    // choose different indices from proj to catch using the wrong union member.
    data.type=XRT_LAYER_PROJECTION_DEPTH;
    data.depth.v[0].sub.image_index=2; data.depth.v[1].sub.image_index=2;
    meteor_projection_image_lease(&data,sc,true); assert(left.uses[2]==2);
    meteor_projection_image_lease(&data,sc,false); assert(!left.uses[2]);
    data.type=99; meteor_projection_image_lease(&data,sc,true); assert(!left.uses[1]);
    data.type=XRT_LAYER_QUAD; data.view_count=0; data.quad.sub.image_index=1;
    for(int overlay=0;overlay<6;++overlay) meteor_projection_image_lease(&data,sc,true);
    assert(left.uses[1]==6);
    for(int overlay=0;overlay<6;++overlay) meteor_projection_image_lease(&data,sc,false);
    assert(!left.uses[1]);
    data.type=XRT_LAYER_CYLINDER; data.cylinder.sub.image_index=2;
    meteor_projection_image_lease(&data,sc,true); assert(left.uses[2]==1);
    meteor_projection_image_lease(&data,sc,false); assert(!left.uses[2]);
    data.type=XRT_LAYER_EQUIRECT2; data.equirect2.sub.image_index=2;
    meteor_projection_image_lease(&data,sc,true); assert(left.uses[2]==1);
    meteor_projection_image_lease(&data,sc,false); assert(!left.uses[2]);
}
