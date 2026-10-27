// Experimental fixed-shape VDA self-attention: one QKV projection, FP32
// softmax/attention accumulation, and the unchanged output projection.
#pragma once
#include "vda_settings.h"
#include <layer.h>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include "vda_layer_profiler.h"
#include "vda_gemm_factory.h"
#include "vda_tensorcore_attention_shader.h"

class VdaSpatialAttention : public ncnn::Layer {
public:
    VdaSpatialAttention() {
        one_blob_only=true; support_vulkan=true;
        support_packing=false; support_vulkan_packing=false;
        support_fp16_storage=true;
    }
    ~VdaSpatialAttention() override { delete qkv; delete projection; }
    int load_param(const ncnn::ParamDict& pd) override {
        embed=pd.get(0,0); heads=pd.get(1,0); tokens=pd.get(8,0);
        if (embed!=384 || heads!=6 || tokens<=0 || tokens>1024 ||
            pd.get(2,0)!=embed*embed || pd.get(3,embed)!=embed ||
            pd.get(4,embed)!=embed || pd.get(5,0) || pd.get(7,0) || pd.get(18,0)) return -1;
        scale=pd.get(6,1.f/std::sqrt(float(embed/heads)));
        qkv=make_gemm(embed*3); projection=make_gemm(embed);
        return qkv && projection ? 0 : -1;
    }
    int load_model(const ncnn::ModelBin& mb) override {
        ncnn::Mat weights[2] = {ncnn::Mat(3*embed*embed),ncnn::Mat(3*embed)};
        if (weights[0].empty() || weights[1].empty()) return -100;
        for (int i=0;i<3;++i) {
            auto w=mb.load(embed*embed,0); auto b=mb.load(embed,1);
            if (w.empty() || b.empty()) return -100;
            std::memcpy(static_cast<float*>(weights[0])+i*embed*embed,w.data,embed*embed*sizeof(float));
            std::memcpy(static_cast<float*>(weights[1])+i*embed,b.data,embed*sizeof(float));
        }
        ncnn::ModelBinFromMatArray joined(weights);
        int result=qkv->load_model(joined);
        if (result) return result;
        ncnn::Mat out_weights[2] = {mb.load(embed*embed,0),mb.load(embed,1)};
        if (out_weights[0].empty() || out_weights[1].empty()) return -100;
        return projection->load_model(ncnn::ModelBinFromMatArray(out_weights));
    }
    int create_pipeline(const ncnn::Option& opt) override {
        if (!opt.use_vulkan_compute || opt.use_fp16_arithmetic || opt.use_fp16_packed) return -1;
        bytes=opt.use_fp16_storage ? 2 : 4;
        tensorcore=vda_setting("VDA_PROBE_TC_ATTENTION")!=nullptr;
        if (!tensorcore) {
            if (const char* value=vda_setting("VDA_PROBE_SPATIAL_QUERIES")) {
                std::string count=value;
                if (count!="4" && count!="8" && count!="10" && count!="12" && count!="16") return -1;
                queries=std::atoi(value);
            }
            if (uint32_t(queries*64)>vkdev->info.max_workgroup_invocations()) return -1;
            subgroup_reductions=vda_setting("VDA_PROBE_SPATIAL_SUBGROUP")!=nullptr;
            packed_kv=vda_setting("VDA_PROBE_SPATIAL_PACKED64")!=nullptr;
            packed_query=vda_setting("VDA_PROBE_SPATIAL_PACKED_QUERY")!=nullptr;
            shuffle_scores=vda_setting("VDA_PROBE_SPATIAL_SHUFFLE_SCORES")!=nullptr;
            if (shuffle_scores && (!subgroup_reductions || !packed_kv ||
                !(vkdev->info.support_subgroup_ops()&VK_SUBGROUP_FEATURE_SHUFFLE_BIT))) return -1;
            if (packed_query && !packed_kv) return -1;
            if (packed_kv && bytes!=2) return -1;
            if (subgroup_reductions && (vkdev->info.subgroup_size()!=64 ||
                !(vkdev->info.support_subgroup_ops()&VK_SUBGROUP_FEATURE_ARITHMETIC_BIT))) return -1;
        }
        if (tensorcore && (bytes!=2 || !vkdev->info.support_VK_KHR_cooperative_matrix() ||
                          !vkdev->info.support_cooperative_matrix_16_16_16())) return -1;
        int result=qkv->create_pipeline(opt);
        if (!result) result=projection->create_pipeline(opt);
        if (result) return result;
        static const char* source=R"glsl(
#version 450
#if SUBGROUP_REDUCTIONS
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_arithmetic : require
#endif
#if SHUFFLE_SCORES
#extension GL_KHR_shader_subgroup_shuffle : require
#endif
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
#if PACKED_KV
layout(binding=0) readonly buffer QKV { uint qkv_packed[]; };
#else
layout(binding=0) readonly buffer QKV { sfp qkv[]; };
#endif
layout(binding=1) writeonly buffer Out { sfp output_data[]; };
layout(push_constant) uniform parameter { int tokens; int embed; int heads; float scale; } p;
#if PACKED_QUERY
shared uint query_packed[QUERY_COUNT*32];
#else
shared float query[QUERY_COUNT*64];
#endif
#if PACKED_KV
shared uint keys[KEY_TILE*KEY_STRIDE];
shared uint values[KEY_TILE*32];
#else
shared float keys[KEY_TILE*KEY_STRIDE];
shared float values[KEY_TILE*64];
#endif
shared float scores[QUERY_COUNT*KEY_TILE];
#if !SUBGROUP_REDUCTIONS
shared float reduction[QUERY_COUNT*KEY_TILE];
#endif
void main() {
    int tid=int(gl_LocalInvocationID.x);
#if SUBGROUP_REDUCTIONS
    int lane=int(gl_SubgroupInvocationID);
    int query_index=int(gl_SubgroupID);
#else
    int lane=tid%64;
    int query_index=tid/64;
#endif
    int row=int(gl_WorkGroupID.y)*QUERY_COUNT+query_index;
    int head=int(gl_WorkGroupID.z);
    int base=head*64;
#if PACKED_KV
    float current=row<p.tokens ? unpackHalf2x16(qkv_packed[(row*(3*p.embed)+base+lane)/2] >> ((lane%2)*16)).x : 0.0;
#else
    float current=row<p.tokens ? float(qkv[row*(3*p.embed)+base+lane]) : 0.0;
#endif
#if PACKED_QUERY
    if (lane<32) query_packed[query_index*32+lane]=row<p.tokens ? qkv_packed[(row*(3*p.embed)+base)/2+lane] : 0u;
#elif SUBGROUP_REDUCTIONS
    query[query_index*64+lane]=current;
#else
    query[tid]=current;
#endif
    barrier();
    float maximum=-3.402823466e+38;
    float denominator=0.0;
    float accumulator=0.0;
    for (int first=0;first<p.tokens;first+=KEY_TILE) {
        for (int i=tid;i<KEY_TILE*KV_COMPONENTS;i+=QUERY_COUNT*64) {
            int key=first+i/KV_COMPONENTS;
            int d=i%KV_COMPONENTS;
#if PACKED_KV
            keys[(i/KV_COMPONENTS)*KEY_STRIDE+d]=key<p.tokens ? qkv_packed[(key*(3*p.embed)+p.embed+base)/2+d] : 0u;
            values[i]=key<p.tokens ? qkv_packed[(key*(3*p.embed)+2*p.embed+base)/2+d] : 0u;
#else
            keys[(i/KV_COMPONENTS)*KEY_STRIDE+d]=key<p.tokens ? float(qkv[key*(3*p.embed)+p.embed+base+d]) : 0.0;
            values[i]=key<p.tokens ? float(qkv[key*(3*p.embed)+2*p.embed+base+d]) : 0.0;
#endif
        }
        barrier();
        float score=-3.402823466e+38;
        if (lane<KEY_TILE) {
            if (first+lane<p.tokens) {
                score=0.0;
#if PACKED_KV
                for (int d=0;d<32;++d) {
                    vec2 value=unpackHalf2x16(keys[lane*KEY_STRIDE+d]);
#if PACKED_QUERY
                    vec2 q=unpackHalf2x16(query_packed[query_index*32+d]);
                    score+=q.x*value.x;
                    score+=q.y*value.y;
#else
                    score+=query[query_index*64+d*2]*value.x;
                    score+=query[query_index*64+d*2+1]*value.y;
#endif
                }
#else
                for (int d=0;d<64;++d) score+=query[query_index*64+d]*keys[lane*KEY_STRIDE+d];
#endif
                score*=p.scale;
            }
            scores[query_index*KEY_TILE+lane]=score;
#if !SUBGROUP_REDUCTIONS
            reduction[query_index*KEY_TILE+lane]=score;
#endif
        }
#if SUBGROUP_REDUCTIONS
        float next_maximum=max(maximum,subgroupMax(score));
        float old_scale=exp(maximum-next_maximum);
        float weight=lane<KEY_TILE ? exp(score-next_maximum) : 0.0;
        float weight_sum=subgroupAdd(weight);
#if !SHUFFLE_SCORES
        if (lane<KEY_TILE) scores[query_index*KEY_TILE+lane]=weight;
        subgroupBarrier();
#endif
        denominator=denominator*old_scale+weight_sum;
#else
        barrier();
        for (int offset=KEY_TILE/2;offset>0;offset/=2) {
            if (lane<offset) reduction[query_index*KEY_TILE+lane]=max(
                reduction[query_index*KEY_TILE+lane],reduction[query_index*KEY_TILE+lane+offset]);
            barrier();
        }
        float next_maximum=max(maximum,reduction[query_index*KEY_TILE]);
        float old_scale=exp(maximum-next_maximum);
        barrier();
        if (lane<KEY_TILE) {
            float weight=exp(scores[query_index*KEY_TILE+lane]-next_maximum);
            scores[query_index*KEY_TILE+lane]=weight;
            reduction[query_index*KEY_TILE+lane]=weight;
        }
        barrier();
        for (int offset=KEY_TILE/2;offset>0;offset/=2) {
            if (lane<offset) reduction[query_index*KEY_TILE+lane]+=reduction[query_index*KEY_TILE+lane+offset];
            barrier();
        }
        denominator=denominator*old_scale+reduction[query_index*KEY_TILE];
#endif
        float sum=0.0;
        for (int key=0;key<KEY_TILE;++key) {
#if PACKED_KV
            float value=unpackHalf2x16(values[key*32+lane/2] >> ((lane%2)*16)).x;
#else
            float value=values[key*64+lane];
#endif
#if SHUFFLE_SCORES
            sum+=subgroupShuffle(weight,uint(key))*value;
#else
            sum+=scores[query_index*KEY_TILE+key]*value;
#endif
        }
        accumulator=accumulator*old_scale+sum;
        maximum=next_maximum;
        // Every thread must finish reading the tile before the next upload.
        barrier();
    }
    if (row<p.tokens) output_data[row*p.embed+base+lane]=sfp(accumulator/denominator);
}
)glsl";
        std::vector<uint32_t> spirv;
        std::string scalar_source=source;
        int key_tile=packed_kv ? 64 : 32;
        int components=packed_kv ? 32 : 64;
        int key_stride=components+(vda_setting("VDA_PROBE_SPATIAL_KEY_PAD") ? 1 : 0);
        if (!tensorcore && uint32_t(key_tile*(key_stride+components)*4+queries*(64+key_tile*2)*4)>vkdev->info.max_shared_memory_size()) return -1;
        scalar_source.insert(scalar_source.find('\n',scalar_source.find("#version"))+1,
            std::string("#define KEY_STRIDE ")+std::to_string(key_stride)+"\n#define QUERY_COUNT "+std::to_string(queries)+
            "\n#define SUBGROUP_REDUCTIONS "+(subgroup_reductions ? "1\n" : "0\n")+
            "#define PACKED_KV "+(packed_kv ? "1\n" : "0\n")+
            "#define PACKED_QUERY "+(packed_query ? "1\n" : "0\n")+
            "#define SHUFFLE_SCORES "+(shuffle_scores ? "1\n" : "0\n")+
            "#define KEY_TILE "+std::to_string(key_tile)+"\n#define KV_COMPONENTS "+std::to_string(components)+"\n");
        result=ncnn::compile_spirv_module(tensorcore ? vda_tensorcore_attention_source : scalar_source.c_str(),opt,spirv);
        if (result) return result;
        attention=new ncnn::Pipeline(vkdev);
        attention->set_local_size_xyz(tensorcore ? 128 : queries*64,1,1);
        if (tensorcore) attention->set_subgroup_size(32);
        else if (subgroup_reductions && vkdev->info.support_subgroup_size_control()) attention->set_subgroup_size(64);
        std::vector<ncnn::vk_specialization_type> specs(3);
        specs[0].i=tensorcore ? 128 : queries*64;specs[1].i=1;specs[2].i=1;
        return attention->create(spirv.data(),spirv.size()*sizeof(uint32_t),specs);
    }
    int upload_model(ncnn::VkTransfer& cmd,const ncnn::Option& opt) override {
        int result=qkv->upload_model(cmd,opt);
        return result ? result : projection->upload_model(cmd,opt);
    }
    int destroy_pipeline(const ncnn::Option& opt) override {
        if (qkv) qkv->destroy_pipeline(opt);
        if (projection) projection->destroy_pipeline(opt);
        delete attention; attention=nullptr;
        return 0;
    }
    int forward(const ncnn::VkMat& input,ncnn::VkMat& output,ncnn::VkCompute& cmd,
                const ncnn::Option& opt) const override {
        if (input.dims!=2 || input.w!=embed || input.h!=tokens ||
            input.elempack!=1 || input.elemsize!=bytes) return -1;
        const char* profile_frame=vda_setting("VDA_PROFILE_SPATIAL_FRAME");
        bool profile=profile_frame && vda_profile_current_frame==std::atoi(profile_frame);
        if (profile && (cmd.submit_and_wait() || cmd.reset())) return -1;
        auto started=std::chrono::steady_clock::now();
        auto stage=[&](const char* label) {
            if (!profile) return 0;
            if (cmd.submit_and_wait()) return -1;
            double elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
            std::fprintf(stderr,"spatial_stage_profile %s %s %.6f\n",name.c_str(),label,elapsed);
            int status=cmd.reset();started=std::chrono::steady_clock::now();return status;
        };
        ncnn::VkMat projected;
        int result=qkv->forward(input,projected,cmd,opt);
        if (result) return result;
        if (stage("qkv")) return -1;
        ncnn::VkMat unpacked;
        vkdev->convert_packing(projected,unpacked,1,cmd,opt);
        if (unpacked.dims!=2 || unpacked.w!=3*embed || unpacked.h!=tokens) return -1;
        ncnn::VkMat attended(embed,tokens,bytes,1,opt.blob_vkallocator);
        if (attended.empty()) return -100;
        std::vector<ncnn::vk_constant_type> constants(4);
        constants[0].i=tokens;constants[1].i=embed;constants[2].i=heads;constants[3].f=scale;
        ncnn::Mat dispatcher;dispatcher.w=tensorcore ? 128 : queries*64;
        dispatcher.h=tensorcore ? (tokens+15)/16 : (tokens+queries-1)/queries;dispatcher.c=heads;
        cmd.record_pipeline(attention,{unpacked,attended},{},constants,dispatcher);
        if (stage("attention")) return -1;
        result=projection->forward(attended,output,cmd,opt);
        return result ? result : stage("output");
    }
private:
    ncnn::Layer* make_gemm(int out_width) {
        auto* layer=vda_create_gemm();
        layer->vkdev=vkdev;
        ncnn::ParamDict pd;
        pd.set(3,1);pd.set(5,1);pd.set(6,1);
        pd.set(7,tokens);pd.set(8,out_width);pd.set(9,embed);
        pd.set(10,4);pd.set(12,1);
        if (layer->load_param(pd)) { delete layer; return nullptr; }
        return layer;
    }
    int embed=0,heads=0,tokens=0;
    int queries=4;
    float scale=0;
    size_t bytes=4;
    bool tensorcore=false;
    bool subgroup_reductions=false;
    bool packed_kv=false;
    bool packed_query=false;
    bool shuffle_scores=false;
    ncnn::Layer* qkv=nullptr;
    ncnn::Layer* projection=nullptr;
    ncnn::Pipeline* attention=nullptr;
};
inline ncnn::Layer* create_vda_spatial_attention(void*) { return new VdaSpatialAttention; }
