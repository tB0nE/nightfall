#include "pcvr_meteor_receiver.h"
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <thread>
int main(int argc, char **argv) {
    std::setvbuf(stdout,nullptr,_IOLBF,0);
    int frames = argc > 1 ? std::atoi(argv[1]) : 32;
    int eye_size = argc > 2 ? std::atoi(argv[2]) : 256;
    if(frames < 1 || frames > 240) return 2;
    if(eye_size!=256 && eye_size!=512) return 2;
    PCVRMeteorReceiver receiver;
    if(!receiver.start()) return 1;
    bool ready=false, passed=false; uint64_t last_sequence=UINT64_MAX; unsigned acquired=0;
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    while(std::chrono::steady_clock::now()<deadline && !receiver.failed()) {
        std::string status=receiver.message();
        if(!ready && status.find("Listening")!=std::string::npos) { std::puts("READY loopback 49090"); ready=true; }
        AHardwareBuffer *buffer=nullptr; MeteorXrFrame metadata;
        if(receiver.frame(buffer,metadata)) {
            AHardwareBuffer_Desc desc{}; AHardwareBuffer_describe(buffer,&desc);
            if(desc.width!=unsigned(eye_size*2) || desc.height!=unsigned(eye_size) || metadata.sequence!=acquired) break;
            last_sequence=metadata.sequence; ++acquired;
            std::printf("BUFFER seq=%llu frame=%llu host_ns=%llu size=%ux%u\n",(unsigned long long)metadata.sequence,(unsigned long long)metadata.id,(unsigned long long)metadata.display_ns,desc.width,desc.height);
            receiver.release_frame();
        }
        if(status.find("holding final picture")!=std::string::npos && last_sequence==uint64_t(frames-1) && acquired==unsigned(frames)) { passed=true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if(!passed) std::fprintf(stderr,"Decoder test failed: %s\n",receiver.message().c_str());
    receiver.release_frame(); receiver.stop_after_gpu_drain();
    auto drain=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while(!receiver.idle() && std::chrono::steady_clock::now()<drain) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    if(!receiver.idle()) { std::fprintf(stderr,"Decoder teardown timeout\n"); std::_Exit(1); }
    std::printf("%s acquired=%u final_sequence=%llu (decoder/image path only; no XR presentation)\n",passed ? "PASS" : "FAIL",acquired,(unsigned long long)last_sequence);
    return passed ? 0 : 1;
}
