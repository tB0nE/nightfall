/* SPDX-License-Identifier: MIT
 * Bounded parser for the reference-count override bit in an AVC slice header.
 * Counts in VA slice parameters are PPS defaults ONLY when override is false.
 */
#ifndef NF_H264_REFERENCE_DEFAULTS_H
#define NF_H264_REFERENCE_DEFAULTS_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
struct nf_avc_config {
    unsigned frame_num_bits, poc_type, poc_bits;
    bool separate_plane, frame_only, delta_always_zero, bottom_poc, redundant;
};
struct nf_avc_bits { const uint8_t *data; size_t size, pos; bool failed; };
static unsigned nf_avc_read(struct nf_avc_bits *b, unsigned count) {
    if (count>32 || b->pos>b->size*8 || count>b->size*8-b->pos) { b->failed=true; return 0; }
    unsigned value=0;
    for (unsigned i=0;i<count;i++,b->pos++) value=(value<<1)|((b->data[b->pos/8]>>(7-b->pos%8))&1);
    return value;
}
static unsigned nf_avc_ue(struct nf_avc_bits *b) {
    unsigned zeros=0;
    while (!b->failed && !nf_avc_read(b,1)) {
        if (++zeros>=31) { b->failed=true; return 0; }
    }
    unsigned suffix=nf_avc_read(b,zeros);
    return b->failed?0:((1U<<zeros)-1)+suffix;
}
/* Returns true only for a valid inter slice using PPS defaults (no override).
 * Unsupported/truncated headers return false and never invent reference counts.
 */
static bool nf_avc_uses_defaults(const uint8_t *nal, size_t size,
                                 const struct nf_avc_config *cfg, bool *b_slice) {
    if (!nal || size<2 || cfg->frame_num_bits<4 || cfg->frame_num_bits>16 ||
        cfg->poc_type>2 || (cfg->poc_type==0 && (cfg->poc_bits<4 || cfg->poc_bits>16))) return false;
    unsigned kind=nal[0]&31;
    if (kind!=1 && kind!=5) return false;
    uint8_t header[256];size_t used=0;unsigned zeros=0;
    for (size_t i=1;i<size && used<sizeof(header);i++) {
        if (zeros>=2 && nal[i]==3) { zeros=0;continue; }
        header[used++]=nal[i];zeros=nal[i]==0?zeros+1:0;
    }
    struct nf_avc_bits bits={header,used,0,false};
    nf_avc_ue(&bits); /* first_mb_in_slice */
    unsigned type=nf_avc_ue(&bits);
    if (type>9) return false;
    type%=5;
    unsigned pps_id=nf_avc_ue(&bits);
    /* Existing synthesis emits PPS 0; do not pretend other IDs are supported. */
    if (pps_id!=0) return false;
    if (cfg->separate_plane) nf_avc_read(&bits,2);
    nf_avc_read(&bits,cfg->frame_num_bits);
    bool field=false;
    if (!cfg->frame_only) { field=nf_avc_read(&bits,1);if(field) nf_avc_read(&bits,1); }
    if (kind==5) nf_avc_ue(&bits);
    if (cfg->poc_type==0) {
        nf_avc_read(&bits,cfg->poc_bits);
        if(cfg->bottom_poc && !field) nf_avc_ue(&bits); /* signed value only skipped */
    } else if(cfg->poc_type==1 && !cfg->delta_always_zero) {
        nf_avc_ue(&bits);
        if(cfg->bottom_poc && !field) nf_avc_ue(&bits);
    }
    if(cfg->redundant) nf_avc_ue(&bits);
    if(type!=0 && type!=1 && type!=3) return false; /* I/SI have no list defaults */
    if(type==1) nf_avc_read(&bits,1); /* direct_spatial_mv_pred_flag */
    bool override=nf_avc_read(&bits,1);
    if(bits.failed || override) return false;
    *b_slice=type==1;
    return true;
}
#endif
