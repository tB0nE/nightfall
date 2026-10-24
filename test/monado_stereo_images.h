// Diagnostic app-side image proof, not a compositor/encoder implementation.
#pragma once
#include <fstream>
#include <chrono>
#include "monado_probe_paths.h"
#include "meteor_eye_format.h"
#include "meteor_eye_rect.h"
#include "meteor_pose_scene.h"

static void vk_check(VkResult result, const char *operation) {
    if (result != VK_SUCCESS) {
        std::fprintf(stderr, "%s failed: %d\n", operation, result);
        std::exit(1);
    }
}

#include "meteor_gpu_scene.h"
#include "meteor_raster_scene.h"

struct StereoImages {
    MeteorGpuScene *gpu_scene = nullptr;
    MeteorRasterScene *raster_scene = nullptr;
    bool measurement = false;
    bool quad_texture = false;
    bool fixed_background = false;
    VkFence completion{};
    VkQueryPool timestamps{};
    float timestamp_period = 0;
    uint32_t timestamp_bits = 0;
    uint32_t width = 256, height = 256;
    int32_t offsets[2][2]{};
    bool array_stereo=false;
    uint32_t slices[2]{},shared_index=0;
    VkFormat source_format=VK_FORMAT_R8G8B8A8_UNORM;
    XrSwapchain chains[2]{};
    std::vector<XrSwapchainImageVulkanKHR> images[2];
    std::vector<bool> initialized[2];
    VkDevice device;
    VkQueue queue;
    VkCommandPool pool;
    VkCommandBuffer command;
    VkBuffer buffer;
    VkDeviceMemory memory;

