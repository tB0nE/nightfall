// Diagnostic: run one loaded cold-model layer repeatedly on an identical tensor.
// No temporal state, upstream layers, or fixed graph executor are involved.
#include <net.h>
#include <gpu.h>
#include <layer.h>
#include <fstream>
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include "vda_vulkan_spatial_attention.h"

int main(int argc,char** argv) {
    if (argc!=8) {
        std::fprintf(stderr,"usage: test MODEL_PREFIX LAYER INPUT_F32 WIDTH HEIGHT REPEATS GPU\n");
        return 2;
    }
    ncnn::create_gpu_instance();
    int width=std::atoi(argv[4]),height=std::atoi(argv[5]),repeats=std::atoi(argv[6]),gpu=std::atoi(argv[7]);
    if (width<=0 || height<=0 || repeats<2 || gpu<0 || gpu>=ncnn::get_gpu_count()) return 2;
    const auto* device=ncnn::get_gpu_device(gpu);
    ncnn::VkBlobAllocator blob(device);ncnn::VkStagingAllocator staging(device);
    ncnn::Net net;net.set_vulkan_device(device);
    net.register_custom_layer("VdaSpatialAttention",create_vda_spatial_attention);
    net.opt.use_vulkan_compute=true;net.opt.use_fp16_storage=false;
    net.opt.use_fp16_packed=false;net.opt.use_fp16_arithmetic=false;
    net.opt.use_cooperative_matrix=false;net.opt.use_packing_layout=true;
    net.opt.blob_vkallocator=&blob;net.opt.workspace_vkallocator=&blob;net.opt.staging_vkallocator=&staging;
    if (std::getenv("VDA_PROBE_NO_LOCAL_MEMORY")) net.opt.use_shader_local_memory=false;
    if (std::getenv("VDA_PROBE_NO_SUBGROUP")) net.opt.use_subgroup_ops=false;
    std::string prefix=argv[1];
    if (net.load_param((prefix+".ncnn.param").c_str()) || net.load_model((prefix+".ncnn.bin").c_str())) return 3;
    const ncnn::Layer* layer=nullptr;
    for (const auto* candidate : net.layers()) if (candidate->name==argv[2]) layer=candidate;
    if (!layer || !layer->support_vulkan || layer->support_inplace) return 3;
    ncnn::Mat input(width,height);
    std::ifstream file(argv[3],std::ios::binary);file.read(static_cast<char*>(input.data),input.total()*4);
    if (!file) return 4;
    ncnn::VkMat original;ncnn::VkCompute upload(device);
    upload.record_upload(input,original,net.opt);if (upload.submit_and_wait()) return 5;
    std::vector<float> reference;int bad=0;double worst=0;
    for (int iteration=0;iteration<repeats;++iteration) {
        ncnn::VkCompute command(device);ncnn::VkMat working;
        command.record_clone(original,working,net.opt);
        std::vector<ncnn::VkMat> bottom{working},top(1);
        int result=layer->one_blob_only ? layer->forward(bottom[0],top[0],command,net.opt)
                                       : layer->forward(bottom,top,command,net.opt);
        if (result || command.submit_and_wait()) return 5;
        ncnn::Mat actual;ncnn::VkCompute download(device);
        download.record_download(top[0],actual,net.opt);if (download.submit_and_wait()) return 5;
        if (actual.elempack!=1) { ncnn::Mat tmp;ncnn::convert_packing(actual,tmp,1);actual=tmp; }
        if (actual.elembits()!=32) return 5;
        std::vector<float> values;
        for (int c=0;c<actual.c;++c) {
            const float* ptr=actual.channel(c);values.insert(values.end(),ptr,ptr+size_t(actual.w)*actual.h*actual.d);
        }
        for (float value : values) if (!std::isfinite(value)) return 6;
        if (!iteration) reference=values;
        else {
            if (reference.size()!=values.size()) return 6;
            double maximum=0;
            for (size_t i=0;i<values.size();++i) maximum=std::max(maximum,double(std::abs(values[i]-reference[i])));
            if (maximum) { ++bad;worst=std::max(worst,maximum); }
        }
    }
    std::printf("layer=%s repeats=%d differing_iterations=%d max_abs=%g\n",argv[2],repeats,bad,worst);
    return bad ? 10 : 0;
}
