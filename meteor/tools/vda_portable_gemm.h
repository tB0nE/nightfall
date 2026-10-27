// Experimental conventional Vulkan GEMM. No cooperative matrices or FP16 ALU.
// FP16 storage, FP32 accumulation, 32x32 output tiles / 64 threads.
#pragma once
#include "vda_settings.h"
#include <layer.h>
#include <string>
#include <cstring>
#include <cstdlib>
#include <utility>
class VdaPortableGemm : public ncnn::Layer {
public:
    VdaPortableGemm() {
        one_blob_only=true;support_vulkan=true;support_fp16_storage=true;
        support_packing=false;support_vulkan_packing=false;
    }
    int load_param(const ncnn::ParamDict& pd) override {
        rows=pd.get(7,0);cols=pd.get(8,0);width=pd.get(9,0);
        alpha=pd.get(0,1.f);beta=pd.get(1,1.f);bias_type=pd.get(10,0);
        return rows>0 && cols>0 && width>0 && pd.get(2,0)==0 && pd.get(3,0)==1 &&
            pd.get(4,0)==0 && pd.get(5,0)==1 && pd.get(6,0)==1 &&
            (bias_type==4 || bias_type==-1) && !pd.get(11,0) && !pd.get(14,0) && !pd.get(18,0) ? 0 : -1;
    }
    int load_model(const ncnn::ModelBin& mb) override {
        ncnn::Mat weights=mb.load(width,cols,0),half;
        if (weights.empty()) return -100;
        ncnn::cast_float32_to_float16(weights,half);
        reordered.create(cols,width,size_t(2),1);if (reordered.empty()) return -100;
        auto* target=static_cast<unsigned short*>(reordered.data);
        const auto* source=static_cast<const unsigned short*>(half.data);
        for (int k=0;k<width;++k) for (int n=0;n<cols;++n) target[k*cols+n]=source[n*width+k];
        ncnn::Mat bias(cols);
        if (bias_type==4) bias=mb.load(cols,1,0);else bias.fill(0.f);
        if (bias.empty()) return -100;
        ncnn::cast_float32_to_float16(bias,half_bias);return 0;
    }
    int create_pipeline(const ncnn::Option& opt) override {
        if (!opt.use_fp16_storage || opt.use_fp16_arithmetic || opt.use_fp16_packed) return -1;
        static const char* shader=R"glsl(
#version 450
#extension GL_EXT_shader_explicit_arithmetic_types_float16 : require
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Input { float16_t input_data[]; };
layout(binding=1) readonly buffer Weights { float16_t weights[]; };
layout(binding=2) readonly buffer Bias { float16_t bias[]; };
layout(binding=3) writeonly buffer Output { float16_t output_data[]; };
layout(push_constant) uniform parameter { int rows;int cols;int width;int stride;float alpha;float beta; } p;
shared float tile_a[32*17];
shared float tile_b[16*33];
void finish_row(int row,int col,vec4 value) {
    if (row>=p.rows) return;
    for (int i=0;i<4;++i) if (col+i<p.cols)
        output_data[row*p.cols+col+i]=float16_t(p.alpha*value[i]+p.beta*float(bias[col+i]));
}
void main() {
    int x=int(gl_LocalInvocationID.x),y=int(gl_LocalInvocationID.y),lane=y*8+x;
    int first_row=int(gl_WorkGroupID.y)*32,first_col=int(gl_WorkGroupID.x)*32;
    vec4 sum0=vec4(0),sum1=vec4(0),sum2=vec4(0),sum3=vec4(0);
    for (int first_k=0;first_k<p.width;first_k+=16) {
        for (int i=lane;i<512;i+=64) {
            int r=i/16,k=i%16;
            tile_a[r*17+k]=first_row+r<p.rows && first_k+k<p.width ? float(input_data[(first_row+r)*p.stride+first_k+k]) : 0.0;
            k=i/32;int c=i%32;
            tile_b[k*33+c]=first_k+k<p.width && first_col+c<p.cols ? float(weights[(first_k+k)*p.cols+first_col+c]) : 0.0;
        }
        barrier();
        for (int k=0;k<16 && first_k+k<p.width;++k) {
            int b=k*33+x*4;
            vec4 value=vec4(tile_b[b],tile_b[b+1],tile_b[b+2],tile_b[b+3]);
            sum0=fma(vec4(tile_a[(y*4)*17+k]),value,sum0);
            sum1=fma(vec4(tile_a[(y*4+1)*17+k]),value,sum1);
            sum2=fma(vec4(tile_a[(y*4+2)*17+k]),value,sum2);
            sum3=fma(vec4(tile_a[(y*4+3)*17+k]),value,sum3);
        }
        barrier();
    }
    int row=first_row+y*4,col=first_col+x*4;
    finish_row(row,col,sum0);finish_row(row+1,col,sum1);
    finish_row(row+2,col,sum2);finish_row(row+3,col,sum3);
}
)glsl";
        std::string source=shader;
        if (vda_setting("VDA_PROBE_PORTABLE_GEMM_FIXED_SHAPE")) {
            // Literal bounds permit loop unrolling / remove full-tile tail
            // checks. Storage, checkpoint values and K order are unchanged.
            for (const auto& replacement : {std::make_pair("p.rows",rows),
                    std::make_pair("p.cols",cols),std::make_pair("p.width",width)}) {
                size_t pos=0;
                while ((pos=source.find(replacement.first,pos))!=std::string::npos) {
                    auto value=std::to_string(replacement.second);
                    source.replace(pos,std::strlen(replacement.first),value);pos+=value.size();
                }
            }
        }
        std::vector<uint32_t> spirv;int status=ncnn::compile_spirv_module(source.c_str(),opt,spirv);if (status) return status;
        pipeline=new ncnn::Pipeline(vkdev);pipeline->set_local_size_xyz(8,8,1);
        std::vector<ncnn::vk_specialization_type> specs(3);specs[0].i=8;specs[1].i=8;specs[2].i=1;
        return pipeline->create(spirv.data(),spirv.size()*4,specs);
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        cmd.record_upload(reordered,gpu_weights,opt);cmd.record_upload(half_bias,gpu_bias,opt);return 0;
    }
    int destroy_pipeline(const ncnn::Option&) override { delete pipeline;pipeline=nullptr;return 0; }
    int forward(const ncnn::VkMat& input,ncnn::VkMat& output,ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        if (input.w!=width || input.elempack!=1 || input.elemsize!=2 ||
            !((input.dims==2 && input.h==rows) || (input.dims==3 && input.h==1 && input.c==rows))) return -1;
        output.create(cols,rows,size_t(2),1,opt.blob_vkallocator);if (output.empty()) return -100;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i=rows;constants[1].i=cols;constants[2].i=width;
        constants[3].i=input.dims==2 ? input.w : int(input.cstep);constants[4].f=alpha;constants[5].f=beta;
        ncnn::Mat dispatch;dispatch.w=(cols+31)/32*8;dispatch.h=(rows+31)/32*8;dispatch.c=1;
        cmd.record_pipeline(pipeline,{input,gpu_weights,gpu_bias,output},{},constants,dispatch);return 0;
    }
private:
    int rows=0,cols=0,width=0,bias_type=0;float alpha=1,beta=1;
    ncnn::Mat reordered,half_bias;ncnn::VkMat gpu_weights,gpu_bias;ncnn::Pipeline* pipeline=nullptr;
};
inline ncnn::Layer* create_vda_portable_gemm(void*) { return new VdaPortableGemm; }
