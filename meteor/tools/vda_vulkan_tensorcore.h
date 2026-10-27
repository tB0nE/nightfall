// Experimental output tiling using 16x16x16 KHR cooperative GEMM. FP16 storage,
// FP32 accumulation, bounds-checked tails. Default 64x64 remains the reference;
// 32x32 is a separately validated opt-in. Probe only.
#pragma once
#include "vda_settings.h"
#include <layer.h>
#include <cstdlib>
#include <string>

class VdaTensorCoreGemm : public ncnn::Layer {
public:
    VdaTensorCoreGemm() {
        one_blob_only=true;support_vulkan=true;support_fp16_storage=true;
        support_packing=false;support_vulkan_packing=false;
    }
    int load_param(const ncnn::ParamDict& pd) override {
        rows=pd.get(7,0);cols=pd.get(8,0);width=pd.get(9,0);
        alpha=pd.get(0,1.f);beta=pd.get(1,1.f);bias_type=pd.get(10,0);
        if (rows<=0 || cols<=0 || width<=0 || pd.get(2,0)!=0 || pd.get(3,0)!=1 ||
            pd.get(4,0)!=0 || pd.get(5,0)!=1 || pd.get(6,0)!=1 ||
            (bias_type!=4 && bias_type!=-1) || pd.get(11,0) || pd.get(14,0) ||
            pd.get(18,0)) return -1;
        return 0;
    }
    int load_model(const ncnn::ModelBin& mb) override {
        ncnn::Mat weights=mb.load(width,cols,0);
        if (weights.empty()) return -100;
        ncnn::cast_float32_to_float16(weights,half_weights);
        transposed_weights=vda_setting("VDA_PROBE_TC_TRANSPOSE_WEIGHTS")!=nullptr;
        if (transposed_weights) {
            // Reorder after FP16 conversion so CPU SIMD/tail rounding and every
            // stored weight bit remain identical to the existing implementation.
            ncnn::Mat transposed(cols,width,size_t(2),1);
            if (transposed.empty()) return -100;
            const auto* source=static_cast<const unsigned short*>(half_weights.data);
            auto* target=static_cast<unsigned short*>(transposed.data);
            for (int k=0;k<width;++k) for (int n=0;n<cols;++n) target[k*cols+n]=source[n*width+k];
            half_weights=transposed;
        }
        ncnn::Mat bias(cols);
        if (bias_type==4) bias=mb.load(cols,1,0);
        else bias.fill(0.f);
        if (bias.empty()) return -100;
        ncnn::cast_float32_to_float16(bias,half_bias);
        return 0;
    }
    int create_pipeline(const ncnn::Option& opt) override {
        if (!opt.use_fp16_storage || !vkdev->info.support_VK_KHR_cooperative_matrix() ||
            !vkdev->info.support_cooperative_matrix_16_16_16()) return -1;
        int k_tile=16;
        if (const char* value=vda_setting("VDA_PROBE_TC_K_TILE")) {
            char* end=nullptr;long parsed=std::strtol(value,&end,10);
            if (!*value || !end || *end || (parsed!=16 && parsed!=32 && parsed!=64)) return -1;
            k_tile=int(parsed);
        }
        int shared_pad=0;
        if (const char* value=vda_setting("VDA_PROBE_TC_SHARED_PAD")) {
            if (std::string(value)!="0" && std::string(value)!="8") return -1;
            shared_pad=std::atoi(value);
        }
        if (const char* value=vda_setting("VDA_PROBE_TC_TILE_SHAPE")) {
            std::string shape=value;
            if (shape=="64x64") { tile_m=64;tile_n=64; }
            else if (shape=="64x32") { tile_m=64;tile_n=32; }
            else if (shape=="32x64") { tile_m=32;tile_n=64; }
            else if (shape=="32x32") { tile_m=32;tile_n=32; }
            else return -1;
        }
        if (uint32_t(2*(tile_m*(k_tile+shared_pad)+k_tile*(tile_n+shared_pad))+tile_m*tile_n*4)>
            vkdev->info.max_shared_memory_size()) return -1;
        static const char* source=R"glsl(
#version 450
#extension GL_EXT_shader_explicit_arithmetic_types_float16 : require
#extension GL_KHR_cooperative_matrix : require
#extension GL_KHR_memory_scope_semantics : require
#extension GL_KHR_shader_subgroup_basic : require
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Input { float16_t input_data[]; };
layout(binding=1) readonly buffer Weights { float16_t weights[]; };
layout(binding=2) readonly buffer Bias { float16_t bias[]; };
layout(binding=3) writeonly buffer Output { float16_t output_data[]; };
layout(push_constant) uniform parameter {
    int rows;int cols;int width;int input_stride;float alpha;float beta;
} p;
shared float16_t tile_a[A_STORAGE];
shared float16_t tile_b[B_STORAGE];
shared float tile_out[OUTPUT_ELEMENTS];
void main() {
    int lane=int(gl_LocalInvocationID.x);
    int subgroup=int(gl_SubgroupID);
    int sub_row=subgroup/2;
    int sub_col=subgroup%2;
    int first_row=int(gl_WorkGroupID.y)*M_TILE;
    int first_col=int(gl_WorkGroupID.x)*N_TILE;
    coopmat<float,gl_ScopeSubgroup,16,16,gl_MatrixUseAccumulator> sum[R_FRAGS][C_FRAGS];
    for (int r=0;r<R_FRAGS;++r) for (int c=0;c<C_FRAGS;++c)
        sum[r][c]=coopmat<float,gl_ScopeSubgroup,16,16,gl_MatrixUseAccumulator>(0.0);
    for (int first_k=0;first_k<p.width;first_k+=K_TILE) {
        for (int i=lane;i<IO_ELEMENTS;i+=128) {
#if A_ELEMENTS < IO_ELEMENTS
            if (i<A_ELEMENTS)
#endif
            {
                int r=i/K_TILE;int c=i%K_TILE;
                tile_a[r*A_STRIDE+c]=first_row+r<p.rows && first_k+c<p.width
                    ? input_data[(first_row+r)*p.input_stride+first_k+c] : float16_t(0.0);
            }
#if B_ELEMENTS < IO_ELEMENTS
            if (i<B_ELEMENTS)
#endif
            {
                int r=i/N_TILE;int c=i%N_TILE;
                tile_b[r*B_STRIDE+c]=first_col+c<p.cols && first_k+r<p.width
#if TRANSPOSE_WEIGHTS
                ? weights[(first_k+r)*p.cols+first_col+c] : float16_t(0.0);
#else
                ? weights[(first_col+c)*p.width+first_k+r] : float16_t(0.0);
#endif
            }
        }
        barrier();
        // Retain the exact ascending 16-element accumulation sequence, even
        // when the final shared tile contains fewer than K_TILE valid columns.
        for (int part=0;part<K_TILE && first_k+part<p.width;part+=16) {
            coopmat<float16_t,gl_ScopeSubgroup,16,16,gl_MatrixUseA> a[R_FRAGS];
            coopmat<float16_t,gl_ScopeSubgroup,16,16,gl_MatrixUseB> b[C_FRAGS];
            for (int r=0;r<R_FRAGS;++r) coopMatLoad(a[r],tile_a,(sub_row*R_FRAGS+r)*16*A_STRIDE+part,A_STRIDE,gl_CooperativeMatrixLayoutRowMajor);
            for (int c=0;c<C_FRAGS;++c) coopMatLoad(b[c],tile_b,part*B_STRIDE+(sub_col*C_FRAGS+c)*16,B_STRIDE,gl_CooperativeMatrixLayoutRowMajor);
            for (int r=0;r<R_FRAGS;++r) for (int c=0;c<C_FRAGS;++c) sum[r][c]=coopMatMulAdd(a[r],b[c],sum[r][c]);
        }
        barrier();
    }
    for (int r=0;r<R_FRAGS;++r) for (int c=0;c<C_FRAGS;++c)
        coopMatStore(sum[r][c],tile_out,(sub_row*R_FRAGS+r)*16*N_TILE+(sub_col*C_FRAGS+c)*16,N_TILE,gl_CooperativeMatrixLayoutRowMajor);
    barrier();
    for (int i=lane;i<OUTPUT_ELEMENTS;i+=128) {
        int row=first_row+i/N_TILE;int col=first_col+i%N_TILE;
        if (row<p.rows && col<p.cols)
            output_data[row*p.cols+col]=float16_t(p.alpha*tile_out[i]+p.beta*float(bias[col]));
    }
}
)glsl";
        std::vector<uint32_t> spirv;
        ncnn::Option shader_opt=opt;shader_opt.use_fp16_arithmetic=false;
        std::string specialized=source;
        specialized.insert(specialized.find('\n',specialized.find("#version"))+1,
            std::string("#define TRANSPOSE_WEIGHTS ")+(transposed_weights ? "1\n" : "0\n")+
            "#define K_TILE "+std::to_string(k_tile)+"\n#define SHARED_PAD "+std::to_string(shared_pad)+
            "\n#define M_TILE "+std::to_string(tile_m)+"\n#define N_TILE "+std::to_string(tile_n)+
            "\n#define R_FRAGS "+std::to_string(tile_m/32)+"\n#define C_FRAGS "+std::to_string(tile_n/32)+
            "\n#define A_STRIDE "+std::to_string(k_tile+shared_pad)+"\n#define B_STRIDE "+std::to_string(tile_n+shared_pad)+
            "\n#define A_STORAGE "+std::to_string(tile_m*(k_tile+shared_pad))+
            "\n#define B_STORAGE "+std::to_string(k_tile*(tile_n+shared_pad))+
            "\n#define OUTPUT_ELEMENTS "+std::to_string(tile_m*tile_n)+
            "\n#define IO_ELEMENTS "+std::to_string(std::max(tile_m,tile_n)*k_tile)+
            "\n#define A_ELEMENTS "+std::to_string(tile_m*k_tile)+"\n#define B_ELEMENTS "+std::to_string(tile_n*k_tile)+"\n");
        int result=ncnn::compile_spirv_module(specialized.c_str(),shader_opt,spirv);
        if (result) return result;
        pipeline=new ncnn::Pipeline(vkdev);
        pipeline->set_subgroup_size(32);pipeline->set_local_size_xyz(128,1,1);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=128;specs[1].i=1;specs[2].i=1;
        return pipeline->create(spirv.data(),spirv.size()*sizeof(uint32_t),specs);
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        cmd.record_upload(half_weights,gpu_weights,opt);
        cmd.record_upload(half_bias,gpu_bias,opt);
        return 0;
    }
    int destroy_pipeline(const ncnn::Option&) override {
        delete pipeline;pipeline=nullptr;
        return 0;
    }
    int forward(const ncnn::VkMat& in,ncnn::VkMat& out,ncnn::VkCompute& cmd,
                const ncnn::Option& opt) const override {
        if (in.w!=width || in.elempack!=1 || in.elemsize!=2 ||
            !((in.dims==2 && in.h==rows) || (in.dims==3 && in.h==1 && in.c==rows))) return -1;
        out.create(cols,rows,size_t(2),1,opt.blob_vkallocator);
        if (out.empty()) return -100;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i=rows;constants[1].i=cols;constants[2].i=width;
        constants[3].i=in.dims==2 ? in.w : int(in.cstep);
        constants[4].f=alpha;constants[5].f=beta;
        ncnn::Mat dispatch;dispatch.w=((cols+tile_n-1)/tile_n)*128;dispatch.h=(rows+tile_m-1)/tile_m;dispatch.c=1;
        cmd.record_pipeline(pipeline,{in,gpu_weights,gpu_bias,out},{},constants,dispatch);
        return 0;
    }
private:
    int rows=0,cols=0,width=0,bias_type=0;
    int tile_m=64,tile_n=64;
    bool transposed_weights=false;
    float alpha=1,beta=1;
    ncnn::Mat half_weights,half_bias;
    ncnn::VkMat gpu_weights,gpu_bias;
    ncnn::Pipeline* pipeline=nullptr;
};
inline ncnn::Layer* create_vda_tensorcore_gemm(void*) { return new VdaTensorCoreGemm; }
