// Authored diagnostic hook for the pinned Monado null compositor.
// Not a general compositor: exactly one full-rect RGBA8 stereo projection only.
#pragma once
#include "util/comp_swapchain.h"
#include <stdio.h>
#include <stdlib.h>
#include "monado_probe_paths.h"
#include "monado_nvenc_dispatch.h"
static unsigned meteor_captured_green[2];

// The system multi-compositor waits on client synchronization before layer_commit.
// Read back synchronously while its layer references keep swapchains alive.
static bool
meteor_capture_eye(struct vk_bundle *vk, struct comp_swapchain *sc, uint32_t index, int eye)
{
    VkCommandPool pool = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkCommandBuffer cmd;
    bool ok = false;
    if (index >= sc->vkic.image_count || sc->vkic.info.format != VK_FORMAT_R8G8B8A8_UNORM ||
        sc->vkic.info.width != 256 || sc->vkic.info.height != 256 || sc->vkic.info.array_size != 1) return false;
    VkCommandPoolCreateInfo pi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = vk->main_queue->family_index};
    if (vk->vkCreateCommandPool(vk->device, &pi, NULL, &pool) != VK_SUCCESS) goto cleanup;
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    if (vk->vkAllocateCommandBuffers(vk->device, &ai, &cmd) != VK_SUCCESS) goto cleanup;
    VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = 256 * 256 * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    if (vk->vkCreateBuffer(vk->device, &bi, NULL, &buffer) != VK_SUCCESS) goto cleanup;
    VkMemoryRequirements req;
    vk->vkGetBufferMemoryRequirements(vk->device, buffer, &req);
    uint32_t type = vk->device_memory_props.memoryTypeCount;
    VkMemoryPropertyFlags flags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (uint32_t i = 0; i < vk->device_memory_props.memoryTypeCount; ++i) {
        if ((req.memoryTypeBits & (1u << i)) && (vk->device_memory_props.memoryTypes[i].propertyFlags & flags) == flags) { type = i; break; }
    }
    if (type == vk->device_memory_props.memoryTypeCount) goto cleanup;
    VkMemoryAllocateInfo mi = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size, .memoryTypeIndex = type};
    if (vk->vkAllocateMemory(vk->device, &mi, NULL, &memory) != VK_SUCCESS) goto cleanup;
    if (vk->vkBindBufferMemory(vk->device, buffer, memory, 0) != VK_SUCCESS) goto cleanup;
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    if (vk->vkBeginCommandBuffer(cmd, &begin) != VK_SUCCESS) goto cleanup;
    VkImageMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL, .dstQueueFamilyIndex = vk->main_queue->family_index,
        .image = sc->vkic.images[index].handle,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {256, 256, 1}};
    vk->vkCmdCopyImageToBuffer(cmd, barrier.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    VkBufferMemoryBarrier host = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer, .size = VK_WHOLE_SIZE};
    vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &host, 0, NULL);
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; barrier.dstAccessMask = 0;
    barrier.srcQueueFamilyIndex = vk->main_queue->family_index; barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
    vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    if (vk->vkEndCommandBuffer(cmd) != VK_SUCCESS) goto cleanup;
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
    vk_queue_lock(vk->main_queue);
    VkResult result = vk->vkQueueSubmit(vk->main_queue->queue, 1, &submit, VK_NULL_HANDLE);
    if (result == VK_SUCCESS) result = vk->vkQueueWaitIdle(vk->main_queue->queue);
    vk_queue_unlock(vk->main_queue);
    if (result != VK_SUCCESS) goto cleanup;
    void *mapped;
    if (vk->vkMapMemory(vk->device, memory, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) goto cleanup;
    const unsigned char *pixels = mapped;
    // Validate eye identity and opaque alpha, then save the actual received bytes.
    ok = true;
    for (uint32_t p = 0; p < 256 * 256; ++p) {
        if (pixels[p*4] != (eye == 0 ? (p % 256 < 128 ? 255 : 128) : 0) ||
            pixels[p*4+2] != (eye == 1 ? (p / 256 < 128 ? 255 : 128) : 0) ||
            pixels[p*4+1] != pixels[1] || pixels[p*4+3] != 255) { ok = false; break; }
    }
    FILE *out = ok ? fopen(meteor_probe_path(eye == 0 ? "server-eye-left.ppm" : "server-eye-right.ppm"), "wb") : NULL;
    if (!out) ok = false;
    if (out) {
        if (fprintf(out, "P6\n256 256\n255\n") < 0) ok = false;
        for (uint32_t p = 0; p < 256 * 256; ++p) if (fwrite(pixels + p*4, 1, 3, out) != 3) { ok = false; break; }
        if (fclose(out) != 0) ok = false;
    }
    if (ok) {
        meteor_captured_green[eye] = pixels[1];
        fprintf(stderr, "METEOR_CAPTURE_EYE eye=%d green=%u\n", eye, pixels[1]);
    }
    vk->vkUnmapMemory(vk->device, memory);
cleanup:
    if (pool) vk->vkDestroyCommandPool(vk->device, pool, NULL);
    if (buffer) vk->vkDestroyBuffer(vk->device, buffer, NULL);
    if (memory) vk->vkFreeMemory(vk->device, memory, NULL);
    return ok;
}

static bool
meteor_capture_layer(struct null_compositor *c)
{
    const struct comp_layer_accum *accum = &c->base.layer_accum;
    if (accum->layer_count == 0) return true;
    if (accum->layer_count != 1) return false;
    const struct comp_layer *layer = &accum->layers[0];
    if (layer->data.type != XRT_LAYER_PROJECTION || layer->data.view_count != 2) return false;
    for (int eye = 0; eye < 2; ++eye) {
        const struct xrt_sub_image *sub = &layer->data.proj.v[eye].sub;
        if (!layer->sc_array[eye] || sub->array_index != 0 || sub->rect.offset.w != 0 || sub->rect.offset.h != 0 ||
            (sub->rect.extent.w != 256 && sub->rect.extent.w != 512) || sub->rect.extent.h != sub->rect.extent.w) return false;
    }
    const char *bridge = getenv("METEOR_NVENC_BRIDGE");
    if (bridge) return meteor_encode_layer(c, layer, bridge);
    for (int eye = 0; eye < 2; ++eye)
        if (!meteor_capture_eye(&c->base.vk, comp_swapchain(layer->sc_array[eye]), layer->data.proj.v[eye].sub.image_index, eye)) return false;
    fprintf(stderr, "METEOR_CAPTURE_OK frame=%lld timestamp=%lld eyes=2\n",
        (long long)accum->data.frame_id, (long long)layer->data.timestamp);
    if (meteor_captured_green[0] != meteor_captured_green[1]) return false;
    if (meteor_captured_green[0] == 255) {
        FILE *done = fopen(meteor_probe_path("capture-complete"), "w");
        if (!done) return false;
        if (fclose(done) != 0) return false;
    }
    return true;
}
