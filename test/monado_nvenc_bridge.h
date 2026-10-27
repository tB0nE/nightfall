#pragma once
#include <vulkan/vulkan.h>
#include <stdint.h>
// Bitstream pointer is borrowed only for this call. The sink must copy it into
// owned storage before returning; zero reports failure. Never block on network here.
typedef int (*meteor_encoded_callback_v1)(void *, const uint8_t *, uint32_t);
#define METEOR_MAX_QUADS 256 // Up to two eye-specific draws per submitted layer.
#define METEOR_LAYER_ABI 4
enum meteor_layer_kind {METEOR_LAYER_QUAD, METEOR_LAYER_EQUIRECT2, METEOR_LAYER_CYLINDER, METEOR_LAYER_PROJECTION};
struct meteor_layer_v2 {
    VkImage image;
    VkFormat format;
    uint32_t width, height, slice;
    int32_t rect[4];
    float pose[7]; // position xyz, quaternion xyzw
    float extent[2];
    float color_scale[4], color_bias[4];
    uint32_t flags, visibility;
    uint32_t flip_y;
    uint32_t kind;
    float radius, horizontal_angle, upper_angle, lower_angle, aspect_ratio;
    float projection_fov[4]; // Tangents: left, right, up, down.
};
// Local diagnostic ABI only. Borrowed handles remain owned by Monado.
struct meteor_stereo_encode_v1 {
    uint32_t size;
    uint32_t layer_abi, layer_stride;
    VkInstance instance;
    VkPhysicalDevice gpu;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family;
    VkImage eyes[2];
    uint64_t frame_id;
    const char *output_path;
    uint64_t display_ns;
    float views[22];
    float head_pose[7]; // Actual tracked world-space head; not inferred from application views.
    meteor_encoded_callback_v1 encoded_callback;
    void *callback_context;
    uint32_t eye_size; // 0 is legacy 256; otherwise 256..4096, multiple of 16, fixed per session.
    uint32_t eye_height; // 0 inherits eye_size for legacy square fixtures.
    int32_t eye_offsets[4]; // Source x/y per eye; crop only, no resize.
    uint32_t eye_slices[2]; // Array layer selected by the submitted sub-image.
    VkFormat eye_formats[2]; // Explicit source order/transfer function.
    uint32_t quad_count;
    const struct meteor_layer_v2 *quads; // Borrowed until synchronous bridge return.
    uint32_t projection_present;
    uint32_t background_only; // Clear to opaque black; no projection images borrowed.
};
typedef void (*meteor_encode_stereo_fn_v1)(const struct meteor_stereo_encode_v1 *);
