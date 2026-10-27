// Isolated Linux AMD interop diagnostic. No runtime registration or networking.
// Pixel path: Vulkan storage buffer -> imported VA surface -> VA VPP NV12 -> encoder.
// Only compressed packets are read by the CPU. FFmpeg 8 may be bundled by Meteor.
#include <vulkan/vulkan.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_vpp.h>
#include <libdrm/drm_fourcc.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
}
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#ifdef METEOR_MONADO_BRIDGE
#include "monado_nvenc_bridge.h"
#include "meteor_eye_format.h"
#include "meteor_eye_rect.h"
#include "meteor_encoder_bitrate.h"
#include "meteor_live_bitrate.h"
#include "meteor_live_foveation.h"
#include "meteor_encoder_channel.h"
#endif

static void require(bool condition,const std::string &message) { if(!condition) throw std::runtime_error(message); }
static void vk_check(VkResult code,const char *what) { require(code==VK_SUCCESS,std::string(what)+": Vulkan "+std::to_string(code)); }
static void va_check(VAStatus code,const char *what) { require(code==VA_STATUS_SUCCESS,std::string(what)+": "+vaErrorStr(code)); }
#define VK_CHECK(expression) vk_check((expression),#expression)
#define VA_CHECK(expression) va_check((expression),#expression)

struct FFmpeg {
    static void *open_library(const char *name) {
        const char *directory=std::getenv("METEOR_XR_FFMPEG_LIBDIR");
        std::string path=directory?std::string(directory)+"/"+name:name;
        return dlopen(path.c_str(),RTLD_NOW|RTLD_LOCAL);
    }
    void *codec=open_library("libavcodec.so.62");
    void *util=open_library("libavutil.so.60");
#define FN(name) decltype(&name) name##_fn=nullptr
    FN(avcodec_version); FN(avutil_version); FN(av_strerror);
    FN(av_hwdevice_ctx_create); FN(av_hwframe_ctx_alloc); FN(av_hwframe_ctx_init); FN(av_hwframe_get_buffer);
    FN(av_buffer_ref); FN(av_buffer_unref); FN(av_frame_alloc); FN(av_frame_free); FN(av_frame_unref);
    FN(avcodec_find_encoder_by_name); FN(avcodec_alloc_context3); FN(avcodec_open2); FN(avcodec_free_context);
    FN(avcodec_send_frame); FN(avcodec_receive_packet); FN(av_packet_alloc); FN(av_packet_unref); FN(av_packet_free);
    FN(av_dict_set); FN(av_dict_free);
#undef FN
    FFmpeg() {
        require(codec&&util,"FFmpeg 8 libraries (avcodec 62, avutil 60) required for VA-API encoding");
#define LOAD(library,name) name##_fn=reinterpret_cast<decltype(name##_fn)>(dlsym(library,#name)); require(name##_fn,"Missing FFmpeg symbol " #name)
        LOAD(codec,avcodec_version); LOAD(util,avutil_version); LOAD(util,av_strerror);
        Dl_info origin{};
        if(dladdr(reinterpret_cast<void*>(avcodec_version_fn),&origin)) std::fprintf(stderr,"XR_FFMPEG library=%s\n",origin.dli_fname);
        require((avcodec_version_fn()>>16)==62 && (avutil_version_fn()>>16)==60,"FFmpeg ABI mismatch");
        LOAD(util,av_hwdevice_ctx_create); LOAD(util,av_hwframe_ctx_alloc); LOAD(util,av_hwframe_ctx_init); LOAD(util,av_hwframe_get_buffer);
        LOAD(util,av_buffer_ref); LOAD(util,av_buffer_unref); LOAD(util,av_frame_alloc); LOAD(util,av_frame_free); LOAD(util,av_frame_unref);
        LOAD(codec,avcodec_find_encoder_by_name); LOAD(codec,avcodec_alloc_context3); LOAD(codec,avcodec_open2); LOAD(codec,avcodec_free_context);
        LOAD(codec,avcodec_send_frame); LOAD(codec,avcodec_receive_packet); LOAD(codec,av_packet_alloc); LOAD(codec,av_packet_unref); LOAD(codec,av_packet_free);
        LOAD(util,av_dict_set); LOAD(util,av_dict_free);
#undef LOAD
    }
    void check(int code,const char *what) {
        if(code>=0) return;
        char error[128]{}; av_strerror_fn(code,error,sizeof(error));
        throw std::runtime_error(std::string(what)+": "+error);
    }
};
using Clock=std::chrono::steady_clock;
static double milliseconds(Clock::time_point start) { return std::chrono::duration<double,std::milli>(Clock::now()-start).count(); }
[[maybe_unused]] static double percentile(std::vector<double> values,double fraction) {
    std::sort(values.begin(),values.end()); return values.at(size_t((values.size()-1)*fraction));
}

// Read-only capability probe: no encoder session, surfaces or GPU submissions.
extern "C" int meteor_vaapi_codecs_v1(const char *node) {
    int fd=-1;VADisplay display=nullptr;bool initialized=false;int supported=0;
    try {
        FFmpeg api;
        fd=open(node,O_RDWR|O_CLOEXEC);require(fd>=0,"Cannot open AMD render node");
        display=vaGetDisplayDRM(fd);require(display,"Cannot create VA display");
        int major=0,minor=0;VA_CHECK(vaInitialize(display,&major,&minor));initialized=true;
        std::vector<VAEntrypoint> entries(vaMaxNumEntrypoints(display));int count=0;
        for(const auto &candidate:std::vector<std::pair<VAProfile,const char*>>{{VAProfileH264Main,"h264_vaapi"},{VAProfileHEVCMain,"hevc_vaapi"}}) {
            count=0;
            if(api.avcodec_find_encoder_by_name_fn(candidate.second) &&
               vaQueryConfigEntrypoints(display,candidate.first,entries.data(),&count)==VA_STATUS_SUCCESS &&
               std::find(entries.begin(),entries.begin()+count,VAEntrypointEncSlice)!=entries.begin()+count)
                supported |= candidate.first==VAProfileH264Main?1:2;
        }
        VA_CHECK(vaQueryConfigEntrypoints(display,VAProfileNone,entries.data(),&count));
        require(std::find(entries.begin(),entries.begin()+count,VAEntrypointVideoProc)!=entries.begin()+count,"VA color conversion unavailable");
    } catch(const std::exception &error) {std::fprintf(stderr,"AMD XR capability check: %s\n",error.what());supported=0;}
    if(initialized) vaTerminate(display);
    if(fd>=0) close(fd);
    return supported;
}

