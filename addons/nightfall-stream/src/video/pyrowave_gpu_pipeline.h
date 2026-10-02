#pragma once

// Zero-copy PyroWave decode for Android - see docs/plans/active/pyrowave-zero-copy-gpu.md.
// PyroWave decodes into Vulkan-internal R8 planes inside our own command buffer, our
// fragment pass converts them to RGBA into one of three RGBA8888 AHardwareBuffers, and
// GLES samples that buffer through an EGLImage (TextureUploader's PyroWave GPU output).
// Only the final RGB frame crosses the Vulkan/GLES boundary; sync is SYNC_FD both ways.

#ifdef __ANDROID__

#include <vulkan/vulkan.h>
#include <pyrowave.h>
#include <android/hardware_buffer.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

namespace godot {

class TextureUploader;

// Creates our own VkInstance/VkDevice and wraps it with pyrowave_create_device().
// Must run before Godot creates its GLES context (same constraint as
// pyrowave_warmup_device()). Returns nullptr on any failure; the caller then falls
// back to pyrowave_create_default_device() and the CPU-readback path.
pyrowave_device pyrowave_gpu_create_device();

// True once pyrowave_gpu_create_device() has succeeded.
bool pyrowave_gpu_available();

class PyrowaveGpuPipeline {
public:
    static constexpr int kSlotCount = 3;

    PyrowaveGpuPipeline() = default;
    ~PyrowaveGpuPipeline();

    // Called with a frame's pts once its GPU work has actually completed, from an
    // internal completion thread - this is when the frame counts as decoded.
    using FrameCompleteCallback = std::function<void(int64_t pts)>;

    // Decode-thread only. Allocates planes, the RGBA ring and Vulkan objects, then has
    // TextureUploader import the ring into GLES (blocks until the render thread is done).
    bool init(pyrowave_device device, pyrowave_decoder decoder, bool fragment_path,
              int width, int height, TextureUploader *uploader, FrameCompleteCallback on_complete);
    void destroy();

    // Decode-thread only. Packets must already be pushed and decode_is_ready true.
    // Records decode + conversion, submits, and hands the frame to the uploader.
    bool decode_frame(int64_t pts);

private:
    struct Slot {
        AHardwareBuffer *ahb = nullptr;
        VkImage image = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
        VkDescriptorSet set = VK_NULL_HANDLE;
        VkCommandBuffer cmd = VK_NULL_HANDLE;
        VkFence fence = VK_NULL_HANDLE;
        VkSemaphore ready = VK_NULL_HANDLE;    // exportable SYNC_FD, signaled by our submit
        VkSemaphore released = VK_NULL_HANDLE; // GLES release fence imported temporarily
        bool submitted = false;
    };

    bool create_plane(int index, uint32_t w, uint32_t h);
    bool create_slot(Slot &slot);
    bool create_conversion_pipeline();
    void write_descriptors(Slot &slot);
    void completion_loop();
    void stop_completion_thread();

    // Each entry is a duplicate of a frame's ready sync fd plus its pts; the thread
    // polls them in submission order (GPU work on one queue completes in order).
    FrameCompleteCallback on_complete_;
    std::thread completion_thread_;
    std::mutex completion_mutex_;
    std::condition_variable completion_cv_;
    std::deque<std::pair<int, int64_t>> completion_queue_;
    bool completion_stop_ = false;

    pyrowave_device device_ = nullptr;
    pyrowave_decoder decoder_ = nullptr;
    TextureUploader *uploader_ = nullptr;
    bool fragment_path_ = false;
    uint32_t width_ = 0;
    uint32_t height_ = 0;

    VkImage planes_[3] = {};
    VkDeviceMemory plane_memory_[3] = {};
    VkImageView plane_views_[3] = {};
    pyrowave_gpu_buffers plane_buffers_ = {};

    VkSampler sampler_ = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout_ = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout_ = VK_NULL_HANDLE;
    VkPipeline pipeline_ = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool_ = VK_NULL_HANDLE;
    VkCommandPool command_pool_ = VK_NULL_HANDLE;
    Slot slots_[kSlotCount];


    PyrowaveGpuPipeline(const PyrowaveGpuPipeline &) = delete;
    PyrowaveGpuPipeline &operator=(const PyrowaveGpuPipeline &) = delete;
};

} // namespace godot

#endif
