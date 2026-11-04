#pragma once
#include "monado_direct_transport.h"
#include "meteor_delivery_threads.h"
#include <stdio.h>

// Diagnostic opt-in: two pending compressed packets plus one in flight.
// Never drop H.264 interframes. The raw encode worker may wait up to two seconds
// for a slot; synchronous compositor callers retain fail-fast saturation.
// No GPU handles are used by the delivery worker.
struct meteor_delivery {
    uint64_t queued_us;
    struct meteor_stereo_encode_v1 metadata;
    struct meteor_owned_packet packet;
};
static struct {
    meteor_delivery_mutex mutex;
    meteor_delivery_condition wake;
    meteor_delivery_thread thread;
    bool started, stopping, failed;
    unsigned head, count, peak;
    uint64_t delivered;
    char port[6];
    struct meteor_delivery pending[2];
} meteor_async = {.mutex=METEOR_DELIVERY_MUTEX_INIT, .wake=METEOR_DELIVERY_CONDITION_INIT};

static void *meteor_delivery_worker(void *unused)
{
    (void)unused;
    for (;;) {
        meteor_delivery_lock(&meteor_async.mutex);
        while (!meteor_async.count && !meteor_async.stopping && !meteor_async.failed)
            meteor_delivery_wait(&meteor_async.wake,&meteor_async.mutex);
        if (meteor_async.failed || (!meteor_async.count && meteor_async.stopping)) {
            meteor_delivery_unlock(&meteor_async.mutex); break;
        }
        struct meteor_delivery item=meteor_async.pending[meteor_async.head];
        memset(&meteor_async.pending[meteor_async.head],0,sizeof(item));
        meteor_async.head=(meteor_async.head+1)%2; --meteor_async.count;
        meteor_delivery_broadcast(&meteor_async.wake);
        meteor_delivery_unlock(&meteor_async.mutex);
        uint64_t start=meteor_direct_now_us();
        bool ok=meteor_direct_send(&item.metadata,&item.packet,meteor_async.port);
        fprintf(stderr,"METEOR_DELIVERY_TIMING frame=%llu queue_us=%llu service_us=%llu ok=%d\n",
            (unsigned long long)item.metadata.frame_id,(unsigned long long)(start-item.queued_us),
            (unsigned long long)(meteor_direct_now_us()-start),ok);
        if (ok) fprintf(stderr,"METEOR_DIRECT_OK frame=%llu bytes=%u async=1\n",
            (unsigned long long)item.metadata.frame_id,item.packet.length);
        free(item.packet.bytes);
        meteor_delivery_lock(&meteor_async.mutex);
        if (ok) ++meteor_async.delivered;
        else meteor_async.failed=true;
        meteor_delivery_broadcast(&meteor_async.wake);
        meteor_delivery_unlock(&meteor_async.mutex);
        if (!ok) break;
    }
    meteor_delivery_lock(&meteor_async.mutex);
    bool failed=meteor_async.failed;
    meteor_delivery_unlock(&meteor_async.mutex);
    if (!failed && !meteor_direct_finish()) {
        meteor_delivery_lock(&meteor_async.mutex); meteor_async.failed=true; meteor_delivery_unlock(&meteor_async.mutex);
    }
    meteor_direct_close();
    return NULL;
}

