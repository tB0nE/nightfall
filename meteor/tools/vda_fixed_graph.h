// Fixed-shape, topologically ordered probe executor. It deliberately omits
// ncnn's dispatch-count submission heuristic, and must not be used as a general
// replacement for the runtime executor. Every output is checked separately.
#pragma once
#include "vda_settings.h"
#include <net.h>
#include <layer.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include "vda_probe_allocator.h"
#include "vda_compute_clone.h"

inline int vda_completed_batch_layers() {
    const char* value=vda_setting("VDA_PROBE_SYNC_LAYERS");
    if (value) {
        char* end=nullptr;long parsed=std::strtol(value,&end,10);
        return *value && end && !*end && parsed>=0 && parsed<=4096 ? int(parsed) : -1;
    }
    return 0;
}

inline int vda_fixed_graph(const ncnn::Net& net,const std::array<ncnn::VkMat,9>& inputs,
                           int input_count,std::array<ncnn::VkMat,9>& outputs,
                           ncnn::VkCompute& cmd) {
    const auto& opt=net.opt;
    const auto* device=net.vulkan_device();
    std::vector<ncnn::VkMat> blobs(net.blobs().size());
    // Batch deferral is diagnostic only: a longer repeat test still failed.
    // Retain whole-frame deferral unless an explicit diagnostic override is set.
    const int batch=vda_completed_batch_layers();
    if (batch<0) return -1;
    int dispatched=0;
    for (size_t i=0;i<net.blobs().size();++i)
        for (int j=0;j<input_count;++j)
            if (net.blobs()[i].name=="in"+std::to_string(j)) blobs[i]=inputs[j];
    for (const auto* layer : net.layers()) {
        if (layer->type=="Input") continue;
        if (!layer->support_vulkan || layer->featmask) return -1;
        std::vector<ncnn::VkMat> bottom(layer->bottoms.size()),top(layer->tops.size());
        for (size_t i=0;i<bottom.size();++i) {
            auto& source=blobs[layer->bottoms[i]];
            if (source.empty()) { std::fprintf(stderr,"fixed_graph_missing_input %s\n",layer->name.c_str());return -1; }
            if (layer->support_inplace && *source.refcount!=1) {
                if (vda_compute_clone) {
                    if (vda_compute_clone->copy(source,bottom[i],cmd,opt)) return -1;
                } else cmd.record_clone(source,bottom[i],opt);
            }
            else bottom[i]=source;
            int pack=1;
            if (layer->support_vulkan_packing) {
                int count=bottom[i].elempack*(bottom[i].dims==1 ? bottom[i].w : bottom[i].dims==2 ? bottom[i].h : bottom[i].c);
                pack=count%4==0 ? 4 : 1;
                if (layer->support_vulkan_any_packing) pack=bottom[i].elempack;
            }
            if (bottom[i].elempack!=pack) {
                ncnn::VkMat converted;device->convert_packing(bottom[i],converted,pack,cmd,opt);bottom[i]=converted;
            }
        }
        int result;
        if (layer->support_inplace) {
            result=layer->one_blob_only ? layer->forward_inplace(bottom[0],cmd,opt)
                                       : layer->forward_inplace(bottom,cmd,opt);
            top=bottom;
        } else {
            result=layer->one_blob_only ? layer->forward(bottom[0],top[0],cmd,opt)
                                       : layer->forward(bottom,top,cmd,opt);
        }
        if (result) { std::fprintf(stderr,"fixed_graph_failed %s code=%d\n",layer->name.c_str(),result);return result; }
        for (size_t i=0;i<layer->tops.size();++i) blobs[layer->tops[i]]=top[i];
        for (int index : layer->bottoms) blobs[index].release();
        if (batch && ++dispatched%batch==0) {
            if (cmd.submit_and_wait() || cmd.reset()) return -1;
            // Released buffers can now be reused without overlapping any
            // earlier GPU work. This bounds the diagnostic allocator's peak.
            vda_drain_completed_buffers(opt);
        }
    }
    for (size_t i=0;i<net.blobs().size();++i)
        for (int j=0;j<9;++j)
            if (net.blobs()[i].name=="out"+std::to_string(j)) outputs[j]=blobs[i];
    for (const auto& output : outputs) if (output.empty()) return -1;
    return 0;
}