extern "C" int meteor_vaapi_capabilities_v1(const char *node) {return (meteor_vaapi_codecs_v1(node)&2)?1:0;}

#ifdef METEOR_MONADO_BRIDGE
#define VK(call) VK_CHECK(call)
#define REQUIRE(condition,message) require(condition,message)
#include "meteor_stereo_compositor.h"
static int bridge_run(int argc,char **argv);
static meteor_stereo_encode_v1 request;
static void bridge_loop() {
    if(!bridge_next(request)) return;
    VkPhysicalDeviceDrmPropertiesEXT identity{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT};
    VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};properties.pNext=&identity;
    vkGetPhysicalDeviceProperties2(request.gpu,&properties);
    if(properties.properties.vendorID!=0x1002 || !identity.hasRender) { std::fprintf(stderr,"VA bridge requires an AMD DRM render device\n");std::exit(1); }
    std::string device="/dev/dri/renderD"+std::to_string(identity.renderMinor);
    const char *selected=std::getenv("NIGHTFALL_XR_RENDER_DEVICE");
    if(selected && device!=selected) {std::fprintf(stderr,"Compositor GPU differs from selected AMD render device\n");std::exit(1);}
    std::string width=std::to_string((request.eye_size?request.eye_size:256)*2);
    std::string height=std::to_string(request.eye_height?request.eye_height:(request.eye_size?request.eye_size:256));
    const char *codec=std::getenv("METEOR_XR_CODEC");
    if(codec && std::strcmp(codec,"h265") && std::strcmp(codec,"h264")) { std::fprintf(stderr,"Unsupported AMD codec\n");std::exit(1); }
    std::string output=request.output_path;
    char *arguments[]={const_cast<char*>("vaapi-bridge"),device.data(),const_cast<char*>(codec && !std::strcmp(codec,"h264")?"h264":"hevc"),width.data(),height.data(),
                      const_cast<char*>("48"),const_cast<char*>("unused"),output.data(),const_cast<char*>("unused")};
    if(bridge_run(9,arguments)) std::exit(1);
}
static int bridge_run(int argc,char **argv) {
#else

int main(int argc,char **argv) {
#endif
    try {
        require(argc==9,"Usage: probe /dev/dri/renderDxxx h264|hevc WIDTH HEIGHT FRAMES pattern.spv output.bitstream report.json");
        const bool hevc=std::string(argv[2])=="hevc";
        require(hevc||std::string(argv[2])=="h264","Choose h264 or hevc");
        const int width=std::stoi(argv[3]),height=std::stoi(argv[4]),frames=std::stoi(argv[5]);
        const char *pace=std::getenv("METEOR_VAAPI_PROBE_PACE_HZ");
        [[maybe_unused]] const int pace_hz=pace?std::stoi(pace):72;
        require(pace_hz>=0 && pace_hz<=144,"Probe pacing must be 0..144 Hz");
        require(width>=64 && height>=64 && width<=8192 && height<=4096 && width%2==0 && height%2==0 && frames>=16 && frames<=1200,"Invalid probe dimensions/frame count");
        FFmpeg api;
        std::fprintf(stderr,"STAGE VAAPI device initialization\n");
        AVBufferRef *hardware=nullptr;
        api.check(api.av_hwdevice_ctx_create_fn(&hardware,AV_HWDEVICE_TYPE_VAAPI,argv[1],nullptr,0),"VAAPI device");
        auto *hardware_context=reinterpret_cast<AVHWDeviceContext*>(hardware->data);
        VADisplay display=static_cast<AVVAAPIDeviceContext*>(hardware_context->hwctx)->display;
        std::fprintf(stderr,"VA driver: %s\n",vaQueryVendorString(display));

        int drm=open(argv[1],O_RDWR|O_CLOEXEC);require(drm>=0,"Cannot open explicit DRM render device");
        struct stat drm_stat{};require(fstat(drm,&drm_stat)==0,"Cannot identify DRM device");
        VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};application.apiVersion=VK_API_VERSION_1_1;
        VkInstanceCreateInfo instance_info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};instance_info.pApplicationInfo=&application;
        VkInstance instance;
#ifdef METEOR_MONADO_BRIDGE
        (void)instance_info;instance=request.instance;
#else
        VK_CHECK(vkCreateInstance(&instance_info,nullptr,&instance));
#endif
        uint32_t count=0;VK_CHECK(vkEnumeratePhysicalDevices(instance,&count,nullptr));
        std::vector<VkPhysicalDevice> devices(count);VK_CHECK(vkEnumeratePhysicalDevices(instance,&count,devices.data()));
        VkPhysicalDevice gpu=VK_NULL_HANDLE;std::string gpu_name;
        for(auto candidate:devices) {
            VkPhysicalDeviceDrmPropertiesEXT identity{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT};
            VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};properties.pNext=&identity;
            vkGetPhysicalDeviceProperties2(candidate,&properties);
            if(properties.properties.vendorID==0x1002 && identity.hasRender &&
                identity.renderMajor==major(drm_stat.st_rdev) && identity.renderMinor==minor(drm_stat.st_rdev)) {
                gpu=candidate;gpu_name=properties.properties.deviceName;break;
            }
        }
        require(gpu,"No AMD Vulkan device matches the explicit VA-API DRM render node; no cross-GPU fallback");
        std::fprintf(stderr,"Matched Vulkan/VAAPI DRM device: %s (%s)\n",gpu_name.c_str(),argv[1]);
        uint32_t families=0;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&families,nullptr);
        std::vector<VkQueueFamilyProperties> queues(families);vkGetPhysicalDeviceQueueFamilyProperties(gpu,&families,queues.data());
        uint32_t family=families;
        for(uint32_t i=0;i<families;++i) if(queues[i].queueFlags&VK_QUEUE_COMPUTE_BIT) {family=i;break;}
        require(family<families,"No compute queue on selected AMD GPU");
