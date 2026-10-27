// Independent double-precision centered-variance oracle, with the native
// coefficient/weight storage rounding applied explicitly.
#include "vda_fused_layernorm.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
// Match upload representation using ncnn's actual CPU cast: SIMD blocks and
// scalar tails can round differently. The normalization oracle remains double.
static ncnn::Mat uploaded_values(const ncnn::Mat& value,bool half,const ncnn::Option& opt) {
    if (!half) return value;
    ncnn::Mat packed,represented;ncnn::cast_float32_to_float16(value,packed,opt);
    ncnn::cast_float16_to_float32(packed,represented,opt);return represented;
}
// Shader stores round to nearest. All oracle values are within FP16 range.
static float half_spacing(float value) {
    if (value==0) return std::ldexp(1.f,-24);
    int exponent;std::frexp(value,&exponent);
    return std::ldexp(1.f,std::max(-24,exponent-11));
}
static float shader_stored(float value,bool half) {
    if (!half || value==0) return value;
    float spacing=half_spacing(value);
    return std::nearbyint(value/spacing)*spacing;
}
static bool check(const ncnn::VulkanDevice* device,int width,bool half,bool padded,float offset,float amplitude,bool affine=true) {
    ncnn::VkBlobAllocator allocator(device);ncnn::VkStagingAllocator staging(device);
    ncnn::Option opt;opt.use_vulkan_compute=true;opt.use_fp16_storage=half;
    opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;
    opt.blob_vkallocator=&allocator;opt.workspace_vkallocator=&allocator;opt.staging_vkallocator=&staging;
    int height=padded ? 3 : 7,channels=padded ? 5 : 1;
    ncnn::Mat input=padded ? ncnn::Mat(width,height,channels) : ncnn::Mat(width,height);
    for (int c=0;c<channels;++c) for (int row=0;row<height;++row) for (int col=0;col<width;++col)
        static_cast<float*>(input.channel(c))[row*width+col]=offset+amplitude*std::sin(float(col+row*11+c*17)*0.137f);
    ncnn::Mat weights[2]={ncnn::Mat(width),ncnn::Mat(width)};
    for (int col=0;col<width;++col) {
        static_cast<float*>(weights[0].data)[col]=0.8f+0.01f*std::cos(float(col));
        static_cast<float*>(weights[1].data)[col]=0.02f*std::sin(float(col));
    }
    ncnn::Mat represented_input=uploaded_values(input,half,opt);
    ncnn::Mat represented_gamma=uploaded_values(weights[0],half,opt);
    ncnn::Mat represented_beta=uploaded_values(weights[1],half,opt);
    VdaFusedLayerNorm layer;layer.vkdev=device;
    ncnn::ParamDict pd;pd.set(0,width);pd.set(1,1e-5f);pd.set(2,int(affine));
    if (layer.load_param(pd) || layer.load_model(ncnn::ModelBinFromMatArray(weights)) || layer.create_pipeline(opt)) return false;
    ncnn::VkTransfer upload(device);layer.upload_model(upload,opt);if (upload.submit_and_wait()) return false;
    ncnn::VkMat gpu_input,unpacked,output;ncnn::VkCompute cmd(device);
    cmd.record_upload(input,gpu_input,opt);device->convert_packing(gpu_input,unpacked,1,cmd,opt);
    if (layer.forward(unpacked,output,cmd,opt)) return false;
    ncnn::Mat actual;cmd.record_download(output,actual,opt);if (cmd.submit_and_wait()) return false;
    if (actual.elembits()!=32 || actual.elempack!=1) return false;
    double worst=0,worst_ratio=0;bool okay=true;
    for (int c=0;c<channels;++c) for (int row=0;row<height;++row) {
        const float* source=static_cast<const float*>(represented_input.channel(c))+row*width;
        const float* values=static_cast<const float*>(actual.channel(c))+row*width;
        double mean=0,variance=0;
        for (int col=0;col<width;++col) mean+=source[col];
        mean/=width;
        for (int col=0;col<width;++col) { double delta=source[col]-mean;variance+=delta*delta; }
        variance/=width;
        double inverse=1/std::sqrt(variance+1e-5);
        float a=shader_stored(float(inverse),half),b=shader_stored(float(-mean*inverse),half);
        for (int col=0;col<width;++col) {
            float value=source[col]*a+b;
            if (affine) value=value*static_cast<float*>(represented_gamma.data)[col]+static_cast<float*>(represented_beta.data)[col];
            value=shader_stored(value,half);
            if (!std::isfinite(values[col])) return false;
            double error=std::abs(double(value)-values[col]);
            // Different FP32 reduction orders can cross an FP16 coefficient
            // boundary. Bound one coefficient ULP plus two final-store ULPs;
            // retain the strict absolute bound for the FP32 implementation.
            double gain=affine ? std::abs(static_cast<float*>(represented_gamma.data)[col]) : 1;
            double budget=half ? (std::abs(source[col])*half_spacing(a)+half_spacing(b))*gain+
                2*half_spacing(value)+1e-6 : 0.0002;
            worst=std::max(worst,error);worst_ratio=std::max(worst_ratio,error/budget);
            okay=okay && error<=budget;
        }
    }
    layer.destroy_pipeline(opt);
    std::printf("width=%d fp16=%d padded=%d offset=%g amplitude=%g affine=%d max_error=%g error_budget_ratio=%g %s\n",
        width,int(half),int(padded),double(offset),double(amplitude),int(affine),worst,worst_ratio,okay ? "PASS" : "FAIL");
    return okay;
}
int main(int argc,char** argv) {
    if (argc!=2) return 2;
    ncnn::create_gpu_instance();int gpu=std::atoi(argv[1]);if (gpu<0 || gpu>=ncnn::get_gpu_count()) return 2;
    const auto* device=ncnn::get_gpu_device(gpu);bool okay=true;
    for (bool half : {false,true}) {
        for (int width : {7,64,192,384}) okay=check(device,width,half,width==7 || width==192,0.f,1.f) && okay;
        okay=check(device,384,half,false,10.f,0.5f) && okay;
        okay=check(device,64,half,true,0.25f,0.f) && okay;
        okay=check(device,192,half,false,0.f,1.f,false) && okay;
    }
    return okay ? 0 : 1;
}
