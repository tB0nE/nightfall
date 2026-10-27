// Synthetic identity-projection oracle for tiled attention, including partial
// query/key tiles and strong logits. No real model files or TensorRT required.
#include "vda_vulkan_spatial_attention.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

static ncnn::Mat rounded(const ncnn::Mat& input) {
    ncnn::Mat half,out;ncnn::cast_float32_to_float16(input,half);
    ncnn::cast_float16_to_float32(half,out);return out;
}

static bool check(const ncnn::VulkanDevice* device,int tokens,float magnitude) {
    constexpr int embed=384,head_width=64;
    ncnn::VkBlobAllocator allocator(device);ncnn::VkStagingAllocator staging(device);
    ncnn::Option opt;opt.use_vulkan_compute=true;opt.use_fp16_storage=true;
    opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;opt.use_cooperative_matrix=false;
    opt.blob_vkallocator=&allocator;opt.workspace_vkallocator=&allocator;opt.staging_vkallocator=&staging;
    ncnn::Mat input(embed,tokens),weights[8];
    for (int i=0;i<embed*tokens;++i) static_cast<float*>(input.data)[i]=std::sin(i*0.137f)*magnitude;
    for (int stage=0;stage<4;++stage) {
        weights[stage*2].create(embed*embed);weights[stage*2].fill(0.f);
        for (int i=0;i<embed;++i) static_cast<float*>(weights[stage*2].data)[i*embed+i]=1.f;
        weights[stage*2+1].create(embed);weights[stage*2+1].fill((stage==1 ? -2.f : float(stage+1))*0.001f);
    }
    VdaSpatialAttention layer;layer.vkdev=device;
    ncnn::ParamDict pd;pd.set(0,embed);pd.set(1,6);pd.set(2,embed*embed);pd.set(8,tokens);
    if (layer.load_param(pd) || layer.load_model(ncnn::ModelBinFromMatArray(weights)) || layer.create_pipeline(opt)) return false;
    ncnn::VkTransfer upload(device);
    if (layer.upload_model(upload,opt) || upload.submit_and_wait()) return false;
    ncnn::VkMat gpu_input,output;ncnn::VkCompute cmd(device);
    cmd.record_upload(input,gpu_input,opt);
    if (gpu_input.elempack!=1) {
        ncnn::VkMat unpacked;device->convert_packing(gpu_input,unpacked,1,cmd,opt);gpu_input=unpacked;
    }
    if (layer.forward(gpu_input,output,cmd,opt)) return false;
    ncnn::Mat actual;cmd.record_download(output,actual,opt);
    if (cmd.submit_and_wait()) return false;
    input=rounded(input);
    ncnn::Mat projected[3];
    for (int stage=0;stage<3;++stage) {
        projected[stage].create(embed,tokens);auto bias=rounded(weights[stage*2+1]);
        for (int row=0;row<tokens;++row) for (int col=0;col<embed;++col)
            projected[stage].row(row)[col]=input.row(row)[col]+static_cast<float*>(bias.data)[col];
        projected[stage]=rounded(projected[stage]);
    }
    auto out_bias=rounded(weights[7]);
    size_t nonfinite=0;double worst=0;
    for (int row=0;row<tokens;++row) for (int head=0;head<6;++head) {
        std::vector<double> logits(tokens);double maximum=-1e30,total=0;
        for (int key=0;key<tokens;++key) {
            double score=0;
            for (int d=0;d<head_width;++d)
                score+=double(projected[0].row(row)[head*64+d])*projected[1].row(key)[head*64+d];
            logits[key]=score/8.0;maximum=std::max(maximum,logits[key]);
        }
        for (double& score : logits) { score=std::exp(score-maximum);total+=score; }
        for (int d=0;d<64;++d) {
            double expected=0;
            for (int key=0;key<tokens;++key)
                expected+=logits[key]*projected[2].row(key)[head*64+d]/total;
            expected+=static_cast<float*>(out_bias.data)[head*64+d];
            float value=actual.row(row)[head*64+d];
            if (!std::isfinite(value)) ++nonfinite;
            else worst=std::max(worst,std::abs(expected-value));
        }
    }
    bool okay=!nonfinite && worst<(magnitude>1 ? 0.02 : 0.002);
    std::printf("tokens=%d magnitude=%g nonfinite=%zu max_error=%.9g %s\n",
        tokens,double(magnitude),nonfinite,worst,okay ? "PASS" : "FAIL");
    layer.destroy_pipeline(opt);return okay;
}
int main(int argc,char** argv) {
    if (argc!=2 || (!std::getenv("VDA_PROBE_SCALAR_ATTENTION_TEST") &&
        (!std::getenv("VDA_PROBE_TC_ATTENTION") || !std::getenv("VDA_PROBE_TENSORCORE")))) return 2;
    ncnn::create_gpu_instance();int gpu=std::atoi(argv[1]);
    if (gpu<0 || gpu>=ncnn::get_gpu_count()) return 2;
    const auto* device=ncnn::get_gpu_device(gpu);bool okay=true;
    for (int tokens : {17,37,778}) okay=check(device,tokens,0.2f) && okay;
    okay=check(device,37,4.f) && okay;
    return okay ? 0 : 1;
}