#ifdef METEOR_MONADO_BRIDGE
        require(gpu==request.gpu,"VA/Vulkan GPU differs from the compositor GPU");family=request.queue_family;
#endif
        float priority=1;
        VkDeviceQueueCreateInfo queue_info{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};queue_info.queueFamilyIndex=family;queue_info.queueCount=1;queue_info.pQueuePriorities=&priority;
        uint32_t extension_count=0;
        VK_CHECK(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&extension_count,nullptr));
        std::vector<VkExtensionProperties> available(extension_count);
        VK_CHECK(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&extension_count,available.data()));
        auto supports=[&](const char *name) {
            return std::any_of(available.begin(),available.end(),[&](const auto &entry) { return std::strcmp(entry.extensionName,name)==0; });
        };
        std::vector<const char*> extensions={VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
            VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME};
        for(auto name:extensions) require(supports(name),std::string("Missing required Vulkan extension: ")+name);
        const bool modifiers=supports(VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME);
        if(modifiers) extensions.push_back(VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME);
        std::fprintf(stderr,"DRM format modifier support: %s\n",modifiers?"yes":"no; requiring matching linear layout");
        VkDeviceCreateInfo device_info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};device_info.queueCreateInfoCount=1;device_info.pQueueCreateInfos=&queue_info;
        device_info.enabledExtensionCount=extensions.size();device_info.ppEnabledExtensionNames=extensions.data();
        VkDevice device;VkQueue queue;
#ifdef METEOR_MONADO_BRIDGE
        (void)device_info;device=request.device;queue=request.queue;
        require(vkGetDeviceProcAddr(device,"vkGetMemoryFdKHR"),"Compositor did not enable external-memory FD export");
#else
        VK_CHECK(vkCreateDevice(gpu,&device_info,nullptr,&device));
        vkGetDeviceQueue(device,family,0,&queue);
#endif

        // Export a GPU-only linear buffer: no linear storage-image capability is
        // required on Polaris. VA interprets the explicit RGBA pitch/layout.
        VkPhysicalDeviceExternalBufferInfo external_query{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO};
        external_query.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;external_query.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT|VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        VkExternalBufferProperties external_properties{VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES};
        vkGetPhysicalDeviceExternalBufferProperties(gpu,&external_query,&external_properties);
        require(external_properties.externalMemoryProperties.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT,
                "Storage-buffer DMA-BUF export is unavailable");
        VkExternalMemoryBufferCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};
        external.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        VkBufferCreateInfo buffer_info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};buffer_info.pNext=&external;
        buffer_info.size=VkDeviceSize(width)*height*4;buffer_info.usage=external_query.usage;
        buffer_info.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
        VkBuffer buffer;VK_CHECK(vkCreateBuffer(device,&buffer_info,nullptr,&buffer));
        VkMemoryRequirements memory_requirements{};vkGetBufferMemoryRequirements(device,buffer,&memory_requirements);
        VkPhysicalDeviceMemoryProperties memory_properties;vkGetPhysicalDeviceMemoryProperties(gpu,&memory_properties);
        uint32_t memory_type=memory_properties.memoryTypeCount;
        for(uint32_t i=0;i<memory_properties.memoryTypeCount;++i)
            if((memory_requirements.memoryTypeBits&(1u<<i)) &&
               (memory_properties.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {memory_type=i;break;}
        require(memory_type<memory_properties.memoryTypeCount,"No device-local export memory type");
        VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};dedicated.buffer=buffer;
        VkExportMemoryAllocateInfo export_info{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};
        export_info.pNext=&dedicated;export_info.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};allocation.pNext=&export_info;
        allocation.allocationSize=memory_requirements.size;allocation.memoryTypeIndex=memory_type;
        VkDeviceMemory memory;VK_CHECK(vkAllocateMemory(device,&allocation,nullptr,&memory));
        VK_CHECK(vkBindBufferMemory(device,buffer,memory,0));
        auto get_fd=reinterpret_cast<PFN_vkGetMemoryFdKHR>(vkGetDeviceProcAddr(device,"vkGetMemoryFdKHR"));
        require(get_fd,"Missing DMA-BUF export function");
        VkMemoryGetFdInfoKHR fd_info{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR};fd_info.memory=memory;
        fd_info.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        int shared_fd=-1;VK_CHECK(get_fd(device,&fd_info,&shared_fd));
        require(memory_requirements.size<=UINT32_MAX,"VA descriptor size overflow");
        VADRMPRIMESurfaceDescriptor shared{};shared.fourcc=VA_FOURCC_RGBA;shared.width=width;shared.height=height;
        shared.num_objects=1;shared.objects[0].fd=shared_fd;shared.objects[0].size=memory_requirements.size;
        shared.objects[0].drm_format_modifier=DRM_FORMAT_MOD_LINEAR;
        shared.num_layers=1;shared.layers[0].drm_format=DRM_FORMAT_ABGR8888;shared.layers[0].num_planes=1;
        shared.layers[0].object_index[0]=0;shared.layers[0].offset[0]=0;shared.layers[0].pitch[0]=uint64_t(width)*4;
        VASurfaceAttrib attributes[2]{};
        attributes[0].type=VASurfaceAttribMemoryType;attributes[0].flags=VA_SURFACE_ATTRIB_SETTABLE;
        attributes[0].value.type=VAGenericValueTypeInteger;attributes[0].value.value.i=VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
        attributes[1].type=VASurfaceAttribExternalBufferDescriptor;attributes[1].flags=VA_SURFACE_ATTRIB_SETTABLE;
        attributes[1].value.type=VAGenericValueTypePointer;attributes[1].value.value.p=&shared;
        VASurfaceID rgba_surface=VA_INVALID_SURFACE;
        VA_CHECK(vaCreateSurfaces(display,VA_RT_FORMAT_RGB32,width,height,&rgba_surface,1,attributes,2));
        close(shared_fd);
        std::fprintf(stderr,"Imported Vulkan-owned linear DMA-BUF into VA: pitch=%llu size=%llu\n",
            static_cast<unsigned long long>(uint64_t(width)*4),static_cast<unsigned long long>(memory_requirements.size));
