// Experimental FP32-accumulating temporal attention kernel for the VDA probe.
// Deliberately accepts only unpacked, equally batched 3-D matrices.
#pragma once
#include <layer.h>
#include <limits>

class VdaTemporalMatMul : public ncnn::Layer {
public:
    VdaTemporalMatMul() {
        one_blob_only = false;
        support_vulkan = true;
        support_packing = false;
        support_vulkan_packing = false;
        support_fp16_storage = true;
    }
    int load_param(const ncnn::ParamDict& pd) override {
        transpose_b = pd.get(0, 0);
        return (transpose_b == 0 || transpose_b == 1) ? 0 : -1;
    }
    int create_pipeline(const ncnn::Option& opt) override {
        if (!opt.use_vulkan_compute) return 0;
        // Accumulate explicitly in float even if the surrounding graph opts
        // into FP16 arithmetic; sfp affects storage, not this shader's math.
        if (opt.use_fp16_packed)
            return -1;
        storage_bytes=opt.use_fp16_storage ? 2 : 4;
        static const char* source = R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer A { sfp a[]; };
layout(binding=1) readonly buffer B { sfp b[]; };
layout(binding=2) writeonly buffer C { sfp c[]; };
layout(push_constant) uniform parameter {
    int m; int n; int k; int batches;
    int astride; int bstride; int cstride; int transpose_b;
} p;
void main() {
    int col = int(gl_GlobalInvocationID.x);
    int row = int(gl_GlobalInvocationID.y);
    int batch = int(gl_GlobalInvocationID.z);
    if (col >= p.n || row >= p.m || batch >= p.batches) return;
    float sum = 0.0;
    for (int k=0; k<p.k; ++k) {
        int bi = p.transpose_b != 0 ? col*p.k+k : k*p.n+col;
        sum += float(a[batch*p.astride+row*p.k+k]) * float(b[batch*p.bstride+bi]);
    }
    c[batch*p.cstride+row*p.n+col] = sfp(sum);
}
)glsl";
        std::vector<uint32_t> spirv;
        int rc = ncnn::compile_spirv_module(source, opt, spirv);
        if (rc) return rc;
        pipeline = new ncnn::Pipeline(vkdev);
        pipeline->set_local_size_xyz(8, 1, 1);
        std::vector<ncnn::vk_specialization_type> specializations(3);
        specializations[0].i=8; specializations[1].i=1; specializations[2].i=1;
        return pipeline->create(spirv.data(), spirv.size()*sizeof(uint32_t), specializations);
    }
    int destroy_pipeline(const ncnn::Option&) override {
        delete pipeline;
        pipeline = nullptr;
        return 0;
    }
    int forward(const std::vector<ncnn::VkMat>& inputs,
                std::vector<ncnn::VkMat>& outputs, ncnn::VkCompute& cmd,
                const ncnn::Option& opt) const override {
        if (inputs.size()!=2 || outputs.size()!=1 || !pipeline) return -1;
        const auto& a = inputs[0]; const auto& b = inputs[1];
        if (a.dims!=3 || b.dims!=3 || a.c!=b.c ||
            a.elempack!=1 || b.elempack!=1 || a.elemsize!=storage_bytes || b.elemsize!=storage_bytes)
            return -1;
        int n = transpose_b ? b.h : b.w;
        int k = transpose_b ? b.w : b.h;
        if (a.w!=k || a.c>65535 || a.cstep>INT32_MAX || b.cstep>INT32_MAX)
            return -1;
        auto& c = outputs[0];
        c.create(n, a.h, a.c, storage_bytes, 1, opt.blob_vkallocator);
        if (c.empty() || c.cstep>INT32_MAX) return -100;
        std::vector<ncnn::vk_constant_type> constants(8);
        const int values[] = {a.h,n,k,a.c,int(a.cstep),int(b.cstep),int(c.cstep),transpose_b};
        for (int i=0; i<8; ++i) constants[i].i=values[i];
        cmd.record_pipeline(pipeline, {a,b,c}, constants, c);
        return 0;
    }
private:
    int transpose_b = 0;
    size_t storage_bytes = 4;
    ncnn::Pipeline* pipeline = nullptr;
};

inline ncnn::Layer* create_vda_temporal_matmul(void*) { return new VdaTemporalMatMul; }
