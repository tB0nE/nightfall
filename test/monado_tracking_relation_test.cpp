#include <cassert>
#include <cstdint>
struct xrt_vec3 {float x,y,z;};
struct xrt_quat {float x,y,z,w;};
struct xrt_pose {xrt_quat orientation; xrt_vec3 position;};
struct xrt_fov {float angle_left,angle_right,angle_up,angle_down;};
struct xrt_space_relation {xrt_pose pose; uint32_t relation_flags;};
struct xrt_device {
    struct Hmd {
        uint32_t view_count;
        struct View {struct {uint32_t w_pixels,h_pixels;} display;} views[2];
        struct {xrt_fov fov[2];} distortion;
    } *hmd;
};
enum {XRT_SPACE_RELATION_ORIENTATION_VALID_BIT=1, XRT_SPACE_RELATION_POSITION_VALID_BIT=2,
      XRT_SPACE_RELATION_ORIENTATION_TRACKED_BIT=4, XRT_SPACE_RELATION_POSITION_TRACKED_BIT=8};
#include "monado_tracking_dispatch.h"
static bool available;
static int sample(void *,int64_t,float *pose,uint64_t *stamp) {
    if(!available) return 0;
    const float p[7]={1,2,3,0,0,0,1};
    memcpy(pose,p,sizeof(p)); *stamp=1; return 1;
}
int main() {
    meteor_tracking_bridge bridge{};
    xrt_space_relation relation{};
    assert(!meteor_tracking_relation(&bridge,1,&relation));
    bridge.client=&bridge; bridge.pose=sample;
    assert(meteor_tracking_relation(&bridge,1,&relation));
    assert(relation.relation_flags==0 && relation.pose.orientation.w==1);
    available=true;
    assert(meteor_tracking_relation(&bridge,1,&relation));
    assert(relation.relation_flags==15 && relation.pose.position.x==1);
    available=false;
    assert(meteor_tracking_relation(&bridge,1,&relation));
    assert(relation.relation_flags==0 && relation.pose.orientation.w==1);
}