#ifdef METEOR_MONADO_BRIDGE
        const uint32_t eye_size=width/2,eye_height=height;
        require(meteor_eye_size_valid(eye_size)&&meteor_eye_size_valid(eye_height),"Invalid XR eye dimensions");
        require(meteor_eye_formats_compatible(request.eye_formats[0],request.eye_formats[1]),"Mixed source transfer functions");
        VkFormat packed_format=meteor_eye_format_srgb(request.eye_formats[0])?VK_FORMAT_R8G8B8A8_SRGB:VK_FORMAT_R8G8B8A8_UNORM;
        VkImageCreateInfo packed_info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};packed_info.imageType=VK_IMAGE_TYPE_2D;
        packed_info.format=packed_format;packed_info.extent={uint32_t(width),uint32_t(height),1};
        packed_info.mipLevels=1;packed_info.arrayLayers=1;packed_info.samples=VK_SAMPLE_COUNT_1_BIT;
        packed_info.tiling=VK_IMAGE_TILING_OPTIMAL;packed_info.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        VkImage packed;VK_CHECK(vkCreateImage(device,&packed_info,nullptr,&packed));
        VkMemoryRequirements packed_requirements;vkGetImageMemoryRequirements(device,packed,&packed_requirements);
        uint32_t packed_type=memory_properties.memoryTypeCount;
        for(uint32_t i=0;i<memory_properties.memoryTypeCount;++i)
            if((packed_requirements.memoryTypeBits&(1u<<i)) && (memory_properties.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {packed_type=i;break;}
        require(packed_type<memory_properties.memoryTypeCount,"No packed image device memory");
        VkMemoryAllocateInfo packed_allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};packed_allocation.allocationSize=packed_requirements.size;packed_allocation.memoryTypeIndex=packed_type;
        VkDeviceMemory packed_memory;VK_CHECK(vkAllocateMemory(device,&packed_allocation,nullptr,&packed_memory));VK_CHECK(vkBindImageMemory(device,packed,packed_memory,0));
        MeteorQuadCompositor quads;bool quad_initialized=false;
        uint32_t previous_quads=UINT32_MAX,previous_projection=UINT32_MAX;
#else
        VkDescriptorSetLayoutBinding binding{};binding.binding=0;binding.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;binding.descriptorCount=1;binding.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT;
        VkDescriptorSetLayoutCreateInfo set_info{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};set_info.bindingCount=1;set_info.pBindings=&binding;
        VkDescriptorSetLayout set_layout;VK_CHECK(vkCreateDescriptorSetLayout(device,&set_info,nullptr,&set_layout));
        VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT,0,12};
        VkPipelineLayoutCreateInfo layout_info{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};layout_info.setLayoutCount=1;layout_info.pSetLayouts=&set_layout;layout_info.pushConstantRangeCount=1;layout_info.pPushConstantRanges=&push;
        VkPipelineLayout pipeline_layout;VK_CHECK(vkCreatePipelineLayout(device,&layout_info,nullptr,&pipeline_layout));
        std::ifstream shader_file(argv[6],std::ios::binary|std::ios::ate);require(bool(shader_file),"Cannot open probe shader");
        auto shader_size=shader_file.tellg();require(shader_size>0 && shader_size%4==0,"Invalid shader size");
        std::vector<uint32_t> shader_words(size_t(shader_size)/4);shader_file.seekg(0);shader_file.read(reinterpret_cast<char*>(shader_words.data()),shader_size);
        VkShaderModuleCreateInfo shader_info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};shader_info.codeSize=shader_words.size()*4;shader_info.pCode=shader_words.data();
        VkShaderModule shader;VK_CHECK(vkCreateShaderModule(device,&shader_info,nullptr,&shader));
        VkComputePipelineCreateInfo compute_info{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};compute_info.layout=pipeline_layout;
        compute_info.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};compute_info.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;compute_info.stage.module=shader;compute_info.stage.pName="main";
        VkPipeline pipeline;VK_CHECK(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&compute_info,nullptr,&pipeline));
        VkDescriptorPoolSize pool_size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1};
        VkDescriptorPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};pool_info.maxSets=1;pool_info.poolSizeCount=1;pool_info.pPoolSizes=&pool_size;
        VkDescriptorPool pool;VK_CHECK(vkCreateDescriptorPool(device,&pool_info,nullptr,&pool));
        VkDescriptorSetAllocateInfo set_allocation{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};set_allocation.descriptorPool=pool;set_allocation.descriptorSetCount=1;set_allocation.pSetLayouts=&set_layout;
        VkDescriptorSet set;VK_CHECK(vkAllocateDescriptorSets(device,&set_allocation,&set));
        VkDescriptorBufferInfo buffer_descriptor{buffer,0,buffer_info.size};
        VkWriteDescriptorSet descriptor{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};descriptor.dstSet=set;descriptor.dstBinding=0;descriptor.descriptorCount=1;descriptor.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;descriptor.pBufferInfo=&buffer_descriptor;
        vkUpdateDescriptorSets(device,1,&descriptor,0,nullptr);
