// Diagnostic allocator: forbid reuse of released buffers until the previous
// frame's GPU work has completed. This deliberately increases peak memory.
#pragma once
#include <allocator.h>
#include <option.h>
#include <vector>
#include <cstdio>
#include <algorithm>
class VdaDeferredAllocator : public ncnn::VkBlobAllocator {
public:
    explicit VdaDeferredAllocator(const ncnn::VulkanDevice* device) : ncnn::VkBlobAllocator(device) {}
    ~VdaDeferredAllocator() override {
        drain();
        std::fprintf(stderr,"deferred_allocator_peak_buffer_capacity_bytes=%zu\n",peak);
    }
    using ncnn::VkBlobAllocator::fastMalloc;
    ncnn::VkBufferMemory* fastMalloc(size_t size) override {
        auto* ptr=ncnn::VkBlobAllocator::fastMalloc(size);
        if (ptr) { outstanding+=ptr->capacity;peak=std::max(peak,outstanding); }
        return ptr;
    }
    using ncnn::VkBlobAllocator::fastFree;
    void fastFree(ncnn::VkBufferMemory* ptr) override { deferred.push_back(ptr); }
    void drain() {
        for (auto* ptr : deferred) {
            outstanding-=ptr->capacity;
            ncnn::VkBlobAllocator::fastFree(ptr);
        }
        deferred.clear();
    }
private:
    std::vector<ncnn::VkBufferMemory*> deferred;
    size_t outstanding=0,peak=0;
};
inline void vda_drain_completed_buffers(ncnn::VkAllocator* allocator) {
    if (auto* deferred=dynamic_cast<VdaDeferredAllocator*>(allocator)) deferred->drain();
}
inline void vda_drain_completed_buffers(const ncnn::Option& opt) {
    vda_drain_completed_buffers(opt.blob_vkallocator);
    if (opt.workspace_vkallocator!=opt.blob_vkallocator) vda_drain_completed_buffers(opt.workspace_vkallocator);
}

// Diagnostic alternative: permit immediate range reuse, but make the first
// use wait for previous accesses to that range. Native allocation initializes
// new metadata to TOP_OF_PIPE / no access even when its backing range is reused.
// Conservatively cover both reads (overwrite hazards) and writes (visibility).
class VdaImmediateAllocator : public ncnn::VkBlobAllocator {
public:
    explicit VdaImmediateAllocator(const ncnn::VulkanDevice* device,bool enable_barrier=true)
        : ncnn::VkBlobAllocator(device),enable_barrier(enable_barrier) {}
    ~VdaImmediateAllocator() override {
        std::fprintf(stderr,"immediate_allocator_peak_buffer_capacity_bytes=%zu first_use_barrier=%d\n",peak,int(enable_barrier));
    }
    using ncnn::VkBlobAllocator::fastMalloc;
    using ncnn::VkBlobAllocator::fastFree;
    ncnn::VkBufferMemory* fastMalloc(size_t size) override {
        auto* ptr=ncnn::VkBlobAllocator::fastMalloc(size);
        if (ptr) {
            outstanding+=ptr->capacity;peak=std::max(peak,outstanding);
            if (enable_barrier) {
                ptr->access_flags=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
                ptr->stage_flags=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            }
        }
        return ptr;
    }
    void fastFree(ncnn::VkBufferMemory* ptr) override {
        outstanding-=ptr->capacity;
        ncnn::VkBlobAllocator::fastFree(ptr);
    }
private:
    size_t outstanding=0,peak=0;
    bool enable_barrier;
};
