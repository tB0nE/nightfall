// Experimental fixed-shape Linear adapter, using unchanged InnerProduct weights
// with ncnn's tiled Vulkan Gemm implementation. Only used by standalone probes.
#pragma once
#include <layer.h>
#include <cstdlib>
#include "vda_gemm_factory.h"

class VdaTemporalProjection : public ncnn::Layer {
public:
    VdaTemporalProjection() {
        inner=vda_create_gemm();
        one_blob_only=true;
        support_vulkan=true;
        support_packing=inner->support_packing;
        support_vulkan_packing=inner->support_vulkan_packing;
        support_vulkan_any_packing=inner->support_vulkan_any_packing;
    }
    ~VdaTemporalProjection() override { delete inner; }
    int load_param(const ncnn::ParamDict& pd) override {
        width=pd.get(0,0); bias=pd.get(1,0); count=pd.get(2,0);
        int rows=pd.get(3,0);
        if (width<=0 || rows<=0 || count<=0 || count%width || (bias!=0 && bias!=1)) return -1;
        ncnn::ParamDict gemm;
        gemm.set(3,1);
        gemm.set(4,0); gemm.set(5,1); gemm.set(6,1);
        gemm.set(7,rows); gemm.set(8,width); gemm.set(9,count/width);
        gemm.set(10,bias ? 4 : -1);
        inner->vkdev=vkdev;
        return inner->load_param(gemm);
    }
    int load_model(const ncnn::ModelBin& mb) override {
        ncnn::Mat weights[2];
        weights[0]=mb.load(count,0);
        if (weights[0].empty()) return -100;
        if (bias) { weights[1]=mb.load(width,1); if (weights[1].empty()) return -100; }
        ncnn::ModelBinFromMatArray original(weights);
        return inner->load_model(original);
    }
    int create_pipeline(const ncnn::Option& opt) override {
        inner->bottom_shapes=bottom_shapes; inner->top_shapes=top_shapes;
        return inner->create_pipeline(opt);
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        return inner->upload_model(cmd,opt);
    }
    int destroy_pipeline(const ncnn::Option& opt) override {
        return inner->destroy_pipeline(opt);
    }
    int forward(const ncnn::VkMat& in,ncnn::VkMat& out,ncnn::VkCompute& cmd,
                const ncnn::Option& opt) const override {
        return inner->forward(in,out,cmd,opt);
    }
private:
    ncnn::Layer* inner;
    int width=0,bias=0,count=0;
};
inline ncnn::Layer* create_vda_temporal_projection(void*) { return new VdaTemporalProjection; }
