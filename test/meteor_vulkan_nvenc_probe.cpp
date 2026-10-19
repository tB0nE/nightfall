// Standalone Linux interop diagnostic. No runtime registration or networking.
// SDK declarations come from the source-pinned nv-codec-headers in WiVRn;
// no WiVRn encoder implementation is used here.
#include <vulkan/vulkan.h>
#include "dynlink_cuda.h"
#include "nvEncodeAPI.h"
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <fstream>
#include <chrono>
#include "monado_nvenc_bridge.h"
#ifdef METEOR_MONADO_BRIDGE
#include <thread>
#include <mutex>
#include <condition_variable>
struct BridgeChannel {
    std::mutex mutex;
    std::condition_variable wake;
    bool pending = false, completed = false, stopping = false, busy = false;
    meteor_stereo_encode_v1 request{};
    std::thread worker;
};
static BridgeChannel channel;
static bool bridge_next(meteor_stereo_encode_v1 &request) {
    std::unique_lock<std::mutex> lock(channel.mutex);
    channel.wake.wait(lock, [] { return channel.pending || channel.stopping; });
    if (channel.stopping) return false;
    request = channel.request; channel.pending = false;
    return true;
}
static void bridge_complete() {
    std::lock_guard<std::mutex> lock(channel.mutex);
    channel.completed = true; channel.wake.notify_all();
}
#endif

#define REQUIRE(test, msg) do { if (!(test)) { std::fprintf(stderr, "%s\n", msg); std::exit(1); } } while (0)
#define VK(call) do { auto result = (call); if (result != VK_SUCCESS) { std::fprintf(stderr, "%s: Vulkan %d\n", #call, result); std::exit(1); } } while (0)
#define CU(call) do { auto result = (call); if (result != CUDA_SUCCESS) { std::fprintf(stderr, "%s: CUDA %d\n", #call, result); std::exit(1); } } while (0)
#define NV(call) do { auto result = (call); if (result != NV_ENC_SUCCESS) { std::fprintf(stderr, "%s: NVENC %d\n", #call, result); std::exit(1); } } while (0)