#endif
        VkCommandPoolCreateInfo command_pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};command_pool_info.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;command_pool_info.queueFamilyIndex=family;
        VkCommandPool command_pool;VK_CHECK(vkCreateCommandPool(device,&command_pool_info,nullptr,&command_pool));
        VkCommandBufferAllocateInfo command_info{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};command_info.commandPool=command_pool;command_info.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;command_info.commandBufferCount=1;
        VkCommandBuffer command;VK_CHECK(vkAllocateCommandBuffers(device,&command_info,&command));
        VkFenceCreateInfo fence_info{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence fence;VK_CHECK(vkCreateFence(device,&fence_info,nullptr,&fence));

        AVBufferRef *frame_pool=api.av_hwframe_ctx_alloc_fn(hardware);require(frame_pool,"Cannot create VA frame pool");
        auto *frame_context=reinterpret_cast<AVHWFramesContext*>(frame_pool->data);
        frame_context->format=AV_PIX_FMT_VAAPI;frame_context->sw_format=AV_PIX_FMT_NV12;
        frame_context->width=width;frame_context->height=height;frame_context->initial_pool_size=4;
        api.check(api.av_hwframe_ctx_init_fn(frame_pool),"VA frame pool initialization");
        VAConfigID vpp_config=VA_INVALID_ID;VAContextID vpp_context=VA_INVALID_ID;
        VA_CHECK(vaCreateConfig(display,VAProfileNone,VAEntrypointVideoProc,nullptr,0,&vpp_config));
        VA_CHECK(vaCreateContext(display,vpp_config,width,height,VA_PROGRESSIVE,nullptr,0,&vpp_context));
        const AVCodec *encoder=api.avcodec_find_encoder_by_name_fn(hevc?"hevc_vaapi":"h264_vaapi");require(encoder,"Requested VA-API encoder is absent from system FFmpeg");
        AVCodecContext *encoding=api.avcodec_alloc_context3_fn(encoder);require(encoding,"Cannot allocate encoder");
        encoding->width=width;encoding->height=height;encoding->pix_fmt=AV_PIX_FMT_VAAPI;
        int encoder_hz=72;uint32_t encoder_bitrate=40'000'000;
#ifdef METEOR_MONADO_BRIDGE
        const char *rate=std::getenv("XRT_COMPOSITOR_NULL_FPS");
        if(rate) {encoder_hz=std::stoi(rate);require(encoder_hz>=20 && encoder_hz<=144,"Invalid XR refresh rate");}
        require(meteor_encoder_bitrate(std::getenv("METEOR_XR_BITRATE_MBPS"),encoder_bitrate,&encoder_bitrate),"Invalid AMD bitrate");
        const char *foveated=std::getenv("METEOR_XR_FOVEATED_ENCODING");
        require(!foveated || !std::strcmp(foveated,"0"),"VA-API spike does not support foveated QP maps");
#endif
        encoding->time_base={1,encoder_hz};encoding->framerate={encoder_hz,1};encoding->bit_rate=encoder_bitrate;
#ifndef METEOR_MONADO_BRIDGE
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_QUALITY")) encoding->compression_level=std::stoi(value);
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_REFS")) encoding->refs=std::stoi(value);
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_MIN_QP")) {
            encoding->qmin=std::stoi(value);require(encoding->qmin>=1 && encoding->qmin<=51,"Invalid minimum QP");
        }
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_SLICES")) {
            encoding->slices=std::stoi(value);require(encoding->slices>=1 && encoding->slices<=128,"Invalid slice count");
        }
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_BUFFER_FRAMES")) {
            int count=std::stoi(value);require(count>=0 && count<=72,"Invalid VBV frame count");
            if(count) {encoding->rc_buffer_size=encoder_bitrate*count/encoder_hz;encoding->rc_initial_buffer_occupancy=encoding->rc_buffer_size;encoding->rc_max_rate=encoder_bitrate;}
        }
#endif
        encoding->gop_size=encoder_hz;encoding->max_b_frames=0;encoding->hw_frames_ctx=api.av_buffer_ref_fn(frame_pool);
        // Main avoids corrupt High/8x8 output observed on Polaris with the
        // pinned FFmpeg 8.0.1 + Mesa stack; preserve resolution and CABAC.
        encoding->profile=hevc?AV_PROFILE_HEVC_MAIN:AV_PROFILE_H264_MAIN;
#ifndef METEOR_MONADO_BRIDGE
        const char *profile=std::getenv("METEOR_VAAPI_PROBE_PROFILE");
        if(!hevc && profile) {
            if(!std::strcmp(profile,"baseline")) encoding->profile=AV_PROFILE_H264_CONSTRAINED_BASELINE;
            else if(!std::strcmp(profile,"main")) encoding->profile=AV_PROFILE_H264_MAIN;
            else {require(!std::strcmp(profile,"high"),"Invalid H264 profile");encoding->profile=AV_PROFILE_H264_HIGH;}
        }
#endif
        encoding->color_range=AVCOL_RANGE_MPEG;encoding->color_primaries=AVCOL_PRI_BT709;
        encoding->color_trc=
#ifdef METEOR_MONADO_BRIDGE
            meteor_eye_format_srgb(request.eye_formats[0])?AVCOL_TRC_IEC61966_2_1:
#endif
            AVCOL_TRC_BT709;encoding->colorspace=AVCOL_SPC_BT709;
        AVDictionary *options=nullptr;
        const char *rate_control="CBR";
#ifndef METEOR_MONADO_BRIDGE
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_RC_MODE")) {
            require(!std::strcmp(value,"CBR")||!std::strcmp(value,"CQP")||!std::strcmp(value,"VBR"),"Invalid diagnostic rate control");rate_control=value;
        }
        if(!std::strcmp(rate_control,"CQP")) api.av_dict_set_fn(&options,"qp","24",0);
