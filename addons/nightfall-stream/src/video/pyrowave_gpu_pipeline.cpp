#include "pyrowave_gpu_pipeline.h"

#ifdef __ANDROID__

#include "texture_uploader.h"
#include "nf_log.h"

#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <vector>

namespace {

const uint32_t kYuvToRgbaSpv[] =
#include "pyrowave_yuv_to_rgba.spv.h"
;

constexpr const char *kTag = "PyrowaveGpu";

// The API-28 libvulkan stub only exports Vulkan 1.0/1.1 symbols; everything newer
// (and every extension entry point) comes through vkGetDeviceProcAddr.
struct VkGlobals {
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t queue_family = 0;

    PFN_vkCmdPipelineBarrier2 CmdPipelineBarrier2 = nullptr;
    PFN_vkGetSemaphoreFdKHR GetSemaphoreFdKHR = nullptr;
    PFN_vkImportSemaphoreFdKHR ImportSemaphoreFdKHR = nullptr;
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID GetAndroidHardwareBufferPropertiesANDROID = nullptr;

    // pyrowave_create_device() requires these to outlive the pyrowave_device,
    // which lives for the whole app.
    VkApplicationInfo app_info = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    VkInstanceCreateInfo instance_info = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    VkPhysicalDeviceFeatures2 features2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    VkPhysicalDeviceVulkan11Features features11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
    VkPhysicalDeviceVulkan12Features features12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    VkPhysicalDeviceVulkan13Features features13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    std::vector<const char *> device_extensions;
    VkDeviceCreateInfo device_info = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    pyrowave_device_create_queue_info pyro_queue = {};

    bool ready = false;
};

VkGlobals g_vk;

uint32_t find_memory_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(g_vk.gpu, &props);
    for (uint32_t i = 0; i < props.memoryTypeCount; i++) {
        if ((bits & (1u << i)) && (props.memoryTypes[i].propertyFlags & want) == want) return i;
    }
    for (uint32_t i = 0; i < props.memoryTypeCount; i++) {
        if (bits & (1u << i)) return i;
    }
    return UINT32_MAX;
}

VkImageMemoryBarrier2 image_barrier(VkImage image,
                                    VkPipelineStageFlags2 src_stage, VkAccessFlags2 src_access,
                                    VkPipelineStageFlags2 dst_stage, VkAccessFlags2 dst_access,
                                    VkImageLayout old_layout, VkImageLayout new_layout,
                                    uint32_t src_family = VK_QUEUE_FAMILY_IGNORED,
                                    uint32_t dst_family = VK_QUEUE_FAMILY_IGNORED) {
    VkImageMemoryBarrier2 b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2 };
    b.srcStageMask = src_stage;
    b.srcAccessMask = src_access;
    b.dstStageMask = dst_stage;
    b.dstAccessMask = dst_access;
    b.oldLayout = old_layout;
    b.newLayout = new_layout;
    b.srcQueueFamilyIndex = src_family;
    b.dstQueueFamilyIndex = dst_family;
    b.image = image;
    b.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    return b;
}

void barriers(VkCommandBuffer cmd, const VkImageMemoryBarrier2 *b, uint32_t count) {
    VkDependencyInfo dep = { VK_STRUCTURE_TYPE_DEPENDENCY_INFO };
    dep.imageMemoryBarrierCount = count;
    dep.pImageMemoryBarriers = b;
    g_vk.CmdPipelineBarrier2(cmd, &dep);
}

VkImageView make_view(VkImage image, VkFormat format) {
    VkImageViewCreateInfo info = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    info.image = image;
    info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    info.format = format;
    info.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    VkImageView view = VK_NULL_HANDLE;
    vkCreateImageView(g_vk.device, &info, nullptr, &view);
    return view;
}

void wait_and_close_fd(int fd) {
    if (fd < 0) return;
    pollfd p = { fd, POLLIN, 0 };
    poll(&p, 1, 1000);
    close(fd);
}

