// Linux-only diagnostic bridge: live USB poses -> isolated Monado virtual HMD.
#include "pcvr_meteor_tracking.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cerrno>

namespace {
uint64_t now_ns() {
    return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
struct Client {
    std::atomic<bool> stop{false}, failed{false}, ready{false};
    std::thread worker;
    std::mutex mutex;
    MeteorTrackingSample sample;
    MeteorHeadsetOptics optics;
    uint64_t mapped_ns=0;
    int fd=-1;
    ~Client() { stop.store(true); if(worker.joinable()) worker.join(); if(fd>=0) close(fd); }
    bool io(void *data,size_t length,bool writing,uint64_t deadline) {
        auto *p=static_cast<uint8_t *>(data);
        while(length && !stop.load() && now_ns()<deadline) {
            pollfd item{fd,short(writing ? POLLOUT : POLLIN),0};
            int n=poll(&item,1,10);
            if(n<0 && errno==EINTR) continue;
            if(n<0) return false;
            if(!n) continue;
            auto count=writing ? send(fd,p,length,MSG_NOSIGNAL) : recv(fd,p,length,0);
            if(count<0 && (errno==EINTR || errno==EAGAIN)) continue;
            if(count<=0) return false;
            p+=count; length-=size_t(count);
        }
        return !length;
    }
    static std::array<uint8_t,32> request(const char *kind) {
        std::array<uint8_t,32> h{}; std::memcpy(h.data(),kind,4);
        meteor_xr_put(h.data()+4,1,2); meteor_xr_put(h.data()+6,32,2); return h;
    }
    void run() {
        MeteorClockMapping clock;
        for(int i=0;i<8;++i) {
            auto h=request("NFXC"); uint64_t h0=now_ns(); meteor_xr_put(h.data()+8,h0,8);
            uint64_t deadline=h0+2000000000;
            if(!io(h.data(),h.size(),true,deadline) || !io(h.data(),h.size(),false,deadline) ||
                std::memcmp(h.data(),"NFXC",4) || meteor_xr_le(h.data()+4,2)!=1 ||
                meteor_xr_le(h.data()+6,2)!=32 || meteor_xr_le(h.data()+8,8)!=h0 ||
                !clock.observe(h0,meteor_xr_le(h.data()+16,8),meteor_xr_le(h.data()+24,8),now_ns())) {
                failed.store(!stop.load()); return;
            }
        }
        std::fprintf(stderr,"METEOR_TRACKING_CLOCK uncertainty_ns=%llu\n",(unsigned long long)clock.uncertainty_ns());
        if(std::getenv("METEOR_XR_HEADSET_OPTICS")) {
            auto h=request("NFXO"); std::array<uint8_t,MeteorOpticsWire::size> packet{};
            uint64_t deadline=now_ns()+2000000000;
            if(!io(h.data(),h.size(),true,deadline) || !io(packet.data(),packet.size(),false,deadline) ||
                !MeteorOpticsWire::decode(packet,optics)) { failed.store(true); return; }
            std::fprintf(stderr,"METEOR_HEADSET_OPTICS epoch=%llu left_x=%.6f right_x=%.6f\n",
                (unsigned long long)optics.epoch,optics.eyes[0],optics.eyes[11]);
        }
        MeteorTrackingWire wire;
        while(!stop.load()) {
            auto h=request("NFXP"); std::array<uint8_t,64> packet{};
            uint64_t deadline=now_ns()+2000000000;
            MeteorTrackingSample incoming; uint64_t mapped=0;
            if(!io(h.data(),h.size(),true,deadline) || !io(packet.data(),packet.size(),false,deadline) ||
                !wire.accept(packet,incoming) || !clock.to_host(incoming.client_ns,mapped) ||
                (optics.epoch && incoming.epoch!=optics.epoch)) break;
            uint64_t receipt=now_ns();
            if((mapped>receipt ? mapped-receipt : receipt-mapped)>250000000+clock.uncertainty_ns()) break;
            {
                std::lock_guard<std::mutex> lock(mutex);
                sample=incoming; mapped_ns=mapped;
            }
            if(!ready.exchange(true)) std::fprintf(stderr,"METEOR_TRACKING_READY epoch=%llu; Quest LOCAL adopted as virtual device origin; latest-only/no prediction\n",(unsigned long long)incoming.epoch);
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        if(stop.load()) {
            auto h=request("NFXQ");
            // Best-effort close; destructor closes socket even if peer is gone.
            send(fd,h.data(),h.size(),MSG_NOSIGNAL | MSG_DONTWAIT);
        } else failed.store(true);
    }
};
}

extern "C" void *meteor_tracking_start_v1(const char *port_text) {
    if(!port_text) return nullptr;
    char *end=nullptr; long port=std::strtol(port_text,&end,10);
    if(!*port_text || *end || port<1 || port>65535) return nullptr;
    auto *c=new Client;
    c->fd=socket(AF_INET,SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC,0);
    if(c->fd<0) { delete c; return nullptr; }
    sockaddr_in address{}; address.sin_family=AF_INET;
    address.sin_port=htons(uint16_t(port)); address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(connect(c->fd,reinterpret_cast<sockaddr *>(&address),sizeof(address))) {
        pollfd item{c->fd,POLLOUT,0}; int error=0; socklen_t size=sizeof(error);
        if(errno!=EINPROGRESS || poll(&item,1,2000)<=0 ||
            getsockopt(c->fd,SOL_SOCKET,SO_ERROR,&error,&size) || error) { delete c; return nullptr; }
    }
    int one=1; setsockopt(c->fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    c->worker=std::thread(&Client::run,c);
    uint64_t deadline=now_ns()+2500000000;
    while(!c->ready.load() && !c->failed.load() && now_ns()<deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if(!c->ready.load() || c->failed.load()) { delete c; return nullptr; }
    return c;
}
extern "C" int meteor_tracking_pose_v1(void *context,int64_t at_ns,float pose[7],uint64_t *sample_ns) {
    auto *c=static_cast<Client *>(context);
    if(!c || c->failed.load() || at_ns<=0 || !pose || !sample_ns) return 0;
    std::unique_lock<std::mutex> lock(c->mutex,std::try_to_lock);
    if(!lock.owns_lock()) return 0;
    uint64_t now=now_ns();
    // No velocity/prediction yet. Do not extrapolate stale poses or answer
    // arbitrary historical/far-future queries with the latest sample.
    uint64_t query=uint64_t(at_ns), stamp=c->mapped_ns;
    if(!stamp || (stamp>now ? stamp-now : now-stamp)>250000000 ||
        (query>stamp ? query-stamp : stamp-query)>250000000) return 0;
    std::memcpy(pose,c->sample.pose.data(),7*sizeof(float)); *sample_ns=stamp; return 1;
}
extern "C" void meteor_tracking_stop_v1(void *context) { delete static_cast<Client *>(context); }
extern "C" int meteor_tracking_optics_v1(void *context,float eyes[22]) {
    auto *c=static_cast<Client *>(context);
    if(!c || !eyes || !c->ready.load() || c->failed.load() || !c->optics.epoch) return 0;
    // Immutable after worker readiness is published with release/acquire ordering.
    std::memcpy(eyes,c->optics.eyes.data(),22*sizeof(float)); return 1;
}
