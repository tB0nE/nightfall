#pragma once
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

// Same 128-byte push layout in both shaders; no Monado/Vulkan ABI dependency.
struct meteor_quad_push {
    float corner[4][4], uv_rect[4], color_scale[4], color_bias[4];
    uint32_t options[4];
};
static inline void meteor_quat_rotate(const float *q, const float *v, float *out) {
    float t[3] = {2*(q[1]*v[2]-q[2]*v[1]), 2*(q[2]*v[0]-q[0]*v[2]), 2*(q[0]*v[1]-q[1]*v[0])};
    out[0]=v[0]+q[3]*t[0]+q[1]*t[2]-q[2]*t[1];
    out[1]=v[1]+q[3]*t[1]+q[2]*t[0]-q[0]*t[2];
    out[2]=v[2]+q[3]*t[2]+q[0]*t[1]-q[1]*t[0];
}
static inline void meteor_layer_world_pose(const float *local,const float *head,bool view_space,float *world) {
    if(!view_space) {for(int k=0;k<7;++k) world[k]=local[k]; return;}
    meteor_quat_rotate(head+3,local,world);
    for(int k=0;k<3;++k) world[k]+=head[k];
    const float *a=head+3,*b=local+3;
    world[3]=a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1];
    world[4]=a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0];
    world[5]=a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3];
    world[6]=a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2];
}
// Rays are interpolated across a fullscreen triangle pair, then normalized in
// the fragment shader. A view-space panorama follows the head, not each eye.
static inline void meteor_panorama_rays(const float *pose,const float *view,const float *head,
                                       bool view_space,float rays[4][4],float *origin) {
    float inverse[4]={-pose[3],-pose[4],-pose[5],pose[6]};
    float position[3];
    for(int k=0;k<3;++k) position[k]=view[k]-(view_space ? head[k] : 0);
    if(view_space) {
        float inv_view[4]={-view[3],-view[4],-view[5],view[6]},local[3];
        meteor_quat_rotate(inv_view,position,local);
        for(int k=0;k<3;++k) position[k]=local[k];
    }
    for(int k=0;k<3;++k) position[k]-=pose[k];
    meteor_quat_rotate(inverse,position,origin);
    for(unsigned i=0;i<4;++i) {
        float ray[3]={tanf(view[(i&1) ? 8 : 7]),tanf(view[(i&2) ? 10 : 9]),-1},world[3];
        if(view_space) {for(int k=0;k<3;++k) world[k]=ray[k];}
        else meteor_quat_rotate(view+3,ray,world);
        meteor_quat_rotate(inverse,world,rays[i]);
        rays[i][3]=1;
    }
}
// OpenXR -Z forward, Vulkan positive-height viewport (screen Y down).
static inline void meteor_quad_corner(const float *quad_pose, const float *size,
                                      const float *view, const float *head_position,
                                      bool view_space, unsigned i, float *clip) {
    float p[3] = {(i&1 ? .5f : -.5f)*size[0], (i&2 ? -.5f : .5f)*size[1], 0}, world[3], eye[3];
    meteor_quat_rotate(quad_pose+3,p,world);
    for (int k=0;k<3;++k) world[k]+=quad_pose[k];
    float inverse[4]={-view[3],-view[4],-view[5],view[6]};
    if (view_space) {
        // View-space layers are relative to the head, not the world. Retain
        // the per-eye offset instead of incorrectly pinning them to each eye.
        float offset[3], local_offset[3];
        for(int k=0;k<3;++k) offset[k]=view[k]-head_position[k];
        meteor_quat_rotate(inverse,offset,local_offset);
        for(int k=0;k<3;++k) eye[k]=world[k]-local_offset[k];
    } else {
        for(int k=0;k<3;++k) world[k]-=view[k];
        meteor_quat_rotate(inverse,world,eye);
    }
    float left=tanf(view[7]),right=tanf(view[8]),up=tanf(view[9]),down=tanf(view[10]);
    clip[0]=2*eye[0]/(right-left)+(right+left)*eye[2]/(right-left);
    clip[1]=-2*eye[1]/(up-down)-(up+down)*eye[2]/(up-down);
    clip[2]=(-1000.f/999.99f)*eye[2]-.0100001f;
    clip[3]=-eye[2];
}
