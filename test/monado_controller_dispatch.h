#pragma once
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
// First diagnostic profile is WinMR solely as a declared stand-in for poses,
// trigger and squeeze-click. No claim of complete Quest Touch emulation.
struct meteor_controller_bridge {
    void *module;
    int (*query)(unsigned,int64_t,float *,float *,uint32_t *,uint64_t *);
    unsigned hand;
};
static bool meteor_controller_initialize(struct meteor_controller_bridge *b,enum xrt_device_name name,enum xrt_device_type type) {
    if(!getenv("METEOR_XR_CONTROLLERS")) return true;
    if(name!=XRT_DEVICE_WMR_CONTROLLER || !getenv("METEOR_TRACKING_BRIDGE")) return false;
    b->hand=type==XRT_DEVICE_TYPE_LEFT_HAND_CONTROLLER ? 0 : 1;
    b->module=dlopen(getenv("METEOR_TRACKING_BRIDGE"),RTLD_NOW|RTLD_LOCAL);
    if(!b->module) return false;
    void *symbol=dlsym(b->module,"meteor_tracking_controller_v1"); memcpy(&b->query,&symbol,sizeof(b->query));
    if(!b->query) { dlclose(b->module); b->module=NULL; return false; }
    return true;
}
static void meteor_controller_release(struct meteor_controller_bridge *b) {
    if(b->module) dlclose(b->module);
    memset(b,0,sizeof(*b));
}
static bool meteor_controller_update(struct meteor_controller_bridge *b,struct xrt_device *device) {
    if(!b->module) return false;
    float poses[14],values[2]={0}; uint32_t flags=0; uint64_t stamp=0;
    uint64_t now=os_monotonic_get_ns();
    if(!b->query(b->hand,(int64_t)now,poses,values,&flags,&stamp)) flags=0;
    for(uint32_t i=0;i<device->input_count;++i) {
        struct xrt_input *input=&device->inputs[i];
        input->timestamp=stamp ? stamp : now; memset(&input->value,0,sizeof(input->value));
        input->active=false;
        switch(input->name) {
        case XRT_INPUT_WMR_GRIP_POSE: input->active=(flags&1)!=0; break;
        case XRT_INPUT_WMR_AIM_POSE: input->active=(flags&2)!=0; break;
        case XRT_INPUT_WMR_TRIGGER_VALUE: input->active=(flags&4)!=0; input->value.vec1.x=values[0]; break;
        case XRT_INPUT_WMR_SQUEEZE_CLICK: input->active=(flags&4)!=0; input->value.boolean=values[1]>.5f; break;
        default: break; // Menu remains local; no synthetic button presses.
        }
    }
    fprintf(stderr,"METEOR_CONTROLLER_INPUT hand=%u flags=%u trigger=%.3f squeeze=%.3f\n",b->hand,flags,values[0],values[1]);
    return true;
}
static bool meteor_controller_pose(struct meteor_controller_bridge *b,enum xrt_input_name name,int64_t at_ns,struct xrt_space_relation *out) {
    if(!b->module) return false;
    memset(out,0,sizeof(*out)); out->pose.orientation.w=1;
    if(name!=XRT_INPUT_WMR_GRIP_POSE && name!=XRT_INPUT_WMR_AIM_POSE) return true;
    float poses[14],values[2]; uint32_t flags=0; uint64_t stamp=0;
    unsigned pose=name==XRT_INPUT_WMR_GRIP_POSE ? 0 : 1;
    if(!b->query(b->hand,at_ns,poses,values,&flags,&stamp) || !(flags&(1u<<pose))) return true;
    const float *p=poses+pose*7;
    out->pose.position=(struct xrt_vec3){p[0],p[1],p[2]}; out->pose.orientation=(struct xrt_quat){p[3],p[4],p[5],p[6]};
    out->relation_flags=XRT_SPACE_RELATION_ORIENTATION_VALID_BIT|XRT_SPACE_RELATION_POSITION_VALID_BIT|
        XRT_SPACE_RELATION_ORIENTATION_TRACKED_BIT|XRT_SPACE_RELATION_POSITION_TRACKED_BIT;
    return true;
}
