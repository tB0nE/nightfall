#pragma once
#include <vulkan/vulkan.h>
#include <sstream>
// Tiny static image: enough presentation to give the diagnostic real XR focus.
struct ProbeTexture {
    VkInstance instance{}; VkPhysicalDevice gpu{}; VkDevice device{}; VkQueue queue{};
    VkImage image{}; VkDeviceMemory memory{}; VkCommandPool pool{}; uint32_t family=0;
    vr::VRVulkanTextureData_t data{};
    ProbeTexture(vr::IVRCompositor *compositor) {
        char required[8192]{};
        require(compositor->GetVulkanInstanceExtensionsRequired(required,sizeof(required))<sizeof(required),"instance extension list");
        auto extensions=[](const char *text) {
            std::istringstream words(text); std::vector<std::string> result; std::string word;
            while(words>>word) result.push_back(word);
            return result;
        };
        auto instance_extensions=extensions(required); std::vector<const char *> instance_names;
        for(const auto &name:instance_extensions) instance_names.push_back(name.c_str());
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion=VK_API_VERSION_1_1;
        VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ci.pApplicationInfo=&app;
        ci.enabledExtensionCount=uint32_t(instance_names.size()); ci.ppEnabledExtensionNames=instance_names.data();
        require(vkCreateInstance(&ci,nullptr,&instance)==VK_SUCCESS,"probe Vulkan instance");
        uint32_t count=1; require(vkEnumeratePhysicalDevices(instance,&count,&gpu)==VK_SUCCESS && count,"probe GPU");
        vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr);
        std::vector<VkQueueFamilyProperties> queues(count); vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,queues.data());
        while(family<count && !(queues[family].queueFlags&VK_QUEUE_GRAPHICS_BIT)) ++family;
        require(family<count,"probe graphics queue");
        float priority=1; VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
        VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;
        require(compositor->GetVulkanDeviceExtensionsRequired(gpu,required,sizeof(required))<sizeof(required),"device extension list");
        auto device_extensions=extensions(required); std::vector<const char *> device_names;
        for(const auto &name:device_extensions) device_names.push_back(name.c_str());
        di.enabledExtensionCount=uint32_t(device_names.size()); di.ppEnabledExtensionNames=device_names.data();
        require(vkCreateDevice(gpu,&di,nullptr,&device)==VK_SUCCESS,"probe Vulkan device");
        vkGetDeviceQueue(device,family,0,&queue);
        VkImageCreateInfo ii{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ii.imageType=VK_IMAGE_TYPE_2D;
        ii.format=VK_FORMAT_R8G8B8A8_UNORM; ii.extent={256,256,1}; ii.mipLevels=ii.arrayLayers=1;
        ii.samples=VK_SAMPLE_COUNT_1_BIT; ii.tiling=VK_IMAGE_TILING_OPTIMAL;
        ii.usage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_SAMPLED_BIT;
        require(vkCreateImage(device,&ii,nullptr,&image)==VK_SUCCESS,"probe image");
        VkMemoryRequirements req; vkGetImageMemoryRequirements(device,image,&req);
        VkPhysicalDeviceMemoryProperties props; vkGetPhysicalDeviceMemoryProperties(gpu,&props);
        uint32_t type=0; while(type<props.memoryTypeCount && !(req.memoryTypeBits&(1u<<type))) ++type;
        require(type<props.memoryTypeCount,"probe memory type");
        VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=req.size; ai.memoryTypeIndex=type;
        require(vkAllocateMemory(device,&ai,nullptr,&memory)==VK_SUCCESS,"probe memory");
        require(vkBindImageMemory(device,image,memory,0)==VK_SUCCESS,"bind probe image");
        VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.queueFamilyIndex=family;
        require(vkCreateCommandPool(device,&pi,nullptr,&pool)==VK_SUCCESS,"probe command pool");
        VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; ca.commandPool=pool;
        ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount=1; VkCommandBuffer command;
        require(vkAllocateCommandBuffers(device,&ca,&command)==VK_SUCCESS,"probe command buffer");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        require(vkBeginCommandBuffer(command,&begin)==VK_SUCCESS,"probe commands");
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; barrier.image=image;
        barrier.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED; barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}; barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
        VkClearColorValue color{{.1f,.1f,.1f,1.f}};
        vkCmdClearColorImage(command,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&color,1,&barrier.subresourceRange);
        barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
        require(vkEndCommandBuffer(command)==VK_SUCCESS,"end probe commands");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        require(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE)==VK_SUCCESS,"submit probe commands");
        require(vkQueueWaitIdle(queue)==VK_SUCCESS,"wait probe commands");
        data.m_nImage=reinterpret_cast<uint64_t>(image); data.m_pDevice=device; data.m_pPhysicalDevice=gpu;
        data.m_pInstance=instance; data.m_pQueue=queue; data.m_nQueueFamilyIndex=family;
        data.m_nWidth=data.m_nHeight=256; data.m_nFormat=VK_FORMAT_R8G8B8A8_UNORM; data.m_nSampleCount=1;
    }
    void submit(vr::IVRCompositor *compositor) {
        vr::Texture_t texture{&data,vr::TextureType_Vulkan,vr::ColorSpace_Auto};
        require(compositor->Submit(vr::Eye_Left,&texture)==vr::VRCompositorError_None,"submit left probe eye");
        require(compositor->Submit(vr::Eye_Right,&texture)==vr::VRCompositorError_None,"submit right probe eye");
    }
    ~ProbeTexture() {
        vkDeviceWaitIdle(device); vkDestroyCommandPool(device,pool,nullptr);
        vkDestroyImage(device,image,nullptr); vkFreeMemory(device,memory,nullptr);
        vkDestroyDevice(device,nullptr); vkDestroyInstance(instance,nullptr);
    }
};
