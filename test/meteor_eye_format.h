#pragma once
#include <stdbool.h>
#include <vulkan/vulkan_core.h>
static inline bool meteor_eye_format_srgb(VkFormat format) {
    return format==VK_FORMAT_R8G8B8A8_SRGB || format==VK_FORMAT_B8G8R8A8_SRGB;
}
static inline bool meteor_eye_format_bgra(VkFormat format) {
    return format==VK_FORMAT_B8G8R8A8_UNORM || format==VK_FORMAT_B8G8R8A8_SRGB;
}
static inline bool meteor_eye_format_valid(VkFormat format) {
    return format==VK_FORMAT_R8G8B8A8_UNORM || format==VK_FORMAT_B8G8R8A8_UNORM || meteor_eye_format_srgb(format);
}
static inline bool meteor_eye_formats_compatible(VkFormat left,VkFormat right) {
    return meteor_eye_format_valid(left) && meteor_eye_format_valid(right) &&
        meteor_eye_format_srgb(left)==meteor_eye_format_srgb(right);
}
