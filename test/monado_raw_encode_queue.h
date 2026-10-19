#pragma once
#include "meteor_latest_job_queue.h"
#include "monado_image_lease.h"

struct meteor_raw_job {
    struct null_compositor *compositor; // Device/context outlive drained worker.
    struct comp_layer layer;
    uint64_t frame_id;
    char *library;
};
static int64_t meteor_last_queued_time;
static bool meteor_raw_process(void *value) {
    struct meteor_raw_job *job=value;
    return meteor_encode_layer_now(job->compositor,&job->layer,job->library,job->frame_id);
}
static void meteor_raw_dispose(void *value) {
    struct meteor_raw_job *job=value;
    meteor_projection_image_lease(&job->layer.data,job->layer.sc_array,false);
    for (uint32_t eye=0;eye<2;++eye) xrt_swapchain_reference(&job->layer.sc_array[eye],NULL);
    free(job->library); free(job);
}
static struct meteor_job_queue meteor_raw_queue={
    .mutex=PTHREAD_MUTEX_INITIALIZER,.wake=PTHREAD_COND_INITIALIZER,
    .process=meteor_raw_process,.dispose=meteor_raw_dispose,
};
static bool meteor_raw_submit(struct null_compositor *c,const struct comp_layer *layer,const char *library,uint64_t id) {
    if (layer->data.timestamp==meteor_last_queued_time) return true;
    if (layer->data.timestamp<meteor_last_queued_time || layer->data.type!=XRT_LAYER_PROJECTION || layer->data.view_count!=2) return false;
    struct meteor_raw_job *job=calloc(1,sizeof(*job));
    if (!job) return false;
    job->library=strdup(library);
    if (!job->library) { free(job); return false; }
    job->compositor=c; job->frame_id=id; job->layer.data=layer->data;
    // Called while delivered slots are protected; acquire independent object
    // references AND image reservations before returning to the compositor.
    for (uint32_t eye=0;eye<2;++eye) xrt_swapchain_reference(&job->layer.sc_array[eye],layer->sc_array[eye]);
    meteor_projection_image_lease(&job->layer.data,job->layer.sc_array,true);
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
