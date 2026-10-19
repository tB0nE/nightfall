#include "pcvr_meteor_tracking_endpoint.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>

uint64_t MeteorTrackingEndpoint::now_ns() {
    return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
MeteorTrackingEndpoint::~MeteorTrackingEndpoint() {
    request_stop(); if (worker.joinable()) worker.join();
}
bool MeteorTrackingEndpoint::start(uint16_t port) {
    if (!done.load() || !port) return false;
    if (worker.joinable()) worker.join();
    stopping.store(false); done.store(false); error.store(false); ready.store(false);
    { std::lock_guard<std::mutex> lock(mutex); latest = {}; }
    worker = std::thread(&MeteorTrackingEndpoint::run, this, port); return true;
}
void MeteorTrackingEndpoint::publish(const MeteorTrackingSample &sample) {
    std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
    if (lock.owns_lock()) latest = sample;
}
bool MeteorTrackingEndpoint::io(int fd, void *bytes, size_t size, bool writing, uint64_t deadline) {
    auto *cursor = static_cast<uint8_t *>(bytes);
    while (size && !stopping.load() && now_ns() < deadline) {
        pollfd p{fd, short(writing ? POLLOUT : POLLIN), 0};
        int result = poll(&p, 1, 10);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return false;
        if (!result) continue;
        auto count = writing ? send(fd, cursor, size, MSG_NOSIGNAL) : recv(fd, cursor, size, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return false;
        cursor += count; size -= size_t(count);
    }
    return !size;
}
void MeteorTrackingEndpoint::run(uint16_t port) {
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    int peer = -1; bool clean = false;
    do {
        if (listener < 0) break;
        int one = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in address{}; address.sin_family = AF_INET;
        address.sin_port = htons(port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) || listen(listener,1)) break;
        ready.store(true);
        while (!stopping.load()) {
            pollfd p{listener, POLLIN, 0};
            if (poll(&p,1,10) <= 0) continue;
            peer = accept4(listener,nullptr,nullptr,SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (peer >= 0) break;
        }
        if (peer < 0) break;
        setsockopt(peer, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        uint64_t sequence = 0, last_ns = 0, input_sequence=0, last_input_ns=0;
        while (!stopping.load()) {
            std::array<uint8_t,32> request{};
            uint64_t deadline = now_ns()+2000000000;
            if (!io(peer,request.data(),request.size(),false,deadline)) break;
            uint64_t received = now_ns();
            if (meteor_xr_le(request.data()+4,2) != 1 || meteor_xr_le(request.data()+6,2) != 32) break;
            bool reserved = false;
            for (size_t i=16;i<32;++i) reserved |= request[i] != 0;
            if (reserved) break;
            if (!std::memcmp(request.data(),"NFXQ",4)) { clean = true; break; }
            if (!std::memcmp(request.data(),"NFXC",4)) {
                if (!meteor_xr_le(request.data()+8,8)) break;
                meteor_xr_put(request.data()+16,received,8);
                meteor_xr_put(request.data()+24,now_ns(),8);
                if (!io(peer,request.data(),request.size(),true,deadline)) break;
            } else if (!std::memcmp(request.data(),"NFXO",4)) {
                MeteorTrackingSample sample;
                while(!stopping.load() && now_ns()<deadline) {
                    { std::lock_guard<std::mutex> lock(mutex); sample=latest; }
                    uint64_t now=now_ns();
                    if(sample.epoch && sample.optics.epoch==sample.epoch && MeteorOpticsWire::valid(sample.optics) &&
                        sample.client_ns<=now && now-sample.client_ns<=250000000) break;
                    sample.epoch=0;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if(!sample.epoch) break;
                auto packet=MeteorOpticsWire::encode(sample.optics);
                if(!io(peer,packet.data(),packet.size(),true,deadline)) break;
            } else if (!std::memcmp(request.data(),"NFXI",4)) {
                MeteorTrackingSample sample;
                while(!stopping.load() && now_ns()<deadline) {
                    { std::lock_guard<std::mutex> lock(mutex); sample=latest; }
                    uint64_t now=now_ns();
                    if(sample.epoch && sample.controllers.epoch==sample.epoch &&
                        sample.controllers.client_ns>last_input_ns && sample.controllers.client_ns<=now &&
                        now-sample.controllers.client_ns<=250000000 && MeteorControllerWire::valid(sample.controllers)) break;
                    sample.epoch=0; std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if(!sample.epoch || input_sequence==UINT64_MAX) break;
                sample.controllers.sequence=input_sequence++;
                auto packet=MeteorControllerWire::encode(sample.controllers);
                if(!io(peer,packet.data(),packet.size(),true,deadline)) break;
                last_input_ns=sample.controllers.client_ns;
            } else if (!std::memcmp(request.data(),"NFXP",4)) {
                MeteorTrackingSample sample;
                while (!stopping.load() && now_ns() < deadline) {
                    { std::lock_guard<std::mutex> lock(mutex); sample = latest; }
                    uint64_t now = now_ns();
                    if (sample.epoch && sample.client_ns > last_ns && sample.client_ns <= now && now-sample.client_ns <= 250000000) break;
                    sample.epoch = 0;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if (!sample.epoch || sequence == UINT64_MAX) break;
                sample.sequence = sequence++;
                auto packet = MeteorTrackingWire::encode(sample);
                if (!io(peer,packet.data(),packet.size(),true,deadline)) break;
                last_ns = sample.client_ns;
            } else break;
        }
    } while (false);
    if (peer >= 0) close(peer);
    if (listener >= 0) close(listener);
    ready.store(false); error.store(!clean && !stopping.load()); done.store(true);
}
