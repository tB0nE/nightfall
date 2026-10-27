#define _POSIX_C_SOURCE 200809L
#include "monado_async_transport.h"
#include <assert.h>
#include <sys/wait.h>
static struct meteor_owned_packet packet(void) {
    struct meteor_owned_packet p={0};
    assert(meteor_encoded_copy(&p,(uint8_t[]){0,0,1,0x65,7},5)); return p;
}
static void read_all(int fd,void *buffer,size_t bytes) {
    uint8_t *p=buffer;
    while(bytes) { ssize_t n=read(fd,p,bytes); assert(n>0); p+=n; bytes-=(size_t)n; }
}
static void pause_ms(unsigned ms) {
    struct timespec t={.tv_sec=ms/1000,.tv_nsec=(long)(ms%1000)*1000000}; nanosleep(&t,NULL);
}
int main(void) {
    int pair[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    pid_t child=fork(); assert(child>=0);
    if(!child) {
        close(pair[0]);
        uint8_t h[152],payload[5],ack[20]={0};
        read_all(pair[1],h,sizeof(h)); assert(!memcmp(h,"NFXR",4));
        read_all(pair[1],payload,sizeof(payload)); assert(payload[4]==7);
        memcpy(ack,"NFXA",4); meteor_direct_u64(ack+4,0,8); meteor_direct_u64(ack+12,9,8);
        assert(write(pair[1],ack,sizeof(ack))==sizeof(ack));
        read_all(pair[1],h,sizeof(h)); assert(h[50]==1);
        uint8_t end[12]={0}; memcpy(end,"NFXE",4); meteor_direct_u64(end+4,1,8);
        assert(write(pair[1],end,sizeof(end))==sizeof(end)); close(pair[1]); _exit(0);
    }
    close(pair[1]); meteor_direct_socket=pair[0]; meteor_direct_epoch=42; meteor_direct_sequence=0;
    struct meteor_stereo_encode_v1 metadata={.frame_id=9,.display_ns=123};
    struct meteor_owned_packet p=packet();
    assert(meteor_async_enqueue(&metadata,&p,"12345")); assert(!p.bytes && !p.length);
    assert(meteor_async_finish()); int status=0; assert(waitpid(child,&status,0)==child && status==0);

    // Decoder cold start: worker backpressure must preserve all encoded packets,
    // not abort just because the first acknowledgement takes 150 ms.
    assert(!setenv("METEOR_XR_ASYNC_ENCODE","1",1));
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    child=fork(); assert(child>=0);
    if(!child) {
        close(pair[0]); pause_ms(150);
        uint8_t h[152],payload[5],ack[20]={0};
        for(unsigned i=0;i<4;++i) {
            read_all(pair[1],h,sizeof(h)); read_all(pair[1],payload,sizeof(payload));
            assert(payload[4]==7 && !h[50]);
            memcpy(ack,"NFXA",4); meteor_direct_u64(ack+4,i,8); meteor_direct_u64(ack+12,9+i,8);
            assert(write(pair[1],ack,sizeof(ack))==sizeof(ack));
        }
        read_all(pair[1],h,sizeof(h)); assert(h[50]==1);
        uint8_t end[12]={0}; memcpy(end,"NFXE",4); meteor_direct_u64(end+4,4,8);
        assert(write(pair[1],end,sizeof(end))==sizeof(end)); close(pair[1]); _exit(0);
    }
    close(pair[1]); meteor_direct_socket=pair[0]; meteor_direct_epoch=44; meteor_direct_sequence=0;
    p=packet(); assert(meteor_async_enqueue(&metadata,&p,"12345"));
    bool active=false;
    for(unsigned i=0;i<200;++i) {
        pthread_mutex_lock(&meteor_async.mutex); active=meteor_async.count==0; pthread_mutex_unlock(&meteor_async.mutex);
        if(active) break;
        pause_ms(1);
    }
    assert(active);
    uint64_t queued_at=meteor_direct_now_ms();
    for(unsigned i=1;i<4;++i) {
        metadata.frame_id=9+i; p=packet(); assert(meteor_async_enqueue(&metadata,&p,"12345")); assert(!p.bytes);
    }
    assert(meteor_direct_now_ms()-queued_at>=50);
    assert(meteor_async_finish()); assert(waitpid(child,&status,0)==child && status==0);
    metadata.frame_id=9;

    // Slow peer: allow one in-flight packet, fill the two pending slots, then
    // prove overflow is explicit and ownership of the rejected packet is kept.
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    meteor_direct_socket=pair[0]; meteor_direct_epoch=43; meteor_direct_sequence=0;
    p=packet(); assert(meteor_async_enqueue(&metadata,&p,"12345"));
    bool in_flight=false;
    for(unsigned i=0;i<200;++i) {
        pthread_mutex_lock(&meteor_async.mutex); in_flight=meteor_async.count==0; pthread_mutex_unlock(&meteor_async.mutex);
        if(in_flight) break;
        pause_ms(1);
    }
    assert(in_flight);
    for(unsigned i=0;i<2;++i) { p=packet(); assert(meteor_async_enqueue(&metadata,&p,"12345")); }
    p=packet(); assert(!meteor_async_enqueue(&metadata,&p,"12345")); assert(p.bytes); free(p.bytes);
    uint64_t start=meteor_direct_now_ms();
    assert(!meteor_async_finish()); assert(meteor_direct_now_ms()-start<3000);
    close(pair[1]);
    // Reset after failure allows another independent session; no retained bytes.
    assert(!meteor_async.started && !meteor_async.count && !meteor_async.pending[0].packet.bytes);
    assert(meteor_async_finish());
}
