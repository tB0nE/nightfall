// Keep ncnn spatial attention off the failing cooperative-matrix path while
// allowing other layers to use it. Standalone benchmark policy, not Meteor.
#pragma once
#include <layer.h>

class VdaSafeAttention : public ncnn::Layer {
public:
    VdaSafeAttention() {
        inner=ncnn::create_layer_vulkan("MultiHeadAttention");
        static_cast<ncnn::Layer&>(*this)=*inner;
    }
    ~VdaSafeAttention() override { delete inner; }
    int load_param(const ncnn::ParamDict& pd) override {
        inner->vkdev=vkdev;
        return inner->load_param(pd);
    }
    int load_model(const ncnn::ModelBin& mb) override { return inner->load_model(mb); }
    int create_pipeline(const ncnn::Option& opt) override {
        inner->bottom_shapes=bottom_shapes;inner->top_shapes=top_shapes;
        return inner->create_pipeline(safe(opt));
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        return inner->upload_model(cmd,safe(opt));
    }
    int destroy_pipeline(const ncnn::Option& opt) override { return inner->destroy_pipeline(safe(opt)); }
    int forward(const std::vector<ncnn::VkMat>& in,std::vector<ncnn::VkMat>& out,
                ncnn::VkCompute& cmd,const ncnn::Option& opt) const override {
        return inner->forward(in,out,cmd,safe(opt));
    }
private:
    static ncnn::Option safe(ncnn::Option opt) { opt.use_cooperative_matrix=false; return opt; }
    ncnn::Layer* inner;
};
inline ncnn::Layer* create_vda_safe_attention(void*) { return new VdaSafeAttention; }
