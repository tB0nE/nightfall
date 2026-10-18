#pragma once
#include <vulkan/vulkan.h>
#include <stdint.h>
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
};
typedef void (*meteor_encode_stereo_fn_v1)(const struct meteor_stereo_encode_v1 *);