void destroy_vk_device() {
    if (g_vk.device) vkDestroyDevice(g_vk.device, nullptr);
    if (g_vk.instance) vkDestroyInstance(g_vk.instance, nullptr);
    g_vk = VkGlobals{};
}

} // namespace

namespace godot {

pyrowave_device pyrowave_gpu_create_device() {
    if (g_vk.ready) return nullptr;

    g_vk.app_info.pApplicationName = "nightfall-pyrowave";
    g_vk.app_info.apiVersion = VK_API_VERSION_1_3;
    g_vk.instance_info.pApplicationInfo = &g_vk.app_info;
    if (vkCreateInstance(&g_vk.instance_info, nullptr, &g_vk.instance) != VK_SUCCESS) {
        NF_LOGE(kTag, "vkCreateInstance failed");
        destroy_vk_device();
        return nullptr;
    }

    uint32_t gpu_count = 1;
    if (vkEnumeratePhysicalDevices(g_vk.instance, &gpu_count, &g_vk.gpu) < 0 || !gpu_count) {
        NF_LOGE(kTag, "No Vulkan physical device");
        destroy_vk_device();
        return nullptr;
    }

    VkPhysicalDeviceProperties gpu_props;
    vkGetPhysicalDeviceProperties(g_vk.gpu, &gpu_props);
    if (gpu_props.apiVersion < VK_API_VERSION_1_3) {
        NF_LOGE(kTag, "Vulkan 1.3 required, device reports %u.%u",
                VK_VERSION_MAJOR(gpu_props.apiVersion), VK_VERSION_MINOR(gpu_props.apiVersion));
        destroy_vk_device();
        return nullptr;
    }

    uint32_t family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_vk.gpu, &family_count, nullptr);
    std::vector<VkQueueFamilyProperties> families(family_count);
    vkGetPhysicalDeviceQueueFamilyProperties(g_vk.gpu, &family_count, families.data());
    constexpr VkQueueFlags kNeeded = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    g_vk.queue_family = UINT32_MAX;
    for (uint32_t i = 0; i < family_count; i++) {
        if ((families[i].queueFlags & kNeeded) == kNeeded) {
            g_vk.queue_family = i;
            break;
        }
    }
    if (g_vk.queue_family == UINT32_MAX) {
        NF_LOGE(kTag, "No graphics+compute queue family");
        destroy_vk_device();
        return nullptr;
    }

    // PyroWave's decoder needs subgroup size control and synchronization2 among
    // others; enable everything the driver offers except the robustness features
    // (measurable cost, nothing here needs them) and protected memory.
    g_vk.features2.pNext = &g_vk.features11;
    g_vk.features11.pNext = &g_vk.features12;
    g_vk.features12.pNext = &g_vk.features13;
    vkGetPhysicalDeviceFeatures2(g_vk.gpu, &g_vk.features2);
    g_vk.features2.features.robustBufferAccess = VK_FALSE;
    g_vk.features13.robustImageAccess = VK_FALSE;
    g_vk.features11.protectedMemory = VK_FALSE;

    uint32_t ext_count = 0;
    vkEnumerateDeviceExtensionProperties(g_vk.gpu, nullptr, &ext_count, nullptr);
    std::vector<VkExtensionProperties> available(ext_count);
    vkEnumerateDeviceExtensionProperties(g_vk.gpu, nullptr, &ext_count, available.data());
    for (const char *wanted : { VK_ANDROID_EXTERNAL_MEMORY_ANDROID_HARDWARE_BUFFER_EXTENSION_NAME,
                                VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
                                VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME }) {
        bool found = false;
        for (auto &e : available) {
            if (!strcmp(e.extensionName, wanted)) found = true;
        }
        if (!found) {
            NF_LOGE(kTag, "Missing device extension %s", wanted);
            destroy_vk_device();
            return nullptr;
        }
        g_vk.device_extensions.push_back(wanted);
    }

