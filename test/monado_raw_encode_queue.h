#pragma once
#include "meteor_latest_job_queue.h"
#include "monado_image_lease.h"

struct meteor_raw_job {
    struct null_compositor *compositor; // Device/context outlive drained worker.
    struct comp_layer layer;
    struct comp_layer overlays[METEOR_MAX_QUADS];
    uint32_t overlay_count;
    float head_pose[7];
    bool has_projection;
    uint64_t frame_id;
    uint64_t queued_us;
    char *library;
};
static int64_t meteor_last_queued_time;
static bool meteor_raw_process(void *value) {
    struct meteor_raw_job *job=value;
    uint64_t start=meteor_direct_now_us();
    bool ok=meteor_encode_layer_now(job->compositor,&job->layer,job->library,job->frame_id,job->overlays,job->overlay_count,job->head_pose);
    fprintf(stderr,"METEOR_RAW_TIMING frame=%llu queue_us=%llu encode_us=%llu ok=%d\n",
        (unsigned long long)job->frame_id,(unsigned long long)(start-job->queued_us),
        (unsigned long long)(meteor_direct_now_us()-start),ok);
    return ok;
}
static void meteor_raw_dispose(void *value) {
    struct meteor_raw_job *job=value;
    if(job->has_projection) meteor_projection_image_lease(&job->layer.data,job->layer.sc_array,false);
    for (uint32_t eye=0;eye<2;++eye) xrt_swapchain_reference(&job->layer.sc_array[eye],NULL);
    for(uint32_t i=0;i<job->overlay_count;++i) {
        meteor_projection_image_lease(&job->overlays[i].data,job->overlays[i].sc_array,false);
        for(uint32_t eye=0;eye<2;++eye) xrt_swapchain_reference(&job->overlays[i].sc_array[eye],NULL);
    }
    free(job->library); free(job);
}
static struct meteor_job_queue meteor_raw_queue={
    .mutex=PTHREAD_MUTEX_INITIALIZER,.wake=PTHREAD_COND_INITIALIZER,
    .process=meteor_raw_process,.dispose=meteor_raw_dispose,
};
static bool meteor_raw_submit(struct null_compositor *c,const struct comp_layer *layer,const char *library,uint64_t id,
                              const struct comp_layer *overlays,uint32_t overlay_count,const float *head_pose) {
    if(layer->data.timestamp<=0) return false;
    if (!meteor_frame_timestamp_new(layer->data.timestamp,meteor_last_queued_time)) {
        if(layer->data.timestamp<meteor_last_queued_time) fprintf(stderr,"METEOR_FRAME_SKIPPED reason=stale_render_timestamp render_ns=%lld previous_ns=%lld\n",
            (long long)layer->data.timestamp,(long long)meteor_last_queued_time);
        return true;
    }
    if (layer->data.type!=XRT_LAYER_PROJECTION || layer->data.view_count!=2 || overlay_count>METEOR_MAX_QUADS) return false;
    struct meteor_raw_job *job=calloc(1,sizeof(*job));
    if (!job) return false;
    job->library=strdup(library);
    if (!job->library) { free(job); return false; }
    job->compositor=c; job->frame_id=id; job->layer.data=layer->data;
    // Called while delivered slots are protected; acquire independent object
    // references AND image reservations before returning to the compositor.
    job->has_projection=layer->sc_array[0]!=NULL;
    if(job->has_projection) {
        for (uint32_t eye=0;eye<2;++eye) xrt_swapchain_reference(&job->layer.sc_array[eye],layer->sc_array[eye]);
        meteor_projection_image_lease(&job->layer.data,job->layer.sc_array,true);
    }
    job->overlay_count=overlay_count;
    memcpy(job->head_pose,head_pose,sizeof(job->head_pose));
    for(uint32_t i=0;i<overlay_count;++i) {
        job->overlays[i].data=overlays[i].data;
        uint32_t count=overlays[i].data.type==XRT_LAYER_PROJECTION ? 2 : 1;
        for(uint32_t eye=0;eye<count;++eye) xrt_swapchain_reference(&job->overlays[i].sc_array[eye],overlays[i].sc_array[eye]);
        meteor_projection_image_lease(&job->overlays[i].data,job->overlays[i].sc_array,true);
    }
    job->queued_us=meteor_direct_now_us();
    if (!meteor_jobs_submit(&meteor_raw_queue,job)) { meteor_raw_dispose(job); return false; }
    meteor_last_queued_time=layer->data.timestamp;
    return true;
}
static bool meteor_raw_finish(void) {
    if (!meteor_raw_queue.started && !meteor_last_queued_time) return true;
    bool ok=meteor_jobs_finish(&meteor_raw_queue);
    fprintf(stderr,"METEOR_RAW_DRAIN accepted=%llu encoded=%llu replaced=%llu failed=%d\n",
        (unsigned long long)meteor_raw_queue.accepted,(unsigned long long)meteor_raw_queue.completed,
        (unsigned long long)meteor_raw_queue.replaced,!ok);
    meteor_last_queued_time=0;
    return ok;
}
