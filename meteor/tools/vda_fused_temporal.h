// Direct temporal attention on [spatial token, time, channel] tensors. Avoids
// head reshapes/permutations and score/softmax intermediate GPU allocations.
#pragma once
#include <layer.h>
#include <cmath>
#include <string>

class VdaFusedTemporal : public ncnn::Layer {
public:
    VdaFusedTemporal() {
        one_blob_only=false;support_vulkan=true;support_fp16_storage=true;
        support_packing=false;support_vulkan_packing=false;
    }
    int load_param(const ncnn::ParamDict& pd) override {
        heads=pd.get(0,0);head_width=pd.get(1,0);tokens=pd.get(2,0);history=pd.get(3,0);
        scale=pd.get(4,0.f);
        return heads>0 && heads<=16 && head_width>0 && head_width<=64 &&
            tokens>0 && tokens<=65535 && history==32 && std::isfinite(scale) && scale>0 ? 0 : -1;
    }
    int create_pipeline(const ncnn::Option& opt) override {
        bytes=opt.use_fp16_storage ? 2 : 4;
        static const char* source=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Q { sfp q[]; };
layout(binding=1) readonly buffer K { sfp k[]; };
layout(binding=2) readonly buffer V { sfp v[]; };
layout(binding=3) writeonly buffer O { sfp result[]; };
layout(push_constant) uniform parameter {
    int heads;int width;int tokens;int channels;
    int qstride;int kstride;int vstride;int ostride;float scale;
} p;
shared float scores[32];
shared float reduction[32];
shared float key_tile[32*HEAD_WIDTH];
shared float query_tile[64];
void main() {
    int lane=int(gl_LocalInvocationID.x);
    int token=int(gl_WorkGroupID.y);
    int head=int(gl_WorkGroupID.z);
    int channel=head*p.width;
    if (lane<HEAD_WIDTH) query_tile[lane]=float(q[token*p.qstride+channel+lane]);
    for (int i=lane;i<32*HEAD_WIDTH;i+=64) {
        int time=i/HEAD_WIDTH;int d=i%HEAD_WIDTH;
        key_tile[i]=float(k[token*p.kstride+time*p.channels+channel+d]);
    }
    barrier();
    if (lane<32) {
        float dot_product=0.0;
        for (int d=0;d<HEAD_WIDTH;++d)
            dot_product+=query_tile[d]*key_tile[lane*HEAD_WIDTH+d];
        // Match the original stored matmul and scaled-score boundaries.
        float score=float(sfp(float(sfp(dot_product))*p.scale));
        scores[lane]=score;reduction[lane]=score;
    }
    barrier();
    for (int offset=16;offset>0;offset/=2) {
        if (lane<offset) reduction[lane]=max(reduction[lane],reduction[lane+offset]);
        barrier();
    }
    float maximum=reduction[0];
    barrier();
    if (lane<32) {
        scores[lane]=exp(scores[lane]-maximum);reduction[lane]=scores[lane];
    }
    barrier();
    for (int offset=16;offset>0;offset/=2) {
        if (lane<offset) reduction[lane]+=reduction[lane+offset];
        barrier();
    }
    float total=reduction[0];
    if (lane<32) scores[lane]=float(sfp(scores[lane]/total));
    barrier();
    if (lane<HEAD_WIDTH) {
        float sum=0.0;
        for (int time=0;time<32;++time)
            sum+=scores[time]*float(v[token*p.vstride+time*p.channels+channel+lane]);
        result[token*p.ostride+channel+lane]=sfp(sum);
    }
}
)glsl";
        ncnn::Option shader_opt=opt;shader_opt.use_fp16_arithmetic=false;
        std::vector<uint32_t> spirv;
        std::string specialized=source;
        size_t version_end=specialized.find('\n',specialized.find("#version"));
        specialized.insert(version_end+1,"#define HEAD_WIDTH "+std::to_string(head_width)+"\n");
        int status=ncnn::compile_spirv_module(specialized.c_str(),shader_opt,spirv);
        if (status) return status;
        pipeline=new ncnn::Pipeline(vkdev);pipeline->set_local_size_xyz(64,1,1);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=64;specs[1].i=1;specs[2].i=1;
        return pipeline->create(spirv.data(),spirv.size()*sizeof(uint32_t),specs);
    }
    int destroy_pipeline(const ncnn::Option&) override { delete pipeline;pipeline=nullptr;return 0; }
    int forward(const std::vector<ncnn::VkMat>& inputs,std::vector<ncnn::VkMat>& outputs,
                ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        if (inputs.size()!=3 || outputs.size()!=1 || !pipeline) return -1;
        int channels=heads*head_width;
        for (int i=0;i<3;++i) {
            const auto& t=inputs[i];
            if (t.dims!=3 || t.w!=channels || t.h!=(i==0 ? 1 : history) || t.c!=tokens ||
                t.elempack!=1 || t.elemsize!=bytes || t.cstep>INT32_MAX) return -1;
        }
        auto& out=outputs[0];out.create(channels,1,tokens,bytes,1,opt.blob_vkallocator);
        if (out.empty() || out.cstep>INT32_MAX) return -100;
        std::vector<ncnn::vk_constant_type> constants(9);
        const int ints[]={heads,head_width,tokens,channels,int(inputs[0].cstep),
                          int(inputs[1].cstep),int(inputs[2].cstep),int(out.cstep)};
        for (int i=0;i<8;++i) constants[i].i=ints[i];constants[8].f=scale;
        ncnn::Mat dispatch;dispatch.w=64;dispatch.h=tokens;dispatch.c=heads;
        cmd.record_pipeline(pipeline,{inputs[0],inputs[1],inputs[2],out},{},constants,dispatch);
        return 0;
    }
private:
    int heads=0,head_width=0,tokens=0,history=0;
    float scale=0;size_t bytes=4;
    ncnn::Pipeline* pipeline=nullptr;
};
inline ncnn::Layer* create_vda_fused_temporal(void*) { return new VdaFusedTemporal; }