    g_vk.queue_info.queueFamilyIndex = g_vk.queue_family;
    g_vk.queue_info.queueCount = 1;
    g_vk.queue_info.pQueuePriorities = &g_vk.queue_priority;
    g_vk.device_info.pNext = &g_vk.features2;
    g_vk.device_info.queueCreateInfoCount = 1;
    g_vk.device_info.pQueueCreateInfos = &g_vk.queue_info;
    g_vk.device_info.enabledExtensionCount = (uint32_t)g_vk.device_extensions.size();
    g_vk.device_info.ppEnabledExtensionNames = g_vk.device_extensions.data();
    if (vkCreateDevice(g_vk.gpu, &g_vk.device_info, nullptr, &g_vk.device) != VK_SUCCESS) {
        NF_LOGE(kTag, "vkCreateDevice failed");
        destroy_vk_device();
        return nullptr;
    }
    vkGetDeviceQueue(g_vk.device, g_vk.queue_family, 0, &g_vk.queue);

    g_vk.CmdPipelineBarrier2 = (PFN_vkCmdPipelineBarrier2)vkGetDeviceProcAddr(g_vk.device, "vkCmdPipelineBarrier2");
    g_vk.GetSemaphoreFdKHR = (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(g_vk.device, "vkGetSemaphoreFdKHR");
    g_vk.ImportSemaphoreFdKHR = (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(g_vk.device, "vkImportSemaphoreFdKHR");
    g_vk.GetAndroidHardwareBufferPropertiesANDROID = (PFN_vkGetAndroidHardwareBufferPropertiesANDROID)
        vkGetDeviceProcAddr(g_vk.device, "vkGetAndroidHardwareBufferPropertiesANDROID");
    if (!g_vk.CmdPipelineBarrier2 || !g_vk.GetSemaphoreFdKHR || !g_vk.ImportSemaphoreFdKHR ||
        !g_vk.GetAndroidHardwareBufferPropertiesANDROID) {
        NF_LOGE(kTag, "Missing Vulkan entry points");
        destroy_vk_device();
        return nullptr;
    }

    g_vk.pyro_queue = { g_vk.queue, g_vk.queue_family, 0 };
    pyrowave_device_create_info info = {};
    info.GetInstanceProcAddr = vkGetInstanceProcAddr;
    info.instance = g_vk.instance;
    info.physical_device = g_vk.gpu;
    info.device = g_vk.device;
    info.instance_create_info = &g_vk.instance_info;
    info.device_create_info = &g_vk.device_info;
    info.queue_info = &g_vk.pyro_queue;
    info.queue_info_count = 1;

    pyrowave_device device = nullptr;
    if (pyrowave_create_device(&info, &device) != PYROWAVE_SUCCESS || !device) {
        NF_LOGE(kTag, "pyrowave_create_device failed on our VkDevice");
        destroy_vk_device();
        return nullptr;
    }
    // Decode and our conversion share one graphics+compute queue and one command buffer.
    pyrowave_device_set_queue_type(device, VK_QUEUE_GRAPHICS_BIT);

    g_vk.ready = true;
    NF_LOG(kTag, "Own Vulkan device ready on %s (queue family %u)", gpu_props.deviceName, g_vk.queue_family);
    return device;
}

bool pyrowave_gpu_available() {
    return g_vk.ready;
}

PyrowaveGpuPipeline::~PyrowaveGpuPipeline() {
    destroy();
}

bool PyrowaveGpuPipeline::create_plane(int index, uint32_t w, uint32_t h) {
    VkImageCreateInfo info = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = VK_FORMAT_R8_UNORM;
    info.extent = { w, h, 1 };
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                 (fragment_path_ ? VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT : VK_IMAGE_USAGE_STORAGE_BIT);
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(g_vk.device, &info, nullptr, &planes_[index]) != VK_SUCCESS) return false;

    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(g_vk.device, planes_[index], &req);
    VkMemoryAllocateInfo alloc = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = find_memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (alloc.memoryTypeIndex == UINT32_MAX) return false;
    if (vkAllocateMemory(g_vk.device, &alloc, nullptr, &plane_memory_[index]) != VK_SUCCESS) return false;
    if (vkBindImageMemory(g_vk.device, planes_[index], plane_memory_[index], 0) != VK_SUCCESS) return false;

    plane_views_[index] = make_view(planes_[index], VK_FORMAT_R8_UNORM);
    if (!plane_views_[index]) return false;

    // Same view description pyrowave_decoder_decode_cpu_buffer_synchronous() builds
    // for its own internal planes.
    auto &view = plane_buffers_.planes[index];
    view.image = planes_[index];
    view.width = w;
    view.height = h;
    view.image_format = VK_FORMAT_R8_UNORM;
    view.view_format = VK_FORMAT_R8_UNORM;
    view.aspect = VK_IMAGE_ASPECT_COLOR_BIT;
    view.swizzle = VK_COMPONENT_SWIZZLE_IDENTITY;
    view.layout = fragment_path_ ? VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_GENERAL;
    return true;
}

bool PyrowaveGpuPipeline::create_slot(Slot &slot) {
    AHardwareBuffer_Desc desc = {};
    desc.width = width_;
    desc.height = height_;
    desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    desc.usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER;
    int alloc_result = AHardwareBuffer_allocate(&desc, &slot.ahb);
    if (alloc_result != 0) {
        NF_LOGE(kTag, "AHardwareBuffer_allocate(%ux%u RGBA8888) failed: %d", width_, height_, alloc_result);
        return false;
    }

    VkAndroidHardwareBufferPropertiesANDROID props = { VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID };
    if (g_vk.GetAndroidHardwareBufferPropertiesANDROID(g_vk.device, slot.ahb, &props) != VK_SUCCESS) return false;

    VkExternalMemoryImageCreateInfo external = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO };
    external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
    VkImageCreateInfo info = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    info.pNext = &external;
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = VK_FORMAT_R8G8B8A8_UNORM;
    info.extent = { width_, height_, 1 };
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_STORAGE_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(g_vk.device, &info, nullptr, &slot.image) != VK_SUCCESS) return false;

    VkMemoryDedicatedAllocateInfo dedicated = { VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO };
    dedicated.image = slot.image;
    VkImportAndroidHardwareBufferInfoANDROID import = { VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID };
    import.pNext = &dedicated;
    import.buffer = slot.ahb;
    VkMemoryAllocateInfo alloc = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    alloc.pNext = &import;
    alloc.allocationSize = props.allocationSize;
    alloc.memoryTypeIndex = find_memory_type(props.memoryTypeBits, 0);
    if (alloc.memoryTypeIndex == UINT32_MAX) return false;
    if (vkAllocateMemory(g_vk.device, &alloc, nullptr, &slot.memory) != VK_SUCCESS) return false;
    if (vkBindImageMemory(g_vk.device, slot.image, slot.memory, 0) != VK_SUCCESS) return false;

    slot.view = make_view(slot.image, VK_FORMAT_R8G8B8A8_UNORM);
    if (!slot.view) return false;

    VkDescriptorSetAllocateInfo set_alloc = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    set_alloc.descriptorPool = descriptor_pool_;
    set_alloc.descriptorSetCount = 1;
    set_alloc.pSetLayouts = &set_layout_;
    if (vkAllocateDescriptorSets(g_vk.device, &set_alloc, &slot.set) != VK_SUCCESS) return false;
    write_descriptors(slot);

    VkCommandBufferAllocateInfo cmd_alloc = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cmd_alloc.commandPool = command_pool_;
    cmd_alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmd_alloc.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(g_vk.device, &cmd_alloc, &slot.cmd) != VK_SUCCESS) return false;

    VkFenceCreateInfo fence_info = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (vkCreateFence(g_vk.device, &fence_info, nullptr, &slot.fence) != VK_SUCCESS) return false;

    VkExportSemaphoreCreateInfo export_info = { VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO };
    export_info.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    VkSemaphoreCreateInfo sem_info = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    sem_info.pNext = &export_info;
    if (vkCreateSemaphore(g_vk.device, &sem_info, nullptr, &slot.ready) != VK_SUCCESS) return false;
    VkSemaphoreCreateInfo plain_sem_info = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    if (vkCreateSemaphore(g_vk.device, &plain_sem_info, nullptr, &slot.released) != VK_SUCCESS) return false;
    return true;
}

