// Cross-language fixture only: fixed test keys, loopback socket, bounded reads.
#include "network/meteor_xr_data.h"
#include "pcvr_meteor_wire.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cassert>
#include <iostream>
#include <fstream>

static void io(int fd,uint8_t *p,size_t n,bool write) {
    while(n){auto count=write?send(fd,p,n,MSG_NOSIGNAL):recv(fd,p,n,0);assert(count>0);p+=count;n-=count;}
}
int main(int argc,char **argv) {
    assert(argc==3);std::ofstream decoded(argv[2],std::ios::binary);assert(decoded.good());
    int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);
    timeval limit{3,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof(limit));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,sizeof(limit));
    sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(std::stoi(argv[1]));address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    assert(connect(fd,reinterpret_cast<sockaddr *>(&address),sizeof(address))==0);
    std::array<uint8_t,32> seed,identity,pin,server_nonce,client_nonce;std::array<uint8_t,16> session;
    seed.fill(1);identity.fill(2);server_nonce.fill(3);client_nonce.fill(4);session.fill(5);
    assert(godot::MeteorCipher::identity_public(seed.data(),pin.data()));
    using Secure=godot::MeteorXrDataCipher;
    Secure video,tracking;assert(video.init(pin,identity,server_nonce,client_nonce,session,Secure::Kind::Video));
    assert(tracking.init(pin,identity,server_nonce,client_nonce,session,Secure::Kind::HeadsetTracking));
    MeteorXrWire wire;unsigned frames=0;
    for(;;) {
        std::array<uint8_t,Secure::HEADER> header;io(fd,header.data(),header.size(),false);size_t length=0;
        assert(video.payload_length(header,length));std::vector<uint8_t> body(length),plain;
        io(fd,body.data(),body.size(),false);
        if(frames==0) {
            Secure probe;
            assert(probe.init(pin,identity,server_nonce,client_nonce,session,Secure::Kind::Video));
            auto corrupt=body;corrupt[0]^=1;
            assert(!probe.open(header,corrupt,plain)&&plain.empty());
            assert(!probe.open(header,body,plain)); // Failed channel cannot recover/reuse nonce.
            auto other_session=session;other_session[0]^=1;
            assert(probe.init(pin,identity,server_nonce,client_nonce,other_session,Secure::Kind::Video));
            assert(!probe.open(header,body,plain));
            auto excessive=header;for(unsigned i=16;i<20;++i)excessive[i]=255;
            size_t ignored=0;assert(!video.payload_length(excessive,ignored));
        }
        assert(video.open(header,std::move(body),plain));assert(plain.size()>=152);
        std::array<uint8_t,152> inner;std::copy_n(plain.begin(),152,inner.begin());MeteorXrFrame frame;
        assert(wire.header(inner,frame));std::vector<uint8_t> payload(plain.begin()+152,plain.end());assert(wire.accept(frame,payload));
        if(frame.end)break;
	    decoded.write(reinterpret_cast<const char *>(payload.data()),payload.size());
        ++frames;
        std::vector<uint8_t> pose(64);memcpy(pose.data(),"NFXT",4);pose[4]=1;pose[6]=64;
        meteor_xr_put(pose.data()+8,9,8);meteor_xr_put(pose.data()+16,frames-1,8);meteor_xr_put(pose.data()+24,frames*1000,8);
	    uint32_t unit;float one=1.f;memcpy(&unit,&one,4);meteor_xr_put(pose.data()+56,unit,4);
        std::vector<uint8_t> encrypted;assert(tracking.seal(pose,encrypted));io(fd,encrypted.data(),encrypted.size(),true);
    }
    assert(frames>0);decoded.close();close(fd);std::cout<<"PASS authenticated video/metadata plus tracking; native wire validator retained frames="<<frames<<"\n";
}
