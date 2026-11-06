#include "monado_async_transport.h"
#include <assert.h>

struct fixture {SOCKET listener;unsigned frames;bool bad_ack;};
static bool exact(SOCKET fd,void *data,int count,bool writing) {
    char *bytes=data;
    while(count) {
        int n=writing ? send(fd,bytes,count,0) : recv(fd,bytes,count,0);
        if(n<=0) return false;
        bytes+=n;count-=n;
    }
    return true;
}
static DWORD WINAPI receiver(void *context) {
    struct fixture *f=context;
    SOCKET fd=accept(f->listener,NULL,NULL);assert(fd!=INVALID_SOCKET);
    DWORD timeout=5000;
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,(char *)&timeout,sizeof(timeout));
    Sleep(150); // Cold decoder: fill the bounded queue before the first ACK.
    for(unsigned i=0;i<f->frames;i++) {
        uint8_t header[152],payload[5],ack[20]={0};
        assert(exact(fd,header,sizeof(header),false));
        assert(exact(fd,payload,sizeof(payload),false));
        assert(!memcmp(header,"NFXR",4) && header[16]==i && header[24]==9+i && header[40]==5);
        assert(payload[4]==7);
        memcpy(ack,f->bad_ack ? "BAD!" : "NFXA",4);
        meteor_direct_u64(ack+4,i,8);meteor_direct_u64(ack+12,9+i,8);
        assert(exact(fd,ack,sizeof(ack),true));
    }
    if(!f->bad_ack) {
        uint8_t header[152],ack[12]={0};
        assert(exact(fd,header,sizeof(header),false));
        assert(header[50]==1 && header[16]==f->frames);
        memcpy(ack,"NFXE",4);meteor_direct_u64(ack+4,f->frames,8);
        assert(exact(fd,ack,sizeof(ack),true));
    }
    closesocket(fd);return 0;
}
static void session(unsigned frames,bool bad_ack) {
    struct fixture f={.frames=frames,.bad_ack=bad_ack};
    f.listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);assert(f.listener!=INVALID_SOCKET);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr={.s_addr=htonl(INADDR_LOOPBACK)}};
    assert(!bind(f.listener,(struct sockaddr *)&address,sizeof(address)));
    assert(!listen(f.listener,1));
    int size=sizeof(address);assert(!getsockname(f.listener,(struct sockaddr *)&address,&size));
    char port[6];snprintf(port,sizeof(port),"%u",ntohs(address.sin_port));
    HANDLE peer=CreateThread(NULL,0,receiver,&f,0,NULL);assert(peer);
    uint64_t start=meteor_direct_now_ms();
    for(unsigned i=0;i<frames;i++) {
        struct meteor_stereo_encode_v1 metadata={.frame_id=9+i,.display_ns=123+i};
        struct meteor_owned_packet packet={0};
        uint8_t bytes[]={0,0,1,0x65,7};
        assert(meteor_encoded_copy(&packet,bytes,sizeof(bytes)));
        assert(meteor_async_enqueue(&metadata,&packet,port));assert(!packet.bytes);
    }
    if(frames==4) assert(meteor_direct_now_ms()-start>=50);
    assert(meteor_async_finish()==!bad_ack);
    assert(WaitForSingleObject(peer,5000)==WAIT_OBJECT_0);
    CloseHandle(peer);closesocket(f.listener);
    assert(!meteor_async.started && !meteor_async.count && !meteor_async.pending[0].packet.bytes);
}
int main(void) {
    WSADATA data;assert(!WSAStartup(MAKEWORD(2,2),&data));
    assert(!_putenv_s("METEOR_XR_ASYNC_DELIVERY","1"));
    session(4,false);session(1,true);session(1,false);
    assert(meteor_async_finish());
    puts("PASS: Windows async delivery preserves four cold-start frames, rejects bad ACK, restarts, and drains END");
    return 0;
}