void PyrowaveGpuPipeline::write_descriptors(Slot &slot) {
    VkDescriptorImageInfo images[4];
    for (int i = 0; i < 3; i++) {
        images[i] = { sampler_, plane_views_[i], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    }
    images[3] = { VK_NULL_HANDLE, slot.view, VK_IMAGE_LAYOUT_GENERAL };
    VkWriteDescriptorSet writes[4];
    for (int i = 0; i < 4; i++) {
        writes[i] = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
        writes[i].dstSet = slot.set;
        writes[i].dstBinding = (uint32_t)i;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType = i < 3 ? VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER : VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        writes[i].pImageInfo = &images[i];
    }
    vkUpdateDescriptorSets(g_vk.device, 4, writes, 0, nullptr);
}

void PyrowaveGpuPipeline::completion_loop() {
    for (;;) {
        std::pair<int, int64_t> entry;
        {
            std::unique_lock<std::mutex> lock(completion_mutex_);
            completion_cv_.wait(lock, [this] { return completion_stop_ || !completion_queue_.empty(); });
            if (completion_queue_.empty()) return;
            entry = completion_queue_.front();
            completion_queue_.pop_front();
        }
        pollfd p = { entry.first, POLLIN, 0 };
        poll(&p, 1, 2000);
        close(entry.first);
        if (on_complete_) on_complete_(entry.second);
    }
}

void PyrowaveGpuPipeline::stop_completion_thread() {
    if (!completion_thread_.joinable()) return;
    {
        std::lock_guard<std::mutex> lock(completion_mutex_);
        completion_stop_ = true;
    }
    completion_cv_.notify_all();
    completion_thread_.join();
    // Anything still queued belongs to frames being torn down; don't report them.
    for (auto &entry : completion_queue_) close(entry.first);
    completion_queue_.clear();
    completion_stop_ = false;
}

bool PyrowaveGpuPipeline::init(pyrowave_device device, pyrowave_decoder decoder, bool fragment_path,
                               int width, int height, TextureUploader *uploader,
                               FrameCompleteCallback on_complete) {
    destroy();
    if (!g_vk.ready || !uploader || width <= 0 || height <= 0 || (width & 1) || (height & 1)) return false;

    device_ = device;
    decoder_ = decoder;
    fragment_path_ = fragment_path;
    width_ = (uint32_t)width;
    height_ = (uint32_t)height;

    auto fail = [this](const char *what) {
        NF_LOGE(kTag, "init failed: %s", what);
        destroy();
        return false;
    };

    if (!create_plane(0, width_, height_) || !create_plane(1, width_ / 2, height_ / 2) ||
        !create_plane(2, width_ / 2, height_ / 2)) {
        return fail("plane images");
    }

    VkSamplerCreateInfo sampler_info = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    sampler_info.magFilter = VK_FILTER_LINEAR;
    sampler_info.minFilter = VK_FILTER_LINEAR;
    sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    if (vkCreateSampler(g_vk.device, &sampler_info, nullptr, &sampler_) != VK_SUCCESS) return fail("sampler");

    VkDescriptorSetLayoutBinding bindings[4] = {};
    for (int i = 0; i < 3; i++) {
        bindings[i] = { (uint32_t)i, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr };
    }
    bindings[3] = { 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr };
    VkDescriptorSetLayoutCreateInfo layout_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    layout_info.bindingCount = 4;
    layout_info.pBindings = bindings;
    if (vkCreateDescriptorSetLayout(g_vk.device, &layout_info, nullptr, &set_layout_) != VK_SUCCESS) {
        return fail("descriptor set layout");
    }

    VkPipelineLayoutCreateInfo pipeline_layout_info = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &set_layout_;
    if (vkCreatePipelineLayout(g_vk.device, &pipeline_layout_info, nullptr, &pipeline_layout_) != VK_SUCCESS) {
        return fail("pipeline layout");
    }

    VkShaderModuleCreateInfo module_info = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    module_info.codeSize = sizeof(kYuvToRgbaSpv);
    module_info.pCode = kYuvToRgbaSpv;
    VkShaderModule module = VK_NULL_HANDLE;
    if (vkCreateShaderModule(g_vk.device, &module_info, nullptr, &module) != VK_SUCCESS) return fail("shader module");
    VkComputePipelineCreateInfo pipeline_info = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    pipeline_info.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0,
                            VK_SHADER_STAGE_COMPUTE_BIT, module, "main", nullptr };
    pipeline_info.layout = pipeline_layout_;
    VkResult pipeline_result = vkCreateComputePipelines(g_vk.device, VK_NULL_HANDLE, 1, &pipeline_info, nullptr, &pipeline_);
    vkDestroyShaderModule(g_vk.device, module, nullptr);
    if (pipeline_result != VK_SUCCESS) return fail("compute pipeline");

    VkDescriptorPoolSize pool_sizes[2] = {
        { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 3 * kSlotCount },
        { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, kSlotCount },
    };
    VkDescriptorPoolCreateInfo pool_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    pool_info.maxSets = kSlotCount;
    pool_info.poolSizeCount = 2;
    pool_info.pPoolSizes = pool_sizes;
    if (vkCreateDescriptorPool(g_vk.device, &pool_info, nullptr, &descriptor_pool_) != VK_SUCCESS) {
        return fail("descriptor pool");
    }

    VkCommandPoolCreateInfo cmd_pool_info = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cmd_pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cmd_pool_info.queueFamilyIndex = g_vk.queue_family;
    if (vkCreateCommandPool(g_vk.device, &cmd_pool_info, nullptr, &command_pool_) != VK_SUCCESS) {
        return fail("command pool");
    }

    for (auto &slot : slots_) {
        if (!create_slot(slot)) return fail("output slot");
    }

    AHardwareBuffer *buffers[kSlotCount];
    for (int i = 0; i < kSlotCount; i++) buffers[i] = slots_[i].ahb;
    if (!uploader->setup_pyrowave_gpu_output(width, height, buffers, kSlotCount)) {
        return fail("GLES import of output ring");
    }
    uploader_ = uploader;
    on_complete_ = std::move(on_complete);
    completion_thread_ = std::thread(&PyrowaveGpuPipeline::completion_loop, this);

    NF_LOG(kTag, "Zero-copy pipeline ready: %ux%u, %s decode path, %d-slot RGBA ring",
           width_, height_, fragment_path_ ? "fragment" : "compute", kSlotCount);
    return true;
}

