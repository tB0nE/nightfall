// Probe-only buffer copy through a compute shader, preserving allocation access
// tracking. Unlike record_clone's transfer destination, both bindings receive
// ncnn's read/write barrier handling before dispatch.
#pragma once
#include <layer.h>
#include <algorithm>
#include <cstdint>
class VdaComputeClone {
public:
    explicit VdaComputeClone(const ncnn::VulkanDevice* device) : device(device) {}
    ~VdaComputeClone() { delete pipeline; }
    int initialize() {
        static const char* source=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Source { uint input_data[]; };
layout(binding=1) writeonly buffer Destination { uint output_data[]; };
layout(push_constant) uniform parameter { int words; } p;
void main() {
    uint i=gl_GlobalInvocationID.x;
    if (i<uint(p.words)) output_data[i]=input_data[i];
}
)glsl";
        ncnn::Option opt;opt.use_fp16_storage=false;opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;
        std::vector<uint32_t> spirv;
        int result=ncnn::compile_spirv_module(source,opt,spirv);if (result) return result;
        pipeline=new ncnn::Pipeline(device);pipeline->set_local_size_xyz(64,1,1);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=64;specs[1].i=1;specs[2].i=1;
        result=pipeline->create(spirv.data(),spirv.size()*4,specs);
        if (!result && (pipeline->shader_info().push_constant_count!=1 || pipeline->shader_info().binding_count!=2)) return -1;
        return result;
    }
    int copy(const ncnn::VkMat& source,ncnn::VkMat& destination,ncnn::VkCompute& cmd,const ncnn::Option& opt) const {
        destination.create_like(source,opt.blob_vkallocator);
        if (destination.empty()) return -100;
        size_t bytes=std::min(source.buffer_capacity(),destination.buffer_capacity());
        if (bytes%4 || bytes/4>size_t(INT32_MAX)) return -1;
        if ((bytes/4+63)/64>device->info.max_workgroup_count_x()) return -1;
        std::vector<ncnn::vk_constant_type> constants(1);constants[0].i=int(bytes/4);
        ncnn::Mat dispatch;dispatch.w=constants[0].i;dispatch.h=1;dispatch.c=1;
        cmd.record_pipeline(pipeline,{source,destination},{},constants,dispatch);
        return 0;
    }
private:
    const ncnn::VulkanDevice* device;
    ncnn::Pipeline* pipeline=nullptr;
};
// Single-threaded standalone probe only. Owner in main outlives graph calls.
inline VdaComputeClone* vda_compute_clone=nullptr;
