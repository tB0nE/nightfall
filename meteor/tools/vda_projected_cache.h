// Experimental per-stream K/V cache. FP16 factorization is algebraically equal
// before rounding, not bit-identical to W(round(state+position)); validate rollouts.
#pragma once
#include "vda_settings.h"
#include "vda_vulkan_projection.h"
#include <array>

struct VdaProjectedContext {
    int slot=-1;
    std::array<int,32> slots{};
    const ncnn::VkMat* selection=nullptr; // 31 history slots plus current slot, float32
};
inline thread_local VdaProjectedContext vda_projected_context;

class VdaProjectedIO {
public:
    ~VdaProjectedIO() { delete pipeline; }
    int initialize(const ncnn::VulkanDevice* device,const ncnn::Option& opt) {
        if (!opt.use_fp16_storage) return -1;
        static const char* shader=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Source { sfp source_data[]; };
layout(binding=1) readonly buffer Position { sfp position[]; };
layout(binding=2) readonly buffer Selection { float selected[]; };
layout(binding=3) writeonly buffer Destination { sfp destination[]; };
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
    } else if (p.mode==1 && time<32) {
        int slot=int(selected[time]);
        destination[(token*32+time)*p.width+channel]=sfp(
            float(source_data[token*p.source_stride+slot*p.width+channel])+
            float(position[time*p.width+channel]));
    } else if (p.mode==2) {
        destination[token*p.destination_stride+channel]=sfp(
            float(source_data[token*p.source_stride+channel])+float(position[31*p.width+channel]));
    }
}
)glsl";
        ncnn::Option shader_opt=opt;shader_opt.use_fp16_arithmetic=false;
        std::vector<uint32_t> spirv;
        int status=ncnn::compile_spirv_module(shader,shader_opt,spirv);
        if (status) return status;
        // The wide setting passes short AMD unit cases but failed a long
        // Polaris rollout. Retain the validated narrow path there until isolated.
        int local=device->info.vendor_id()==0x10de ? 64 : 8;
        if (const char* override=vda_setting("VDA_PROBE_CACHE_LOCAL_X")) local=std::atoi(override);
        if (local!=8 && local!=64) return -1;
        pipeline=new ncnn::Pipeline(device);pipeline->set_local_size_xyz(local,1,1);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=local;specs[1].i=1;specs[2].i=1;
        return pipeline->create(spirv.data(),spirv.size()*sizeof(uint32_t),specs);
    }
    void record(const ncnn::VkMat& src,const ncnn::VkMat& pos,const ncnn::VkMat& selection,
                const ncnn::VkMat& dst,int width,int tokens,int slot,int mode,ncnn::VkCompute& cmd) const {
        std::vector<ncnn::vk_constant_type> constants(6);
        int stride=src.dims==2 ? src.w : int(src.cstep);
        const int values[]={width,tokens,stride,int(dst.cstep),slot,mode};
        for (int i=0;i<6;++i) constants[i].i=values[i];
        ncnn::Mat dispatch;dispatch.w=width;dispatch.h=mode==1 ? 32 : 1;dispatch.c=tokens;
        cmd.record_pipeline(pipeline,{src,pos,selection,dst},{},constants,dispatch);
    }
private:
    ncnn::Pipeline* pipeline=nullptr;
};

inline ncnn::Layer* vda_cache_projector(const ncnn::VulkanDevice* device,int rows,int width) {
    ncnn::Layer* layer=vda_create_gemm();
    layer->vkdev=device;
    ncnn::ParamDict pd;pd.set(3,1);pd.set(5,1);pd.set(6,1);
    pd.set(7,rows);pd.set(8,width);pd.set(9,width);pd.set(10,-1);pd.set(12,1);
    if (layer->load_param(pd)) { delete layer;return nullptr; }
    return layer;
}