void PyrowaveGpuPipeline::destroy() {
    stop_completion_thread();
    on_complete_ = nullptr;
    if (uploader_) {
        uploader_->teardown_pyrowave_gpu_output();
        uploader_ = nullptr;
    }
    if (!g_vk.device) return;

    bool any = command_pool_ || sampler_ || planes_[0];
    for (auto &slot : slots_) any = any || slot.ahb;
    if (!any) return;

    vkQueueWaitIdle(g_vk.queue);

    for (auto &slot : slots_) {
        if (slot.ready) vkDestroySemaphore(g_vk.device, slot.ready, nullptr);
        if (slot.released) vkDestroySemaphore(g_vk.device, slot.released, nullptr);
        if (slot.fence) vkDestroyFence(g_vk.device, slot.fence, nullptr);
        if (slot.view) vkDestroyImageView(g_vk.device, slot.view, nullptr);
        if (slot.image) vkDestroyImage(g_vk.device, slot.image, nullptr);
        if (slot.memory) vkFreeMemory(g_vk.device, slot.memory, nullptr);
        if (slot.ahb) AHardwareBuffer_release(slot.ahb);
        slot = Slot{};
    }
    if (command_pool_) vkDestroyCommandPool(g_vk.device, command_pool_, nullptr);
    if (descriptor_pool_) vkDestroyDescriptorPool(g_vk.device, descriptor_pool_, nullptr);
    if (pipeline_) vkDestroyPipeline(g_vk.device, pipeline_, nullptr);
    if (pipeline_layout_) vkDestroyPipelineLayout(g_vk.device, pipeline_layout_, nullptr);
    if (set_layout_) vkDestroyDescriptorSetLayout(g_vk.device, set_layout_, nullptr);
    if (sampler_) vkDestroySampler(g_vk.device, sampler_, nullptr);
    for (int i = 0; i < 3; i++) {
        if (plane_views_[i]) vkDestroyImageView(g_vk.device, plane_views_[i], nullptr);
        if (planes_[i]) vkDestroyImage(g_vk.device, planes_[i], nullptr);
        if (plane_memory_[i]) vkFreeMemory(g_vk.device, plane_memory_[i], nullptr);
        planes_[i] = VK_NULL_HANDLE;
        plane_memory_[i] = VK_NULL_HANDLE;
        plane_views_[i] = VK_NULL_HANDLE;
    }
    command_pool_ = VK_NULL_HANDLE;
    descriptor_pool_ = VK_NULL_HANDLE;
    pipeline_ = VK_NULL_HANDLE;
    pipeline_layout_ = VK_NULL_HANDLE;
    set_layout_ = VK_NULL_HANDLE;
    sampler_ = VK_NULL_HANDLE;
    plane_buffers_ = {};
    device_ = nullptr;
    decoder_ = nullptr;
}

