// Persistent Vulkan VDA runner. The validated probe kernels are shared verbatim;
// configuration is thread-local and independent of process environment variables.
#include <net.h>
#include <layer.h>
#include <modelbin.h>
#include <c_api.h>
#include "vda_finite.h"
#include "vulkan_processing.h"
#include <memory>
#include <stdexcept>
#include <cstring>
#include <cmath>
#include "../tools/vda_settings.h"
#include "../tools/vda_vulkan_matmul.h"
#include "../tools/vda_vulkan_projection.h"
#include "../tools/vda_vulkan_spatial_attention.h"
#include "../tools/vda_fused_temporal.h"
#include "../tools/vda_projected_cache.h"
#include "../tools/vda_fused_layernorm.h"
#include "../tools/vda_sequence_history.h"
#include "../tools/vda_fixed_graph.h"
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
static void require(bool ok,const char* error) {if (!ok) throw std::runtime_error(error);}
static void error_text(char* output,size_t capacity,const char* error) {
    if (output && capacity) {std::strncpy(output,error,capacity-1);output[capacity-1]=0;}
}
struct Runner {
    VdaSettings settings;
    VdaFrameShape shape;
    const ncnn::VulkanDevice* device=nullptr;
    // Reverse destruction order: nets/history/selection before allocators.
    std::unique_ptr<VdaDeferredAllocator> blob;
    std::unique_ptr<ncnn::VkBlobAllocator> workspace;
    std::unique_ptr<ncnn::VkStagingAllocator> staging;
    ncnn::Net step,cold;
    std::unique_ptr<ncnn::Pipeline> finite;
    std::unique_ptr<VdaSequenceHistory> history;
    std::vector<const VdaCachedProjection*> cached;
    ncnn::VkMat selection;
    std::unique_ptr<MeteorProcessing> processing;
    ncnn::VkMat prepared_image;
    ncnn::VkMat resident_depth;
    bool seeded=false;
    Runner(const char* directory,int gpu,int width,int height):shape{width,height} {
        require(ncnn_version_number()==NCNN_VERSION_NUMBER,"VDA Vulkan runtime/ncnn version mismatch");
        require(shape.valid() && ((width==518 && height==294)||(width==392 && height==224)),"Unsupported VDA dimensions");
        require(ncnn::create_gpu_instance()==0 && gpu>=0 && gpu<ncnn::get_gpu_count(),"Vulkan GPU unavailable");
        device=ncnn::get_gpu_device(gpu);
        require(device->info.type()!=3 && device->info.support_fp16_storage(),"VDA needs a hardware Vulkan GPU with FP16 storage");
        settings={{"VDA_PROBE_WIDTH",std::to_string(width)},{"VDA_PROBE_HEIGHT",std::to_string(height)},
                  {"VDA_PROBE_FUSED_LAYERNORM","1"}};
        bool tensorcore=device->info.vendor_id()==0x10de && device->info.support_VK_KHR_cooperative_matrix() && device->info.support_cooperative_matrix_16_16_16();
        if (tensorcore) {
            settings["VDA_PROBE_TENSORCORE"]="1";settings["VDA_PROBE_TC_ATTENTION"]="1";
            settings["VDA_PROBE_TC_TRANSPOSE_WEIGHTS"]="1";settings["VDA_PROBE_TC_TILE_SHAPE"]="32x32";
        } else {
            settings["VDA_PROBE_SPATIAL_KEY_PAD"]="1";settings["VDA_PROBE_SPATIAL_PACKED64"]="1";
            settings["VDA_PROBE_SPATIAL_QUERIES"]=device->info.max_workgroup_invocations()>=768 ? "12" : device->info.max_workgroup_invocations()>=512 ? "8" : "4";
            if (device->info.subgroup_size()==64 && (device->info.support_subgroup_ops()&VK_SUBGROUP_FEATURE_ARITHMETIC_BIT)) settings["VDA_PROBE_SPATIAL_SUBGROUP"]="1";
        }
        VdaSettingsScope scope(settings);
        blob.reset(new VdaDeferredAllocator(device));workspace.reset(new ncnn::VkBlobAllocator(device));staging.reset(new ncnn::VkStagingAllocator(device));
        step.register_custom_layer("VdaTemporalMatMul",create_vda_temporal_matmul);
        step.register_custom_layer("VdaTemporalProjection",create_vda_temporal_projection);
        step.register_custom_layer("VdaSpatialAttention",create_vda_spatial_attention);
        step.register_custom_layer("VdaFusedTemporal",create_vda_fused_temporal);
        step.register_custom_layer("VdaPositionedQuery",create_vda_positioned_query);
        step.register_custom_layer("VdaCachedProjection",create_vda_cached_projection);
        step.register_custom_layer("LayerNorm",create_vda_fused_layernorm);
        if (tensorcore) step.register_custom_layer("Gemm",create_vda_tensorcore_gemm);
        auto& opt=step.opt;
        opt.use_vulkan_compute=true;opt.use_fp16_storage=true;opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;
        opt.use_packing_layout=true;opt.use_cooperative_matrix=false;
        if (!tensorcore && device->info.subgroup_size()==64) opt.use_shader_local_memory=false;
        opt.num_threads=4;opt.blob_vkallocator=blob.get();opt.workspace_vkallocator=workspace.get();opt.staging_vkallocator=staging.get();
        step.set_vulkan_device(device);cold.opt=opt;cold.opt.use_fp16_storage=false;cold.set_vulkan_device(device);
        std::string dir(directory);
        require(step.load_param((dir+"/step.ncnn.param").c_str())==0 && step.load_model((dir+"/step.ncnn.bin").c_str())==0,"Cannot load VDA step graph");
        require(cold.load_param((dir+"/cold.ncnn.param").c_str())==0 && cold.load_model((dir+"/cold.ncnn.bin").c_str())==0,"Cannot load VDA cold graph");
        for (auto* l:step.layers()) {
            require(l->support_vulkan,"VDA step contains CPU-only operation");
            if (auto* p=dynamic_cast<VdaCachedProjection*>(l)) cached.push_back(p);
        }
        for (auto* l:cold.layers()) require(l->support_vulkan,"VDA cold contains CPU-only operation");
        require(cached.size()==16,"Invalid VDA projected-cache graph");
        history.reset(new VdaSequenceHistory(device,opt,shape));require(history->initialize(false)==0,"Cannot allocate VDA history");
        finite=vda_finite_pipeline(device,opt);
    }
    void infer(const float* input,float* depth,bool reset,const ncnn::VkMat* prepared_input=nullptr,float sigma=0,bool resident=false) {
        VdaSettingsScope scope(settings);
        struct Guard {~Guard(){vda_projected_context={};}} guard;
        vda_drain_completed_buffers(step.opt);
        bool first=reset || !seeded;int slot=first ? 0 : history->free_slot();require(slot>=0,"No VDA history slot");
        auto& net=first ? cold : step;
        std::array<ncnn::VkMat,9> inputs,outputs;
        ncnn::Mat image;
        ncnn::VkCompute prepare(device);
        if(prepared_input)device->convert_packing(*prepared_input,inputs[0],1,first ? 1 : 2,prepare,net.opt);
        else {image.create(shape.width,shape.height,3);std::memcpy(image.data,input,size_t(shape.width)*shape.height*3*sizeof(float));prepare.record_upload(image,inputs[0],net.opt);}
        if (!first) {
            ncnn::Mat selected(32);auto slots=history->selection();
            for (int i=0;i<31;++i) {
                require(slots[i]!=slot,"Invalid VDA history selection");
                static_cast<float*>(selected.data)[i]=float(slots[i]);vda_projected_context.slots[i]=slots[i];
            }
            static_cast<float*>(selected.data)[31]=float(slot);vda_projected_context.slots[31]=slot;
            prepare.record_clone(selected,selection,step.opt);vda_projected_context.slot=slot;vda_projected_context.selection=&selection;
        }
        require(prepare.submit_and_wait()==0,"VDA upload failed");
        ncnn::VkCompute compute(device);require(vda_fixed_graph(net,inputs,1,outputs,compute)==0 && compute.submit_and_wait()==0,"VDA inference failed");
        std::array<ncnn::Mat,9> cpu;
        if (first) {
            ncnn::VkCompute download(device);for(int i=resident ? 1 : 0;i<9;++i) download.record_download(outputs[i],cpu[i],cold.opt);
            require(download.submit_and_wait()==0,"VDA cold readback failed");
        }
        ncnn::VkCompute store(device);std::array<ncnn::VkMat,9> stored=outputs;
        if (first) {
            for (int i=1;i<9;++i) {
                ncnn::Mat unpacked=cpu[i],half;
                if (unpacked.elempack!=1) {ncnn::Mat tmp;ncnn::convert_packing(unpacked,tmp,1);unpacked=tmp;}
                ncnn::cast_float32_to_float16(unpacked,half);store.record_clone(half,stored[i],step.opt);
            }
            for (const auto* projection:cached) {projection->reset_history();require(projection->prime(stored[projection->state_index()+1],slot,store,step.opt)==0,"VDA history seed failed");}
        }
        ncnn::Mat zero(1);*static_cast<unsigned*>(zero.data)=0;
        ncnn::Option raw=step.opt;raw.use_fp16_storage=false;raw.use_fp16_packed=false;raw.use_packing_layout=false;
        ncnn::VkMat flag;store.record_clone(zero,flag,raw);
        for (int i=1;i<9;++i) {
            std::vector<ncnn::vk_constant_type> constants(1);constants[0].i=stored[i].total()*stored[i].elempack/2;
            ncnn::Mat dispatcher;dispatcher.w=(constants[0].i+127)/128*128;dispatcher.h=dispatcher.c=1;
            store.record_pipeline(finite.get(),{stored[i],flag},{},constants,dispatcher);
        }
        ncnn::Mat bad;store.record_clone(flag,bad,raw);
        require(store.submit_and_wait()==0,"VDA history store failed");
        require(*static_cast<unsigned*>(bad.data)==0,"Nonfinite VDA temporal state");
        if (first) history->seed();else history->push(slot);
        if(resident) {
            require(bool(processing),"VDA processing unavailable");resident_depth=processing->soften(outputs[0],sigma);seeded=true;return;
        }
        if(sigma>0) {
            require(bool(processing),"VDA processing unavailable");auto softened=processing->soften(outputs[0],sigma);
            ncnn::VkCompute download(device);download.record_clone(softened,cpu[0],processing->opt);require(download.submit_and_wait()==0,"VDA softened depth readback failed");
        } else if (!first) {ncnn::VkCompute download(device);download.record_download(outputs[0],cpu[0],step.opt);require(download.submit_and_wait()==0,"VDA depth readback failed");}
        ncnn::Mat result=cpu[0];
        if (result.elempack!=1) {ncnn::Mat unpacked;ncnn::convert_packing(result,unpacked,1);result=unpacked;}
        require(result.elembits()==32 && result.total()==size_t(shape.width)*shape.height,"Invalid VDA depth shape");
        auto* values=static_cast<const float*>(result.data);
        for (int i=0;i<shape.width*shape.height;++i) require(std::isfinite(values[i]),"Nonfinite VDA depth");
        std::memcpy(depth,values,size_t(shape.width)*shape.height*sizeof(float));seeded=true;
    }
};
API unsigned meteor_vda_abi() {return 1;}
API int meteor_vda_supported(int gpu) {
    if (ncnn::create_gpu_instance()!=0 || gpu<0 || gpu>=ncnn::get_gpu_count()) return 0;
    const auto& info=ncnn::get_gpu_device(gpu)->info;
    return info.type()!=3 && info.support_fp16_storage() && info.max_workgroup_invocations()>=256 && info.max_shared_memory_size()>=24576;
}
API void* meteor_vda_create(const char* path,int gpu,int width,int height,char* error,size_t capacity) {
    try {return new Runner(path,gpu,width,height);}catch(const std::exception& e){error_text(error,capacity,e.what());return nullptr;}catch(...){error_text(error,capacity,"VDA initialization failed");return nullptr;}
}
API int meteor_vda_infer(void* runner,const float* rgb,float* depth,int reset,char* error,size_t capacity) {
    if (!runner || !rgb || !depth) {error_text(error,capacity,"Invalid VDA arguments");return -1;}
    try {static_cast<Runner*>(runner)->infer(rgb,depth,reset!=0);return 0;}catch(const std::exception& e){static_cast<Runner*>(runner)->seeded=false;error_text(error,capacity,e.what());return -1;}catch(...){static_cast<Runner*>(runner)->seeded=false;error_text(error,capacity,"VDA inference failed");return -1;}
}
API void meteor_vda_destroy(void* runner) {delete static_cast<Runner*>(runner);}
API int meteor_vda_prepare(void* handle,const void* source,int sw,int sh,int planar,float* thumbnail,char* error,size_t capacity) {
    if(!handle||!source||!thumbnail||sw<1||sh<1||sw>8192||sh>8192){error_text(error,capacity,"Invalid VDA preparation input");return -1;}
    try {
        auto* runner=static_cast<Runner*>(handle);
        if(!runner->processing)runner->processing=std::make_unique<MeteorProcessing>(runner->device->info.device_index(),runner->shape.width,runner->shape.height);
        runner->prepared_image=runner->processing->prepare(source,sw,sh,planar!=0,thumbnail);return 0;
    }catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API int meteor_vda_infer_prepared(void* handle,float* output,int reset,float sigma,char* error,size_t capacity) {
    if(!handle||!output||!std::isfinite(sigma)||sigma<0||sigma>4){error_text(error,capacity,"Invalid prepared VDA input");return -1;}
    try {auto* runner=static_cast<Runner*>(handle);require(!runner->prepared_image.empty(),"No prepared VDA frame");runner->infer(nullptr,output,reset!=0,&runner->prepared_image,sigma);return 0;}catch(const std::exception& e){static_cast<Runner*>(handle)->seeded=false;error_text(error,capacity,e.what());return -1;}
}
API int meteor_vda_infer_resident(void* handle,void** output,int reset,float sigma,char* error,size_t capacity) {
    if(!handle||!output||!std::isfinite(sigma)||sigma<0||sigma>4){error_text(error,capacity,"Invalid resident VDA input");return -1;}
    *output=nullptr;
    try {auto* p=static_cast<Runner*>(handle);require(!p->prepared_image.empty(),"No prepared VDA frame");p->infer(nullptr,nullptr,reset!=0,&p->prepared_image,sigma,true);*output=new MeteorResidentDepth(*p->processing,p->resident_depth);return 0;}catch(const std::exception& e){static_cast<Runner*>(handle)->seeded=false;error_text(error,capacity,e.what());return -1;}
}
API unsigned meteor_processing_abi() {return 2;}
API void* meteor_processing_create(int gpu,int width,int height,char* error,size_t capacity) {
    try {return new MeteorProcessing(gpu,width,height);}catch(const std::exception& e){error_text(error,capacity,e.what());return nullptr;}
}
API int meteor_processing_post(void* runner,const float* raw,const unsigned char* rgb,int gw,int gh,int first,float da,float ra,int align,int cleanup,unsigned char* output,char* error,size_t capacity) {
    if(!runner||!raw||!output||(align&&(!rgb||gw<1||gh<1||gw>8192||gh>8192))) {error_text(error,capacity,"Invalid processing input");return -1;}
    try {static_cast<MeteorProcessing*>(runner)->process(raw,rgb,gw,gh,first,da,ra,align,cleanup,output);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API void meteor_processing_destroy(void* runner) {delete static_cast<MeteorProcessing*>(runner);}
API int meteor_processing_edge(void* runner,ncnn_net_t net,const unsigned char* rgb,void** output,char* error,size_t capacity) {
    if(!runner||!net||!net->pthis||!rgb||!output){error_text(error,capacity,"Invalid resident EdgePad input");return -1;}*output=nullptr;
    try {
        auto* p=static_cast<MeteorProcessing*>(runner);auto* model=static_cast<ncnn::Net*>(net->pthis);
        require(model->opt.use_vulkan_compute&&model->vulkan_device()==p->device,"Resident depth model/device mismatch");
        ncnn::Mat image(p->width,p->height,3);require(!image.empty(),"Cannot allocate EdgePad input");
        for(int c=0;c<3;c++){float* channel=image.channel(c);for(int i=0;i<p->width*p->height;i++)channel[i]=float(rgb[i*3+c])/255.f;}
        // The C net's options have no extractor allocators. Supply our owned
        // allocators before recording upload, just as the extractor does.
        auto upload_opt=model->opt;upload_opt.blob_vkallocator=p->allocator.get();upload_opt.workspace_vkallocator=p->allocator.get();upload_opt.staging_vkallocator=p->staging.get();
        ncnn::VkCompute cmd(p->device);ncnn::VkMat input,depth;cmd.record_upload(image,input,upload_opt);
        auto ex=model->create_extractor();ex.set_blob_vkallocator(p->allocator.get());ex.set_workspace_vkallocator(p->allocator.get());ex.set_staging_vkallocator(p->staging.get());
        require(ex.input("in0",input)==0&&ex.extract("out0",depth,cmd)==0&&cmd.submit_and_wait()==0,"Resident EdgePad inference failed");
        require(depth.w==p->width&&depth.h==p->height&&depth.c*depth.elempack==1,"Invalid resident EdgePad shape");
        *output=new MeteorResidentDepth(*p,depth);return 0;
    }catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API void meteor_processing_depth_destroy(void* depth) {delete static_cast<MeteorResidentDepth*>(depth);}
API int meteor_processing_depth_download(void* depth,float* output,char* error,size_t capacity) {
    if(!depth||!output){error_text(error,capacity,"Invalid resident readback");return -1;}
    try {auto* d=static_cast<MeteorResidentDepth*>(depth);ncnn::VkStagingAllocator staging(d->device);ncnn::Option opt;opt.use_fp16_storage=false;opt.use_fp16_packed=false;opt.blob_vkallocator=d->allocator.get();opt.staging_vkallocator=&staging;ncnn::VkCompute cmd(d->device);ncnn::Mat cpu;cmd.record_clone(d->data,cpu,opt);require(cmd.submit_and_wait()==0,"Resident readback failed");std::memcpy(output,cpu.data,size_t(d->width)*d->height*4);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API int meteor_processing_post_resident(void* runner,void* depth,const unsigned char* rgb,int gw,int gh,int first,float da,float ra,int align,int cleanup,unsigned char* output,char* error,size_t capacity) {
    if(!runner||!depth||!output||(align&&(!rgb||gw<1||gh<1||gw>8192||gh>8192))){error_text(error,capacity,"Invalid resident postprocessing input");return -1;}
    try {auto* p=static_cast<MeteorProcessing*>(runner);auto* d=static_cast<MeteorResidentDepth*>(depth);require(p->device==d->device&&p->width==d->width&&p->height==d->height,"Resident depth processor/device mismatch");ncnn::VkCompute cmd(p->device);p->process_device(d->data,rgb,gw,gh,first,da,ra,align,cleanup,output,cmd);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API int meteor_processing_nv12(void* runner,const unsigned char* source,int sw,int sh,int matrix,int full,unsigned char* output,char* error,size_t capacity) {
    if(!runner||!source||!output||sw<2||sh<2||sw>8192||sh>8192||sw%2||sh%2){error_text(error,capacity,"Invalid NV12 processing input");return -1;}
    try {static_cast<MeteorProcessing*>(runner)->nv12(source,sw,sh,matrix,full!=0,output);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
// Test/reference ABI: inspect prepared tensors and softening without a model.
API int meteor_processing_depth_upload(void* runner,const float* source,void** output,char* error,size_t capacity) {
    if(!runner||!source||!output){error_text(error,capacity,"Invalid reference depth upload");return -1;}*output=nullptr;
    try {auto* p=static_cast<MeteorProcessing*>(runner);ncnn::Mat host(p->width,p->height);require(!host.empty(),"Cannot allocate reference depth");std::memcpy(host.data,source,size_t(p->width)*p->height*4);ncnn::VkCompute cmd(p->device);ncnn::VkMat raw;cmd.record_clone(host,raw,p->opt);require(cmd.submit_and_wait()==0,"Cannot upload reference depth");*output=new MeteorResidentDepth(*p,raw);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API int meteor_processing_prepare(void* runner,const void* source,int sw,int sh,int planar,float* output,char* error,size_t capacity) {
    if(!runner||!source||!output||sw<1||sh<1||sw>8192||sh>8192){error_text(error,capacity,"Invalid tensor processing input");return -1;}
    try {auto* p=static_cast<MeteorProcessing*>(runner);float thumb[432];auto tensor=p->prepare(source,sw,sh,planar!=0,thumb);ncnn::VkCompute cmd(p->device);ncnn::Mat cpu;cmd.record_clone(tensor,cpu,p->opt);require(cmd.submit_and_wait()==0,"Cannot read prepared tensor");for(int c=0;c<3;c++)std::memcpy(output+size_t(c)*p->width*p->height,cpu.channel(c),size_t(p->width)*p->height*4);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
API int meteor_processing_blur(void* runner,const float* source,float sigma,float* output,char* error,size_t capacity) {
    if(!runner||!source||!output||!std::isfinite(sigma)||sigma<0||sigma>4){error_text(error,capacity,"Invalid blur input");return -1;}
    try {auto* p=static_cast<MeteorProcessing*>(runner);ncnn::VkCompute up(p->device);ncnn::Mat cpu(p->width,p->height);std::memcpy(cpu.data,source,size_t(p->width)*p->height*4);ncnn::VkMat raw;up.record_clone(cpu,raw,p->opt);require(up.submit_and_wait()==0,"Cannot upload depth");auto blurred=p->soften(raw,sigma);ncnn::VkCompute down(p->device);down.record_clone(blurred,cpu,p->opt);require(down.submit_and_wait()==0,"Cannot read blurred depth");std::memcpy(output,cpu.data,size_t(p->width)*p->height*4);return 0;}catch(const std::exception& e){error_text(error,capacity,e.what());return -1;}
}
