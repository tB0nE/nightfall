// The Monado bridge's AMD path on Windows (see meteor_amf_encoder.h). Same contract as the
// NVENC loop in meteor_vulkan_nvenc_probe.cpp: one synchronous encode per bridge request, the
// same log lines, and a REQUIRE failure ends the process.
#pragma once
#include "meteor_amf_encoder.h"

static void amf_bridge_loop(meteor_stereo_encode_v1 request) {
    const meteor_stereo_encode_v1 *input=&request;
    VkPhysicalDevice gpu=input->gpu;
    VkDevice device=input->device;
    VkQueue queue=input->queue;
    const uint32_t family=input->queue_family;
    const uint32_t eye_size=input->eye_size ? input->eye_size : 256;
    const uint32_t eye_height=input->eye_height ? input->eye_height : eye_size;
    REQUIRE(meteor_eye_size_valid(eye_size) && meteor_eye_size_valid(eye_height),"Unsupported eye-size profile");
    const uint32_t width=eye_size*2,height=eye_height;
    REQUIRE(meteor_eye_formats_compatible(input->eye_formats[0],input->eye_formats[1]),"Unsupported/mixed source transfer functions");
    const VkFormat source_formats[2]={input->eye_formats[0],input->eye_formats[1]};
    const VkFormat packed_format=meteor_eye_format_srgb(source_formats[0]) ? VK_FORMAT_R8G8B8A8_SRGB : VK_FORMAT_R8G8B8A8_UNORM;
    for(int eye=0;eye<2;++eye) if(meteor_eye_format_bgra(source_formats[eye])) {
        VkFormatProperties source{},destination{};
        vkGetPhysicalDeviceFormatProperties(gpu,source_formats[eye],&source);
        vkGetPhysicalDeviceFormatProperties(gpu,packed_format,&destination);
        REQUIRE((source.optimalTilingFeatures&VK_FORMAT_FEATURE_BLIT_SRC_BIT) &&
            (destination.optimalTilingFeatures&VK_FORMAT_FEATURE_BLIT_DST_BIT),"Required channel-order blit unavailable");
    }
    std::fprintf(stderr,"METEOR_SOURCE_FORMAT left=%d right=%d packed=%d preserve_display_bytes=1\n",int(source_formats[0]),int(source_formats[1]),int(packed_format));

    // Packing and quads draw here, in the transfer function the eyes use; a byte-exact copy
    // then moves it into the shared texture AMF reads (always RGBA8 UNORM).
    VkPhysicalDeviceMemoryProperties memory_props; vkGetPhysicalDeviceMemoryProperties(gpu,&memory_props);
    VkImageCreateInfo ici{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    ici.imageType=VK_IMAGE_TYPE_2D; ici.format=packed_format; ici.extent={width,height,1};
    ici.mipLevels=ici.arrayLayers=1; ici.samples=VK_SAMPLE_COUNT_1_BIT; ici.tiling=VK_IMAGE_TILING_OPTIMAL;
    ici.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    VkImage image; VK(vkCreateImage(device,&ici,nullptr,&image));
    VkMemoryRequirements req; vkGetImageMemoryRequirements(device,image,&req);
    uint32_t memory_type=memory_props.memoryTypeCount;
    for(uint32_t i=0;i<memory_props.memoryTypeCount;++i)
        if((req.memoryTypeBits&(1u<<i)) && (memory_props.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { memory_type=i; break; }
    REQUIRE(memory_type<memory_props.memoryTypeCount,"No device-local memory for the packed frame");
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; mai.allocationSize=req.size; mai.memoryTypeIndex=memory_type;
    VkDeviceMemory image_memory; VK(vkAllocateMemory(device,&mai,nullptr,&image_memory));
    VK(vkBindImageMemory(device,image,image_memory,0));

    MeteorAmfEncoder amf;
    if(!amf.open(gpu,device,width,height)) { std::fprintf(stderr,"AMF: %s\n",amf.error.c_str()); REQUIRE(false,"AMF shared texture unavailable"); }
    const char *codec_text=getenv("METEOR_XR_CODEC");
    REQUIRE(!codec_text || !strcmp(codec_text,"h264") || !strcmp(codec_text,"h265"),"Unsupported XR codec");
    const bool hevc=codec_text && !strcmp(codec_text,"h265");
    const char *rate_text=getenv("XRT_COMPOSITOR_NULL_FPS");
    const uint32_t rate=rate_text ? uint32_t(atoi(rate_text)) : 60;
    REQUIRE(rate==20 || rate==60 || rate==72,"Unsupported XR encoder rate");
    const uint32_t fallback_bitrate=4000000*(width/512)*(height/256);
    uint32_t bitrate_bps=0;
    REQUIRE(meteor_encoder_bitrate(getenv("METEOR_XR_BITRATE_MBPS"),fallback_bitrate,&bitrate_bps),"Invalid XR bitrate");
    if(!amf.start(hevc,rate,bitrate_bps,packed_format==VK_FORMAT_R8G8B8A8_SRGB)) {
        std::fprintf(stderr,"AMF: %s\n",amf.error.c_str()); REQUIRE(false,"AMF encoder unavailable");
    }
    uint32_t live_bitrate=bitrate_bps;
    MeteorLiveBitrate bitrate_updates;
    std::fprintf(stderr,"METEOR_FOVEATED_ENCODING enabled=0 mode=unsupported backend=amf\n");
    std::fprintf(stderr,"METEOR_VIDEO_CONFIG eye_size=%u bitrate_bps=%u\n",eye_size,bitrate_bps);
    std::fprintf(stderr,"METEOR_VIDEO_DIMENSIONS per_eye=%ux%u packed=%ux%u\n",eye_size,height,width,height);
    std::fprintf(stderr,"METEOR_VIDEO_CODEC codec=%s fps=%u\n",hevc ? "h265" : "h264",rate);
    std::puts("METEOR_ENCODER_INIT surfaces=1 queue_capacity=1 backend=amf");
    std::fflush(stdout);

    VkCommandPoolCreateInfo pci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pci.queueFamilyIndex=family;
    pci.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool pool; VK(vkCreateCommandPool(device,&pci,nullptr,&pool));
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; cai.commandPool=pool;
    cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount=1;
    VkCommandBuffer cmd; VK(vkAllocateCommandBuffers(device,&cai,&cmd));
    std::ofstream output(input->output_path,std::ios::binary);
    REQUIRE(output.good(),"Cannot open output");
    MeteorQuadCompositor quads;
    bool quad_initialized=false,first_frame=true;
    uint32_t previous_quads=UINT32_MAX,previous_projection=UINT32_MAX,previous_copy_mode=UINT32_MAX;
    uint64_t encoded_count=0;
    const VkImageSubresourceRange range{VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
    for(;;) {
        REQUIRE(input->device==device && input->gpu==gpu && input->queue==queue && input->queue_family==family,"Bridge device changed during session");
        REQUIRE((input->eye_size ? input->eye_size : 256)==eye_size,"Bridge dimensions changed during session");
        REQUIRE((input->eye_height ? input->eye_height : eye_size)==eye_height,"Bridge height changed during session");
        REQUIRE(input->eye_formats[0]==source_formats[0] && input->eye_formats[1]==source_formats[1],"Source formats changed during session");
        const auto pack_start=std::chrono::steady_clock::now();
        if(input->background_only!=previous_copy_mode) {
            fprintf(stderr,"METEOR_RENDER_PATH mode=%s\n",input->background_only ? "general" : "copy");
            previous_copy_mode=input->background_only;
        }
        REQUIRE(input->quad_count<=METEOR_MAX_QUADS && (!input->quad_count || input->quads),"Invalid quad list");
        if(input->quad_count && !quad_initialized) {
            quads.init(gpu,device,image,packed_format,eye_size,eye_height);
            quad_initialized=true;
        }
        if(input->quad_count!=previous_quads || input->projection_present!=previous_projection) {
            std::fprintf(stderr,"METEOR_COMPOSITION projection=%u quads=%u gpu=1\n",input->projection_present,input->quad_count);
            previous_quads=input->quad_count;
            previous_projection=input->projection_present;
        }
        if(!first_frame) VK(vkResetCommandBuffer(cmd,0));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK(vkBeginCommandBuffer(cmd,&begin));
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        barrier.oldLayout=first_frame ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcAccessMask=first_frame ? 0 : VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.image=image; barrier.subresourceRange=range;
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
        meteor_record_stereo(cmd,input,image,family,eye_size,eye_height,quads);
        // The packed frame becomes the copy's source.
        barrier.oldLayout=input->quad_count ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcAccessMask=input->quad_count ? VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT : VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        // The shared texture is taken from D3D11 (external), written, and handed back.
        VkImageMemoryBarrier shared{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        shared.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED; shared.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        shared.srcQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL; shared.dstQueueFamilyIndex=family;
        shared.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; shared.image=amf.image; shared.subresourceRange=range;
        const VkImageMemoryBarrier before_copy[2]={barrier,shared};
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT|VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,0,nullptr,0,nullptr,2,before_copy);
        VkImageCopy copy{}; copy.srcSubresource=copy.dstSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.extent={width,height,1};
        vkCmdCopyImage(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,amf.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);
        shared.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; shared.newLayout=VK_IMAGE_LAYOUT_GENERAL;
        shared.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; shared.dstAccessMask=0;
        shared.srcQueueFamilyIndex=family; shared.dstQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL;
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,0,nullptr,1,&shared);
        VK(vkEndCommandBuffer(cmd));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&cmd;
        VK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE)); VK(vkQueueWaitIdle(queue));
        std::fprintf(stderr,"GPU_PACK frame=%llu us=%lld\n",(unsigned long long)input->frame_id,
            (long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-pack_start).count());

        bitrate_updates.poll(getenv("METEOR_PROBE_OUTPUT"),fallback_bitrate,live_bitrate,[&](uint32_t target) {
            amf.set_bitrate(target);
            return 0;
        });
        const auto start=std::chrono::steady_clock::now();
        const bool encoded=amf.encode(first_frame,input->frame_id,[&](const uint8_t *data,uint32_t size) {
            output.write(reinterpret_cast<const char *>(data),size);
            if(input->encoded_callback) {
                REQUIRE(input->encoded_callback(input->callback_context,data,size),"Encoded packet callback failed");
            }
            std::fprintf(stderr,"AMF timestamp=%llu bytes=%u submit-to-lock-us=%lld\n",(unsigned long long)input->frame_id,size,
                (long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
            return true;
        });
        if(!encoded) { std::fprintf(stderr,"AMF: %s\n",amf.error.c_str()); REQUIRE(false,"AMF encode failed"); }
        ++encoded_count;
        first_frame=false;
        bridge_complete();
        if(!bridge_next(request)) break;
    }
    std::printf("METEOR_ENCODER_DRAIN frames=%llu surfaces=1 backend=amf\n",(unsigned long long)encoded_count);
    std::fflush(stdout);
    output.close();  // every frame already waited for its own queue work
    amf.destroy();
    if(quad_initialized) quads.destroy();
    vkDestroyCommandPool(device,pool,nullptr);
    vkDestroyImage(device,image,nullptr); vkFreeMemory(device,image_memory,nullptr);
    std::puts("METEOR_ENCODER_RELEASED");
    std::fflush(stdout);
    std::puts("PASS: Monado eye images -> GPU stereo packing -> D3D11 shared texture -> AMF, without pixel readback.");
}
