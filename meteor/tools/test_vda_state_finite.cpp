#include "../native/vda_finite.h"
#include <cstdio>
#include <cstring>
int main() {
    if (ncnn::create_gpu_instance() || ncnn::get_gpu_count()<1) return 2;
    auto* gpu=ncnn::get_gpu_device(0);ncnn::VkBlobAllocator allocator(gpu);ncnn::VkStagingAllocator staging(gpu);
    ncnn::Option opt;opt.use_vulkan_compute=true;opt.use_fp16_storage=true;opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;
    opt.blob_vkallocator=&allocator;opt.workspace_vkallocator=&allocator;opt.staging_vkallocator=&staging;
    auto pipeline=vda_finite_pipeline(gpu,opt);
    ncnn::Option raw=opt;raw.use_fp16_storage=false;raw.use_fp16_packed=false;raw.use_packing_layout=false;
    for (unsigned bits : {0u,0x3c003c00u,0x7bfffbffu,0x7c003c00u,0x3c00fc00u,0x7e003c00u,0x3c007e00u}) {
        ncnn::Mat data(1),zero(1),bad;std::memcpy(data.data,&bits,4);*static_cast<unsigned*>(zero.data)=0;
        ncnn::VkMat input,flag;ncnn::VkCompute cmd(gpu);cmd.record_clone(data,input,raw);cmd.record_clone(zero,flag,raw);
        std::vector<ncnn::vk_constant_type> constants(1);constants[0].i=1;ncnn::Mat dispatch;dispatch.w=128;dispatch.h=dispatch.c=1;
        cmd.record_pipeline(pipeline.get(),{input,flag},{},constants,dispatch);cmd.record_clone(flag,bad,raw);
        if (cmd.submit_and_wait()) return 3;
        bool expected=(bits&0x7c00u)==0x7c00u || (bits&0x7c000000u)==0x7c000000u;
        unsigned actual=*static_cast<unsigned*>(bad.data);
        std::printf("half_bits=%08x expected=%u actual=%u\n",bits,unsigned(expected),actual);
        if (actual!=unsigned(expected)) return 1;
    }
}