#endif
        std::fprintf(stderr,"VA encoder configuration: codec=%s profile=%d rc=%s fps=%d dimensions=%dx%d\n",hevc?"hevc":"h264",encoding->profile,rate_control,encoder_hz,width,height);
#ifndef METEOR_MONADO_BRIDGE
        if(const char *value=std::getenv("METEOR_VAAPI_PROBE_CODER")) {require(!std::strcmp(value,"cavlc")||!std::strcmp(value,"cabac"),"Invalid coder");if(!hevc) api.av_dict_set_fn(&options,"coder",value,0);}
#endif
        api.av_dict_set_fn(&options,"rc_mode",rate_control,0);api.av_dict_set_fn(&options,"async_depth","1",0);
        api.check(api.avcodec_open2_fn(encoding,encoder,&options),"Opening hardware encoder");api.av_dict_free_fn(&options);
        AVFrame *frame=api.av_frame_alloc_fn();AVPacket *packet=api.av_packet_alloc_fn();require(frame&&packet,"Cannot allocate frame/packet");
        #ifdef METEOR_MONADO_BRIDGE
        std::fprintf(stderr,"METEOR_VIDEO_CONFIG eye_size=%u bitrate_bps=%u\n",eye_size,encoder_bitrate);
        std::fprintf(stderr,"METEOR_VIDEO_CODEC codec=%s fps=%d\n",hevc?"h265":"h264",encoder_hz);
        std::fprintf(stderr,"METEOR_ENCODER_INIT backend=vaapi codec=%s width=%d height=%d\n",hevc?"hevc":"h264",width,height);
        std::fprintf(stderr,"METEOR_SOURCE_FORMAT left=%d right=%d packed=%d preserve_display_bytes=1\n",int(request.eye_formats[0]),int(request.eye_formats[1]),int(packed_format));
#endif
        std::ofstream output(argv[7],std::ios::binary);require(bool(output),"Cannot open encoded output");
        int packet_count=0;uint64_t bytes=0;
        auto receive=[&] {
            while(true) {
                int result=api.avcodec_receive_packet_fn(encoding,packet);
                if(result==AVERROR(EAGAIN)||result==AVERROR_EOF) break;
                api.check(result,"Receiving encoded packet");
                output.write(reinterpret_cast<char*>(packet->data),packet->size);output.flush();require(bool(output),"Cannot write packet");
#ifdef METEOR_MONADO_BRIDGE
                if(request.encoded_callback) require(request.encoded_callback(request.callback_context,packet->data,packet->size),"Encoded callback failed");
#endif
                ++packet_count;bytes+=packet->size;api.av_packet_unref_fn(packet);
            }
        };
        std::vector<double> compute_ms,convert_ms,encode_ms,total_ms;
        [[maybe_unused]] auto loop_start=Clock::now();
#ifdef METEOR_MONADO_BRIDGE
        const bool inspect_pixels=std::getenv("METEOR_VAAPI_INSPECT_PIXELS")!=nullptr;
        VkBuffer inspect_buffer=VK_NULL_HANDLE;VkDeviceMemory inspect_memory=VK_NULL_HANDLE;
        if(inspect_pixels) {
            VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};info.size=buffer_info.size;info.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
            VK_CHECK(vkCreateBuffer(device,&info,nullptr,&inspect_buffer));VkMemoryRequirements req;vkGetBufferMemoryRequirements(device,inspect_buffer,&req);
            uint32_t type=memory_properties.memoryTypeCount;
            for(uint32_t i=0;i<memory_properties.memoryTypeCount;++i) if((req.memoryTypeBits&(1u<<i)) &&
                (memory_properties.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {type=i;break;}
            require(type<memory_properties.memoryTypeCount,"No oracle readback memory");
            VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};allocation.allocationSize=req.size;allocation.memoryTypeIndex=type;
            VK_CHECK(vkAllocateMemory(device,&allocation,nullptr,&inspect_memory));VK_CHECK(vkBindBufferMemory(device,inspect_buffer,inspect_memory,0));
        }
#endif
#ifdef METEOR_MONADO_BRIDGE
        MeteorLiveBitrate bitrate_updates;bool applied_foveation=false;
#endif
        int submitted=0;
        for(int i=0;
#ifdef METEOR_MONADO_BRIDGE
            true;
#else
            i<frames;
#endif
            ++i) {
#ifdef METEOR_MONADO_BRIDGE
            require(request.device==device && request.gpu==gpu && request.queue==queue && request.queue_family==family,"Compositor device changed");
            require((request.eye_size?request.eye_size:256)==eye_size && (request.eye_height?request.eye_height:eye_size)==eye_height,"XR dimensions changed within a session");
            require(meteor_eye_formats_compatible(request.eye_formats[0],request.eye_formats[1]) &&
                    meteor_eye_format_srgb(request.eye_formats[0])==(packed_format==VK_FORMAT_R8G8B8A8_SRGB),"Source transfer function changed");
            require(request.quad_count<=METEOR_MAX_QUADS && (!request.quad_count || request.quads),"Invalid layers");
            if(previous_quads!=request.quad_count || previous_projection!=request.projection_present) {
                std::fprintf(stderr,"METEOR_COMPOSITION projection=%u quads=%u gpu=1\n",request.projection_present,request.quad_count);
                previous_quads=request.quad_count;previous_projection=request.projection_present;
            }
            if(request.quad_count&&!quad_initialized) {quads.init(gpu,device,packed,packed_format,eye_size,eye_height);quad_initialized=true;}
#endif
#ifdef METEOR_MONADO_BRIDGE
            bitrate_updates.poll(std::getenv("METEOR_PROBE_OUTPUT"),40'000'000,encoder_bitrate,[](uint32_t) {return 95;});
            meteor_poll_foveation(std::getenv("METEOR_PROBE_OUTPUT"),applied_foveation,false);
#endif
            auto start=Clock::now();
            VK_CHECK(vkResetCommandBuffer(command,0));
            VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            VK_CHECK(vkBeginCommandBuffer(command,&begin));
            VkBufferMemoryBarrier acquire{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};acquire.buffer=buffer;acquire.offset=0;acquire.size=VK_WHOLE_SIZE;
            acquire.srcQueueFamilyIndex=i?VK_QUEUE_FAMILY_FOREIGN_EXT:VK_QUEUE_FAMILY_IGNORED;acquire.dstQueueFamilyIndex=i?family:VK_QUEUE_FAMILY_IGNORED;
            acquire.dstAccessMask=
#ifdef METEOR_MONADO_BRIDGE
                VK_ACCESS_TRANSFER_WRITE_BIT;
#else
                VK_ACCESS_SHADER_WRITE_BIT;
#endif
            vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT|VK_PIPELINE_STAGE_TRANSFER_BIT),0,0,nullptr,1,&acquire,0,nullptr);
