// Standalone conversion validation probe. Not linked into Meteor.
#include <net.h>
#include <gpu.h>
#include <layer.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <memory>
#include <array>
#include "vda_vulkan_matmul.h"
#include "vda_layer_profiler.h"
#include "vda_vulkan_projection.h"
#include "vda_vulkan_spatial_attention.h"
#include "vda_safe_attention.h"
#include "vda_fixed_graph.h"
#include "vda_fused_temporal.h"
#include "vda_sequence_runner.h"
#include "vda_projected_cache.h"
#include "vda_probe_allocator.h"
#include "vda_fused_layernorm.h"

int main(int argc, char** argv) {
    if (argc != 5 && argc != 6) {
        std::fprintf(stderr, "usage: probe MODEL_PREFIX GPU_INDEX INPUT_F32 OUTPUT_PREFIX [CACHE_PREFIX]\n");
        return 2;
    }
    ncnn::create_gpu_instance();
    int gpu = std::atoi(argv[2]);
    if (gpu < -1 || gpu >= ncnn::get_gpu_count()) return 2;
    if (std::getenv("VDA_PROFILE_RECORD_ONLY") && std::getenv("VDA_PROFILE_VALIDATE")) return 2;
    const bool resident = std::getenv("VDA_PROBE_RESIDENT") != nullptr;
    if (resident && gpu < 0) return 2;
    const ncnn::VulkanDevice* device = gpu>=0 ? ncnn::get_gpu_device(gpu) : nullptr;
    // Allocators outlive the net and all input/output tensors.
    std::unique_ptr<ncnn::VkBlobAllocator> blob;
    std::unique_ptr<ncnn::VkBlobAllocator> workspace;
    std::unique_ptr<ncnn::VkStagingAllocator> staging;
    const bool reuse_barrier=std::getenv("VDA_PROBE_REUSE_BARRIER")!=nullptr;
    if ((std::getenv("VDA_PROBE_DEFER_FREE") && std::getenv("VDA_PROBE_ALLOW_BUFFER_REUSE")) ||
        (reuse_barrier && (std::getenv("VDA_PROBE_DEFER_FREE") || std::getenv("VDA_PROBE_ALLOW_BUFFER_REUSE")))) return 2;
    const bool defer_free=resident && (std::getenv("VDA_PROBE_DEFER_FREE") ||
        (device->info.vendor_id()==0x1002 && !reuse_barrier && !std::getenv("VDA_PROBE_ALLOW_BUFFER_REUSE")));
    const char* scope_env=std::getenv("VDA_PROBE_DEFER_SCOPE");
    const std::string scope=scope_env ? scope_env :
        (defer_free && device->info.vendor_id()==0x1002 ? "blob" : "all");
    const bool split_allocators=scope!="all" || std::getenv("VDA_PROBE_SPLIT_ALLOCATORS");
    if (scope!="all" && scope!="blob" && scope!="workspace") return 2;
    if (scope_env && (!defer_free || reuse_barrier)) return 2;
    if (resident) {
        if (reuse_barrier) blob.reset(new VdaImmediateAllocator(device));
        else if (defer_free && scope!="workspace") blob.reset(new VdaDeferredAllocator(device));
        else if (split_allocators) blob.reset(new VdaImmediateAllocator(device,false));
        else blob.reset(new ncnn::VkBlobAllocator(device));
        if (split_allocators) workspace.reset(scope=="workspace" || (scope=="all" && defer_free)
            ? static_cast<ncnn::VkBlobAllocator*>(new VdaDeferredAllocator(device)) : new VdaImmediateAllocator(device,false));
        staging.reset(new ncnn::VkStagingAllocator(device));
    }
    ncnn::Net net;
    net.register_custom_layer("VdaTemporalMatMul", create_vda_temporal_matmul);
    net.register_custom_layer("VdaTemporalProjection", create_vda_temporal_projection);
    net.register_custom_layer("VdaSpatialAttention", create_vda_spatial_attention);
    net.register_custom_layer("VdaFusedTemporal",create_vda_fused_temporal);
    net.register_custom_layer("VdaPositionedQuery",create_vda_positioned_query);
    net.register_custom_layer("VdaCachedProjection",create_vda_cached_projection);
    if (std::getenv("VDA_PROBE_FUSED_LAYERNORM"))
        net.register_custom_layer("LayerNorm",create_vda_fused_layernorm);
    if (std::getenv("VDA_PROBE_SAFE_ATTENTION"))
        net.register_custom_layer("MultiHeadAttention",create_vda_safe_attention);
    if (std::getenv("VDA_PROBE_TENSORCORE"))
        net.register_custom_layer("Gemm",create_vda_tensorcore_gemm);
    else if (std::getenv("VDA_PROBE_PORTABLE_GEMM"))
        net.register_custom_layer("Gemm",create_vda_portable_gemm);
    net.opt.num_threads = 4;
    net.opt.use_vulkan_compute = gpu >= 0;
    net.opt.use_fp16_storage = std::getenv("VDA_PROBE_FP16_STORAGE") != nullptr;
    net.opt.use_fp16_packed = false;
    net.opt.use_fp16_arithmetic = std::getenv("VDA_PROBE_FP16_ARITHMETIC") != nullptr;
    // Keep temporal tensors in a predictable layout while validating conversion.
    net.opt.use_packing_layout = std::getenv("VDA_PROBE_PACKING") != nullptr;
    if (std::getenv("VDA_PROBE_NO_SUBGROUP")) net.opt.use_subgroup_ops=false;
    if (std::getenv("VDA_PROBE_NO_LOCAL_MEMORY")) net.opt.use_shader_local_memory=false;
    if (std::getenv("VDA_PROBE_NO_COOPERATIVE_MATRIX")) net.opt.use_cooperative_matrix=false;
    if (std::getenv("VDA_PROBE_NO_TENSOR_STORAGE")) net.opt.use_tensor_storage=false;
    std::fprintf(stderr,"probe_options fp16_storage=%d packing=%d resident=%d\n",
        int(net.opt.use_fp16_storage),int(net.opt.use_packing_layout),int(resident));
    if (std::getenv("VDA_PROBE_TENSORCORE")) {
        auto setting=[](const char* key,const char* fallback) { const char* value=std::getenv(key);return value ? value : fallback; };
        std::fprintf(stderr,"probe_tensorcore output_tile=%s k_tile=%s shared_pad=%s transposed_weights=%d fused_layernorm=%d\n",
            setting("VDA_PROBE_TC_TILE_SHAPE","64x64"),setting("VDA_PROBE_TC_K_TILE","16"),
            setting("VDA_PROBE_TC_SHARED_PAD","0"),int(std::getenv("VDA_PROBE_TC_TRANSPOSE_WEIGHTS")!=nullptr),
            int(std::getenv("VDA_PROBE_FUSED_LAYERNORM")!=nullptr));
    }
    {
        const char* queries=std::getenv("VDA_PROBE_SPATIAL_QUERIES");
        std::fprintf(stderr,"probe_spatial queries=%s key_padding=%d subgroup=%d packed64=%d portable_gemm=%d\n",
            queries ? queries : "4",int(std::getenv("VDA_PROBE_SPATIAL_KEY_PAD")!=nullptr),
            int(std::getenv("VDA_PROBE_SPATIAL_SUBGROUP")!=nullptr),int(std::getenv("VDA_PROBE_SPATIAL_PACKED64")!=nullptr),
            int(std::getenv("VDA_PROBE_PORTABLE_GEMM")!=nullptr));
    }
    std::fprintf(stderr,"probe_buffer_reuse=%s\n",reuse_barrier ? "explicit_first_use_barrier" : defer_free ? "deferred_until_frame_complete" : "native");
    if (resident) {
        net.opt.blob_vkallocator=blob.get();
        net.opt.workspace_vkallocator=workspace ? workspace.get() : blob.get();
        net.opt.staging_vkallocator=staging.get();
        std::fprintf(stderr,"probe_fixed_graph_completed_batch_layers=%d\n",vda_completed_batch_layers());
        std::fprintf(stderr,"probe_defer_scope=%s\n",scope.c_str());
        std::fprintf(stderr,"probe_split_allocators=%d\n",int(split_allocators));
    }
    if (gpu >= 0) net.set_vulkan_device(gpu);
    std::string prefix(argv[1]);
    if (net.load_param((prefix + ".ncnn.param").c_str()) ||
        net.load_model((prefix + ".ncnn.bin").c_str())) return 3;
    std::unique_ptr<VdaComputeClone> compute_clone;
    struct CloneGuard { ~CloneGuard() { vda_compute_clone=nullptr; } } clone_guard;
    if (std::getenv("VDA_PROBE_COMPUTE_CLONE")) {
        if (!resident || std::getenv("VDA_PROBE_NATIVE_EXECUTOR")) return 2;
        compute_clone.reset(new VdaComputeClone(device));
        if (compute_clone->initialize()) return 3;
        vda_compute_clone=compute_clone.get();
    }
    bool cpu_fallback = false;
    if (gpu >= 0) for (const auto* layer : net.layers())
        if (!layer->support_vulkan) {
            cpu_fallback = true;
            std::fprintf(stderr, "cpu_layer %s %s\n", layer->type.c_str(), layer->name.c_str());
        }
    if (resident && cpu_fallback) return 9;
    if (!std::getenv("VDA_PROBE_SEQUENCE")) for (const auto* layer : net.layers())
        if (dynamic_cast<const VdaCachedProjection*>(layer)) {
            std::fprintf(stderr,"projected_history_requires_sequence_mode\n");return 2;
        }
    if (std::getenv("VDA_PROBE_SEQUENCE")) {
        const char* cold_prefix=std::getenv("VDA_PROBE_COLD_PREFIX");
        if (!resident || argc!=5 || !cold_prefix) return 2;
        return vda_run_sequence(net,device,argv[3],argv[4],cold_prefix);
    }
    if (std::getenv("VDA_PROBE_PROFILE")) {
        if (!resident) return 2;
        for (auto*& layer : net.mutable_layers()) layer=new VdaProfileLayer(layer);
    }
    const auto frame_shape=vda_frame_shape();if (!frame_shape.valid()) return 2;
    ncnn::Mat image(frame_shape.width,frame_shape.height,3);
    std::ifstream input(argv[3], std::ios::binary);
    input.read(static_cast<char*>(image.data), image.total() * sizeof(float));
    if (!input) return 4;
    const char* repeats_env = std::getenv("VDA_PROBE_REPEATS");
    const int repeats = repeats_env ? std::atoi(repeats_env) : 1;
    if (repeats < 1 || repeats > 1000) return 2;
    ncnn::Mat caches[8];
    if (argc == 6) {
        const auto tokens=frame_shape.tokens();
        const int channels[] = {192,192,384,384,64,64,64,64};
        for (int i = 0; i < 8; ++i) {
            caches[i].create(channels[i], 31, tokens[i]);
            std::ifstream file(std::string(argv[5]) + std::to_string(i) + ".f32", std::ios::binary);
            for (int c = 0; c < tokens[i]; ++c)
                file.read(reinterpret_cast<char*>(static_cast<float*>(caches[i].channel(c))),
                          channels[i]*31*sizeof(float));
            if (!file) return 7;
        }
    }
    std::array<ncnn::VkMat,9> gpu_inputs;
    if (resident) {
        ncnn::VkCompute upload(device);
        upload.record_upload(image,gpu_inputs[0],net.opt);
        if (argc==6) for (int i=0;i<8;++i)
            upload.record_upload(caches[i],gpu_inputs[i+1],net.opt);
        if (upload.submit_and_wait()) return 8;
    }
    const bool check_repeat=std::getenv("VDA_PROBE_CHECK_REPEAT")!=nullptr;
    const char* output_blob=std::getenv("VDA_PROBE_OUTPUT_BLOB");
    const int output_count=output_blob ? 1 : 9;
    if (output_blob && std::getenv("VDA_PROBE_FIXED_GRAPH")) return 2;
    std::array<std::vector<float>,9> first_results;
    int differing_iterations=0;
    for (int iteration = 0; iteration < repeats; ++iteration) {
    vda_drain_completed_buffers(net.opt);
    auto start = std::chrono::steady_clock::now();
    auto ex = net.create_extractor();
    std::array<ncnn::Mat,9> results;
    if (resident) {
        ncnn::VkCompute compute(device);
        std::array<ncnn::VkMat,9> outputs;
        // Preserve fixtures across extractors: the GPU input API can expose
        // storage to in-place graph operations. Clone on device per iteration.
        std::array<ncnn::VkMat,9> working_inputs;
        compute.record_clone(gpu_inputs[0],working_inputs[0],net.opt);
        if (ex.input("in0",working_inputs[0])) return 5;
        if (argc==6) for (int i=0;i<8;++i)
        {
            compute.record_clone(gpu_inputs[i+1],working_inputs[i+1],net.opt);
            if (ex.input(("in"+std::to_string(i+1)).c_str(),working_inputs[i+1])) return 7;
        }
        if (std::getenv("VDA_PROBE_FIXED_GRAPH")) {
            if (vda_fixed_graph(net,working_inputs,argc==6 ? 9 : 1,outputs,compute)) return 6;
        } else for (int i=0;i<output_count;++i)
            if (ex.extract(output_blob ? output_blob : ("out"+std::to_string(i)).c_str(),outputs[i],compute)) return 6;
        auto recorded=std::chrono::steady_clock::now();
        if (compute.submit_and_wait()) return 8;
        std::fprintf(stderr,"graph_record_ms=%.3f submit_wait_ms=%.3f\n",
            std::chrono::duration<double,std::milli>(recorded-start).count(),
            std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-recorded).count());
        std::fprintf(stderr,"resident_graph_ms=%.3f\n",
            std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());
        if (iteration!=repeats-1 && !check_repeat) continue;
        ncnn::VkCompute download(device);
        for (int i=0;i<output_count;++i) download.record_download(outputs[i],results[i],net.opt);
        if (download.submit_and_wait()) return 8;
    } else {
        if (ex.input("in0",image)) return 5;
        if (argc==6) for (int i=0;i<8;++i)
            if (ex.input(("in"+std::to_string(i+1)).c_str(),caches[i])) return 7;
        for (int i=0;i<output_count;++i)
            if (ex.extract(output_blob ? output_blob : ("out"+std::to_string(i)).c_str(),results[i])) return 6;
        std::fprintf(stderr,"host_inputs_all_outputs_ms=%.3f\n",
            std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());
    }
    bool differs=false;
    for (int i = 0; i < output_count; ++i) {
        ncnn::Mat out = results[i];
        std::string name = "out" + std::to_string(i);
        if (out.empty()) return 6;
        if (iteration != repeats-1 && !check_repeat) continue;
        if (out.elempack!=1) {
            ncnn::Mat unpacked;
            ncnn::convert_packing(out,unpacked,1);
            out=unpacked;
        }
        if (check_repeat) {
            std::vector<float> values;
            for (int c=0;c<out.c;++c) {
                const float* channel=out.channel(c);
                values.insert(values.end(),channel,channel+size_t(out.w)*out.h*out.d*out.elempack);
            }
            if (iteration==0) first_results[i]=values;
            else {
                if (first_results[i].size()!=values.size()) return 10;
                float maximum=0;
                for (size_t j=0;j<values.size();++j) {
                    if (!std::isfinite(values[j]) || !std::isfinite(first_results[i][j])) return 10;
                    maximum=std::max(maximum,std::abs(values[j]-first_results[i][j]));
                }
                if (maximum>0) {
                    differs=true;
                    std::fprintf(stderr,"repeat_difference iteration=%d output=%d max_abs=%g\n",iteration,i,double(maximum));
                }
            }
        }
        if (iteration!=repeats-1) continue;
        std::fprintf(stderr,"output %s dims=%d w=%d h=%d c=%d pack=%d elemsize=%zu\n",
            name.c_str(),out.dims,out.w,out.h,out.c,out.elempack,out.elemsize);
        std::ofstream output(std::string(argv[4]) + "-" + name + ".f32", std::ios::binary);
        // Mat channel storage can include padding; write only logical values.
        for (int c = 0; c < out.c; ++c) {
            const float* values = out.channel(c);
            output.write(reinterpret_cast<const char*>(values),
                         size_t(out.w) * out.h * out.d * out.elempack * sizeof(float));
        }
    }
    if (differs) ++differing_iterations;
    }
    if (check_repeat) {
        std::fprintf(stderr,"repeat_check iterations=%d differing_iterations=%d\n",repeats,differing_iterations);
        if (differing_iterations) return 10;
    }
}
