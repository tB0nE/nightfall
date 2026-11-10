// Checks the Windows AMF PCVR path without Monado: a Vulkan device on the AMD GPU writes a
// test pattern into the D3D11 texture it shares with AMF, which encodes it.
//   meteor-amf-encode-test <h264|h265> <width> <height> <frames> <out.bitstream>
// Prints the encoder's largest frame and one line per packet; exits 0 on success.
#define VK_USE_PLATFORM_WIN32_KHR
#include "meteor_amf_vulkan.h"
#include <fstream>
#include <vector>

#define CHECK(test,msg) do { if(!(test)) { std::fprintf(stderr,"FAIL: %s\n",msg); return 1; } } while(0)

int main(int argc,char **argv) {
    CHECK(argc==6,"usage: meteor-amf-encode-test <h264|h265> <width> <height> <frames> <out>");
    const bool hevc=!std::strcmp(argv[1],"h265");
    const uint32_t width=uint32_t(std::atoi(argv[2])),height=uint32_t(std::atoi(argv[3])),frames=uint32_t(std::atoi(argv[4]));
    uint32_t max_w=0,max_h=0; meteor_amf_max_frame(hevc,max_w,max_h);
    std::printf("max_frame=%ux%u\n",max_w,max_h);

    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo ii{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ii.pApplicationInfo=&app;
    VkInstance instance; CHECK(vkCreateInstance(&ii,nullptr,&instance)==VK_SUCCESS,"vkCreateInstance");
    uint32_t count=0; vkEnumeratePhysicalDevices(instance,&count,nullptr);
    std::vector<VkPhysicalDevice> gpus(count); vkEnumeratePhysicalDevices(instance,&count,gpus.data());
    VkPhysicalDevice gpu=VK_NULL_HANDLE;
    for(auto candidate:gpus) {
        VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(candidate,&p);
        if(p.vendorID==0x1002) { gpu=candidate; std::printf("gpu=%s\n",p.deviceName); break; }
    }
    CHECK(gpu,"No AMD Vulkan device");
    uint32_t families=0; vkGetPhysicalDeviceQueueFamilyProperties(gpu,&families,nullptr);
    std::vector<VkQueueFamilyProperties> queues(families); vkGetPhysicalDeviceQueueFamilyProperties(gpu,&families,queues.data());
    uint32_t family=families;
    for(uint32_t i=0;i<families;++i) if(queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT) { family=i; break; }
    CHECK(family<families,"No graphics queue");
    float priority=1;
    VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
    const char *extensions[]={VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME};
    VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;
    di.enabledExtensionCount=1; di.ppEnabledExtensionNames=extensions;
    VkDevice device; CHECK(vkCreateDevice(gpu,&di,nullptr,&device)==VK_SUCCESS,"vkCreateDevice");
    VkQueue queue; vkGetDeviceQueue(device,family,0,&queue);

    MeteorAmfVulkanShare share;
    if(!share.open(gpu,device,width,height)) { std::fprintf(stderr,"FAIL: %s\n",share.error.c_str()); return 1; }
    MeteorAmfEncoder amf;
    amf.attach(share.d3d.Get(),share.texture.Get(),width,height,amf::AMF_SURFACE_RGBA);
    std::puts("import=ok");
    if(!amf.start(hevc,72,20000000,false)) { std::fprintf(stderr,"FAIL: %s\n",amf.error.c_str()); return 1; }
    std::puts("encoder=ok");

    VkCommandPoolCreateInfo pci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pci.queueFamilyIndex=family;
    pci.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool pool; vkCreateCommandPool(device,&pci,nullptr,&pool);
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; cai.commandPool=pool; cai.commandBufferCount=1;
    VkCommandBuffer cmd; vkAllocateCommandBuffers(device,&cai,&cmd);
    std::ofstream out(argv[5],std::ios::binary);
    for(uint32_t frame=0;frame<frames;++frame) {
        vkResetCommandBuffer(cmd,0);
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; vkBeginCommandBuffer(cmd,&begin);
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED; barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL; barrier.dstQueueFamilyIndex=family;
        barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.image=share.image;
        barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
        // Solid red: the decoded frame shows whether colour survives the RGBA -> NV12 trip.
        VkClearColorValue red{{1,0,0,1}};
        VkImageSubresourceRange range{VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdClearColorImage(cmd,share.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&red,1,&range);
        barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout=VK_IMAGE_LAYOUT_GENERAL;
        barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=0;
        barrier.srcQueueFamilyIndex=family; barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL;
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,0,nullptr,1,&barrier);
        vkEndCommandBuffer(cmd);
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&cmd;
        CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE)==VK_SUCCESS,"vkQueueSubmit");
        vkQueueWaitIdle(queue);
        const auto start=std::chrono::steady_clock::now();
        const bool ok=amf.encode(frame==0,frame,[&](const uint8_t *data,uint32_t size) {
            out.write(reinterpret_cast<const char *>(data),size);
            std::printf("packet frame=%u bytes=%u us=%lld\n",frame,size,(long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count());
            return true;
        });
        if(!ok) { std::fprintf(stderr,"FAIL: %s\n",amf.error.c_str()); return 1; }
    }
    out.close();
    vkDeviceWaitIdle(device);
    amf.destroy();
    share.destroy();
    vkDestroyCommandPool(device,pool,nullptr); vkDestroyDevice(device,nullptr); vkDestroyInstance(instance,nullptr);
    std::puts("PASS");
    return 0;
}
