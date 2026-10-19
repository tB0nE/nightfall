#pragma once
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
// Diagnostic profiles: original WinMR stand-in and partial native Touch.
// Extended Touch forwards sticks/A-X/touches; B/Y/menu/system stay local.
// Haptics are opt-in, bounded and queued; output callbacks never do socket I/O.
static enum xrt_input_name meteor_touch_inputs[]={
    XRT_INPUT_TOUCH_GRIP_POSE,XRT_INPUT_TOUCH_AIM_POSE,
    XRT_INPUT_TOUCH_TRIGGER_VALUE,XRT_INPUT_TOUCH_SQUEEZE_VALUE,
    XRT_INPUT_TOUCH_THUMBSTICK,XRT_INPUT_TOUCH_THUMBSTICK_CLICK,XRT_INPUT_TOUCH_THUMBSTICK_TOUCH,
    XRT_INPUT_TOUCH_X_CLICK,XRT_INPUT_TOUCH_X_TOUCH,XRT_INPUT_TOUCH_A_CLICK,XRT_INPUT_TOUCH_A_TOUCH,XRT_INPUT_TOUCH_TRIGGER_TOUCH,
};
static enum xrt_output_name meteor_touch_outputs[]={XRT_OUTPUT_NAME_TOUCH_HAPTIC};
struct meteor_controller_bridge {
    void *module;
    int (*query)(unsigned,int64_t,float *,float *,uint32_t *,uint64_t *);
    int (*query_v2)(unsigned,int64_t,float *,float *,uint32_t *,uint32_t *,uint64_t *);
    unsigned hand;
    int (*haptic)(unsigned,float,int64_t);
};
static bool meteor_controller_initialize(struct meteor_controller_bridge *b,enum xrt_device_name name,enum xrt_device_type type) {
    if(!getenv("METEOR_XR_CONTROLLERS")) return true;
    if((name!=XRT_DEVICE_WMR_CONTROLLER && name!=XRT_DEVICE_TOUCH_CONTROLLER) || !getenv("METEOR_TRACKING_BRIDGE")) return false;
    b->hand=type==XRT_DEVICE_TYPE_LEFT_HAND_CONTROLLER ? 0 : 1;
    b->module=dlopen(getenv("METEOR_TRACKING_BRIDGE"),RTLD_NOW|RTLD_LOCAL);
    if(!b->module) return false;
    void *symbol=dlsym(b->module,"meteor_tracking_controller_v1"); memcpy(&b->query,&symbol,sizeof(b->query));
    if(!b->query) { dlclose(b->module); b->module=NULL; return false; }
    if(getenv("METEOR_XR_TOUCH_INPUTS")) {
        symbol=dlsym(b->module,"meteor_tracking_controller_v2"); memcpy(&b->query_v2,&symbol,sizeof(b->query_v2));
        if(!b->query_v2) { dlclose(b->module); b->module=NULL; return false; }
    }
    if(getenv("METEOR_XR_HAPTICS")) {
        symbol=dlsym(b->module,"meteor_tracking_haptic_v1"); memcpy(&b->haptic,&symbol,sizeof(b->haptic));
        if(!b->haptic) { dlclose(b->module); b->module=NULL; return false; }
    }
    return true;
}
static void meteor_controller_release(struct meteor_controller_bridge *b) {
    if(b->module) dlclose(b->module);
    memset(b,0,sizeof(*b));
}
static bool meteor_controller_read(struct meteor_controller_bridge *b,int64_t at,float poses[14],float values[4],uint32_t *buttons,uint32_t *flags,uint64_t *stamp) {
    if(b->query_v2) return b->query_v2(b->hand,at,poses,values,buttons,flags,stamp)!=0;
    *buttons=0; values[2]=values[3]=0;
    return b->query(b->hand,at,poses,values,flags,stamp)!=0;
}
static bool meteor_controller_update(struct meteor_controller_bridge *b,struct xrt_device *device) {
    if(!b->module) return false;
    float poses[14],values[4]={0}; uint32_t flags=0,buttons=0; uint64_t stamp=0;
    uint64_t now=os_monotonic_get_ns();
    if(!meteor_controller_read(b,(int64_t)now,poses,values,&buttons,&flags,&stamp)) flags=0;
    for(uint32_t i=0;i<device->input_count;++i) {
        struct xrt_input *input=&device->inputs[i];
        input->timestamp=stamp ? stamp : now; memset(&input->value,0,sizeof(input->value));
        input->active=false;
        switch(input->name) {
        case XRT_INPUT_WMR_GRIP_POSE: input->active=(flags&1)!=0; break;
        case XRT_INPUT_TOUCH_GRIP_POSE: input->active=(flags&1)!=0; break;
        case XRT_INPUT_WMR_AIM_POSE: input->active=(flags&2)!=0; break;
        case XRT_INPUT_TOUCH_AIM_POSE: input->active=(flags&2)!=0; break;
        case XRT_INPUT_WMR_TRIGGER_VALUE: input->active=(flags&4)!=0; input->value.vec1.x=values[0]; break;
        case XRT_INPUT_TOUCH_TRIGGER_VALUE: input->active=(flags&4)!=0; input->value.vec1.x=values[0]; break;
        case XRT_INPUT_TOUCH_SQUEEZE_VALUE: input->active=(flags&4)!=0; input->value.vec1.x=values[1]; break;
        case XRT_INPUT_TOUCH_THUMBSTICK: input->active=b->query_v2 && (flags&8); input->value.vec2=(struct xrt_vec2){values[2],values[3]}; break;
        case XRT_INPUT_TOUCH_THUMBSTICK_CLICK: input->active=b->query_v2 && (flags&4); input->value.boolean=(buttons&2)!=0; break;
        case XRT_INPUT_TOUCH_THUMBSTICK_TOUCH: input->active=b->query_v2 && (flags&4); input->value.boolean=(buttons&8)!=0; break;
        case XRT_INPUT_TOUCH_X_CLICK: case XRT_INPUT_TOUCH_A_CLICK:
            input->active=b->query_v2 && (flags&4) && ((input->name==XRT_INPUT_TOUCH_X_CLICK)==(b->hand==0)); input->value.boolean=input->active && (buttons&1); break;
        case XRT_INPUT_TOUCH_X_TOUCH: case XRT_INPUT_TOUCH_A_TOUCH:
            input->active=b->query_v2 && (flags&4) && ((input->name==XRT_INPUT_TOUCH_X_TOUCH)==(b->hand==0)); input->value.boolean=input->active && (buttons&4); break;
        case XRT_INPUT_TOUCH_TRIGGER_TOUCH: input->active=b->query_v2 && (flags&4); input->value.boolean=(buttons&16)!=0; break;
        case XRT_INPUT_WMR_SQUEEZE_CLICK: input->active=(flags&4)!=0; input->value.boolean=values[1]>.5f; break;
        default: break; // Menu remains local; no synthetic button presses.
        }
    }
    fprintf(stderr,"METEOR_CONTROLLER_INPUT hand=%u flags=%u trigger=%.3f squeeze=%.3f\n",b->hand,flags,values[0],values[1]);
    if(b->query_v2) fprintf(stderr,"METEOR_TOUCH_INPUT hand=%u stick=%.3f,%.3f buttons=%u\n",b->hand,values[2],values[3],buttons);
    return true;
}
static bool meteor_controller_pose(struct meteor_controller_bridge *b,enum xrt_input_name name,int64_t at_ns,struct xrt_space_relation *out) {
    if(!b->module) return false;
    memset(out,0,sizeof(*out)); out->pose.orientation.w=1;
    if(name!=XRT_INPUT_WMR_GRIP_POSE && name!=XRT_INPUT_WMR_AIM_POSE &&
        name!=XRT_INPUT_TOUCH_GRIP_POSE && name!=XRT_INPUT_TOUCH_AIM_POSE) return true;
    float poses[14],values[4]; uint32_t flags=0,buttons=0; uint64_t stamp=0;
    unsigned pose=(name==XRT_INPUT_WMR_GRIP_POSE || name==XRT_INPUT_TOUCH_GRIP_POSE) ? 0 : 1;
    if(!meteor_controller_read(b,at_ns,poses,values,&buttons,&flags,&stamp) || !(flags&(1u<<pose))) return true;
    const float *p=poses+pose*7;
    out->pose.position=(struct xrt_vec3){p[0],p[1],p[2]}; out->pose.orientation=(struct xrt_quat){p[3],p[4],p[5],p[6]};
    out->relation_flags=XRT_SPACE_RELATION_ORIENTATION_VALID_BIT|XRT_SPACE_RELATION_POSITION_VALID_BIT|
        XRT_SPACE_RELATION_ORIENTATION_TRACKED_BIT|XRT_SPACE_RELATION_POSITION_TRACKED_BIT;
    return true;
}
