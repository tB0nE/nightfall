// CPU-oracle tests for direct temporal attention, matching stored intermediate
// rounding in FP16 and exercising padded per-token storage.
#include "vda_fused_temporal.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

static float round_to_half(float x) { return ncnn::float16_to_float32(ncnn::float32_to_float16(x)); }

static bool check(const ncnn::VulkanDevice* device,int heads,int width,int tokens,bool half,float magnitude) {
    ncnn::VkBlobAllocator allocator(device);ncnn::VkStagingAllocator staging(device);
    ncnn::Option opt;opt.use_vulkan_compute=true;opt.use_fp16_storage=half;
    opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;
    opt.blob_vkallocator=&allocator;opt.workspace_vkallocator=&allocator;opt.staging_vkallocator=&staging;
    const int channels=heads*width;float scale=1.f/std::sqrt(float(width));
    ncnn::Mat cpu[3]={ncnn::Mat(channels,1,tokens),ncnn::Mat(channels,32,tokens),ncnn::Mat(channels,32,tokens)};
    std::vector<ncnn::VkMat> inputs(3),outputs(1);ncnn::VkCompute upload(device);
    for (int index=0;index<3;++index) {
        for (int token=0;token<tokens;++token) {
            float* values=cpu[index].channel(token);
            for (int i=0;i<channels*cpu[index].h;++i)
                values[i]=std::sin(i*0.173f+token*0.071f+index*0.41f)*magnitude;
        }
        ncnn::Mat storage=cpu[index];
        if (half) {
            ncnn::cast_float32_to_float16(cpu[index],storage);
            ncnn::cast_float16_to_float32(storage,cpu[index]);
        }
        upload.record_clone(storage,inputs[index],opt);
    }
    if (upload.submit_and_wait()) return false;
    VdaFusedTemporal layer;layer.vkdev=device;
    ncnn::ParamDict pd;pd.set(0,heads);pd.set(1,width);pd.set(2,tokens);pd.set(3,32);pd.set(4,scale);
    if (layer.load_param(pd) || layer.create_pipeline(opt)) return false;
    ncnn::VkCompute cmd(device);
    if (layer.forward(inputs,outputs,cmd,opt)) return false;
    ncnn::Mat actual;cmd.record_download(outputs[0],actual,opt);
    if (cmd.submit_and_wait()) return false;
    if (actual.elempack!=1) { ncnn::Mat unpacked;ncnn::convert_packing(actual,unpacked,1);actual=unpacked; }
    size_t nonfinite=0;double worst=0;
    for (int token=0;token<tokens;++token) for (int head=0;head<heads;++head) {
        const float* q=cpu[0].channel(token);const float* k=cpu[1].channel(token);const float* v=cpu[2].channel(token);
        double scores[32],maximum=-1e30,total=0;
        for (int time=0;time<32;++time) {
            double dot=0;
            for (int d=0;d<width;++d) dot+=double(q[head*width+d])*k[time*channels+head*width+d];
            scores[time]=half ? round_to_half(round_to_half(float(dot))*scale) : dot*scale;
            maximum=std::max(maximum,scores[time]);
        }
        for (double& score : scores) { score=std::exp(score-maximum);total+=score; }
        for (double& score : scores) score=half ? round_to_half(float(score/total)) : score/total;
        const float* result=actual.channel(token);
        for (int d=0;d<width;++d) {
            double expected=0;
            for (int time=0;time<32;++time) expected+=scores[time]*v[time*channels+head*width+d];
            if (half) expected=round_to_half(float(expected));
            float value=result[head*width+d];
            if (!std::isfinite(value)) ++nonfinite;
            else worst=std::max(worst,std::abs(expected-value));
        }
    }
    // Mismatched history must fail before dispatching.
    auto invalid=inputs;invalid[1].h=31;ncnn::VkCompute unused(device);
    bool rejects_bad_shape=layer.forward(invalid,outputs,unused,opt)!=0;
    double tolerance=half ? (magnitude>1 ? 0.03 : 0.002) : 2e-5;
    bool okay=!nonfinite && worst<tolerance && rejects_bad_shape;
    std::printf("heads=%d width=%d tokens=%d fp16=%d magnitude=%g max_error=%.9g %s\n",
        heads,width,tokens,int(half),double(magnitude),worst,okay ? "PASS" : "FAIL");
    layer.destroy_pipeline(opt);return okay;
}
int main(int argc,char** argv) {
    if (argc!=2) return 2;
    ncnn::create_gpu_instance();int gpu=std::atoi(argv[1]);
    if (gpu<0 || gpu>=ncnn::get_gpu_count()) return 2;
    auto* device=ncnn::get_gpu_device(gpu);bool okay=true;
    for (bool half : {false,true}) {
        for (int width : {8,24,48}) okay=check(device,8,width,7,half,0.5f) && okay;
        okay=check(device,1,7,3,half,0.5f) && okay;
        okay=check(device,8,24,7,half,4.f) && okay;
    }
    return okay ? 0 : 1;
}