    StereoImages(XrSession session, VkPhysicalDevice gpu, VkDevice dev, uint32_t family,
                 uint32_t source_width=0,uint32_t source_height=0) : device(dev) {
        measurement = std::getenv("METEOR_XR_GPU_MEASURE") != nullptr;
        if(measurement && (!std::getenv("METEOR_XR_GPU_SCENE_SHADER") || !std::getenv("METEOR_XR_TRACKED_SCENE"))) {
            std::fprintf(stderr,"Measurement requires GPU tracked scene\n"); std::exit(1);
        }
        const char *size = std::getenv("METEOR_XR_EYE_SIZE");
        if (size) {
            char *end=nullptr;
            unsigned long parsed=std::strtoul(size,&end,10);
            if (!*size || *end || parsed>4096 || !meteor_eye_size_valid(uint32_t(parsed))) { std::fprintf(stderr,"Invalid eye-size profile\n"); std::exit(1); }
            width = height = uint32_t(parsed);
            height=meteor_eye_dimension(std::getenv("METEOR_XR_EYE_HEIGHT"),width);
            if(!height) { std::fprintf(stderr,"Invalid eye height\n"); std::exit(1); }
        }
        if(source_width && source_height) {width=source_width; height=source_height;}
        uint32_t count = 0;
        check(xrEnumerateSwapchainFormats(session, 0, &count, nullptr), "count formats");
        std::vector<int64_t> formats(count);
        check(xrEnumerateSwapchainFormats(session, count, &count, formats.data()), "formats");
        const char *format_name=std::getenv("METEOR_XR_SOURCE_FORMAT");
        if(!format_name) format_name="rgba8";
        if(!std::strcmp(format_name,"rgba8")) source_format=VK_FORMAT_R8G8B8A8_UNORM;
        else if(!std::strcmp(format_name,"bgra8")) source_format=VK_FORMAT_B8G8R8A8_UNORM;
        else if(!std::strcmp(format_name,"rgba8-srgb")) source_format=VK_FORMAT_R8G8B8A8_SRGB;
        else if(!std::strcmp(format_name,"bgra8-srgb")) source_format=VK_FORMAT_B8G8R8A8_SRGB;
        else { std::fprintf(stderr,"Unknown source format\n"); std::exit(1); }
        if(source_format!=VK_FORMAT_R8G8B8A8_UNORM && std::getenv("METEOR_XR_GPU_SCENE_SHADER")) {
            std::fprintf(stderr,"Alternate formats require reference pattern renderer\n"); std::exit(1);
        }
        bool supported = false;
        for (auto format : formats) if (format == source_format) supported = true;
        if (!supported) { std::fprintf(stderr, "Requested source format unavailable\n"); std::exit(1); }
        std::printf("APP_SOURCE_FORMAT name=%s value=%d\n",format_name,int(source_format));
        array_stereo=std::getenv("METEOR_XR_ARRAY_STEREO")!=nullptr;
        if(array_stereo) {
            if(std::getenv("METEOR_XR_GPU_SCENE_SHADER")) {
                std::fprintf(stderr,"Array fixture requires reference renderer\n"); std::exit(1);
            }
            slices[0]=1; slices[1]=0; // Deliberately reversed to catch hardcoded eye indices.
        }
        for (int eye = 0; eye < 2; ++eye) {
            bool padded=std::getenv("METEOR_XR_PADDED_SUBRECT")!=nullptr;
            if(padded && std::getenv("METEOR_XR_GPU_SCENE_SHADER")) {
                std::fprintf(stderr,"Padded subrect diagnostic requires reference pattern renderer\n"); std::exit(1);
            }
            if(padded) { offsets[eye][0]=eye==0 ? 8 : 12; offsets[eye][1]=eye==0 ? 12 : 8; }
            if(array_stereo && eye==1) {
                chains[1]=chains[0]; images[1]=images[0]; initialized[1].resize(images[1].size(),false);
                std::printf("APP_EYE_ARRAY shared=1 slices=1,0\n");
                if(padded) std::printf("APP_EYE_SUBRECT eye=1 source=%ux%u offset=%d,%d extent=%ux%u\n",
                    width+32,height+32,offsets[1][0],offsets[1][1],width,height);
                continue;
            }
            XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
            info.format = source_format;
            info.sampleCount = 1; info.width = width; info.height = height; info.faceCount = 1; info.arraySize = 1; info.mipCount = 1;
            if(padded) { info.width+=32; info.height+=32; }
            if(array_stereo) info.arraySize=2;
            if(padded) std::printf("APP_EYE_SUBRECT eye=%d source=%ux%u offset=%d,%d extent=%ux%u\n",
                eye,info.width,info.height,offsets[eye][0],offsets[eye][1],width,height);
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
        buffer_info.size = width * height * 4; buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        vk_check(vkCreateBuffer(device, &buffer_info, nullptr, &buffer), "readback buffer");
        VkMemoryRequirements requirements; vkGetBufferMemoryRequirements(device, buffer, &requirements);
        VkPhysicalDeviceMemoryProperties props; vkGetPhysicalDeviceMemoryProperties(gpu, &props);
        uint32_t type = props.memoryTypeCount;
        for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
            VkMemoryPropertyFlags required = measurement ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT :
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
            if ((requirements.memoryTypeBits & (1u << i)) && (props.memoryTypes[i].propertyFlags & required) == required) {
                if(type==props.memoryTypeCount) type=i;
                if(props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) { type=i; break; }
            }
        }
        if (type == props.memoryTypeCount) { std::fprintf(stderr, "No readback memory\n"); std::exit(1); }
        VkMemoryAllocateInfo memory_info{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        memory_info.allocationSize = requirements.size; memory_info.memoryTypeIndex = type;
        vk_check(vkAllocateMemory(device, &memory_info, nullptr, &memory), "readback allocation");
        vk_check(vkBindBufferMemory(device, buffer, memory, 0), "bind readback");
        if (const char *shader=std::getenv("METEOR_XR_GPU_SCENE_SHADER")) {
            if (!std::getenv("METEOR_XR_TRACKED_SCENE")) { std::fprintf(stderr,"GPU scene requires tracked scene mode\n"); std::exit(1); }
            if(const char *directory=std::getenv("METEOR_XR_RASTER_SCENE")) {
                if(!measurement) { std::fprintf(stderr,"Raster scene requires explicit measurement mode\n"); std::exit(1); }
                raster_scene=new MeteorRasterScene(gpu,device,width,height,images,directory);
                std::printf("APP_RASTER_SCENE enabled=1 cubes=25 depth_test=1\n");
            } else gpu_scene=new MeteorGpuScene(device,buffer,shader);
            std::printf("APP_GPU_SCENE enabled=1 reference_validation=%d\n",measurement ? 0 : 1);
        }
        if(measurement) {
            VkFenceCreateInfo fence_info{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
            vk_check(vkCreateFence(device,&fence_info,nullptr,&completion),"scene completion fence");
            VkPhysicalDeviceProperties properties; vkGetPhysicalDeviceProperties(gpu,&properties);
            timestamp_period=properties.limits.timestampPeriod;
            uint32_t families=0; vkGetPhysicalDeviceQueueFamilyProperties(gpu,&families,nullptr);
            std::vector<VkQueueFamilyProperties> queues(families);
            vkGetPhysicalDeviceQueueFamilyProperties(gpu,&families,queues.data());
            timestamp_bits=queues.at(family).timestampValidBits;
            if(!timestamp_bits || !properties.limits.timestampComputeAndGraphics) {
                std::fprintf(stderr,"GPU scene measurement requires compute timestamps\n"); std::exit(1);
            }
            VkQueryPoolCreateInfo query{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
            query.queryType=VK_QUERY_TYPE_TIMESTAMP; query.queryCount=2;
            vk_check(vkCreateQueryPool(device,&query,nullptr,&timestamps),"scene timestamps");
        }
    }

    void measure(int eye,uint32_t index,const XrView &view,uint32_t frame) {
        MeteorSceneCamera camera(view);
        auto start=std::chrono::steady_clock::now();
        vk_check(vkResetCommandBuffer(command,0),"reset GPU scene command");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        vk_check(vkBeginCommandBuffer(command,&begin),"begin GPU scene command");
        vkCmdResetQueryPool(command,timestamps,0,2);
        vkCmdWriteTimestamp(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,timestamps,0);
        if(raster_scene) {
            VkImageMemoryBarrier image{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
            image.oldLayout=initialized[eye][index] ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
            image.newLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            image.srcQueueFamilyIndex=image.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
            image.image=images[eye][index].image; image.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
            image.srcAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
            image.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                0,0,nullptr,0,nullptr,1,&image);
            raster_scene->render(command,index+(eye ? images[0].size() : 0),camera,frame);
        } else {
        gpu_scene->render(command,camera,width,height);
        VkBufferMemoryBarrier ready{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        ready.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; ready.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        ready.srcQueueFamilyIndex=ready.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        ready.buffer=buffer; ready.size=VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,0,nullptr,1,&ready,0,nullptr);
        VkImageMemoryBarrier image{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        image.oldLayout=initialized[eye][index] ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
        image.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        image.srcQueueFamilyIndex=image.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        image.image=images[eye][index].image; image.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        image.srcAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
        image.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,0,nullptr,0,nullptr,1,&image);
        VkBufferImageCopy copy{}; copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.imageExtent={width,height,1};
        vkCmdCopyBufferToImage(command,buffer,image.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);
        image.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; image.newLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        image.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
        image.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,0,nullptr,0,nullptr,1,&image);
        }
        vkCmdWriteTimestamp(command,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,timestamps,1);
        vk_check(vkEndCommandBuffer(command),"end GPU scene command");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        vk_check(vkQueueSubmit(queue,1,&submit,completion),"submit GPU scene");
        // Keep single-buffer ownership explicit. No readback or queue-wide idle.
        vk_check(vkWaitForFences(device,1,&completion,VK_TRUE,1000000000),"wait GPU scene completion");
        uint64_t ticks[2];
        vk_check(vkGetQueryPoolResults(device,timestamps,0,2,sizeof(ticks),ticks,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT),"GPU scene timestamps");
        uint64_t mask=timestamp_bits==64 ? UINT64_MAX : (uint64_t(1)<<timestamp_bits)-1;
        double gpu_us=double((ticks[1]-ticks[0])&mask)*timestamp_period/1000.;
        vk_check(vkResetFences(device,1,&completion),"reset scene fence");
        initialized[eye][index]=true;
        auto wall_us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count();
        std::printf("APP_GPU_EYE gpu_us=%.3f submit_wait_us=%lld\n",gpu_us,(long long)wall_us);
    }

    void write(int eye, int frame, const XrView *view = nullptr) {
        auto stamp=std::chrono::steady_clock::now();
        auto elapsed=[&]() { auto now=std::chrono::steady_clock::now(); auto us=std::chrono::duration_cast<std::chrono::microseconds>(now-stamp).count(); stamp=now; return us; };
        uint32_t index;
        XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        if(array_stereo && eye==1) index=shared_index;
        else {
            check(xrAcquireSwapchainImage(chains[eye], &acquire, &index), "acquire eye");
            if(array_stereo) shared_index=index;
        }
        XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = 1000000000;
        auto waited = (array_stereo && eye==1) ? XR_SUCCESS : xrWaitSwapchainImage(chains[eye], &wait);
        if (waited != XR_SUCCESS) { std::fprintf(stderr, "Eye wait incomplete: %d\n", waited); std::exit(1); }
        auto wait_us=elapsed();
        if(measurement) {
            if(!view) { std::fprintf(stderr,"Missing measured view\n"); std::exit(1); }
            measure(eye,index,*view,uint32_t(frame));
            XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            check(xrReleaseSwapchainImage(chains[eye],&release),"release measured eye");
            return;
        }
        const int green = std::getenv("METEOR_CONTINUOUS_FRAMES") ? (frame * 73) % 256 : static_cast<int>(frame * 255 / 4.f + .5f);
        void *upload;
        vk_check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &upload), "map upload");
        auto *input = static_cast<unsigned char *>(upload);
        XrView identity{XR_TYPE_VIEW}; identity.pose.orientation.w=1;
        MeteorSceneCamera camera(view ? *view : identity);
        for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
            uint32_t p = (y * width + x) * 4;
            input[p] = eye == 0 ? (x < width/2 ? 255 : 128) : 0;
            input[p+1] = green;
            input[p+2] = eye == 1 ? (y < height/2 ? 255 : 128) : 0;
            input[p+3] = 255;
            if(view) {
                auto color=meteor_scene(camera,(x+.5f)/width,(y+.5f)/height);
                input[p]=uint8_t(std::clamp(color.x,0.f,1.f)*255);
                input[p+1]=uint8_t(std::clamp(color.y,0.f,1.f)*255);
                input[p+2]=uint8_t(std::clamp(color.z,0.f,1.f)*255);
            }
            if(quad_texture) {
                const bool cylinder=std::getenv("METEOR_XR_CYLINDER_FIXTURE")!=nullptr;
                input[p]=cylinder ? uint8_t((p/4%width)*255/(width-1)) : 0;
                input[p+1]=255;
                if(std::getenv("METEOR_XR_STACK_FIXTURE") && (frame/4)%10==5) input[p+1]=128;
                input[p+2]=cylinder ? uint8_t((p/4/width)*255/(height-1)) : 0;
                input[p+3]=128;
            }
            else if(fixed_background) input[p+1]=64;
        }
        std::vector<unsigned char> expected(input,input+width*height*4);
        if(meteor_eye_format_bgra(source_format)) for(uint32_t p=0;p<width*height;++p) std::swap(input[p*4],input[p*4+2]);
        vkUnmapMemory(device, memory);
        auto generate_us=elapsed();
        vk_check(vkResetCommandBuffer(command, 0), "reset command");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        vk_check(vkBeginCommandBuffer(command, &begin), "begin command");
        if(gpu_scene) {
            gpu_scene->render(command,camera,width,height);
            VkBufferMemoryBarrier rendered{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            rendered.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; rendered.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
            rendered.srcQueueFamilyIndex=rendered.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
            rendered.buffer=buffer; rendered.size=VK_WHOLE_SIZE;
            vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,1,&rendered,0,nullptr);
        }
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout = initialized[eye][index] ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = images[eye][index].image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        barrier.subresourceRange.baseArrayLayer=slices[eye];
        barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        // Asymmetric per-eye spatial pattern detects flips as well as eye swaps.
        VkBufferMemoryBarrier uploaded{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        uploaded.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; uploaded.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        uploaded.srcQueueFamilyIndex = uploaded.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        uploaded.buffer = buffer; uploaded.size = VK_WHOLE_SIZE;
        if(!gpu_scene) vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 1, &uploaded, 0, nullptr);
        VkBufferImageCopy copy{}; copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}; copy.imageExtent = {width, height, 1};
        copy.imageSubresource.baseArrayLayer=slices[eye];
        copy.imageOffset={offsets[eye][0],offsets[eye][1],0};
        if(offsets[eye][0] || offsets[eye][1]) {
            VkClearColorValue padding{{1.f,0.f,1.f,1.f}};
            vkCmdClearColorImage(command,barrier.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&padding,1,&barrier.subresourceRange);
            VkImageMemoryBarrier clear_to_copy=barrier;
            clear_to_copy.oldLayout=clear_to_copy.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            clear_to_copy.srcAccessMask=clear_to_copy.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
            vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&clear_to_copy);
        }
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
        auto submit_us=elapsed();
        void *mapped; vk_check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped), "map readback");
        // Never repeatedly walk potentially uncached GPU-mapped memory while
        // checking pixels/extracting RGB. Snapshot once into ordinary host RAM.
        std::vector<unsigned char> readback(width*height*4);
        std::memcpy(readback.data(),mapped,readback.size());
        if(meteor_eye_format_bgra(source_format)) for(uint32_t p=0;p<width*height;++p) std::swap(readback[p*4],readback[p*4+2]);
        const auto *pixels = readback.data();
        if((quad_texture || fixed_background) && std::memcmp(pixels,expected.data(),expected.size())) {
            std::fprintf(stderr,"Quad fixture readback mismatch\n"); std::exit(1);
        }
        if(view) {
            if(gpu_scene) {
                // Float arithmetic can move a silhouette/floor boundary by a pixel.
                // Bound both total error and the fraction of large differences.
                uint64_t error=0,large=0;
                for(size_t p=0;p<expected.size();++p) {
                    int delta=std::abs(int(pixels[p])-int(expected[p])); error+=delta; large+=delta>3;
                }
                if(error>expected.size() || large*1000>expected.size()*2) {
                    std::fprintf(stderr,"GPU scene differs from independent CPU oracle: error=%llu large=%llu\n",
                        (unsigned long long)error,(unsigned long long)large); std::exit(1);
                }
            } else if(std::memcmp(pixels,expected.data(),expected.size())) { std::fprintf(stderr,"Scene readback mismatch\n"); std::exit(1); }
            std::ofstream reference(meteor_probe_path(eye==0 ? "scene-left.rgb" : "scene-right.rgb"),
                std::ios::binary | (frame==0 ? std::ios::trunc : std::ios::app));
            std::vector<unsigned char> rgb(width*height*3);
            for(uint32_t p=0;p<width*height;++p) std::memcpy(rgb.data()+p*3,pixels+p*4,3);
            reference.write(reinterpret_cast<const char *>(rgb.data()),rgb.size());
            if(!reference) { std::fprintf(stderr,"Cannot write scene reference\n"); std::exit(1); }
        }
        for (uint32_t p = 0; p < width * height; ++p) {
            if (!view && !quad_texture && !fixed_background && (pixels[p*4] != (eye == 0 ? (p % width < width/2 ? 255 : 128) : 0) ||
                pixels[p*4+2] != (eye == 1 ? (p / width < height/2 ? 255 : 128) : 0) ||
                std::abs(static_cast<int>(pixels[p*4+1]) - green) > 1 || pixels[p*4+3] != 255)) {
                std::fprintf(stderr, "Eye %d frame %d pixel %u mismatch\n", eye, frame, p); std::exit(1);
            }
        }
        if (frame == 4) {
            std::ofstream out(meteor_probe_path(eye == 0 ? "eye-left.ppm" : "eye-right.ppm"), std::ios::binary);
            out << "P6\n" << width << ' ' << height << "\n255\n";
            std::vector<unsigned char> rgb(width*height*3);
            for (uint32_t p=0;p<width*height;++p) std::memcpy(rgb.data()+p*3,pixels+p*4,3);
            out.write(reinterpret_cast<const char *>(rgb.data()),rgb.size());
            if (!out) { std::fprintf(stderr, "Cannot write eye artifact\n"); std::exit(1); }
        }
        vkUnmapMemory(device, memory); initialized[eye][index] = true;
        auto verify_us=elapsed();
        XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        if(!array_stereo || eye==1) check(xrReleaseSwapchainImage(chains[eye], &release), "release eye");
        std::printf("APP_EYE wait_us=%lld generate_us=%lld submit_readback_us=%lld verify_artifact_us=%lld release_us=%lld\n",
            (long long)wait_us,(long long)generate_us,(long long)submit_us,(long long)verify_us,(long long)elapsed());
    }

    void destroy() {
        delete raster_scene;
        if(timestamps) vkDestroyQueryPool(device,timestamps,nullptr);
        if(completion) vkDestroyFence(device,completion,nullptr);
        delete gpu_scene;
        vkDestroyBuffer(device, buffer, nullptr); vkFreeMemory(device, memory, nullptr);
        vkDestroyCommandPool(device, pool, nullptr);
        for (int eye=0;eye<(array_stereo ? 1 : 2);++eye) check(xrDestroySwapchain(chains[eye]), "destroy eye swapchain");
    }
};
