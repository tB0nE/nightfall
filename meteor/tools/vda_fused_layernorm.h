// Probe-only row LayerNorm: centered FP32 variance and one workgroup per row.
// Preserve native ncnn's stored coefficient/weight precision; no E[x*x]-mean^2.
#pragma once
#include <layer.h>
#include <cmath>
class VdaFusedLayerNorm : public ncnn::Layer {
public:
    VdaFusedLayerNorm() {
        one_blob_only=true;support_vulkan=true;support_fp16_storage=true;
        support_packing=false;support_vulkan_packing=false;
    }
    int load_param(const ncnn::ParamDict& pd) override {
        width=pd.get(0,0);eps=pd.get(1,1e-5f);affine=pd.get(2,1);
        return width>0 && width<=384 && std::isfinite(eps) && eps>0 && (affine==0 || affine==1) ? 0 : -1;
    }
    int load_model(const ncnn::ModelBin& mb) override {
        if (affine) { gamma=mb.load(width,1);beta=mb.load(width,1); }
        else { gamma.create(width);beta.create(width);gamma.fill(1.f);beta.fill(0.f); }
        return gamma.empty() || beta.empty() ? -100 : 0;
    }
    int create_pipeline(const ncnn::Option& opt) override {
        if (opt.use_fp16_arithmetic || opt.use_fp16_packed) return -1;
        bytes=opt.use_fp16_storage ? 2 : 4;
        static const char* source=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Input { sfp input_data[]; };
layout(binding=1) readonly buffer Gamma { sfp gamma_data[]; };
layout(binding=2) readonly buffer Beta { sfp beta_data[]; };
layout(binding=3) writeonly buffer Output { sfp output_data[]; };
layout(push_constant) uniform parameter {
    int width;int height;int rows;int input_stride;int output_stride;float eps;
} p;
shared float reduction[64];
shared float coeffs[2];
void main() {
    int lane=int(gl_LocalInvocationID.x);
    int row=int(gl_WorkGroupID.y);
    if (row>=p.rows) return;
    int input_base=(row/p.height)*p.input_stride+(row%p.height)*p.width;
    int output_base=(row/p.height)*p.output_stride+(row%p.height)*p.width;
    float values[6];float sum=0.0;
    for (int i=0;i<6;++i) {
        int col=lane+i*64;
        values[i]=col<p.width ? float(input_data[input_base+col]) : 0.0;
        sum+=values[i];
    }
    reduction[lane]=sum;barrier();
    for (int offset=32;offset>0;offset/=2) {
        if (lane<offset) reduction[lane]+=reduction[lane+offset];
        barrier();
    }
    float mean=reduction[0]/float(p.width);
    barrier();
    sum=0.0;
    for (int i=0;i<6;++i) if (lane+i*64<p.width) {
        float centered=values[i]-mean;sum+=centered*centered;
    }
    reduction[lane]=sum;barrier();
    for (int offset=32;offset>0;offset/=2) {
        if (lane<offset) reduction[lane]+=reduction[lane+offset];
        barrier();
    }
    if (lane==0) {
        float a=1.0/sqrt(reduction[0]/float(p.width)+p.eps);
        coeffs[0]=float(sfp(a));coeffs[1]=float(sfp(-mean*a));
    }
    barrier();
    for (int i=0;i<6;++i) {
        int col=lane+i*64;
        if (col<p.width) {
            float value=values[i]*coeffs[0]+coeffs[1];
            value=value*float(gamma_data[col])+float(beta_data[col]);
            output_data[output_base+col]=sfp(value);
        }
    }
}
)glsl";
        std::vector<uint32_t> spirv;
        int status=ncnn::compile_spirv_module(source,opt,spirv);if (status) return status;
        pipeline=new ncnn::Pipeline(vkdev);pipeline->set_local_size_xyz(64,1,1);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=64;specs[1].i=1;specs[2].i=1;
        return pipeline->create(spirv.data(),spirv.size()*4,specs);
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        cmd.record_upload(gamma,gpu_gamma,opt);cmd.record_upload(beta,gpu_beta,opt);return 0;
    }
    int destroy_pipeline(const ncnn::Option&) override { delete pipeline;pipeline=nullptr;return 0; }
    int forward(const ncnn::VkMat& input,ncnn::VkMat& output,ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        if (!pipeline || input.dims<1 || input.dims>3 || input.w!=width || input.elempack!=1 || input.elemsize!=bytes) return -1;
        output.create_like(input,opt.blob_vkallocator);if (output.empty()) return -100;
        int height=input.dims==1 ? 1 : input.h;
        int rows=height*(input.dims==3 ? input.c : 1);
        if (rows<=0 || uint32_t(rows)>vkdev->info.max_workgroup_count_y()) return -1;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i=width;constants[1].i=height;constants[2].i=rows;
        constants[3].i=int(input.cstep);constants[4].i=int(output.cstep);constants[5].f=eps;
        ncnn::Mat dispatch;dispatch.w=64;dispatch.h=rows;dispatch.c=1;
        cmd.record_pipeline(pipeline,{input,gpu_gamma,gpu_beta,output},{},constants,dispatch);
        return 0;
    }
private:
    int width=0,affine=1;float eps=1e-5f;size_t bytes=4;
    ncnn::Mat gamma,beta;ncnn::VkMat gpu_gamma,gpu_beta;
    ncnn::Pipeline* pipeline=nullptr;
};
inline ncnn::Layer* create_vda_fused_layernorm(void*) { return new VdaFusedLayerNorm; }
