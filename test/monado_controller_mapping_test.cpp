#include <cassert>
#include <cstdint>
#include <initializer_list>
enum xrt_input_name {
    XRT_INPUT_TOUCH_GRIP_POSE,XRT_INPUT_TOUCH_AIM_POSE,XRT_INPUT_TOUCH_TRIGGER_VALUE,
    XRT_INPUT_TOUCH_SQUEEZE_VALUE,XRT_INPUT_TOUCH_THUMBSTICK,XRT_INPUT_TOUCH_THUMBSTICK_CLICK,
    XRT_INPUT_TOUCH_THUMBSTICK_TOUCH,XRT_INPUT_TOUCH_X_CLICK,XRT_INPUT_TOUCH_X_TOUCH,
    XRT_INPUT_TOUCH_A_CLICK,XRT_INPUT_TOUCH_A_TOUCH,XRT_INPUT_TOUCH_TRIGGER_TOUCH,
    XRT_INPUT_TOUCH_Y_CLICK,XRT_INPUT_TOUCH_Y_TOUCH,XRT_INPUT_TOUCH_B_CLICK,XRT_INPUT_TOUCH_B_TOUCH,
    XRT_INPUT_WMR_GRIP_POSE,XRT_INPUT_WMR_AIM_POSE,XRT_INPUT_WMR_TRIGGER_VALUE,XRT_INPUT_WMR_SQUEEZE_CLICK
};
enum xrt_output_name {XRT_OUTPUT_NAME_TOUCH_HAPTIC};
enum xrt_device_name {XRT_DEVICE_WMR_CONTROLLER,XRT_DEVICE_TOUCH_CONTROLLER};
enum xrt_device_type {XRT_DEVICE_TYPE_LEFT_HAND_CONTROLLER,XRT_DEVICE_TYPE_RIGHT_HAND_CONTROLLER};
struct xrt_vec2 {float x,y;};
struct xrt_vec3 {float x,y,z;};
struct xrt_quat {float x,y,z,w;};
struct xrt_pose {xrt_quat orientation; xrt_vec3 position;};
struct xrt_space_relation {xrt_pose pose; uint32_t relation_flags;};
enum {XRT_SPACE_RELATION_ORIENTATION_VALID_BIT=1,XRT_SPACE_RELATION_POSITION_VALID_BIT=2,
      XRT_SPACE_RELATION_ORIENTATION_TRACKED_BIT=4,XRT_SPACE_RELATION_POSITION_TRACKED_BIT=8};
struct xrt_input {
    xrt_input_name name; uint64_t timestamp; bool active;
    union {bool boolean; struct {float x;} vec1; xrt_vec2 vec2;} value;
};
struct xrt_device {uint32_t input_count; xrt_input *inputs;};
static uint64_t os_monotonic_get_ns() {return 100;}
#include "monado_controller_dispatch.h"
static uint32_t pressed=0,valid=15;
static int query(unsigned,int64_t,float *,float *values,uint32_t *buttons,uint32_t *flags,uint64_t *stamp) {
    values[0]=.5f; values[1]=.75f; values[2]=.25f; values[3]=-.5f;
    *buttons=pressed; *flags=valid; *stamp=100; return 1;
}
int main() {
    assert(meteor_touch_outputs[0]==XRT_OUTPUT_NAME_TOUCH_HAPTIC);
    for(unsigned hand=0;hand<2;++hand) {
        xrt_input inputs[sizeof(meteor_touch_inputs)/sizeof(*meteor_touch_inputs)]{};
        for(unsigned i=0;i<sizeof(inputs)/sizeof(*inputs);++i) inputs[i].name=meteor_touch_inputs[i];
        xrt_device device{sizeof(inputs)/sizeof(*inputs),inputs};
        meteor_controller_bridge bridge{}; bridge.module=&bridge; bridge.query_v2=query; bridge.hand=hand;
        auto button=[&](xrt_input_name name) -> xrt_input & {
            for(auto &input:inputs) if(input.name==name) return input;
            assert(false); return inputs[0];
        };
        for(uint32_t bit:{2u,32u,64u}) {
            pressed=bit; valid=15;
            assert(meteor_controller_update(&bridge,&device));
            assert(button(XRT_INPUT_TOUCH_THUMBSTICK_CLICK).value.boolean==(bit==2));
            assert(button(hand ? XRT_INPUT_TOUCH_B_CLICK : XRT_INPUT_TOUCH_Y_CLICK).value.boolean==(bit==32));
            assert(button(hand ? XRT_INPUT_TOUCH_B_TOUCH : XRT_INPUT_TOUCH_Y_TOUCH).value.boolean==(bit==64));
            assert(!button(hand ? XRT_INPUT_TOUCH_Y_CLICK : XRT_INPUT_TOUCH_B_CLICK).active);
            pressed=0;
            assert(meteor_controller_update(&bridge,&device));
            assert(!button(XRT_INPUT_TOUCH_THUMBSTICK_CLICK).value.boolean);
            assert(!button(hand ? XRT_INPUT_TOUCH_B_CLICK : XRT_INPUT_TOUCH_Y_CLICK).value.boolean);
        }
        valid=0;
        assert(meteor_controller_update(&bridge,&device));
        assert(!button(XRT_INPUT_TOUCH_THUMBSTICK_CLICK).active);
    }
}
