// Exercise the actual bridge over Winsock with an independently offset clock.
#include "meteor_tracking_client_bridge.cpp"
#include <cassert>
#include <future>
#include <string>
#include <fstream>
static bool transfer(SOCKET fd,void *data,size_t size,bool writing) {
    auto *bytes=static_cast<char *>(data);
    while(size) {
        int n=writing ? send(fd,bytes,int(size),0) : recv(fd,bytes,int(size),0);
        if(n<=0) return false;
        bytes+=n; size-=n;
    }
    return true;
}
int main(int argc,char **argv) {
    const bool serving=(argc==2 || argc==3) && std::string(argv[1])=="--serve";
    WSADATA data; assert(WSAStartup(MAKEWORD(2,2),&data)==0);
    _putenv_s("METEOR_XR_CONTROLLERS","1");
    _putenv_s("METEOR_XR_TOUCH_INPUTS","1");
    _putenv_s("METEOR_XR_HEADSET_OPTICS","");
    assert(!meteor_tracking_start_v1("0"));
    assert(!meteor_tracking_start_v1("invalid"));
    SOCKET listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP); assert(listener!=INVALID_SOCKET);
    sockaddr_in address{}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(serving) {
        unsigned long port=45994;
        if(argc==3) {
            char *end=nullptr;port=std::strtoul(argv[2],&end,10);
            if(!*argv[2] || *end || port>65535) return 2;
        }
        address.sin_port=htons(static_cast<uint16_t>(port));
    }
    assert(bind(listener,reinterpret_cast<sockaddr *>(&address),sizeof(address))==0);
    int size=sizeof(address); assert(getsockname(listener,reinterpret_cast<sockaddr *>(&address),&size)==0);
    assert(listen(listener,1)==0);
    std::atomic<bool> pause{false},disconnect{false};
    std::atomic<unsigned> haptics{0};
    std::thread server([&] {
        do {
        SOCKET peer=accept(listener,nullptr,nullptr); assert(peer!=INVALID_SOCKET);
        uint64_t sequence=0;
        uint64_t controller_sequence=0;
        while(!disconnect.load()) {
            auto request=Client::request("NFXP");
            if(!transfer(peer,request.data(),request.size(),false)) break;
            if(!std::memcmp(request.data(),"NFXC",4)) {
                meteor_xr_put(request.data()+16,now_ns()+5000000000ULL,8);
                meteor_xr_put(request.data()+24,now_ns()+5000000000ULL,8);
                if(!transfer(peer,request.data(),request.size(),true)) break;
            } else if(!std::memcmp(request.data(),"NFXO",4)) {
                MeteorHeadsetOptics optics; optics.epoch=42;
                optics.eyes={-.032f,0,0,0,0,0,1,-.8f,.7f,.75f,-.65f,
                              .032f,0,0,0,0,0,1,-.7f,.8f,.75f,-.65f};
                auto packet=MeteorOpticsWire::encode(optics);
                if(!transfer(peer,packet.data(),packet.size(),true)) break;
            } else if(!std::memcmp(request.data(),"NFXP",4)) {
                while(pause.load() && !disconnect.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
                if(disconnect.load()) break;
                MeteorTrackingSample sample; sample.epoch=42; sample.sequence=sequence++;
                sample.client_ns=now_ns()+5000000000ULL; sample.pose={.25f,.5f,-.75f,0,0,0,1};
                if(serving && std::getenv("METEOR_TRACKING_MOTION")) {
                    double t=double(now_ns())*1e-9;
                    float yaw=.35f*float(std::sin(t*.9)),pitch=.15f*float(std::sin(t*.7));
                    float sy=std::sin(yaw*.5f),cy=std::cos(yaw*.5f),sp=std::sin(pitch*.5f),cp=std::cos(pitch*.5f);
                    sample.pose={.25f+.08f*float(std::sin(t)),.5f+.04f*float(std::sin(t*.7)),-.75f,cy*sp,sy*cp,-sy*sp,cy*cp};
                }
                auto packet=MeteorTrackingWire::encode(sample);
                if(!transfer(peer,packet.data(),packet.size(),true)) break;
            } else if(!std::memcmp(request.data(),"NFXJ",4)) {
                MeteorControllerSample input; input.epoch=42; input.sequence=controller_sequence++;
                input.client_ns=now_ns()+5000000000ULL;
                for(unsigned hand=0;hand<2;++hand) {
                    auto &state=input.hands[hand]; state.flags=15; state.buttons=127;
                    state.trigger=.25f; state.squeeze=.75f; state.stick={hand ? .5f : -.5f,.25f};
                    state.poses[0]=hand ? .3f : -.3f; state.poses[6]=1;
                    std::copy(state.poses.begin(),state.poses.begin()+7,state.poses.begin()+7);
                }
                if(const char *fixture=std::getenv("METEOR_CONTROLLER_FIXTURE")) {
                    unsigned left=0,right=0; std::ifstream file(fixture);
                    if(file>>left>>right) {input.hands[0].buttons=left; input.hands[1].buttons=right;}
                    else {input.hands[0].buttons=input.hands[1].buttons=0;}
                }
                if(std::getenv("METEOR_NEUTRAL_INPUT")) for(auto &hand:input.hands) {
                    hand.buttons=0;hand.trigger=hand.squeeze=0;hand.stick={0,0};
                }
                auto packet=MeteorControllerWire::encode(input,true);
                if(!transfer(peer,packet.data(),packet.size(),true)) break;
            } else if(!std::memcmp(request.data(),"NFXH",4)) {
                MeteorHaptic pulse; assert(MeteorHapticWire::decode(request,pulse));
                assert(pulse.epoch==42);
                if(argc==1) assert(pulse.amplitude==.5f && pulse.duration_ms==150);
                haptics.fetch_or(1u<<pulse.hand);
                if(!transfer(peer,request.data(),request.size(),true)) break;
                std::printf("haptic_ack_hand=%u amplitude=%.3f duration_ms=%u\n",pulse.hand,pulse.amplitude,pulse.duration_ms); std::fflush(stdout);
            } else break;
        }
        shutdown(peer,SD_BOTH); closesocket(peer);
        } while(serving && std::getenv("METEOR_TRACKING_RECONNECT"));
    });
    if(serving) {
        std::printf("Synthetic tracking fixture listening on loopback:%u\n",ntohs(address.sin_port)); std::fflush(stdout);
        server.join(); closesocket(listener); WSACleanup(); return 0;
    }
    const auto port=std::to_string(ntohs(address.sin_port));
    void *client=meteor_tracking_start_v1(port.c_str()); assert(client);
    float pose[7]{}; uint64_t stamp=0;
    assert(meteor_tracking_pose_v1(client,int64_t(now_ns()),pose,&stamp));
    assert(pose[0]==.25f && pose[1]==.5f && pose[2]==-.75f && pose[6]==1);
    assert(now_ns()>stamp && now_ns()-stamp<250000000);
    for(unsigned hand=0;hand<2;++hand) {
        float poses[14]{},values[4]{}; uint32_t flags=0,buttons=0;
        assert(meteor_tracking_controller_v2(hand,int64_t(now_ns()),poses,values,&buttons,&flags,&stamp));
        assert(flags==15 && buttons==127 && values[0]==.25f && values[1]==.75f);
        assert(values[2]==(hand ? .5f : -.5f) && poses[0]==(hand ? .3f : -.3f));
        assert(meteor_tracking_haptic_v1(hand,.9f,500000000));
    }
    auto haptic_deadline=now_ns()+1000000000;
    while(haptics.load()!=3 && now_ns()<haptic_deadline) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(haptics.load()==3);
    pause.store(true); std::this_thread::sleep_for(std::chrono::milliseconds(350));
    assert(!meteor_tracking_pose_v1(client,int64_t(now_ns()),pose,&stamp));
    float stale_poses[14]{},stale_values[4]{}; uint32_t stale_buttons=127,stale_flags=15;
    assert(!meteor_tracking_controller_v2(0,int64_t(now_ns()),stale_poses,stale_values,&stale_buttons,&stale_flags,&stamp));
    assert(stale_buttons==0 && stale_flags==0);
    pause.store(false);
    auto deadline=now_ns()+1000000000;
    while(!meteor_tracking_pose_v1(client,int64_t(now_ns()),pose,&stamp) && now_ns()<deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(meteor_tracking_pose_v1(client,int64_t(now_ns()),pose,&stamp));
    disconnect.store(true);
    server.join();
    deadline=now_ns()+1000000000;
    while(!static_cast<Client *>(client)->failed.load() && now_ns()<deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(!meteor_tracking_pose_v1(client,int64_t(now_ns()),pose,&stamp));
    const auto stopped=now_ns(); meteor_tracking_stop_v1(client);
    assert(now_ns()-stopped<1000000000);
    closesocket(listener); WSACleanup();
    std::puts("PASS: clock mapping, poses, both controller inputs, bounded haptic ACKs, stale rejection, recovery and disconnect");
}
