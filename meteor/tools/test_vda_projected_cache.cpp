// Identity-weight oracle: positional index, current-frame projection, slot
// replacement and reset must be exact even with padded channel storage.
#include "vda_projected_cache.h"
#include <cmath>
#include <cstdio>

static float half(float x) { return ncnn::float16_to_float32(ncnn::float32_to_float16(x)); }
static float raw_value(int stamp,int token,int channel) { return half(stamp/16.f+token/8.f+channel/64.f); }
static float pos_value(int time,int channel) { return half(time/8.f+channel/32.f); }

static bool check(const ncnn::VulkanDevice* device,int width) {
    constexpr int tokens=3;
    ncnn::VkBlobAllocator allocator(device);ncnn::VkStagingAllocator staging(device);
    ncnn::Option opt;opt.use_vulkan_compute=true;opt.use_fp16_storage=true;
    opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;opt.use_cooperative_matrix=false;
    opt.blob_vkallocator=&allocator;opt.workspace_vkallocator=&allocator;opt.staging_vkallocator=&staging;
    VdaCachedProjection cached;VdaPositionedQuery query;
    cached.vkdev=device;query.vkdev=device;
    ncnn::ParamDict pd;pd.set(0,width);pd.set(1,0);pd.set(2,width*width);pd.set(3,tokens);pd.set(4,0);
    ncnn::Mat weight(width*width);weight.fill(0.f);
    for (int i=0;i<width;++i) static_cast<float*>(weight.data)[i*width+i]=1.f;
    if (cached.load_param(pd) || query.load_param(pd) ||
        cached.load_model(ncnn::ModelBinFromMatArray(&weight)) ||
        query.load_model(ncnn::ModelBinFromMatArray(&weight)) ||
        cached.create_pipeline(opt) || query.create_pipeline(opt)) return false;
    ncnn::VkTransfer weights(device);
    if (cached.upload_model(weights,opt) || query.upload_model(weights,opt) || weights.submit_and_wait()) return false;
    ncnn::Mat positions(width,32,1),half_positions;
    for (int t=0;t<32;++t) for (int c=0;c<width;++c)
        static_cast<float*>(positions.data)[t*width+c]=pos_value(t,c);
    ncnn::cast_float32_to_float16(positions,half_positions);
    ncnn::VkMat gpu_positions;
    ncnn::VkCompute prepare(device);prepare.record_clone(half_positions,gpu_positions,opt);
    if (prepare.submit_and_wait()) return false;
    std::array<int,44> stamps{};
    auto state = [&](int stamp,ncnn::VkCompute& cmd) {
        ncnn::Mat cpu(width,1,tokens),storage;
        for (int t=0;t<tokens;++t) for (int c=0;c<width;++c)
            cpu.channel(t).row(0)[c]=raw_value(stamp,t,c);
        ncnn::cast_float32_to_float16(cpu,storage);
        ncnn::VkMat gpu;cmd.record_clone(storage,gpu,opt);return gpu;
    };
    auto prime = [&](int slot,int stamp) {
        ncnn::VkCompute cmd(device);auto input=state(stamp,cmd);
        stamps[slot]=stamp;
        return cached.prime(input,slot,cmd,opt)==0 && cmd.submit_and_wait()==0;
    };
    for (int slot : {0,1,4,43}) if (!prime(slot,slot+3)) return false;
    bool okay=true;double worst=0;
    for (int phase=0;phase<3;++phase) {
        if (phase==1 && !prime(4,67)) return false;
        if (phase==2) { cached.reset_history();if (!prime(0,99)) return false; }
        int slot=phase==0 ? 2 : phase==1 ? 3 : 1;
        int stamp=phase==2 ? 100 : 31+phase;
        stamps[slot]=stamp;
        ncnn::Mat selection(32);int previous_slots[]={0,1,4,43,2};
        for (int time=0;time<31;++time) {
            int chosen=phase==2 ? 0 : previous_slots[time%(phase==0 ? 4 : 5)];
            vda_projected_context.slots[time]=chosen;
            static_cast<float*>(selection.data)[time]=float(chosen);
        }
        vda_projected_context.slots[31]=slot;
        static_cast<float*>(selection.data)[31]=float(slot);
        vda_projected_context.slot=slot;
        ncnn::VkMat indices;ncnn::VkCompute cmd(device);cmd.record_clone(selection,indices,opt);
        vda_projected_context.selection=&indices;
        auto current=state(stamp,cmd);
        std::vector<ncnn::VkMat> inputs={current,gpu_positions},projected(1),positioned(1);
        if (cached.forward(inputs,projected,cmd,opt) || query.forward(inputs,positioned,cmd,opt)) return false;
        ncnn::Mat actual,actual_query;cmd.record_download(projected[0],actual,opt);cmd.record_download(positioned[0],actual_query,opt);
        if (cmd.submit_and_wait()) return false;
        if (actual.elempack!=1) { ncnn::Mat unpacked;ncnn::convert_packing(actual,unpacked,1);actual=unpacked; }
        if (actual_query.elempack!=1) { ncnn::Mat unpacked;ncnn::convert_packing(actual_query,unpacked,1);actual_query=unpacked; }
        for (int token=0;token<tokens;++token) for (int time=0;time<32;++time) for (int c=0;c<width;++c) {
            float expected=half(raw_value(stamps[vda_projected_context.slots[time]],token,c)+pos_value(time,c));
            float value=actual.row(token*32+time)[c];
            if (!std::isfinite(value)) okay=false;
            worst=std::max(worst,double(std::abs(expected-value)));
        }
        for (int token=0;token<tokens;++token) for (int c=0;c<width;++c) {
            float expected=half(raw_value(stamp,token,c)+pos_value(31,c));
            float value=actual_query.row(token)[c];
            if (!std::isfinite(value)) okay=false;
            worst=std::max(worst,double(std::abs(expected-value)));
        }
        if (phase==2) {
            vda_projected_context.slots[0]=43; // old session slot is invalid after reset
            ncnn::VkCompute invalid(device);
            if (cached.forward(inputs,projected,invalid,opt)==0) okay=false;
        }
        vda_projected_context.selection=nullptr;
    }
    cached.destroy_pipeline(opt);query.destroy_pipeline(opt);
    okay=okay && worst==0;
    std::printf("width=%d slot_reuse_reset_position_query max_error=%.9g %s\n",width,worst,okay ? "PASS" : "FAIL");
    return okay;
}
int main(int argc,char** argv) {
    if (argc!=2) return 2;
    ncnn::create_gpu_instance();int index=std::atoi(argv[1]);
    if (index<0 || index>=ncnn::get_gpu_count()) return 2;
    bool okay=true;
    for (int width : {7,64}) okay=check(ncnn::get_gpu_device(index),width) && okay;
    vda_projected_context={};return okay ? 0 : 1;
}
