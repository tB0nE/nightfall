#define XR_USE_GRAPHICS_API_VULKAN
#define XR_USE_TIMESPEC
#include <time.h>
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <thread>
#include <chrono>
#include <memory>
#include <fstream>
#include <string>

static void check(XrResult result, const char *operation) {
    if (XR_FAILED(result)) { std::fprintf(stderr, "%s failed: %d\n", operation, result); std::exit(1); }
}
#include "monado_stereo_images.h"
#include "meteor_openxr_input_probe.h"
int main() {
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    uint32_t count = 0;
    check(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr), "extensions");
    std::vector<XrExtensionProperties> extensions(count, {XR_TYPE_EXTENSION_PROPERTIES});
    check(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, extensions.data()), "extensions");
    bool vulkan = false;
    for (const auto &extension : extensions) if (!std::strcmp(extension.extensionName, XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME)) vulkan = true;
    if (!vulkan) { std::fprintf(stderr, "Vulkan binding unavailable\n"); return 1; }
    const char *enabled[] = {XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME, XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME};
    XrInstanceCreateInfo info{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strcpy(info.applicationInfo.applicationName, "Nightfall Monado runtime probe");
    info.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    info.enabledExtensionCount = 2; info.enabledExtensionNames = enabled;
    XrInstance instance; check(xrCreateInstance(&info, &instance), "create instance");
    XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
    check(xrGetInstanceProperties(instance, &properties), "runtime properties");
    std::printf("Runtime: %s\n", properties.runtimeName);
    XrSystemGetInfo system_info{XR_TYPE_SYSTEM_GET_INFO}; system_info.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system; check(xrGetSystem(instance, &system_info, &system), "get simulated HMD");
#define GET_XR_PROC(name) PFN_##name name = nullptr; check(xrGetInstanceProcAddr(instance, #name, reinterpret_cast<PFN_xrVoidFunction *>(&name)), #name)
    GET_XR_PROC(xrGetVulkanGraphicsRequirements2KHR);
    GET_XR_PROC(xrCreateVulkanInstanceKHR);
    GET_XR_PROC(xrGetVulkanGraphicsDevice2KHR);
    GET_XR_PROC(xrCreateVulkanDeviceKHR);
    GET_XR_PROC(xrConvertTimeToTimespecTimeKHR);
#undef GET_XR_PROC
    XrGraphicsRequirementsVulkan2KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR};
    check(xrGetVulkanGraphicsRequirements2KHR(instance, system, &requirements), "graphics requirements");
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo vk_info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; vk_info.pApplicationInfo = &app;
    XrVulkanInstanceCreateInfoKHR vk_create{XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR};
    vk_create.systemId = system; vk_create.pfnGetInstanceProcAddr = vkGetInstanceProcAddr; vk_create.vulkanCreateInfo = &vk_info;
    VkInstance vk_instance; VkResult vk_result;
    check(xrCreateVulkanInstanceKHR(instance, &vk_create, &vk_instance, &vk_result), "Vulkan instance");
    if (vk_result != VK_SUCCESS) return 1;
    XrVulkanGraphicsDeviceGetInfoKHR gpu_info{XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR};
    gpu_info.systemId = system; gpu_info.vulkanInstance = vk_instance;
    VkPhysicalDevice gpu; check(xrGetVulkanGraphicsDevice2KHR(instance, &gpu_info, &gpu), "Vulkan device");
    uint32_t queue_count = 0; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &queue_count, nullptr);
    std::vector<VkQueueFamilyProperties> queues(queue_count); vkGetPhysicalDeviceQueueFamilyProperties(gpu, &queue_count, queues.data());
    uint32_t queue_family = queue_count;
    const VkQueueFlags required_queue=VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    for (uint32_t i = 0; i < queue_count; ++i) if ((queues[i].queueFlags & required_queue)==required_queue) { queue_family = i; break; }
    if (queue_family == queue_count) return 1;
    float priority = 1;
    VkDeviceQueueCreateInfo queue_info{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    queue_info.queueFamilyIndex = queue_family; queue_info.queueCount = 1; queue_info.pQueuePriorities = &priority;
    VkDeviceCreateInfo device_info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; device_info.queueCreateInfoCount = 1; device_info.pQueueCreateInfos = &queue_info;
    XrVulkanDeviceCreateInfoKHR device_create{XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR};
    device_create.systemId = system; device_create.pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    device_create.vulkanPhysicalDevice = gpu; device_create.vulkanCreateInfo = &device_info;
    VkDevice device; check(xrCreateVulkanDeviceKHR(instance, &device_create, &device, &vk_result), "create Vulkan device");
    if (vk_result != VK_SUCCESS) return 1;
    XrGraphicsBindingVulkan2KHR binding{XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR};
    binding.instance = vk_instance; binding.physicalDevice = gpu; binding.device = device; binding.queueFamilyIndex = queue_family;
    XrSessionCreateInfo session_info{XR_TYPE_SESSION_CREATE_INFO}; session_info.systemId = system;
    session_info.next = &binding;
    XrSession session; check(xrCreateSession(instance, &session_info, &session), "offscreen graphics session");
    MeteorInputProbe input_probe(instance,session);
    XrReferenceSpaceCreateInfo space_info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    const bool tracked_scene=std::getenv("METEOR_XR_TRACKED_SCENE") != nullptr;
    // Monado STAGE is the root space for this simulated device, unlike its
    // startup-recentered LOCAL. The bridge adopts the client's tracking space
    // as that root (floor-relative STAGE on the updated Quest client).
    space_info.referenceSpaceType = tracked_scene ? XR_REFERENCE_SPACE_TYPE_STAGE : XR_REFERENCE_SPACE_TYPE_LOCAL;
    space_info.poseInReferenceSpace.orientation.w = 1;
    XrSpace space; check(xrCreateReferenceSpace(session, &space_info, &space), "local space");
    bool running = false;
    for (int attempt = 0; attempt < 100 && !running; ++attempt) {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        XrResult result = xrPollEvent(instance, &event);
        if (result == XR_EVENT_UNAVAILABLE) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }
        check(result, "poll event");
        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED &&
            reinterpret_cast<XrEventDataSessionStateChanged *>(&event)->state == XR_SESSION_STATE_READY) {
            XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
            check(xrBeginSession(session, &begin), "begin session"); running = true;
        }
    }
    if (!running) { std::fprintf(stderr, "Session never became READY\n"); return 1; }
    if(input_probe.enabled) { input_probe.run(); return 0; }
    StereoImages stereo(session, gpu, device, queue_family);
    const bool quad_fixture=std::getenv("METEOR_XR_QUAD_FIXTURE")!=nullptr;
    stereo.fixed_background=quad_fixture;
    std::unique_ptr<StereoImages> quad_images;
    XrSpace quad_space=XR_NULL_HANDLE;
    if(quad_fixture) {
        quad_images=std::make_unique<StereoImages>(session,gpu,device,queue_family);
        quad_images->quad_texture=true;
        XrReferenceSpaceCreateInfo view_space{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        view_space.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_VIEW; view_space.poseInReferenceSpace.orientation.w=1;
        check(xrCreateReferenceSpace(session,&view_space,&quad_space),"quad view space");
    }
    const char *continuous = std::getenv("METEOR_CONTINUOUS_FRAMES");
    const int frame_count = continuous ? std::atoi(continuous) : 5;
    if (frame_count < 1 || frame_count > 240) return 1;
    const bool free_running = std::getenv("METEOR_XR_FREE_RUNNING") != nullptr;
    if (free_running && (!continuous || !std::getenv("METEOR_NVENC_BRIDGE"))) return 2;
    long long final_timestamp = 0;
    for (int frame = 0; frame < frame_count; ++frame) {
        XrFrameWaitInfo wait{XR_TYPE_FRAME_WAIT_INFO}; XrFrameState state{XR_TYPE_FRAME_STATE};
        check(xrWaitFrame(session, &wait, &state), "wait frame");
        XrFrameBeginInfo begin{XR_TYPE_FRAME_BEGIN_INFO}; check(xrBeginFrame(session, &begin), "begin frame");
        XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO}; locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        locate.displayTime = state.predictedDisplayTime; locate.space = space;
        XrViewState view_state{XR_TYPE_VIEW_STATE}; XrView views[2]{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
        check(xrLocateViews(session, &locate, &view_state, 2, &count, views), "locate stereo views");
        if (count != 2 || state.predictedDisplayTime <= 0 ||
            !(view_state.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT)) return 1;
        if (std::getenv("METEOR_TRACKING_BRIDGE")) {
            std::printf("Tracked view frame=%d left_position=%.6f,%.6f,%.6f orientation=%.6f,%.6f,%.6f,%.6f\n",
                frame, views[0].pose.position.x, views[0].pose.position.y, views[0].pose.position.z,
                views[0].pose.orientation.x, views[0].pose.orientation.y, views[0].pose.orientation.z, views[0].pose.orientation.w);
            std::printf("Tracked center=%.6f,%.6f,%.6f\n",
                (views[0].pose.position.x+views[1].pose.position.x)*.5f,
                (views[0].pose.position.y+views[1].pose.position.y)*.5f,
                (views[0].pose.position.z+views[1].pose.position.z)*.5f);
        }
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime = state.predictedDisplayTime; end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        XrCompositionLayerProjectionView projection_views[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}, {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
        auto render_start=std::chrono::steady_clock::now();
        for (int eye = 0; eye < 2; ++eye) {
            stereo.write(eye, frame, tracked_scene && !quad_fixture ? &views[eye] : nullptr);
            projection_views[eye].pose = views[eye].pose; projection_views[eye].fov = views[eye].fov;
            projection_views[eye].subImage.swapchain = stereo.chains[eye];
            projection_views[eye].subImage.imageArrayIndex=stereo.slices[eye];
            projection_views[eye].subImage.imageRect.offset={stereo.offsets[eye][0],stereo.offsets[eye][1]};
            projection_views[eye].subImage.imageRect.extent = {static_cast<int32_t>(stereo.width), static_cast<int32_t>(stereo.height)};
        }
        std::printf("APP_RENDER frame=%d us=%lld\n",frame,(long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-render_start).count());
        XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        layer.space = space; layer.viewCount = 2; layer.views = projection_views;
        const XrCompositionLayerBaseHeader *layers[9] = {reinterpret_cast<const XrCompositionLayerBaseHeader *>(&layer)};
        XrCompositionLayerQuad quads[8]{};
        const bool overlay_only_frame=quad_fixture && (frame/6)%2==0;
        if(quad_fixture) {
            quad_images->write(0,frame);
            for(int i=0;i<8;++i) {
                auto &q=quads[i]; q.type=XR_TYPE_COMPOSITION_LAYER_QUAD; q.space=quad_space;
                q.layerFlags=XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT|XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
                q.eyeVisibility=i==0 ? XR_EYE_VISIBILITY_LEFT : i==1 ? XR_EYE_VISIBILITY_RIGHT : XR_EYE_VISIBILITY_BOTH;
                q.pose.orientation.w=1; q.pose.position={float(i%3-1)*.8f,.6f-float(i/3)*.6f,-2};
                q.size={.5f,.4f}; q.subImage.swapchain=quad_images->chains[0];
                q.subImage.imageRect.extent={int32_t(quad_images->width),int32_t(quad_images->height)};
                layers[i+1]=reinterpret_cast<const XrCompositionLayerBaseHeader *>(&q);
            }
            std::printf("APP_QUAD_FIXTURE count=8 projection=%d shared_image=1 straight_alpha=1 visibility=left,right,both\n",!overlay_only_frame);
        }
        // GPU encode diagnostic submits only the final known frame; otherwise
        // compositor pacing may skip intermediate frames before encoding starts.
        end.layerCount = (continuous || !std::getenv("METEOR_NVENC_BRIDGE") || frame == 4) ? 1 : 0;
        if(quad_fixture && end.layerCount) end.layerCount=overlay_only_frame ? 8 : 9;
        end.layers = overlay_only_frame ? layers+1 : layers;
        check(xrEndFrame(session, &end), "end frame");
        struct timespec monotonic_time;
        check(xrConvertTimeToTimespecTimeKHR(instance, state.predictedDisplayTime, &monotonic_time), "convert display time");
        final_timestamp = static_cast<long long>(monotonic_time.tv_sec)*1000000000LL+monotonic_time.tv_nsec;
        std::printf("Frame %d monotonic_ns=%lld\n", frame,
            static_cast<long long>(monotonic_time.tv_sec) * 1000000000LL + monotonic_time.tv_nsec);
        std::printf("Frame %d: two pixel-verified eye images, submitted layers=%u, predicted time %lld\n", frame, end.layerCount, static_cast<long long>(state.predictedDisplayTime));
        if(quad_fixture && frame==12) {
            // Model a game loading a world while xrizer retains its last
            // submitted static overlays. Tracking/presentation must continue.
            std::printf("APP_QUAD_STATIC_HOLD source_ns=%lld ms=650\n",final_timestamp);
            std::fflush(stdout);
            std::this_thread::sleep_for(std::chrono::milliseconds(650));
        }
        if (continuous && !free_running) {
            // Stop-and-wait diagnostic ensures each changing pattern is checked;
            // this is bounded backpressure, not a sustainable-rate benchmark.
            bool acknowledged = false;
            const long long expected = static_cast<long long>(monotonic_time.tv_sec) * 1000000000LL + monotonic_time.tv_nsec;
            for (int attempt = 0; attempt < 2000; ++attempt) {
                std::ifstream ack(meteor_probe_path("capture-complete"));
                long long received = 0;
                if ((ack >> received) && received == expected) { acknowledged = true; break; }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            if (!acknowledged) { std::fprintf(stderr, "Frame %d acknowledgment timed out\n", frame); return 1; }
        }
    }
    // Diagnostic file acknowledgment only: keep swapchains alive until the
    // asynchronous compositor has consumed frame 4. Not a streaming protocol.
    bool captured = false;
    for (int attempt = 0; attempt < 2000; ++attempt) {
        std::ifstream done(meteor_probe_path("capture-complete"));
        long long received = 0;
        if (continuous ? ((done >> received) && received == final_timestamp) : done.good()) { captured = true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!captured) { std::fprintf(stderr, "Server never acknowledged final stereo capture\n"); return 1; }
    check(xrRequestExitSession(session), "request exit");
    bool stopped = false;
    for (int attempt = 0; attempt < 100 && !stopped; ++attempt) {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        XrResult result = xrPollEvent(instance, &event);
        if (result == XR_EVENT_UNAVAILABLE) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }
        check(result, "poll stop");
        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED &&
            reinterpret_cast<XrEventDataSessionStateChanged *>(&event)->state == XR_SESSION_STATE_STOPPING) {
            check(xrEndSession(session), "end session"); stopped = true;
        }
    }
    if (!stopped) { std::fprintf(stderr, "Session never became STOPPING\n"); return 1; }
    stereo.destroy();
    if(quad_images) { quad_images->destroy(); check(xrDestroySpace(quad_space),"destroy quad space"); }
    check(xrDestroySpace(space), "destroy space"); check(xrDestroySession(session), "destroy session");
    vkDestroyDevice(device, nullptr); vkDestroyInstance(vk_instance, nullptr);
    check(xrDestroyInstance(instance), "destroy instance");
    return 0;
}
