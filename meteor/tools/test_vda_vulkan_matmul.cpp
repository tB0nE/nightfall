// Exact-shape correctness and timing tests for the experimental temporal kernel.
#include "vda_vulkan_matmul.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>

static bool check(const ncnn::VulkanDevice* device, int batches, int m,
                  int n, int k, bool transpose_b, bool fp16) {
    ncnn::VkBlobAllocator allocator(device);
    ncnn::VkStagingAllocator staging(device);
    ncnn::Option opt;
    opt.use_vulkan_compute=true;
    opt.use_packing_layout=false;
    opt.use_fp16_storage=fp16;
    opt.use_fp16_packed=false;
    opt.use_fp16_arithmetic=false;
    opt.blob_vkallocator=&allocator;
    opt.workspace_vkallocator=&allocator;
    opt.staging_vkallocator=&staging;
    ncnn::Mat a(k,m,batches), b(transpose_b ? k : n,transpose_b ? n : k,batches);
    for (int z=0;z<batches;++z) {
        float* av=a.channel(z); float* bv=b.channel(z);
        for (int i=0;i<k*m;++i) av[i]=std::sin(float(i+z*7)*0.17f);
        for (int i=0;i<k*n;++i) bv[i]=std::cos(float(i+z*11)*0.13f);
    }
    VdaTemporalMatMul layer;
    layer.vkdev=device;
    ncnn::ParamDict pd; pd.set(0,int(transpose_b));
    if (layer.load_param(pd) || layer.create_pipeline(opt)) return false;
    std::vector<ncnn::VkMat> inputs(2),outputs(1);
    ncnn::Mat uploaded_a=a,uploaded_b=b;
    if (fp16) {
        ncnn::cast_float32_to_float16(a,uploaded_a);
        ncnn::cast_float32_to_float16(b,uploaded_b);
        // Oracle uses the same rounded input values, with FP64 accumulation.
        ncnn::cast_float16_to_float32(uploaded_a,a);
        ncnn::cast_float16_to_float32(uploaded_b,b);
    }
    ncnn::VkCompute upload(device);
    upload.record_clone(uploaded_a,inputs[0],opt); upload.record_clone(uploaded_b,inputs[1],opt);
    if (upload.submit_and_wait()) return false;
    double total=0;
    for (int iteration=0;iteration<12;++iteration) {
        auto start=std::chrono::steady_clock::now();
        ncnn::VkCompute cmd(device);
        // Amortize queue submission and host scheduling; this measures a burst
        // of dependent writes, not a driver timestamp for one kernel.
        for (int dispatch=0;dispatch<16;++dispatch)
            if (layer.forward(inputs,outputs,cmd,opt)) return false;
        if (cmd.submit_and_wait()) return false;
        if (iteration>=2)
            total+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    }
    ncnn::Mat actual;
    ncnn::VkCompute download(device); download.record_download(outputs[0],actual,opt);
    if (download.submit_and_wait()) return false;
    double worst=0;
    bool okay=true;
    for (int z=0;z<batches;++z) {
        const float* av=a.channel(z); const float* bv=b.channel(z);
        const float* cv=actual.channel(z);
        for (int row=0;row<m;++row) for (int col=0;col<n;++col) {
            double expected=0;
            for (int i=0;i<k;++i)
                expected+=double(av[row*k+i])*bv[transpose_b ? col*k+i : i*n+col];
            double error=std::abs(expected-cv[row*n+col]);
            worst=std::max(worst,error);
            const double tolerance=fp16 ? 1e-3 : 2e-5;
            if (!std::isfinite(cv[row*n+col]) || error>tolerance*(1+std::abs(expected))) okay=false;
        }
    }
    std::printf("storage=%s batches=%d m=%d n=%d k=%d transpose=%d mean_ms=%.6f max_error=%.9g %s\n",
        fp16 ? "fp16" : "fp32",batches,m,n,k,int(transpose_b),total/160,worst,okay ? "PASS" : "FAIL");
    // Shape mismatch must be rejected instead of silently reading past inputs.
    auto invalid=inputs; invalid[1].c=batches+1;
    ncnn::VkCompute unused(device);
    okay=okay && layer.forward(invalid,outputs,unused,opt)!=0;
    layer.destroy_pipeline(opt);
    return okay;
}

int main(int argc,char** argv) {
    if (argc!=2 && argc!=3) return 2;
    const bool fp16=argc==3 && std::string(argv[2])=="--fp16";
    if (argc==3 && !fp16) return 2;
    ncnn::create_gpu_instance();
    int gpu=std::atoi(argv[1]);
    if (gpu<0 || gpu>=ncnn::get_gpu_count()) return 2;
    const auto* device=ncnn::get_gpu_device(gpu);
    bool okay=true;
    for (bool trans : {false,true}) okay=check(device,3,3,5,7,trans,fp16) && okay;
    // Eight heads per spatial position in the exported streaming model.
    for (const auto& shape : {std::pair<int,int>{777*8,24}, {209*8,48},
                              {777*8,8}, {3108*8,8}}) {
        okay=check(device,shape.first,1,32,shape.second,true,fp16) && okay;
        okay=check(device,shape.first,1,shape.second,32,false,fp16) && okay;
    }
    return okay ? 0 : 1;
}
