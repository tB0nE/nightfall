// Diagnostic per-layer synchronization profiler. Times include queue overhead
// and preceding layout conversions; do not use their sum as throughput.
#pragma once
#include "vda_settings.h"
#include <layer.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cmath>

// The sequence runner selects a single warmed frame; all other frames execute
// normally so cached history is built from distinct real video inputs.
inline int vda_profile_current_frame=-1;

class VdaProfileLayer : public ncnn::Layer {
public:
    explicit VdaProfileLayer(ncnn::Layer* original) : inner(original) {
        static_cast<ncnn::Layer&>(*this)=*original;
    }
    ~VdaProfileLayer() override { delete inner; }
    int destroy_pipeline(const ncnn::Option& opt) override {
        return inner->destroy_pipeline(opt);
    }
    template<class F> int timed(ncnn::VkCompute& cmd,F operation) const {
        if (const char* frame=vda_setting("VDA_PROFILE_SEQUENCE_FRAME"))
            if (vda_profile_current_frame!=std::atoi(frame)) return operation();
        auto start=std::chrono::steady_clock::now();
        int result=operation();
        if (vda_setting("VDA_PROFILE_RECORD_ONLY")) {
            double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
            std::fprintf(stderr,"record_profile %s %s %.6f\n",type.c_str(),name.c_str(),ms);
            return result;
        }
        if (!result) result=cmd.submit_and_wait();
        double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        std::fprintf(stderr,"layer_profile %s %s %.6f\n",type.c_str(),name.c_str(),ms);
        if (!result) result=cmd.reset();
        return result;
    }
    int validate(const ncnn::VkMat& tensor,const ncnn::Option& opt) const {
        if (!vda_setting("VDA_PROFILE_VALIDATE")) return 0;
        ncnn::Mat cpu;
        ncnn::VkCompute download(vkdev);
        download.record_download(tensor,cpu,opt);
        if (download.submit_and_wait()) return -99;
        if (cpu.elembits()==16) {
            ncnn::Mat converted; ncnn::cast_float16_to_float32(cpu,converted);cpu=converted;
        }
        if (cpu.elembits()!=32) return -99;
        for (int c=0;c<cpu.c;++c) {
            const float* values=cpu.channel(c);
            size_t count=size_t(cpu.w)*cpu.h*cpu.d*cpu.elempack;
            for (size_t i=0;i<count;++i) if (!std::isfinite(values[i])) {
                std::fprintf(stderr,"first_nonfinite %s %s channel=%d index=%zu value=%g\n",
                    type.c_str(),name.c_str(),c,i,double(values[i]));
                return -99;
            }
        }
        return 0;
    }
    int forward(const std::vector<ncnn::VkMat>& in,std::vector<ncnn::VkMat>& out,
                ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        int result=timed(cmd,[&] { return inner->forward(in,out,cmd,opt); });
        if (!result) for (const auto& tensor : out) { result=validate(tensor,opt); if (result) break; }
        return result;
    }
    int forward(const ncnn::VkMat& in,ncnn::VkMat& out,
                ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        int result=timed(cmd,[&] { return inner->forward(in,out,cmd,opt); });
        return result ? result : validate(out,opt);
    }
    int forward_inplace(std::vector<ncnn::VkMat>& tensors,ncnn::VkCompute& cmd,
                        const ncnn::Option& opt) const override {
        int result=timed(cmd,[&] { return inner->forward_inplace(tensors,cmd,opt); });
        if (!result) for (const auto& tensor : tensors) { result=validate(tensor,opt); if (result) break; }
        return result;
    }
    int forward_inplace(ncnn::VkMat& tensor,ncnn::VkCompute& cmd,
                        const ncnn::Option& opt) const override {
        int result=timed(cmd,[&] { return inner->forward_inplace(tensor,cmd,opt); });
        return result ? result : validate(tensor,opt);
    }
private:
    ncnn::Layer* inner;
};