class VdaPositionedQuery : public ncnn::Layer {
public:
    VdaPositionedQuery() { support_vulkan=true;support_fp16_storage=true;one_blob_only=false; }
    ~VdaPositionedQuery() override { delete inner; }
    int load_param(const ncnn::ParamDict& pd) override {
        width=pd.get(0,0);tokens=pd.get(3,0);
        if (width<=0 || tokens<=0 || pd.get(1,0) || pd.get(2,0)!=width*width) return -1;
        inner=new VdaTemporalProjection;inner->vkdev=vkdev;
        return inner->load_param(pd);
    }
    int load_model(const ncnn::ModelBin& mb) override { return inner->load_model(mb); }
    int create_pipeline(const ncnn::Option& opt) override {
        int status=inner->create_pipeline(opt);return status ? status : io.initialize(vkdev,opt);
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override { return inner->upload_model(cmd,opt); }
    int destroy_pipeline(const ncnn::Option& opt) override { return inner ? inner->destroy_pipeline(opt) : 0; }
    int forward(const std::vector<ncnn::VkMat>& in,std::vector<ncnn::VkMat>& out,
                ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        if (in.size()!=2 || out.size()!=1 || in[0].dims!=3 || in[0].w!=width ||
            in[0].h!=1 || in[0].c!=tokens || in[1].w!=width || in[1].h!=32 ||
            in[1].c!=1 || in[0].elempack!=1 || in[1].elempack!=1 ||
            in[0].elemsize!=2 || in[1].elemsize!=2) return -1;
        ncnn::VkMat positioned(width,1,tokens,size_t(2),1,opt.blob_vkallocator);
        if (positioned.empty()) return -100;
        io.record(in[0],in[1],in[0],positioned,width,tokens,0,2,cmd);
        return inner->forward(positioned,out[0],cmd,opt);
    }
private:
    int width=0,tokens=0;
    ncnn::Layer* inner=nullptr;
    VdaProjectedIO io;
};

class VdaCachedProjection : public ncnn::Layer {
public:
    VdaCachedProjection() { support_vulkan=true;support_fp16_storage=true;one_blob_only=false; }
    ~VdaCachedProjection() override { delete raw_projector;delete pos_projector; }
    int state_index() const { return state; }
    size_t pool_bytes() const { return pool.total()*pool.elemsize; }
    void reset_history() const { valid.fill(false); }
    int load_param(const ncnn::ParamDict& pd) override {
        width=pd.get(0,0);tokens=pd.get(3,0);state=pd.get(4,-1);
        if (width<=0 || tokens<=0 || state<0 || state>=8 || pd.get(1,0) || pd.get(2,0)!=width*width) return -1;
        raw_projector=vda_cache_projector(vkdev,tokens,width);
        pos_projector=vda_cache_projector(vkdev,32,width);
        return raw_projector && pos_projector ? 0 : -1;
    }
    int load_model(const ncnn::ModelBin& mb) override {
        ncnn::Mat weight=mb.load(width*width,0);
        if (weight.empty()) return -100;
        int status=raw_projector->load_model(ncnn::ModelBinFromMatArray(&weight));
        return status ? status : pos_projector->load_model(ncnn::ModelBinFromMatArray(&weight));
    }
    int create_pipeline(const ncnn::Option& opt) override {
        int status=raw_projector->create_pipeline(opt);
        if (!status) status=pos_projector->create_pipeline(opt);
        if (!status) status=io.initialize(vkdev,opt);
        if (status) return status;
        pool.create(width,44,tokens,size_t(2),1,opt.blob_vkallocator);
        return pool.empty() ? -100 : 0;
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        int status=raw_projector->upload_model(cmd,opt);
        return status ? status : pos_projector->upload_model(cmd,opt);
    }
    int destroy_pipeline(const ncnn::Option& opt) override {
        if (raw_projector) raw_projector->destroy_pipeline(opt);
        if (pos_projector) pos_projector->destroy_pipeline(opt);
        return 0;
    }
    int prime(const ncnn::VkMat& raw,int slot,ncnn::VkCompute& cmd,const ncnn::Option& opt) const {
        if (slot<0 || slot>=44 || raw.dims!=3 || raw.w!=width || raw.h!=1 || raw.c!=tokens ||
            raw.elempack!=1 || raw.elemsize!=2) return -1;
        ncnn::VkMat projected;
        int status=raw_projector->forward(raw,projected,cmd,opt);
        if (status) return status;
        io.record(projected,projected,projected,pool,width,tokens,slot,0,cmd);
        valid[slot]=true;
        return 0;
    }
    int forward(const std::vector<ncnn::VkMat>& in,std::vector<ncnn::VkMat>& out,
                ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        if (in.size()!=2 || out.size()!=1 || !vda_projected_context.selection ||
            vda_projected_context.slot<0 || in[1].w!=width || in[1].h!=32 ||
            in[1].c!=1 || in[1].elempack!=1 || in[1].elemsize!=2) return -1;
        if (vda_projected_context.slot>=44 || vda_projected_context.slots[31]!=vda_projected_context.slot) return -1;
        for (int i=0;i<31;++i) {
            int slot=vda_projected_context.slots[i];
            if (slot<0 || slot>=44 || slot==vda_projected_context.slot || !valid[slot]) return -1;
        }
        if (position.empty()) {
            // Position is an immutable model constant; flatten its single
            // channel by metadata only, preserving contiguous storage.
            ncnn::VkMat matrix=in[1];matrix.dims=2;
            int status=pos_projector->forward(matrix,position,cmd,opt);
            if (status) return status;
        }
        int status=prime(in[0],vda_projected_context.slot,cmd,opt);
        if (status) return status;
        out[0].create(width,tokens*32,size_t(2),1,opt.blob_vkallocator);
        if (out[0].empty()) return -100;
        io.record(pool,position,*vda_projected_context.selection,out[0],width,tokens,0,1,cmd);
        return 0;
    }
private:
    int width=0,tokens=0,state=-1;
    ncnn::Layer* raw_projector=nullptr;
    ncnn::Layer* pos_projector=nullptr;
    VdaProjectedIO io;
    ncnn::VkMat pool;
    mutable ncnn::VkMat position;
    mutable std::array<bool,44> valid{};
};
inline ncnn::Layer* create_vda_positioned_query(void*) { return new VdaPositionedQuery; }
inline ncnn::Layer* create_vda_cached_projection(void*) { return new VdaCachedProjection; }
