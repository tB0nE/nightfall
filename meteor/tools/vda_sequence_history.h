// Fixed-shape validation history: same 44 slots / 31-sample selection as
// Meteor's VDA History, with FP16 storage and gather entirely on Vulkan.
#pragma once
#include "vda_settings.h"
#include <layer.h>
#include <array>
#include <algorithm>
#include "vda_resolution.h"

class VdaSequenceHistory {
public:
    static constexpr int count=8,slots=44,history=31;
    const std::array<int,8> tokens;
    const std::array<int,8> channels={192,192,384,384,64,64,64,64};
    VdaSequenceHistory(const ncnn::VulkanDevice* d,ncnn::Option o,VdaFrameShape shape={})
        : tokens(shape.tokens()),device(d),opt(o) {}
    ~VdaSequenceHistory() { delete pipeline; }
    int initialize(bool raw_pool=true) {
        if (!raw_pool) return 0;
        static const char* shader=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Source { sfp source_data[]; };
layout(binding=1) readonly buffer Selection { float selected[]; };
layout(binding=2) writeonly buffer Destination { sfp destination[]; };
layout(push_constant) uniform parameter {
    int width;int tokens;int source_stride;int destination_stride;int slot;int mode;
} p;
void main() {
    int channel=int(gl_GlobalInvocationID.x);
    int time=int(gl_GlobalInvocationID.y);
    int token=int(gl_GlobalInvocationID.z);
    if (channel>=p.width || token>=p.tokens) return;
    if (p.mode==0) {
        destination[token*p.destination_stride+p.slot*p.width+channel]=
            source_data[token*p.source_stride+channel];
    } else if (time<31) {
        int slot=int(selected[time]);
        destination[token*p.destination_stride+time*p.width+channel]=
            source_data[token*p.source_stride+slot*p.width+channel];
    }
}
)glsl";
        std::vector<uint32_t> spirv;
        int status=ncnn::compile_spirv_module(shader,opt,spirv);
        if (status) return status;
        int local=device->info.vendor_id()==0x10de ? 64 : 8;
        if (const char* override=vda_setting("VDA_PROBE_HISTORY_LOCAL_X")) local=std::atoi(override);
        if (local!=8 && local!=64) return -1;
        pipeline=new ncnn::Pipeline(device);pipeline->set_local_size_xyz(local,1,1);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=local;specs[1].i=1;specs[2].i=1;
        status=pipeline->create(spirv.data(),spirv.size()*sizeof(uint32_t),specs);
        if (status) return status;
        for (int i=0;i<count;++i) {
            pool[i].create(channels[i],slots,tokens[i],size_t(2),1,opt.blob_vkallocator);
            if (pool[i].empty()) return -100;
        }
        return 0;
    }
    void seed() { list.assign(32,0);steps=0; }
    std::array<int,31> selection() const {
        std::array<int,31> out{};
        out[0]=list[0];out[1]=list[1];
        for (int i=0;i<29;++i) out[i+2]=list[list.size()-29+i];
        return out;
    }
    int free_slot() const {
        for (int i=0;i<slots;++i)
            if (std::find(list.begin(),list.end(),i)==list.end()) return i;
        return -1;
    }
    void push(int slot) { ++steps;list.push_back(slot);if (steps+32>42) list.erase(list.begin()+1); }
    int gather(std::array<ncnn::VkMat,9>& inputs,ncnn::VkCompute& cmd) const {
        auto chosen=selection();
        ncnn::Mat cpu(31);
        for (int i=0;i<31;++i) static_cast<float*>(cpu.data)[i]=float(chosen[i]);
        ncnn::VkMat indices;cmd.record_clone(cpu,indices,opt);
        for (int i=0;i<count;++i) {
            inputs[i+1].create(channels[i],31,tokens[i],size_t(2),1,opt.blob_vkallocator);
            if (inputs[i+1].empty()) return -100;
            dispatch(i,pool[i],inputs[i+1],indices,0,1,cmd);
        }
        return 0;
    }
    int store(const std::array<ncnn::VkMat,9>& outputs,int slot,ncnn::VkCompute& cmd) const {
        if (slot<0 || slot>=slots) return -1;
        for (int i=0;i<count;++i) {
            ncnn::VkMat state;
            device->convert_packing(outputs[i+1],state,1,cmd,opt);
            if (state.dims!=3 || state.w!=channels[i] || state.h!=1 ||
                state.c!=tokens[i] || state.elembits()!=16) return -1;
            dispatch(i,state,pool[i],state,slot,0,cmd);
        }
        return 0;
    }
private:
    void dispatch(int i,const ncnn::VkMat& source,const ncnn::VkMat& destination,
                  const ncnn::VkMat& indices,int slot,int mode,ncnn::VkCompute& cmd) const {
        std::vector<ncnn::vk_constant_type> constants(6);
        const int values[]={channels[i],tokens[i],int(source.cstep),int(destination.cstep),slot,mode};
        for (int j=0;j<6;++j) constants[j].i=values[j];
        ncnn::Mat dispatch;dispatch.w=channels[i];dispatch.h=mode ? 31 : 1;dispatch.c=tokens[i];
        cmd.record_pipeline(pipeline,{source,indices,destination},{},constants,dispatch);
    }
    const ncnn::VulkanDevice* device;
    ncnn::Option opt;
    std::array<ncnn::VkMat,8> pool;
    std::vector<int> list;
    int steps=0;
    ncnn::Pipeline* pipeline=nullptr;
};
