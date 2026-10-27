// Encoder-independent stereo packing and layer composition. Caller holds the
// Monado queue mutex and keeps source images alive until GPU completion.
#pragma once
#include "meteor_quad_compositor.h"
static void meteor_record_stereo(VkCommandBuffer cmd,const meteor_stereo_encode_v1 *input,
                                 VkImage image,uint32_t family,uint32_t eye_size,uint32_t eye_height,
                                 MeteorQuadCompositor &quads) {
    if(input->background_only) {
        VkClearColorValue black{{0,0,0,1}};
        VkImageSubresourceRange range{VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdClearColorImage(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&black,1,&range);
    }
    for (int eye = 0; !input->background_only && eye < 2; ++eye) {
        VkImageMemoryBarrier src{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        src.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; src.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        src.srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL; src.dstQueueFamilyIndex = family;
        src.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT; src.image = input->eyes[eye];
        src.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, input->eye_slices[eye], 1};
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &src);
        VkImageCopy copy{}; copy.srcSubresource = copy.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        copy.srcSubresource.baseArrayLayer=input->eye_slices[eye];
        copy.srcOffset={input->eye_offsets[eye*2],input->eye_offsets[eye*2+1],0};
        copy.dstOffset.x = eye * eye_size; copy.extent = {eye_size, eye_height, 1};
        if(meteor_eye_format_bgra(input->eye_formats[eye])) {
            VkImageBlit blit{}; blit.srcSubresource=copy.srcSubresource; blit.dstSubresource=copy.dstSubresource;
            blit.srcOffsets[0]=copy.srcOffset; blit.srcOffsets[1]={copy.srcOffset.x+int32_t(eye_size),copy.srcOffset.y+int32_t(eye_height),1};
            blit.dstOffsets[0]=copy.dstOffset; blit.dstOffsets[1]={copy.dstOffset.x+int32_t(eye_size),int32_t(eye_height),1};
            vkCmdBlitImage(cmd,input->eyes[eye],VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&blit,VK_FILTER_NEAREST);
        } else vkCmdCopyImage(cmd, input->eyes[eye], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        src.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; src.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        src.srcQueueFamilyIndex = family; src.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
        src.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; src.dstAccessMask = 0;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &src);
    }
    if(input->quad_count) quads.record(cmd,*input,image,family);
}
