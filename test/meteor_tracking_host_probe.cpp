#include "pcvr_meteor_tracking.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <chrono>
#include <thread>
#include <cstdio>
#include <cstdlib>

static uint64_t now_ns() {
    return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
static bool io(int fd, void *bytes, size_t length, bool writing) {
    auto *p=static_cast<uint8_t *>(bytes);
    while (length) {
        auto n=writing ? send(fd,p,length,MSG_NOSIGNAL) : recv(fd,p,length,0);
        if (n<=0) return false;
        p+=n; length-=size_t(n);
    }
    return true;
}
int main(int argc, char **argv) {
    if (argc!=2) return 2;
    char *end=nullptr; long port=std::strtol(argv[1],&end,10);
    if (!*argv[1] || *end || port<1 || port>65535) return 2;
    int fd=socket(AF_INET,SOCK_STREAM | SOCK_CLOEXEC,0);
    if (fd<0) return 1;
    timeval timeout{2,0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    sockaddr_in address{}; address.sin_family=AF_INET;
    address.sin_port=htons(uint16_t(port)); address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if (connect(fd,reinterpret_cast<sockaddr *>(&address),sizeof(address))) { close(fd); return 1; }
    auto request=[](const char *magic) {
        std::array<uint8_t,32> h{}; std::memcpy(h.data(),magic,4);
        meteor_xr_put(h.data()+4,1,2); meteor_xr_put(h.data()+6,32,2); return h;
    };
    MeteorClockMapping clock;
    for (int i=0;i<8;++i) {
        auto h=request("NFXC"); uint64_t h0=now_ns(); meteor_xr_put(h.data()+8,h0,8);
        if (!io(fd,h.data(),h.size(),true) || !io(fd,h.data(),h.size(),false)) { close(fd); return 1; }
        uint64_t h3=now_ns();
        if (std::memcmp(h.data(),"NFXC",4) || meteor_xr_le(h.data()+4,2)!=1 ||
            meteor_xr_le(h.data()+6,2)!=32 || meteor_xr_le(h.data()+8,8)!=h0 ||
            !clock.observe(h0,meteor_xr_le(h.data()+16,8),meteor_xr_le(h.data()+24,8),h3)) { close(fd); return 1; }
    }
    MeteorTrackingWire wire; uint64_t previous=0;
    for (int i=0;i<120;++i) {
        auto h=request("NFXP"); std::array<uint8_t,64> packet{}; MeteorTrackingSample sample;
        if (!io(fd,h.data(),h.size(),true) || !io(fd,packet.data(),packet.size(),false) || !wire.accept(packet,sample)) { close(fd); return 1; }
        uint64_t mapped=0, receipt=now_ns();
        if (!clock.to_host(sample.client_ns,mapped) || mapped<=previous ||
            (mapped>receipt ? mapped-receipt : receipt-mapped)>250000000+clock.uncertainty_ns()) { close(fd); return 1; }
        previous=mapped;
        std::printf("{\"sequence\":%llu,\"client_ns\":%llu,\"host_ns\":%llu,\"uncertainty_ns\":%llu,\"pose\":[",
            (unsigned long long)sample.sequence,(unsigned long long)sample.client_ns,
            (unsigned long long)mapped,(unsigned long long)clock.uncertainty_ns());
        for (size_t p=0;p<7;++p) std::printf("%s%.9g",p ? "," : "",sample.pose[p]);
        std::puts("]}");
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    auto quit=request("NFXQ"); bool ok=io(fd,quit.data(),quit.size(),true); close(fd);
    if (ok) std::fprintf(stderr,"PASS: 120 fresh LOCAL head poses; explicit host clock mapping; uncertainty=%llu ns (not Monado injection)\n",(unsigned long long)clock.uncertainty_ns());
    return ok ? 0 : 1;
}
