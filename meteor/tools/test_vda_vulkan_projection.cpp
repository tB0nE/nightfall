// Standalone boundary/precision test for VDA's native cooperative Gemm path.
#include "vda_vulkan_projection.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <datareader.h>
#include <cstring>
#include <memory>

static bool check(const ncnn::VulkanDevice* device,int rows,int width,int outputs,bool cooperative) {
    ncnn::VkBlobAllocator allocator(device);
    ncnn::VkStagingAllocator staging(device);
    ncnn::Option opt;
    opt.use_vulkan_compute=true;opt.use_fp16_storage=true;
    opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;
    opt.use_cooperative_matrix=cooperative;
    opt.blob_vkallocator=&allocator;opt.workspace_vkallocator=&allocator;
    opt.staging_vkallocator=&staging;
    ncnn::Mat input(width,rows),weights[2]={ncnn::Mat(width*outputs),ncnn::Mat(outputs)};
    for (int i=0;i<width*rows;++i) static_cast<float*>(input.data)[i]=std::sin(i*0.173f)*0.2f;
    for (int i=0;i<width*outputs;++i) static_cast<float*>(weights[0].data)[i]=std::cos(i*0.139f)*0.02f;
    for (int i=0;i<outputs;++i) static_cast<float*>(weights[1].data)[i]=std::sin(i*0.23f)*0.001f;
    std::unique_ptr<ncnn::Layer> owned;
    bool portable=std::getenv("VDA_PROBE_PORTABLE_GEMM")!=nullptr;
    if (portable) owned.reset(new VdaPortableGemm);else owned.reset(new VdaTemporalProjection);
    auto& layer=*owned;
    layer.vkdev=device;
    ncnn::ParamDict pd;
    if (portable) {
        pd.set(3,1);pd.set(5,1);pd.set(6,1);pd.set(7,rows);pd.set(8,outputs);pd.set(9,width);pd.set(10,4);
    } else { pd.set(0,outputs);pd.set(1,1);pd.set(2,width*outputs);pd.set(3,rows); }
    if (layer.load_param(pd)) return false;
    if (portable) {
        // Exercise actual Gemm serialization, not just MatArray (which ignores
        // tagged/raw load modes and previously hid a bias cursor mismatch).
        std::vector<unsigned char> bytes;
        for (int index=0;index<2;++index) {
            const auto& weight=weights[index];
            size_t logical_bytes=(index==0 ? size_t(width)*outputs : size_t(outputs))*sizeof(float);
            uint32_t tag=0;size_t start=bytes.size();
            bytes.resize(start+4+logical_bytes);
            std::memcpy(bytes.data()+start,&tag,4);
            std::memcpy(bytes.data()+start+4,weight.data,logical_bytes);
        }
        const unsigned char* cursor=bytes.data();
        ncnn::DataReaderFromMemory reader(cursor);ncnn::ModelBinFromDataReader model(reader);
        if (layer.load_model(model) || cursor!=bytes.data()+bytes.size()) return false;
    } else if (layer.load_model(ncnn::ModelBinFromMatArray(weights))) return false;
    if (layer.create_pipeline(opt)) return false;
    ncnn::VkTransfer transfer(device);
    if (layer.upload_model(transfer,opt) || transfer.submit_and_wait()) return false;
    ncnn::VkMat gpu_input,output;
    ncnn::VkCompute cmd(device);cmd.record_upload(input,gpu_input,opt);
    if (!layer.support_vulkan_packing && gpu_input.elempack!=1) {
        ncnn::VkMat unpacked;device->convert_packing(gpu_input,unpacked,1,cmd,opt);gpu_input=unpacked;
    }
    if (layer.forward(gpu_input,output,cmd,opt)) return false;
    ncnn::Mat actual;cmd.record_download(output,actual,opt);
    if (cmd.submit_and_wait()) return false;
    if (actual.elempack!=1) { ncnn::Mat unpacked;ncnn::convert_packing(actual,unpacked,1);actual=unpacked; }
    ncnn::Mat half,rounded_input,rounded_weights,rounded_bias;
    ncnn::cast_float32_to_float16(input,half);ncnn::cast_float16_to_float32(half,rounded_input);
    ncnn::cast_float32_to_float16(weights[0],half);ncnn::cast_float16_to_float32(half,rounded_weights);
    ncnn::cast_float32_to_float16(weights[1],half);ncnn::cast_float16_to_float32(half,rounded_bias);
    size_t nonfinite=0;double worst=0;
    for (int row=0;row<rows;++row) {
        const float* result=actual.row(row);
        for (int col=0;col<outputs;++col) if (!std::isfinite(result[col])) ++nonfinite;
        if (row%37 && row<rows-16) continue;
        for (int col=0;col<outputs;col+=13) {
            double expected=static_cast<const float*>(rounded_bias.data)[col];
            const float* in=rounded_input.row(row);
            const float* w=static_cast<const float*>(rounded_weights.data)+col*width;
            for (int k=0;k<width;++k) expected+=double(in[k])*w[k];
            worst=std::max(worst,std::abs(expected-result[col]));
        }
    }
    bool okay=!nonfinite && worst<0.002;
    std::printf("coop=%d M=%d N=%d K=%d nonfinite=%zu sampled_max_error=%.9g %s\n",
        int(cooperative),rows,outputs,width,nonfinite,worst,okay ? "PASS" : "FAIL");
    layer.destroy_pipeline(opt);
    return okay;
}
int main(int argc,char** argv) {
    if (argc!=3) return 2;
    ncnn::create_gpu_instance();int gpu=std::atoi(argv[1]);
    if (gpu<0 || gpu>=ncnn::get_gpu_count()) return 2;
    auto* device=ncnn::get_gpu_device(gpu);
    bool cooperative=std::atoi(argv[2])!=0;bool okay=true;
    for (int rows : {768,778,784}) okay=check(device,rows,384,1536,cooperative) && okay;
    okay=check(device,209,384,384,cooperative) && okay;
    if (std::getenv("VDA_PROBE_TENSORCORE") || std::getenv("VDA_PROBE_PORTABLE_GEMM")) {
        okay=check(device,19,33,63,cooperative) && okay;
        okay=check(device,65,65,79,cooperative) && okay;
    }
    return okay ? 0 : 1;
}
