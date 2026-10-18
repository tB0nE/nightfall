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

static void check(XrResult result, const char *operation) {
    if (XR_FAILED(result)) { std::fprintf(stderr, "%s failed: %d\n", operation, result); std::exit(1); }
}
#include "monado_stereo_images.h"
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
    for (uint32_t i = 0; i < queue_count; ++i) if (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { queue_family = i; break; }
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
    XrReferenceSpaceCreateInfo space_info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    const bool tracked_scene=std::getenv("METEOR_XR_TRACKED_SCENE") != nullptr;
    // Monado STAGE is the root space for this simulated device, unlike its
    // startup-recentered LOCAL. The bridge adopts Quest LOCAL as that root.
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
    StereoImages stereo(session, gpu, device, queue_family);
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
        for (int eye = 0; eye < 2; ++eye) {
            stereo.write(eye, frame, tracked_scene ? &views[eye] : nullptr);
            projection_views[eye].pose = views[eye].pose; projection_views[eye].fov = views[eye].fov;
            projection_views[eye].subImage.swapchain = stereo.chains[eye];
            projection_views[eye].subImage.imageRect.extent = {static_cast<int32_t>(StereoImages::width), static_cast<int32_t>(StereoImages::height)};
        }
        XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        layer.space = space; layer.viewCount = 2; layer.views = projection_views;
        const XrCompositionLayerBaseHeader *layers[] = {reinterpret_cast<const XrCompositionLayerBaseHeader *>(&layer)};
        // GPU encode diagnostic submits only the final known frame; otherwise
        // compositor pacing may skip intermediate frames before encoding starts.
        end.layerCount = (continuous || !std::getenv("METEOR_NVENC_BRIDGE") || frame == 4) ? 1 : 0;
        end.layers = layers;
        check(xrEndFrame(session, &end), "end frame");
        struct timespec monotonic_time;
        check(xrConvertTimeToTimespecTimeKHR(instance, state.predictedDisplayTime, &monotonic_time), "convert display time");
        final_timestamp = static_cast<long long>(monotonic_time.tv_sec)*1000000000LL+monotonic_time.tv_nsec;
        std::printf("Frame %d monotonic_ns=%lld\n", frame,
            static_cast<long long>(monotonic_time.tv_sec) * 1000000000LL + monotonic_time.tv_nsec);
        std::printf("Frame %d: two pixel-verified eye images, submitted layers=%u, predicted time %lld\n", frame, end.layerCount, static_cast<long long>(state.predictedDisplayTime));
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
    check(xrDestroySpace(space), "destroy space"); check(xrDestroySession(session), "destroy session");
    vkDestroyDevice(device, nullptr); vkDestroyInstance(vk_instance, nullptr);
    check(xrDestroyInstance(instance), "destroy instance");
    return 0;
}
