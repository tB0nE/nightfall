#pragma once
// 16 queries × 64 keys per block; stable online softmax and FP32 accumulator.
static const char* vda_tensorcore_attention_source=R"glsl(
#version 450
#extension GL_EXT_shader_explicit_arithmetic_types_float16 : require
#extension GL_KHR_cooperative_matrix : require
#extension GL_KHR_memory_scope_semantics : require
#extension GL_KHR_shader_subgroup_basic : require
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer QKV { float16_t qkv[]; };
layout(binding=1) writeonly buffer Out { float16_t output_data[]; };
layout(push_constant) uniform parameter { int tokens;int embed;int heads;float scale; } p;
shared float16_t query[1024];
shared float16_t keys[4096];
shared float16_t values[4096];
shared float scores[1024];
shared float16_t weights[1024];
shared float accumulator[1024];
shared float reduction[128];
shared float maxima[16];
shared float denominators[16];
void main() {
    int tid=int(gl_LocalInvocationID.x);
    int warp=int(gl_SubgroupID);
    int first_row=int(gl_WorkGroupID.y)*16;
    int head=int(gl_WorkGroupID.z);
    int base=head*64;
    int row=tid/8;
    int lane=tid%8;
    for (int i=tid;i<1024;i+=128) {
        int source_row=first_row+i/64;
        query[i]=source_row<p.tokens ? qkv[source_row*(3*p.embed)+base+i%64] : float16_t(0.0);
        accumulator[i]=0.0;
    }
    if (tid<16) { maxima[tid]=-3.402823466e+38;denominators[tid]=0.0; }
    barrier();
    for (int first=0;first<p.tokens;first+=64) {
        for (int i=tid;i<4096;i+=128) {
            int key=first+i/64;
            keys[i]=key<p.tokens ? qkv[key*(3*p.embed)+p.embed+base+i%64] : float16_t(0.0);
            values[i]=key<p.tokens ? qkv[key*(3*p.embed)+2*p.embed+base+i%64] : float16_t(0.0);
        }
        barrier();
        coopmat<float,gl_ScopeSubgroup,16,16,gl_MatrixUseAccumulator> qk=
            coopmat<float,gl_ScopeSubgroup,16,16,gl_MatrixUseAccumulator>(0.0);
        for (int d=0;d<64;d+=16) {
            coopmat<float16_t,gl_ScopeSubgroup,16,16,gl_MatrixUseA> q;
            coopmat<float16_t,gl_ScopeSubgroup,16,16,gl_MatrixUseB> k;
            coopMatLoad(q,query,d,64,gl_CooperativeMatrixLayoutRowMajor);
            coopMatLoad(k,keys,warp*16*64+d,64,gl_CooperativeMatrixLayoutColumnMajor);
            qk=coopMatMulAdd(q,k,qk);
        }
        coopMatStore(qk,scores,warp*16,64,gl_CooperativeMatrixLayoutRowMajor);
        barrier();
        float maximum=-3.402823466e+38;
        for (int key=lane;key<64;key+=8) {
            float score=first+key<p.tokens ? scores[row*64+key]*p.scale : -3.402823466e+38;
            scores[row*64+key]=score;maximum=max(maximum,score);
        }
        reduction[tid]=maximum;
        barrier();
        for (int offset=4;offset>0;offset/=2) {
            if (lane<offset) reduction[row*8+lane]=max(reduction[row*8+lane],reduction[row*8+lane+offset]);
            barrier();
        }
        float next_maximum=max(maxima[row],reduction[row*8]);
        float old_scale=exp(maxima[row]-next_maximum);
        float old_denominator=denominators[row];
        barrier();
        float total=0.0;
        for (int key=lane;key<64;key+=8) {
            float weight=exp(scores[row*64+key]-next_maximum);
            weights[row*64+key]=float16_t(weight);total+=weight;
            accumulator[row*64+key]*=old_scale;
        }
        reduction[tid]=total;
        barrier();
        for (int offset=4;offset>0;offset/=2) {
            if (lane<offset) reduction[row*8+lane]+=reduction[row*8+lane+offset];
            barrier();
        }
        if (lane==0) { maxima[row]=next_maximum;denominators[row]=old_denominator*old_scale+reduction[row*8]; }
        barrier();
        coopmat<float,gl_ScopeSubgroup,16,16,gl_MatrixUseAccumulator> pv;
        coopMatLoad(pv,accumulator,warp*16,64,gl_CooperativeMatrixLayoutRowMajor);
        for (int key=0;key<64;key+=16) {
            coopmat<float16_t,gl_ScopeSubgroup,16,16,gl_MatrixUseA> a;
            coopmat<float16_t,gl_ScopeSubgroup,16,16,gl_MatrixUseB> b;
            coopMatLoad(a,weights,key,64,gl_CooperativeMatrixLayoutRowMajor);
            coopMatLoad(b,values,key*64+warp*16,64,gl_CooperativeMatrixLayoutRowMajor);
            pv=coopMatMulAdd(a,b,pv);
        }
        coopMatStore(pv,accumulator,warp*16,64,gl_CooperativeMatrixLayoutRowMajor);
        barrier();
    }
    for (int feature=lane;feature<64;feature+=8)
        if (first_row+row<p.tokens)
            output_data[(first_row+row)*p.embed+base+feature]=
                float16_t(accumulator[row*64+feature]/denominators[row]);
}
)glsl";
