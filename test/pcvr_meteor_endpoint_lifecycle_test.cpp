#include "pcvr_meteor_tracking_endpoint.h"
#include <cassert>
#include <chrono>
#include <thread>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

template<class Predicate> void bounded_wait(Predicate predicate) {
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    bool ready=predicate();
    while(!ready && std::chrono::steady_clock::now()<deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        ready=predicate();
    }
    assert(ready);
}
int main() {
    // Reserve an available loopback port, then reuse it across the SAME endpoint.
    int reserve=socket(AF_INET,SOCK_STREAM,0); assert(reserve>=0);
    sockaddr_in address{}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    assert(bind(reserve,reinterpret_cast<sockaddr *>(&address),sizeof(address))==0);
    socklen_t length=sizeof(address); assert(getsockname(reserve,reinterpret_cast<sockaddr *>(&address),&length)==0);
    close(reserve);
    MeteorTrackingEndpoint endpoint;
    for(unsigned mode=0;mode<6;++mode) {
        assert(endpoint.start(ntohs(address.sin_port)));
        assert(!endpoint.start(ntohs(address.sin_port)));
        bounded_wait([&]{ return endpoint.listening(); });
        MeteorHaptic pulse;
        assert(!endpoint.take_haptic(0,pulse) && !endpoint.take_haptic(1,pulse));
        if(mode==0) { // Cancellation while waiting for a connection.
            endpoint.request_stop(); bounded_wait([&]{return endpoint.idle();});
            assert(!endpoint.failed()); continue;
        }
        MeteorTrackingSample sample; sample.epoch=100+mode; sample.client_ns=MeteorTrackingEndpoint::now_ns();
        endpoint.publish(sample);
        int peer=socket(AF_INET,SOCK_STREAM,0); assert(peer>=0);
        timeval timeout{3,0}; setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        assert(connect(peer,reinterpret_cast<sockaddr *>(&address),sizeof(address))==0);
        pulse={}; pulse.epoch=sample.epoch; pulse.hand=mode%2; pulse.amplitude=.5f; pulse.duration_ms=100;
        auto packet=MeteorHapticWire::encode(pulse),ack=packet;
        assert(send(peer,packet.data(),packet.size(),MSG_NOSIGNAL)==32);
        assert(recv(peer,ack.data(),ack.size(),MSG_WAITALL)==32 && ack==packet);
        MeteorHaptic consumed;
        bounded_wait([&]{ return endpoint.take_haptic(pulse.hand,consumed); });
        assert(consumed.amplitude==.5f && consumed.epoch==sample.epoch);
        if(mode==1) { // Explicit clean protocol exit.
            packet={}; std::memcpy(packet.data(),"NFXQ",4);
            meteor_xr_put(packet.data()+4,1,2); meteor_xr_put(packet.data()+6,32,2);
            assert(send(peer,packet.data(),packet.size(),MSG_NOSIGNAL)==32);
        } else if(mode==2) { // Mid-packet disconnect.
            assert(send(peer,"NFX",3,MSG_NOSIGNAL)==3); shutdown(peer,SHUT_RDWR);
        } else if(mode==3) { // Connected but silent peer must time out.
        } else if(mode==4) { // Local stop interrupts a pending partial read.
            assert(send(peer,"N",1,MSG_NOSIGNAL)==1); endpoint.request_stop();
        } else { // Old-session commands cannot survive restart.
            pulse.epoch=sample.epoch-1; pulse.sequence=1;
            packet=MeteorHapticWire::encode(pulse);
            assert(send(peer,packet.data(),packet.size(),MSG_NOSIGNAL)==32);
        }
        bounded_wait([&]{return endpoint.idle();});
        close(peer);
        assert(endpoint.failed()==(mode==2 || mode==3 || mode==5));
        for(unsigned hand=0;hand<2;++hand) {
            assert(endpoint.take_haptic(hand,consumed));
            assert(consumed.amplitude==0 && consumed.duration_ms==0);
        }
    }
}