#ifdef METEOR_MONADO_BRIDGE
static void bridge_loop() {
    meteor_stereo_encode_v1 request;
    if (!bridge_next(request)) return;
    const meteor_stereo_encode_v1 *input = &request;
#else
int main(int argc, char **argv) {
    REQUIRE(argc == 2, "Usage: meteor-vulkan-nvenc-probe output.h264");
#endif
    void *cuda = dlopen("libcuda.so.1", RTLD_NOW);
    REQUIRE(cuda, "CUDA driver library unavailable");
#define LOAD(name, type, symbol) auto name = reinterpret_cast<type *>(dlsym(cuda, symbol)); REQUIRE(name, "Missing CUDA symbol " symbol)
    LOAD(cuInit, tcuInit, "cuInit");
    LOAD(cuDeviceGetCount, tcuDeviceGetCount, "cuDeviceGetCount");
    LOAD(cuDeviceGetUuid, tcuDeviceGetUuid, "cuDeviceGetUuid");
    LOAD(cuCtxCreate, tcuCtxCreate_v2, "cuCtxCreate_v2");
    LOAD(cuCtxDestroy, tcuCtxDestroy_v2, "cuCtxDestroy_v2");
    LOAD(cuImportExternalMemory, tcuImportExternalMemory, "cuImportExternalMemory");
    LOAD(cuExternalMemoryGetMappedMipmappedArray, tcuExternalMemoryGetMappedMipmappedArray, "cuExternalMemoryGetMappedMipmappedArray");
    LOAD(cuMipmappedArrayGetLevel, tcuMipmappedArrayGetLevel, "cuMipmappedArrayGetLevel");
    LOAD(cuMipmappedArrayDestroy, tcuMipmappedArrayDestroy, "cuMipmappedArrayDestroy");
    LOAD(cuDestroyExternalMemory, tcuDestroyExternalMemory, "cuDestroyExternalMemory");
#undef LOAD
    CU(cuInit(0));
#ifdef METEOR_MONADO_BRIDGE
    std::vector<VkPhysicalDevice> gpus{input->gpu};
#else
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ii{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ii.pApplicationInfo = &app;
    VkInstance instance; VK(vkCreateInstance(&ii, nullptr, &instance));
    uint32_t count = 0; VK(vkEnumeratePhysicalDevices(instance, &count, nullptr));
    std::vector<VkPhysicalDevice> gpus(count); VK(vkEnumeratePhysicalDevices(instance, &count, gpus.data()));
#endif
    VkPhysicalDevice gpu = VK_NULL_HANDLE; CUdevice cuda_device = -1;
    int cuda_count = 0; CU(cuDeviceGetCount(&cuda_count));
    for (auto candidate : gpus) {
        VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceProperties2 props{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; props.pNext = &id;
        vkGetPhysicalDeviceProperties2(candidate, &props);
        for (int i = 0; i < cuda_count; ++i) {
            CUuuid uuid; CU(cuDeviceGetUuid(&uuid, i));
            if (!std::memcmp(uuid.bytes, id.deviceUUID, VK_UUID_SIZE)) { gpu = candidate; cuda_device = i; break; }
        }
        if (gpu) { std::printf("Matched Vulkan/CUDA UUID: %s\n", props.properties.deviceName); break; }
    }
    REQUIRE(gpu, "No same-UUID Vulkan/CUDA device (no fallback)");
    CUcontext context; CU(cuCtxCreate(&context, 0, cuda_device));
#ifdef METEOR_MONADO_BRIDGE
    uint32_t family = input->queue_family;
    VkDevice device = input->device;
    VkQueue queue = input->queue;
#else
    uint32_t families = 0; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &families, nullptr);
    std::vector<VkQueueFamilyProperties> queues(families); vkGetPhysicalDeviceQueueFamilyProperties(gpu, &families, queues.data());
    uint32_t family = families;
    for (uint32_t i = 0; i < families; ++i) if (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { family = i; break; }
    REQUIRE(family < families, "No graphics queue");
    float priority = 1;
    VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueFamilyIndex = family; qi.queueCount = 1; qi.pQueuePriorities = &priority;
    const char *extensions[] = {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME};
    VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount = 1; di.pQueueCreateInfos = &qi;
    di.enabledExtensionCount = 1; di.ppEnabledExtensionNames = extensions;
    VkDevice device; VK(vkCreateDevice(gpu, &di, nullptr, &device));
    VkQueue queue; vkGetDeviceQueue(device, family, 0, &queue);
#endif
    auto get_fd = reinterpret_cast<PFN_vkGetMemoryFdKHR>(vkGetDeviceProcAddr(device, "vkGetMemoryFdKHR"));
    REQUIRE(get_fd, "External memory FD export unavailable");
#ifdef METEOR_MONADO_BRIDGE
    const uint32_t eye_size=input->eye_size ? input->eye_size : 256;
    REQUIRE(eye_size==256 || eye_size==512,"Unsupported eye-size profile");
    const uint32_t width=eye_size*2,height=eye_size;
#else
    constexpr uint32_t width = 512, height = 256;
#endif
    VkPhysicalDeviceMemoryProperties memory_props; vkGetPhysicalDeviceMemoryProperties(gpu, &memory_props);
    auto memory_type = [&](uint32_t bits, VkMemoryPropertyFlags flags) {
        for (uint32_t i = 0; i < memory_props.memoryTypeCount; ++i)
            if ((bits & (1u << i)) && (memory_props.memoryTypes[i].propertyFlags & flags) == flags) return i;
        std::fprintf(stderr, "No suitable Vulkan memory type\n"); std::exit(1);
    };
    VkExternalMemoryImageCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO}; external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkPhysicalDeviceExternalImageFormatInfo external_format{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO};
    external_format.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkPhysicalDeviceImageFormatInfo2 format_info{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2};
    format_info.pNext = &external_format; format_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    format_info.type = VK_IMAGE_TYPE_2D; format_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    format_info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    VkExternalImageFormatProperties external_props{VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES};
    VkImageFormatProperties2 format_props{VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2}; format_props.pNext = &external_props;
    VK(vkGetPhysicalDeviceImageFormatProperties2(gpu, &format_info, &format_props));
    REQUIRE(external_props.externalMemoryProperties.externalMemoryFeatures & VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT,
        "RGBA8 optimal image is not exportable (no fallback)");
    VkImageCreateInfo ici{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ici.pNext = &external;
    ici.imageType = VK_IMAGE_TYPE_2D; ici.format = VK_FORMAT_R8G8B8A8_UNORM; ici.extent = {width, height, 1};
    ici.mipLevels = 1; ici.arrayLayers = 1; ici.samples = VK_SAMPLE_COUNT_1_BIT; ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    VkImage image; VK(vkCreateImage(device, &ici, nullptr, &image));
    VkMemoryRequirements req; vkGetImageMemoryRequirements(device, image, &req);
    VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO}; dedicated.image = image;
    VkExportMemoryAllocateInfo export_info{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO}; export_info.pNext = &dedicated;
    export_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; mai.pNext = &export_info; mai.allocationSize = req.size;
    mai.memoryTypeIndex = memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory image_memory; VK(vkAllocateMemory(device, &mai, nullptr, &image_memory));
    VK(vkBindImageMemory(device, image, image_memory, 0));
    VkMemoryGetFdInfoKHR fd_info{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR}; fd_info.memory = image_memory; fd_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    int fd; VK(get_fd(device, &fd_info, &fd));
    CUDA_EXTERNAL_MEMORY_HANDLE_DESC desc{}; desc.type = CU_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD;
    desc.handle.fd = fd; desc.size = req.size; desc.flags = 1; // CUDA_EXTERNAL_MEMORY_DEDICATED
    CUexternalMemory cuda_memory; CU(cuImportExternalMemory(&cuda_memory, &desc)); // CUDA now owns FD.
    CUDA_EXTERNAL_MEMORY_MIPMAPPED_ARRAY_DESC array_desc{};
    array_desc.arrayDesc.Width = width; array_desc.arrayDesc.Height = height;
    array_desc.arrayDesc.Format = CU_AD_FORMAT_UNSIGNED_INT8; array_desc.arrayDesc.NumChannels = 4;
    array_desc.arrayDesc.Flags = 2; // CUDA_ARRAY3D_SURFACE_LDST
    array_desc.numLevels = 1;
    CUmipmappedArray mip; CU(cuExternalMemoryGetMappedMipmappedArray(&mip, cuda_memory, &array_desc));
    CUarray array; CU(cuMipmappedArrayGetLevel(&array, mip, 0));

#ifndef METEOR_MONADO_BRIDGE
    VkBufferCreateInfo bci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; bci.size = width * height * 4; bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    VkBuffer upload; VK(vkCreateBuffer(device, &bci, nullptr, &upload));
    vkGetBufferMemoryRequirements(device, upload, &req);
    mai.pNext = nullptr; mai.allocationSize = req.size; mai.memoryTypeIndex = memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory upload_memory; VK(vkAllocateMemory(device, &mai, nullptr, &upload_memory)); VK(vkBindBufferMemory(device, upload, upload_memory, 0));
    void *mapped; VK(vkMapMemory(device, upload_memory, 0, VK_WHOLE_SIZE, 0, &mapped));
    auto *pixels = static_cast<unsigned char *>(mapped);
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        auto p = (y * width + x) * 4; bool left = x < width/2;
        pixels[p] = left ? (x < width/4 ? 255 : 128) : 0;
        pixels[p+1] = 64; pixels[p+2] = left ? 0 : (y < height/2 ? 255 : 128); pixels[p+3] = 255;
    }
    vkUnmapMemory(device, upload_memory);
#endif
    VkCommandPoolCreateInfo pci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pci.queueFamilyIndex = family;
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool pool; VK(vkCreateCommandPool(device, &pci, nullptr, &pool));
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; cai.commandPool = pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
    VkCommandBuffer cmd; VK(vkAllocateCommandBuffers(device, &cai, &cmd));
#ifdef METEOR_MONADO_BRIDGE
    void *nv = nullptr, *encoder = nullptr;
    NV_ENCODE_API_FUNCTION_LIST api{};
    NV_ENC_REGISTER_RESOURCE reg{};
    NV_ENC_MAP_INPUT_RESOURCE map{};
    NV_ENC_CREATE_BITSTREAM_BUFFER bitstream{};
    std::ofstream output(input->output_path, std::ios::binary);
    REQUIRE(output.good(), "Cannot open output");
    bool first_frame = true;
    uint64_t encoded_count = 0;
    for (;;) {
    REQUIRE(input->device == device && input->gpu == gpu && input->queue == queue && input->queue_family == family,
        "Bridge device changed during session");
    REQUIRE((input->eye_size ? input->eye_size : 256)==eye_size,"Bridge dimensions changed during session");
    auto pack_start=std::chrono::steady_clock::now();
    if (!first_frame) VK(vkResetCommandBuffer(cmd, 0));
#endif
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK(vkBeginCommandBuffer(cmd, &begin));
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.image = image; barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
#ifdef METEOR_MONADO_BRIDGE
    if (!first_frame) {
        barrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL; barrier.dstQueueFamilyIndex = family;
    }
#endif
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
#ifdef METEOR_MONADO_BRIDGE
    for (int eye = 0; eye < 2; ++eye) {
        VkImageMemoryBarrier src{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        src.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; src.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        src.srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL; src.dstQueueFamilyIndex = family;
        src.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT; src.image = input->eyes[eye];
        src.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &src);
        VkImageCopy copy{}; copy.srcSubresource = copy.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        copy.dstOffset.x = eye * eye_size; copy.extent = {eye_size, eye_size, 1};
        vkCmdCopyImage(cmd, input->eyes[eye], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        src.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; src.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        src.srcQueueFamilyIndex = family; src.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
        src.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT; src.dstAccessMask = 0;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &src);
    }
#else
    VkBufferImageCopy copy{}; copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}; copy.imageExtent = {width, height, 1};
    vkCmdCopyBufferToImage(cmd, upload, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
#endif
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier.srcQueueFamilyIndex = family; barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    VK(vkEndCommandBuffer(cmd));
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount = 1; submit.pCommandBuffers = &cmd;
    VK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); VK(vkQueueWaitIdle(queue));
#ifdef METEOR_MONADO_BRIDGE
    std::fprintf(stderr,"GPU_PACK frame=%llu us=%lld\n",(unsigned long long)input->frame_id,
        (long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-pack_start).count());
#endif

#ifdef METEOR_MONADO_BRIDGE
    if (first_frame) {
    nv = dlopen("libnvidia-encode.so.1", RTLD_NOW);
#else
    void *nv = dlopen("libnvidia-encode.so.1", RTLD_NOW);
#endif
    REQUIRE(nv, "NVENC driver unavailable");
    auto create = reinterpret_cast<NVENCSTATUS (NVENCAPI *)(NV_ENCODE_API_FUNCTION_LIST *)>(dlsym(nv, "NvEncodeAPICreateInstance"));
    REQUIRE(create, "NVENC API entrypoint unavailable");
#ifndef METEOR_MONADO_BRIDGE
    NV_ENCODE_API_FUNCTION_LIST api{};
#endif
    api.version = NV_ENCODE_API_FUNCTION_LIST_VER; NV(create(&api));
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open{}; open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    open.apiVersion = NVENCAPI_VERSION; open.deviceType = NV_ENC_DEVICE_TYPE_CUDA; open.device = context;
#ifndef METEOR_MONADO_BRIDGE
    void *encoder;
#endif
    NV(api.nvEncOpenEncodeSessionEx(&open, &encoder));
    NV_ENC_PRESET_CONFIG preset{}; preset.version = NV_ENC_PRESET_CONFIG_VER; preset.presetCfg.version = NV_ENC_CONFIG_VER;
    NV(api.nvEncGetEncodePresetConfigEx(encoder, NV_ENC_CODEC_H264_GUID, NV_ENC_PRESET_P1_GUID, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset));
    preset.presetCfg.frameIntervalP = 1; preset.presetCfg.gopLength = 60;
    preset.presetCfg.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR; preset.presetCfg.rcParams.averageBitRate = 4000000*(width/512)*(height/256);
    preset.presetCfg.rcParams.enableLookahead = 0;
    // Match the driver's RGB conversion profile explicitly. Without VUI,
    // decoders can assume BT.601 for the wider BT.709 test and corrupt colors.
    auto &vui=preset.presetCfg.encodeCodecConfig.h264Config.h264VUIParameters;
    vui.videoSignalTypePresentFlag=1; vui.videoFormat=NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
    vui.videoFullRangeFlag=0; vui.colourDescriptionPresentFlag=1;
    vui.colourPrimaries=NV_ENC_VUI_COLOR_PRIMARIES_BT709;
    vui.transferCharacteristics=NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
    vui.colourMatrix=width>512 ? NV_ENC_VUI_MATRIX_COEFFS_BT709 : NV_ENC_VUI_MATRIX_COEFFS_SMPTE170M;
    NV_ENC_INITIALIZE_PARAMS init{}; init.version = NV_ENC_INITIALIZE_PARAMS_VER;
    init.encodeGUID = NV_ENC_CODEC_H264_GUID; init.presetGUID = NV_ENC_PRESET_P1_GUID;
    init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY; init.encodeWidth = init.darWidth = width;
    init.encodeHeight = init.darHeight = height; init.frameRateNum = 60; init.frameRateDen = 1;
    init.enablePTD = 1; init.encodeConfig = &preset.presetCfg;
    NV(api.nvEncInitializeEncoder(encoder, &init));
#ifndef METEOR_MONADO_BRIDGE
    NV_ENC_REGISTER_RESOURCE reg{};
#endif
    reg.version = NV_ENC_REGISTER_RESOURCE_VER;
    reg.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_CUDAARRAY; reg.resourceToRegister = array;
    reg.width = width; reg.height = height; reg.bufferFormat = NV_ENC_BUFFER_FORMAT_ABGR;
    reg.bufferUsage = NV_ENC_INPUT_IMAGE; NV(api.nvEncRegisterResource(encoder, &reg));
#ifndef METEOR_MONADO_BRIDGE
    NV_ENC_MAP_INPUT_RESOURCE map{};
    NV_ENC_CREATE_BITSTREAM_BUFFER bitstream{};
#endif
    bitstream.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    NV(api.nvEncCreateBitstreamBuffer(encoder, &bitstream));
#ifdef METEOR_MONADO_BRIDGE
    std::puts("METEOR_ENCODER_INIT surfaces=1 queue_capacity=1");
    std::fflush(stdout);
    }
    const uint32_t frame_count = 1;
    const uint64_t timestamp_base = input->frame_id;
#else
    const char *output_path = argv[1];
    const uint32_t frame_count = 5;
    const uint64_t timestamp_base = 0;
#endif
#ifndef METEOR_MONADO_BRIDGE
    std::ofstream output(output_path, std::ios::binary); REQUIRE(output.good(), "Cannot open output");
#endif
    map.version = NV_ENC_MAP_INPUT_RESOURCE_VER; map.registeredResource = reg.registeredResource;
    NV(api.nvEncMapInputResource(encoder, &map));
    for (uint32_t frame = 0; frame < frame_count; ++frame) {
        NV_ENC_PIC_PARAMS pic{}; pic.version = NV_ENC_PIC_PARAMS_VER;
        pic.inputBuffer = map.mappedResource; pic.bufferFmt = map.mappedBufferFmt;
        pic.inputWidth = width; pic.inputHeight = height; pic.outputBitstream = bitstream.bitstreamBuffer;
        pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME; pic.inputTimeStamp = timestamp_base + frame;
#ifdef METEOR_MONADO_BRIDGE
        if (first_frame) pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
#else
        if (frame == 0) pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
#endif
        auto start = std::chrono::steady_clock::now();
        NV(api.nvEncEncodePicture(encoder, &pic));
        NV_ENC_LOCK_BITSTREAM lock{}; lock.version = NV_ENC_LOCK_BITSTREAM_VER; lock.outputBitstream = bitstream.bitstreamBuffer;
        NV(api.nvEncLockBitstream(encoder, &lock));
        REQUIRE(lock.outputTimeStamp == timestamp_base + frame, "Encoder frame timestamp mismatch");
        output.write(static_cast<const char *>(lock.bitstreamBufferPtr), lock.bitstreamSizeInBytes);
#ifdef METEOR_MONADO_BRIDGE
        if (input->encoded_callback) {
            REQUIRE(input->encoded_callback(input->callback_context,
                static_cast<const uint8_t *>(lock.bitstreamBufferPtr), lock.bitstreamSizeInBytes),
                "Encoded packet callback failed");
        }
#endif
        auto us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count();
        std::fprintf(stderr,"NVENC timestamp=%llu bytes=%u submit-to-lock-us=%lld (tiny diagnostic, not XR benchmark)\n", static_cast<unsigned long long>(timestamp_base + frame), lock.bitstreamSizeInBytes, static_cast<long long>(us));
        NV(api.nvEncUnlockBitstream(encoder, bitstream.bitstreamBuffer));
    }
    output.flush(); REQUIRE(output.good(), "Cannot write bitstream");
    NV(api.nvEncUnmapInputResource(encoder, map.mappedResource));
#ifdef METEOR_MONADO_BRIDGE
    ++encoded_count;
    first_frame = false;
    bridge_complete();
    if (!bridge_next(request)) break;
    }
    std::printf("METEOR_ENCODER_DRAIN frames=%llu surfaces=1\n", static_cast<unsigned long long>(encoded_count));
    std::fflush(stdout);
#endif
    output.close(); REQUIRE(output.good(), "Cannot close bitstream");
    NV_ENC_PIC_PARAMS eos{}; eos.version = NV_ENC_PIC_PARAMS_VER; eos.encodePicFlags = NV_ENC_PIC_FLAG_EOS;
    NV(api.nvEncEncodePicture(encoder, &eos));
    NV(api.nvEncUnregisterResource(encoder, reg.registeredResource));
    NV(api.nvEncDestroyBitstreamBuffer(encoder, bitstream.bitstreamBuffer)); NV(api.nvEncDestroyEncoder(encoder));
    CU(cuMipmappedArrayDestroy(mip)); CU(cuDestroyExternalMemory(cuda_memory));
    vkDestroyCommandPool(device, pool, nullptr);
#ifndef METEOR_MONADO_BRIDGE
    vkDestroyBuffer(device, upload, nullptr); vkFreeMemory(device, upload_memory, nullptr);
#endif
    vkDestroyImage(device, image, nullptr); vkFreeMemory(device, image_memory, nullptr);
#ifndef METEOR_MONADO_BRIDGE
    vkDestroyDevice(device, nullptr); vkDestroyInstance(instance, nullptr);
#endif
    CU(cuCtxDestroy(context));
    dlclose(nv); dlclose(cuda);
#ifdef METEOR_MONADO_BRIDGE
    std::puts("METEOR_ENCODER_RELEASED");
    std::fflush(stdout);
    std::puts("PASS: Monado eye images -> GPU stereo packing -> CUDA array -> NVENC, without pixel readback.");
#else
    std::puts("PASS: exportable Vulkan image -> CUDA array -> NVENC, without pixel readback. Not yet connected to Monado.");
#endif
}
#ifdef METEOR_MONADO_BRIDGE
extern "C" void meteor_encode_stereo_v1(const meteor_stereo_encode_v1 *input) {
    REQUIRE(input && input->size == sizeof(*input), "Bridge ABI size mismatch");
    std::unique_lock<std::mutex> lock(channel.mutex);
    REQUIRE(!channel.busy && !channel.pending && !channel.stopping, "Bridge submitted while busy/stopping");
    channel.busy = true;
    if (!channel.worker.joinable()) channel.worker = std::thread(bridge_loop);
    channel.request = *input; channel.pending = true; channel.completed = false;
    channel.wake.notify_all();
    channel.wake.wait(lock, [] { return channel.completed; });
    channel.busy = false;
}
extern "C" void meteor_encode_finish_v1() {
    {
        std::lock_guard<std::mutex> lock(channel.mutex);
        channel.stopping = true; channel.wake.notify_all();
    }
    if (channel.worker.joinable()) channel.worker.join();
}
#endif
