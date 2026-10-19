#pragma once
#include <vulkan/vulkan.h>
#include <stdint.h>
// Bitstream pointer is borrowed only for this call. The sink must copy it into
// owned storage before returning; zero reports failure. Never block on network here.
typedef int (*meteor_encoded_callback_v1)(void *, const uint8_t *, uint32_t);
// Local diagnostic ABI only. Borrowed handles remain owned by Monado.
struct meteor_stereo_encode_v1 {
    uint32_t size;
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
    meteor_encoded_callback_v1 encoded_callback;
    void *callback_context;
    uint32_t eye_size; // 0 is legacy 256; otherwise 256 or 512, fixed per session.
    int32_t eye_offsets[4]; // Source x/y per eye; crop only, no resize.
    uint32_t eye_slices[2]; // Array layer selected by the submitted sub-image.
    VkFormat eye_formats[2]; // Explicit source order/transfer function.
};
typedef void (*meteor_encode_stereo_fn_v1)(const struct meteor_stereo_encode_v1 *);