// Successful enqueue transfers packet ownership; failure leaves it with caller.
static bool meteor_async_enqueue(const struct meteor_stereo_encode_v1 *input,
                                 struct meteor_owned_packet *packet,const char *port)
{
    if (!input || !packet || !packet->bytes || !packet->length || packet->length>8*1024*1024 || !port) return false;
    char *end=NULL; long number=strtol(port,&end,10);
    if (!*port || *end || number<1 || number>65535 || strlen(port)>5) return false;
    meteor_delivery_lock(&meteor_async.mutex);
    // The raw encode worker and Windows' bounded compositor adapter may wait
    // through decoder cold start. Linux synchronous callers still fail fast.
    // Encoded packets retain order and ownership without growing queues.
    bool can_wait=getenv("METEOR_XR_ASYNC_ENCODE")!=NULL;
#ifdef _WIN32
    can_wait=can_wait || getenv("METEOR_XR_ASYNC_DELIVERY")!=NULL;
#endif
    if(meteor_async.count==2 && !meteor_async.failed && !meteor_async.stopping && can_wait) {
        uint64_t deadline=meteor_direct_now_ms()+2000;
        fprintf(stderr,"METEOR_DELIVERY_BACKPRESSURE waiting_for_slot=1\n");
        while(meteor_async.count==2 && !meteor_async.failed && !meteor_async.stopping) {
            int result=meteor_delivery_wait_until(&meteor_async.wake,&meteor_async.mutex,deadline);
            if(result) break;
        }
    }
    if (meteor_async.failed || meteor_async.stopping || meteor_async.count==2 ||
        (meteor_async.started && strcmp(port,meteor_async.port))) {
        fprintf(stderr,"METEOR_DELIVERY_REJECT pending=%u failed=%d stopping=%d\n",
            meteor_async.count,meteor_async.failed,meteor_async.stopping);
        meteor_async.failed=true; meteor_delivery_broadcast(&meteor_async.wake);
        meteor_delivery_unlock(&meteor_async.mutex); return false;
    }
    if (!meteor_async.started) {
        strcpy(meteor_async.port,port);
        if (meteor_delivery_create(&meteor_async.thread,meteor_delivery_worker,NULL)) {
            meteor_async.failed=true; meteor_delivery_unlock(&meteor_async.mutex); return false;
        }
        meteor_async.started=true;
    }
    unsigned index=(meteor_async.head+meteor_async.count)%2;
    meteor_async.pending[index].queued_us=meteor_direct_now_us();
    // Only wire metadata is retained. Explicitly erase borrowed GPU pointers and
    // callback/path addresses so worker ownership cannot accidentally grow later.
    struct meteor_stereo_encode_v1 *m=&meteor_async.pending[index].metadata;
    memset(m,0,sizeof(*m)); m->frame_id=input->frame_id; m->display_ns=input->display_ns;
    m->eye_size=input->eye_size;
    m->eye_height=input->eye_height;
    memcpy(m->views,input->views,sizeof(m->views));
    meteor_async.pending[index].packet=*packet; packet->bytes=NULL; packet->length=0;
    ++meteor_async.count;
    if (meteor_async.count>meteor_async.peak) meteor_async.peak=meteor_async.count;
    meteor_delivery_signal(&meteor_async.wake); meteor_delivery_unlock(&meteor_async.mutex);
    return true;
}

static bool meteor_async_finish(void)
{
    meteor_delivery_lock(&meteor_async.mutex);
    bool started=meteor_async.started;
    meteor_async.stopping=true; meteor_delivery_signal(&meteor_async.wake);
    meteor_delivery_unlock(&meteor_async.mutex);
    if (started) meteor_delivery_join(meteor_async.thread);
    meteor_delivery_lock(&meteor_async.mutex);
    bool ok=!meteor_async.failed;
    fprintf(stderr,"METEOR_ASYNC_DRAIN delivered=%llu peak_pending=%u failed=%d\n",
        (unsigned long long)meteor_async.delivered,meteor_async.peak,!ok);
    for (unsigned i=0;i<2;++i) {
        free(meteor_async.pending[i].packet.bytes);
        memset(&meteor_async.pending[i],0,sizeof(meteor_async.pending[i]));
    }
    meteor_async.started=meteor_async.stopping=meteor_async.failed=false;
    meteor_async.head=meteor_async.count=meteor_async.peak=0; meteor_async.delivered=0;
    meteor_delivery_unlock(&meteor_async.mutex);
    return ok;
}