bool PyrowaveGpuPipeline::decode_frame(int64_t pts) {
    if (!uploader_ || !decoder_) return false;

    int release_fd = -1;
    int index = uploader_->acquire_pyrowave_gpu_slot(&release_fd);
    if (index < 0) {
        NF_LOGE(kTag, "No free output slot");
        return false;
    }
    Slot &slot = slots_[index];

    if (slot.submitted) {
        vkWaitForFences(g_vk.device, 1, &slot.fence, VK_TRUE, UINT64_MAX);
        vkResetFences(g_vk.device, 1, &slot.fence);
        slot.submitted = false;
    }

    vkResetCommandBuffer(slot.cmd, 0);
    VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(slot.cmd, &begin);

    const VkImageLayout decode_layout = fragment_path_ ? VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_GENERAL;
    const VkPipelineStageFlags2 decode_stage = fragment_path_ ? VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
                                                              : VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    const VkAccessFlags2 decode_write = fragment_path_ ? VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
                                                       : VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT;
    const VkAccessFlags2 decode_access = decode_write | (fragment_path_ ? VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT
                                                                        : VK_ACCESS_2_SHADER_STORAGE_READ_BIT);

    // Planes are shared across frames: the previous frame's conversion pass must be done
    // reading them before this decode overwrites them (same queue, so a barrier suffices).
    VkImageMemoryBarrier2 pre[4];
    for (int i = 0; i < 3; i++) {
        pre[i] = image_barrier(planes_[i], VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, 0, decode_stage, decode_access,
                               VK_IMAGE_LAYOUT_UNDEFINED, decode_layout);
    }
    pre[3] = image_barrier(slot.image, VK_PIPELINE_STAGE_2_NONE, 0,
                           VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT,
                           VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
                           VK_QUEUE_FAMILY_FOREIGN_EXT, g_vk.queue_family);
    barriers(slot.cmd, pre, 4);

    pyrowave_device_set_command_buffer(device_, slot.cmd);
    pyrowave_result decode_result = pyrowave_decoder_decode_gpu_buffer(decoder_, nullptr, nullptr, &plane_buffers_);
    pyrowave_device_set_command_buffer(device_, VK_NULL_HANDLE);
    if (decode_result != PYROWAVE_SUCCESS) {
        vkEndCommandBuffer(slot.cmd);
        uploader_->abandon_pyrowave_gpu_slot(index, release_fd);
        NF_LOGE(kTag, "pyrowave_decoder_decode_gpu_buffer failed: %d", (int)decode_result);
        return false;
    }

    VkImageMemoryBarrier2 mid[3];
    for (int i = 0; i < 3; i++) {
        mid[i] = image_barrier(planes_[i], decode_stage, decode_write,
                               VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
                               decode_layout, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }
    barriers(slot.cmd, mid, 3);

    vkCmdBindPipeline(slot.cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_);
    vkCmdBindDescriptorSets(slot.cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout_, 0, 1, &slot.set, 0, nullptr);
    vkCmdDispatch(slot.cmd, (width_ + 7) / 8, (height_ + 7) / 8, 1);

    VkImageMemoryBarrier2 release = image_barrier(slot.image,
                                                  VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT,
                                                  VK_PIPELINE_STAGE_2_NONE, 0,
                                                  VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL,
                                                  g_vk.queue_family, VK_QUEUE_FAMILY_FOREIGN_EXT);
    barriers(slot.cmd, &release, 1);
    vkEndCommandBuffer(slot.cmd);

    // GLES may still be sampling this slot from an earlier frame - wait on its release
    // fence on the GPU (temporary import), or on the CPU if the import isn't accepted.
    bool wait_released = false;
    if (release_fd >= 0) {
        VkImportSemaphoreFdInfoKHR import = { VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR };
        import.semaphore = slot.released;
        import.flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT;
        import.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        import.fd = release_fd;
        if (g_vk.ImportSemaphoreFdKHR(g_vk.device, &import) == VK_SUCCESS) {
            wait_released = true;
        } else {
            wait_and_close_fd(release_fd);
        }
        release_fd = -1;
    }

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    if (wait_released) {
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &slot.released;
        submit.pWaitDstStageMask = &wait_stage;
    }
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &slot.cmd;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &slot.ready;
    VkResult submit_result = vkQueueSubmit(g_vk.queue, 1, &submit, slot.fence);
    if (submit_result != VK_SUCCESS) {
        // The device is most likely lost at this point; don't hand GLES anything.
        uploader_->abandon_pyrowave_gpu_slot(index, -1);
        NF_LOGE(kTag, "vkQueueSubmit failed: %d", (int)submit_result);
        return false;
    }
    slot.submitted = true;

    int ready_fd = -1;
    VkSemaphoreGetFdInfoKHR get_fd = { VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR };
    get_fd.semaphore = slot.ready;
    get_fd.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    if (g_vk.GetSemaphoreFdKHR(g_vk.device, &get_fd, &ready_fd) != VK_SUCCESS) {
        // GLES can't wait on the GPU without the fd, so finish the frame on the CPU. The
        // binary semaphore is left signaled and can't be signaled again, so replace it.
        ready_fd = -1;
        vkWaitForFences(g_vk.device, 1, &slot.fence, VK_TRUE, UINT64_MAX);
        vkDestroySemaphore(g_vk.device, slot.ready, nullptr);
        VkExportSemaphoreCreateInfo export_info = { VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO };
        export_info.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        VkSemaphoreCreateInfo sem_info = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        sem_info.pNext = &export_info;
        vkCreateSemaphore(g_vk.device, &sem_info, nullptr, &slot.ready);
    }

    // The uploader takes ownership of ready_fd, so track completion through a duplicate.
    int completion_fd = ready_fd >= 0 ? fcntl(ready_fd, F_DUPFD_CLOEXEC, 0) : -1;
    uploader_->present_pyrowave_gpu_slot(index, ready_fd);
    if (completion_fd >= 0) {
        {
            std::lock_guard<std::mutex> lock(completion_mutex_);
            completion_queue_.emplace_back(completion_fd, pts);
        }
        completion_cv_.notify_one();
    } else if (on_complete_) {
        // Either the frame already completed on the CPU path above, or dup failed.
        vkWaitForFences(g_vk.device, 1, &slot.fence, VK_TRUE, UINT64_MAX);
        on_complete_(pts);
    }
    return true;
}

} // namespace godot

#endif