#ifdef METEOR_MONADO_BRIDGE
            VkImageMemoryBarrier target{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};target.image=packed;
            target.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED;target.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            target.srcQueueFamilyIndex=target.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
            target.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;target.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
            vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&target);
            meteor_record_stereo(command,&request,packed,family,eye_size,eye_height,quads);
            target.oldLayout=request.quad_count?VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL:VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            target.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            target.srcAccessMask=request.quad_count?VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT:VK_ACCESS_TRANSFER_WRITE_BIT;
            target.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
            vkCmdPipelineBarrier(command,request.quad_count?VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT:VK_PIPELINE_STAGE_TRANSFER_BIT,
                                 VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&target);
            VkBufferImageCopy copy{};copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};copy.imageExtent={uint32_t(width),uint32_t(height),1};
            vkCmdCopyImageToBuffer(command,packed,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buffer,1,&copy);
#else
            uint32_t parameters[]={uint32_t(width),uint32_t(height),uint32_t(i)};
            vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);
            vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline_layout,0,1,&set,0,nullptr);
            vkCmdPushConstants(command,pipeline_layout,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(parameters),parameters);
            vkCmdDispatch(command,(width+15)/16,(height+15)/16,1);
#endif
#ifdef METEOR_MONADO_BRIDGE
            if(inspect_pixels && i==0) {
                VkBufferMemoryBarrier inspect_barrier=acquire;inspect_barrier.srcQueueFamilyIndex=inspect_barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
                inspect_barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;inspect_barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
                vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,1,&inspect_barrier,0,nullptr);
                VkBufferCopy copy{0,0,buffer_info.size};vkCmdCopyBuffer(command,buffer,inspect_buffer,1,&copy);
            }
