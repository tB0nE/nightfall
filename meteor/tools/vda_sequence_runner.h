// Real-frame recurrent validation. Decoding/preprocessing are offline fixtures;
// history gathers/stores are GPU-resident and timed separately from the graph.
#pragma once
#include "vda_settings.h"
#include "vda_sequence_history.h"
#include "vda_fixed_graph.h"
#include "vda_projected_cache.h"
#include "vda_probe_allocator.h"
#include "vda_layer_profiler.h"
#include <filesystem>
#include <fstream>
#include <sstream>
#include <chrono>
#include <cmath>
#include <iomanip>

inline double vda_elapsed(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
}
inline std::string vda_frame_name(int index) {
    std::ostringstream name;name<<"frame_"<<std::setfill('0')<<std::setw(4)<<index;return name.str();
}
inline int vda_run_sequence(ncnn::Net& step,const ncnn::VulkanDevice* device,
                            const std::string& directory,const std::string& output_directory,
                            const std::string& cold_prefix) {
    namespace fs=std::filesystem;
    const auto shape=vda_frame_shape();if (!shape.valid()) return 2;
    if (!step.opt.use_fp16_storage) return 2;
    ncnn::Net cold;cold.opt=step.opt;
    cold.opt.use_fp16_storage=false;cold.opt.use_fp16_packed=false;cold.opt.use_fp16_arithmetic=false;
    cold.opt.use_cooperative_matrix=false;cold.set_vulkan_device(device);
    if (cold.load_param((cold_prefix+".ncnn.param").c_str()) ||
        cold.load_model((cold_prefix+".ncnn.bin").c_str())) return 3;
    for (const auto* layer : cold.layers()) if (!layer->support_vulkan) return 9;
    VdaSequenceHistory history(device,step.opt,shape);
    std::vector<const VdaCachedProjection*> cached;
    for (auto* layer : step.layers())
        if (auto* projection=dynamic_cast<VdaCachedProjection*>(layer)) cached.push_back(projection);
    bool projected=!cached.empty();
    if (projected && cached.size()!=16) return 3;
    if (projected) {
        size_t bytes=0;for (const auto* projection : cached) bytes+=projection->pool_bytes();
        std::fprintf(stderr,"projected_cache_pools_bytes=%zu raw_history_gather=disabled\n",bytes);
    }
    if (history.initialize(!projected)) return 3;
    if (vda_setting("VDA_PROFILE_SEQUENCE_FRAME")) {
        for (auto*& layer : step.mutable_layers()) layer=new VdaProfileLayer(layer);
    }
    struct ContextGuard { ~ContextGuard() { vda_projected_context={}; } } context_guard;
    ncnn::VkMat selection_buffer;
    fs::create_directories(output_directory);
    std::ifstream manifest(fs::path(directory)/"frames.tsv");
    if (!manifest) return 4;
    std::ofstream timing(fs::path(output_directory)/"timings.csv");
    std::ofstream trace(fs::path(output_directory)/"history.tsv");
    timing<<"frame,timestamp,reset,prepare_ms,graph_ms,store_ms,validation_download_ms\n";
    int expected=0;double previous_timestamp=-1;std::string line;
    while (std::getline(manifest,line)) {
        int index;double timestamp;std::string reset;
        std::istringstream row(line);
        if (!(row>>index>>timestamp>>reset) || index!=expected++) return 4;
        if (!std::isfinite(timestamp) || timestamp<0 || timestamp<=previous_timestamp ||
            (reset!="none" && reset!="start" && reset!="gap" && reset!="cut")) return 4;
        if (index>0 && ((reset=="none" && timestamp-previous_timestamp>0.5) ||
                        (reset=="gap" && timestamp-previous_timestamp<=0.5))) return 4;
        previous_timestamp=timestamp;
        bool first=reset!="none";
        vda_profile_current_frame=index;
        vda_drain_completed_buffers(step.opt);
        if (index==0 && !first) return 4;
        int slot=first ? 0 : history.free_slot();
        if (slot<0) return 4;
        trace<<index<<'\t'<<reset<<'\t'<<slot;
        if (!first) for (int selected : history.selection()) trace<<'\t'<<selected;
        trace<<'\n';
        auto started=std::chrono::steady_clock::now();
        ncnn::Mat image(shape.width,shape.height,3);
        std::ifstream frame(fs::path(directory)/(vda_frame_name(index)+".f32"),std::ios::binary);
        frame.read(static_cast<char*>(image.data),image.total()*sizeof(float));
        if (!frame || frame.peek()!=std::char_traits<char>::eof()) return 4;
        auto& net=first ? cold : step;
        std::array<ncnn::VkMat,9> inputs,outputs;
        ncnn::VkCompute prepare(device);
        prepare.record_upload(image,inputs[0],net.opt);
        if (!first && projected) {
            ncnn::Mat selection(32);
            auto selected=history.selection();
            for (int i=0;i<31;++i) {
                if (selected[i]==slot) return 5;
                static_cast<float*>(selection.data)[i]=float(selected[i]);
                vda_projected_context.slots[i]=selected[i];
            }
            static_cast<float*>(selection.data)[31]=float(slot);
            vda_projected_context.slots[31]=slot;
            prepare.record_clone(selection,selection_buffer,step.opt);
            vda_projected_context.slot=slot;
            vda_projected_context.selection=&selection_buffer;
        } else if (!first && history.gather(inputs,prepare)) return 5;
        if (prepare.submit_and_wait()) return 5;
        double prepare_ms=vda_elapsed(started);
        started=std::chrono::steady_clock::now();
        ncnn::VkCompute compute(device);
        const int input_count=first || projected ? 1 : 9;
        if (vda_setting("VDA_PROBE_NATIVE_EXECUTOR")) {
            auto extractor=net.create_extractor();
            for (int i=0;i<input_count;++i)
                if (extractor.input(("in"+std::to_string(i)).c_str(),inputs[i])) return 6;
            for (int i=0;i<9;++i)
                if (extractor.extract(("out"+std::to_string(i)).c_str(),outputs[i],compute)) return 6;
        } else if (vda_fixed_graph(net,inputs,input_count,outputs,compute)) return 6;
        if (compute.submit_and_wait()) return 6;
        double graph_ms=vda_elapsed(started);
        double download_ms=0;
        // Cold outputs are FP32, while Meteor stores every history state as FP16.
        // Cold seeding uses one validation readback/cast; recurrent stores stay GPU-only.
        std::array<ncnn::Mat,9> cpu;
        if (first) {
            started=std::chrono::steady_clock::now();ncnn::VkCompute download(device);
            for (int i=0;i<9;++i) download.record_download(outputs[i],cpu[i],cold.opt);
            if (download.submit_and_wait()) return 7;
            download_ms=vda_elapsed(started);
        }
        started=std::chrono::steady_clock::now();
        ncnn::VkCompute store(device);
        std::array<ncnn::VkMat,9> stored=outputs;
        if (first) for (int i=1;i<9;++i) {
            ncnn::Mat unpacked=cpu[i],half;
            if (unpacked.elempack!=1) { ncnn::Mat tmp;ncnn::convert_packing(unpacked,tmp,1);unpacked=tmp; }
            ncnn::cast_float32_to_float16(unpacked,half);
            store.record_clone(half,stored[i],step.opt);
        }
        if (projected) {
            if (first) for (const auto* projection : cached) {
                projection->reset_history();
                if (projection->prime(stored[projection->state_index()+1],slot,store,step.opt)) return 7;
            }
        } else if (history.store(stored,slot,store)) return 7;
        if (store.submit_and_wait()) return 7;
        if (first) history.seed(); else history.push(slot);
        double store_ms=vda_elapsed(started);
        if (!first) {
            started=std::chrono::steady_clock::now();ncnn::VkCompute download(device);
            for (int i=0;i<9;++i) download.record_download(outputs[i],cpu[i],step.opt);
            if (download.submit_and_wait()) return 7;
            download_ms=vda_elapsed(started);
        }
        for (int i=0;i<9;++i) {
            ncnn::Mat unpacked=cpu[i];
            if (unpacked.elempack!=1) { ncnn::Mat tmp;ncnn::convert_packing(unpacked,tmp,1);unpacked=tmp; }
            if (unpacked.elembits()!=32) return 7;
            for (int c=0;c<unpacked.c;++c) {
                const float* values=unpacked.channel(c);
                for (size_t j=0;j<size_t(unpacked.w)*unpacked.h*unpacked.d;++j)
                    if (!std::isfinite(values[j])) { std::fprintf(stderr,"sequence_nonfinite frame=%d output=%d\n",index,i);return 8; }
            }
            ncnn::Mat saved=unpacked;
            if (i) ncnn::cast_float32_to_float16(unpacked,saved);
            std::string suffix=i ? ".state"+std::to_string(i-1)+".f16" : ".depth.f32";
            std::ofstream file(fs::path(output_directory)/(vda_frame_name(index)+suffix),std::ios::binary);
            for (int c=0;c<saved.c;++c) {
                auto channel=saved.channel(c);
                file.write(static_cast<const char*>(channel.data),size_t(saved.w)*saved.h*saved.d*saved.elemsize);
            }
            if (!file) return 7;
        }
        timing<<index<<','<<std::setprecision(12)<<timestamp<<','<<reset<<','<<prepare_ms<<','<<graph_ms<<','<<store_ms<<','<<download_ms<<'\n';
        timing.flush();trace.flush();
        if (index%8==0 || first) std::fprintf(stderr,"sequence_frame=%d reset=%s graph_ms=%.3f\n",index,reset.c_str(),graph_ms);
    }
    return expected ? 0 : 4;
}
