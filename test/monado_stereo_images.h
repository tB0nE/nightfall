// Diagnostic app-side image proof, not a compositor/encoder implementation.
#pragma once
#include <fstream>
#include "monado_probe_paths.h"
#include "meteor_pose_scene.h"

static void vk_check(VkResult result, const char *operation) {
    if (result != VK_SUCCESS) {
        std::fprintf(stderr, "%s failed: %d\n", operation, result);
        std::exit(1);
    }
}

struct StereoImages {
    static constexpr uint32_t width = 256, height = 256;
    XrSwapchain chains[2]{};
    std::vector<XrSwapchainImageVulkanKHR> images[2];
    std::vector<bool> initialized[2];
    VkDevice device;
    VkQueue queue;
    VkCommandPool pool;
    VkCommandBuffer command;
    VkBuffer buffer;
    VkDeviceMemory memory;

    StereoImages(XrSession session, VkPhysicalDevice gpu, VkDevice dev, uint32_t family) : device(dev) {
        uint32_t count = 0;
        check(xrEnumerateSwapchainFormats(session, 0, &count, nullptr), "count formats");
        std::vector<int64_t> formats(count);
        check(xrEnumerateSwapchainFormats(session, count, &count, formats.data()), "formats");
        bool supported = false;
        for (auto format : formats) if (format == VK_FORMAT_R8G8B8A8_UNORM) supported = true;
        if (!supported) { std::fprintf(stderr, "RGBA8 UNORM unavailable\n"); std::exit(1); }
        for (int eye = 0; eye < 2; ++eye) {
            XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT;
            info.format = VK_FORMAT_R8G8B8A8_UNORM;
            info.sampleCount = 1; info.width = width; info.height = height; info.faceCount = 1; info.arraySize = 1; info.mipCount = 1;
            check(xrCreateSwapchain(session, &info, &chains[eye]), "create eye swapchain");
            check(xrEnumerateSwapchainImages(chains[eye], 0, &count, nullptr), "image count");
            images[eye].resize(count, {XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR});
            initialized[eye].resize(count, false);
            check(xrEnumerateSwapchainImages(chains[eye], count, &count,
                reinterpret_cast<XrSwapchainImageBaseHeader *>(images[eye].data())), "eye images");
        }
        vkGetDeviceQueue(device, family, 0, &queue);
        VkCommandPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        pool_info.queueFamilyIndex = family; pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        vk_check(vkCreateCommandPool(device, &pool_info, nullptr, &pool), "command pool");
        VkCommandBufferAllocateInfo alloc{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        alloc.commandPool = pool; alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; alloc.commandBufferCount = 1;
        vk_check(vkAllocateCommandBuffers(device, &alloc, &command), "command buffer");
        VkBufferCreateInfo buffer_info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        buffer_info.size = width * height * 4; buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        vk_check(vkCreateBuffer(device, &buffer_info, nullptr, &buffer), "readback buffer");
        VkMemoryRequirements requirements; vkGetBufferMemoryRequirements(device, buffer, &requirements);
        VkPhysicalDeviceMemoryProperties props; vkGetPhysicalDeviceMemoryProperties(gpu, &props);
        uint32_t type = props.memoryTypeCount;
        for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
            VkMemoryPropertyFlags required = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
            if ((requirements.memoryTypeBits & (1u << i)) && (props.memoryTypes[i].propertyFlags & required) == required) { type = i; break; }
        }
        if (type == props.memoryTypeCount) { std::fprintf(stderr, "No readback memory\n"); std::exit(1); }
        VkMemoryAllocateInfo memory_info{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        memory_info.allocationSize = requirements.size; memory_info.memoryTypeIndex = type;
        vk_check(vkAllocateMemory(device, &memory_info, nullptr, &memory), "readback allocation");
        vk_check(vkBindBufferMemory(device, buffer, memory, 0), "bind readback");
    }

    void write(int eye, int frame, const XrView *view = nullptr) {
        uint32_t index;
        XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        check(xrAcquireSwapchainImage(chains[eye], &acquire, &index), "acquire eye");
        XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = 1000000000;
        auto waited = xrWaitSwapchainImage(chains[eye], &wait);
        if (waited != XR_SUCCESS) { std::fprintf(stderr, "Eye wait incomplete: %d\n", waited); std::exit(1); }
        const int green = std::getenv("METEOR_CONTINUOUS_FRAMES") ? (frame * 73) % 256 : static_cast<int>(frame * 255 / 4.f + .5f);
        void *upload;
        vk_check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &upload), "map upload");
        auto *input = static_cast<unsigned char *>(upload);
        for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
            uint32_t p = (y * width + x) * 4;
            input[p] = eye == 0 ? (x < width/2 ? 255 : 128) : 0;
            input[p+1] = green;
            input[p+2] = eye == 1 ? (y < height/2 ? 255 : 128) : 0;
            input[p+3] = 255;
            if(view) {
                auto color=meteor_scene(*view,(x+.5f)/width,(y+.5f)/height);
                input[p]=uint8_t(std::clamp(color.x,0.f,1.f)*255);
                input[p+1]=uint8_t(std::clamp(color.y,0.f,1.f)*255);
                input[p+2]=uint8_t(std::clamp(color.z,0.f,1.f)*255);
            }
        }
        std::vector<unsigned char> expected(input,input+width*height*4);
        vkUnmapMemory(device, memory);
        vk_check(vkResetCommandBuffer(command, 0), "reset command");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        vk_check(vkBeginCommandBuffer(command, &begin), "begin command");
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout = initialized[eye][index] ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = images[eye][index].image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        // Asymmetric per-eye spatial pattern detects flips as well as eye swaps.
        VkBufferMemoryBarrier uploaded{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        uploaded.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; uploaded.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        uploaded.srcQueueFamilyIndex = uploaded.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        uploaded.buffer = buffer; uploaded.size = VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 1, &uploaded, 0, nullptr);
        VkBufferImageCopy copy{}; copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}; copy.imageExtent = {width, height, 1};
        vkCmdCopyBufferToImage(command, buffer, barrier.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        uploaded.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; uploaded.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 1, &uploaded, 0, nullptr);
        vkCmdCopyImageToBuffer(command, barrier.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
        VkBufferMemoryBarrier host{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        host.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; host.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        host.srcQueueFamilyIndex = host.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; host.buffer = buffer; host.size = VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &host, 0, nullptr);
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        vk_check(vkEndCommandBuffer(command), "end command");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
        vk_check(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "submit eye commands");
        vk_check(vkQueueWaitIdle(queue), "finish diagnostic readback");
        void *mapped; vk_check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped), "map readback");
        const auto *pixels = static_cast<const unsigned char *>(mapped);
        if(view) {
            if(std::memcmp(pixels,expected.data(),expected.size())) { std::fprintf(stderr,"Scene readback mismatch\n"); std::exit(1); }
            std::ofstream reference(meteor_probe_path(eye==0 ? "scene-left.rgb" : "scene-right.rgb"),
                std::ios::binary | (frame==0 ? std::ios::trunc : std::ios::app));
            for(uint32_t p=0;p<width*height;++p) reference.write(reinterpret_cast<const char *>(pixels+p*4),3);
            if(!reference) { std::fprintf(stderr,"Cannot write scene reference\n"); std::exit(1); }
        }
        for (uint32_t p = 0; p < width * height; ++p) {
            if (!view && (pixels[p*4] != (eye == 0 ? (p % width < width/2 ? 255 : 128) : 0) ||
                pixels[p*4+2] != (eye == 1 ? (p / width < height/2 ? 255 : 128) : 0) ||
                std::abs(static_cast<int>(pixels[p*4+1]) - green) > 1 || pixels[p*4+3] != 255)) {
                std::fprintf(stderr, "Eye %d frame %d pixel %u mismatch\n", eye, frame, p); std::exit(1);
            }
        }
        if (frame == 4) {
            std::ofstream out(meteor_probe_path(eye == 0 ? "eye-left.ppm" : "eye-right.ppm"), std::ios::binary);
            out << "P6\n" << width << ' ' << height << "\n255\n";
            for (uint32_t p = 0; p < width * height; ++p) out.write(reinterpret_cast<const char *>(pixels + p*4), 3);
            if (!out) { std::fprintf(stderr, "Cannot write eye artifact\n"); std::exit(1); }
        }
        vkUnmapMemory(device, memory); initialized[eye][index] = true;
        XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        check(xrReleaseSwapchainImage(chains[eye], &release), "release eye");
    }

    void destroy() {
        vkDestroyBuffer(device, buffer, nullptr); vkFreeMemory(device, memory, nullptr);
        vkDestroyCommandPool(device, pool, nullptr);
        for (auto chain : chains) check(xrDestroySwapchain(chain), "destroy eye swapchain");
    }
};