#endif
            VkBufferMemoryBarrier release=acquire;
            release.srcQueueFamilyIndex=family;release.dstQueueFamilyIndex=VK_QUEUE_FAMILY_FOREIGN_EXT;
            release.srcAccessMask=acquire.dstAccessMask;release.dstAccessMask=0;
            vkCmdPipelineBarrier(command,(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT|VK_PIPELINE_STAGE_TRANSFER_BIT),VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,1,&release,0,nullptr);
            VK_CHECK(vkEndCommandBuffer(command));
            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&command;
            VK_CHECK(vkQueueSubmit(queue,1,&submit,fence));VK_CHECK(vkWaitForFences(device,1,&fence,VK_TRUE,10'000'000'000ULL));
            VK_CHECK(vkResetFences(device,1,&fence));
#ifdef METEOR_MONADO_BRIDGE
            if(inspect_pixels && i==0) {
                void *pixels=nullptr;VK_CHECK(vkMapMemory(device,inspect_memory,0,buffer_info.size,0,&pixels));
                std::ofstream inspection(std::string(argv[7])+".rgba",std::ios::binary);inspection.write(static_cast<const char*>(pixels),buffer_info.size);
                vkUnmapMemory(device,inspect_memory);std::fprintf(stderr,"METEOR_DEBUG_PIXEL_READBACK enabled=1 diagnostic_only=1\n");
            }
#endif
            double compute_elapsed=milliseconds(start);
#ifdef METEOR_MONADO_BRIDGE
            std::fprintf(stderr,"GPU_PACK frame=%llu us=%lld\n",(unsigned long long)request.frame_id,(long long)(compute_elapsed*1000));
#endif
            api.check(api.av_hwframe_get_buffer_fn(frame_pool,frame,0),"Getting encoder surface");
            const VASurfaceID destination=VASurfaceID(reinterpret_cast<uintptr_t>(frame->data[3]));
            auto convert_start=Clock::now();
            VARectangle rectangle{0,0,uint16_t(width),uint16_t(height)};
            VAProcPipelineParameterBuffer conversion{};conversion.surface=rgba_surface;
            conversion.surface_region=&rectangle;conversion.output_region=&rectangle;
            conversion.surface_color_standard=VAProcColorStandardBT709;conversion.output_color_standard=VAProcColorStandardBT709;
            conversion.input_color_properties.color_range=VA_SOURCE_RANGE_FULL;
            conversion.output_color_properties.color_range=VA_SOURCE_RANGE_REDUCED;
            VABufferID conversion_buffer=VA_INVALID_ID;
            VA_CHECK(vaCreateBuffer(display,vpp_context,VAProcPipelineParameterBufferType,sizeof(conversion),1,&conversion,&conversion_buffer));
            VA_CHECK(vaBeginPicture(display,vpp_context,destination));VA_CHECK(vaRenderPicture(display,vpp_context,&conversion_buffer,1));VA_CHECK(vaEndPicture(display,vpp_context));
            // Diagnostic only: test the driver's implicit VPP -> encode dependency.
            // Output is still drained before reusing the shared source next frame.
#ifndef METEOR_MONADO_BRIDGE
            if(!std::getenv("METEOR_VAAPI_PROBE_IMPLICIT_VPP_SYNC"))
#endif
                VA_CHECK(vaSyncSurface(display,destination));
            VA_CHECK(vaDestroyBuffer(display,conversion_buffer));
            double convert_elapsed=milliseconds(convert_start);
            auto encode_start=Clock::now();frame->pts=i;
            api.check(api.avcodec_send_frame_fn(encoding,frame),"Sending encoder frame");receive();api.av_frame_unref_fn(frame);
            if(i>=8) {compute_ms.push_back(compute_elapsed);convert_ms.push_back(convert_elapsed);encode_ms.push_back(milliseconds(encode_start));total_ms.push_back(milliseconds(start));}
            ++submitted;
#ifndef METEOR_MONADO_BRIDGE
            std::fprintf(stderr,"PROBE_PROGRESS frame=%d packets=%d\n",submitted,packet_count);
#endif
#ifdef METEOR_MONADO_BRIDGE
            std::fprintf(stderr,"METEOR_VAAPI_ENCODE frame=%llu packets=%d\n",(unsigned long long)request.frame_id,packet_count);
            require(packet_count==submitted,"VA encoder buffered output unexpectedly");
            std::fprintf(stderr,"METEOR_VAAPI_TIMING encode_us=%lld vpp_us=%lld\n",(long long)(milliseconds(encode_start)*1000),(long long)(convert_elapsed*1000));
            bridge_complete();
            if(!bridge_next(request)) break;
#else
            if(pace_hz) std::this_thread::sleep_until(loop_start+std::chrono::microseconds((int64_t(i)+1)*1'000'000/pace_hz));
#endif
        }
        api.check(api.avcodec_send_frame_fn(encoding,nullptr),"Flushing encoder");receive();output.close();
#ifndef METEOR_MONADO_BRIDGE
        double elapsed=milliseconds(loop_start);
        require(packet_count==submitted,"Encoder did not return one packet per frame");
        std::ofstream report(argv[8]);
        report<<"{\n  \"gpu\": "<<std::quoted(gpu_name)<<",\n  \"codec\": "<<std::quoted(argv[2])
            <<",\n  \"width\": "<<width<<",\n  \"height\": "<<height<<",\n  \"frames\": "<<frames<<",\n  \"packets\": "<<packet_count
            <<",\n  \"encoded_bytes\": "<<bytes<<",\n  \"observed_fps\": "<<frames*1000.0/elapsed<<",\n  \"pacing_hz\": "<<pace_hz
            <<",\n  \"compute_ms_p50\": "<<percentile(compute_ms,.5)<<",\n  \"vpp_ms_p50\": "<<percentile(convert_ms,.5)
            <<",\n  \"encode_ms_p50\": "<<percentile(encode_ms,.5)<<",\n  \"total_ms_p50\": "<<percentile(total_ms,.5)
            <<",\n  \"total_ms_p95\": "<<percentile(total_ms,.95)<<",\n  \"cpu_pixel_transfers\": false,\n  \"serialized_probe\": true\n}\n";
        std::fprintf(stderr,"PASS GPU-only pixel path: %d packets, %.1f fps, total p50 %.2f ms, p95 %.2f ms\n",packet_count,frames*1000.0/elapsed,percentile(total_ms,.5),percentile(total_ms,.95));
#else
        std::fprintf(stderr,"METEOR_ENCODER_DRAIN frames=%d backend=vaapi\n",submitted);
#endif
        api.av_packet_free_fn(&packet);api.av_frame_free_fn(&frame);api.avcodec_free_context_fn(&encoding);api.av_buffer_unref_fn(&frame_pool);
        VA_CHECK(vaDestroyContext(display,vpp_context));VA_CHECK(vaDestroyConfig(display,vpp_config));
        VK_CHECK(vkDeviceWaitIdle(device));vkDestroyFence(device,fence,nullptr);vkDestroyCommandPool(device,command_pool,nullptr);
#ifdef METEOR_MONADO_BRIDGE
        if(inspect_pixels) {vkDestroyBuffer(device,inspect_buffer,nullptr);vkFreeMemory(device,inspect_memory,nullptr);}
        if(quad_initialized) quads.destroy();
        vkDestroyImage(device,packed,nullptr);vkFreeMemory(device,packed_memory,nullptr);
#else
        vkDestroyPipeline(device,pipeline,nullptr);vkDestroyShaderModule(device,shader,nullptr);vkDestroyDescriptorPool(device,pool,nullptr);
        vkDestroyPipelineLayout(device,pipeline_layout,nullptr);vkDestroyDescriptorSetLayout(device,set_layout,nullptr);
#endif
        VA_CHECK(vaDestroySurfaces(display,&rgba_surface,1));
        vkDestroyBuffer(device,buffer,nullptr);vkFreeMemory(device,memory,nullptr);
#ifndef METEOR_MONADO_BRIDGE
        vkDestroyDevice(device,nullptr);vkDestroyInstance(instance,nullptr);
#endif
        api.av_buffer_unref_fn(&hardware);close(drm);
#ifdef METEOR_MONADO_BRIDGE
        std::fprintf(stderr,"METEOR_ENCODER_RELEASED backend=vaapi\n");
#endif
        return 0;
    } catch(const std::exception &error) {std::fprintf(stderr,"VAAPI PROBE FAILED: %s\n",error.what());return 1;}
}

#ifdef METEOR_MONADO_BRIDGE
extern "C" void meteor_encode_stereo_v1(const meteor_stereo_encode_v1 *input) {
    REQUIRE(input && input->size == sizeof(*input) && input->layer_abi==METEOR_LAYER_ABI && input->layer_stride==sizeof(meteor_layer_v2), "Bridge ABI size/version mismatch");
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
