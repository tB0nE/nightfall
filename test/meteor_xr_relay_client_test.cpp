// Exercises the production native workers with existing wire consumers.
#include "network/meteor_xr_relay_client.h"
#include "pcvr_meteor_tracking.h"
#include <arpa/inet.h>
#include <cassert>
#include <iostream>
#include <sys/socket.h>
#include <unistd.h>

static void io(int fd, uint8_t *bytes, size_t length, bool writing) {
  while (length) {
    auto n = writing ? send(fd, bytes, length, MSG_NOSIGNAL)
                     : recv(fd, bytes, length, 0);
    assert(n > 0);
    bytes += n;
    length -= n;
  }
}
static int listener(uint16_t &port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  assert(fd >= 0);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  assert(bind(fd, reinterpret_cast<sockaddr *>(&a), sizeof(a)) == 0 &&
         listen(fd, 1) == 0);
  socklen_t size = sizeof(a);
  assert(getsockname(fd, reinterpret_cast<sockaddr *>(&a), &size) == 0);
  port = ntohs(a.sin_port);
  return fd;
}
int main(int argc, char **argv) {
  assert(argc == 3 || argc == 4);
  godot::MeteorXrRelayClient::Config config;
  config.address = "127.0.0.1";
  config.video = std::stoi(argv[1]);
  config.tracking = std::stoi(argv[2]);
  std::array<uint8_t, 32> seed;
  seed.fill(1);
  config.identity.fill(2);
  config.server_nonce.fill(3);
  config.client_nonce.fill(4);
  config.session.fill(5);
  assert(godot::MeteorCipher::identity_public(seed.data(), config.host.data()));
  int video_listener = listener(config.local_video), tracking_listener = -1;
  if (argc == 4)
    config.local_tracking = std::stoi(argv[3]);
  else
    tracking_listener = listener(config.local_tracking);
  std::thread decoder([&] {
    int fd = accept(video_listener, nullptr, nullptr);
    assert(fd >= 0);
    MeteorXrWire wire;
    for (;;) {
      std::array<uint8_t, 152> header;
      io(fd, header.data(), header.size(), false);
      MeteorXrFrame frame;
      assert(wire.header(header, frame));
      std::vector<uint8_t> payload(frame.bytes);
      io(fd, payload.data(), payload.size(), false);
      assert(wire.accept(frame, payload));
      std::vector<uint8_t> ack(frame.end ? 12 : 20);
      memcpy(ack.data(), frame.end ? "NFXE" : "NFXA", 4);
      meteor_xr_put(ack.data() + 4, frame.sequence, 8);
      if (!frame.end)
        meteor_xr_put(ack.data() + 12, frame.id, 8);
      io(fd, ack.data(), ack.size(), true);
      if (frame.end)
        break;
    }
    close(fd);
    close(video_listener);
  });
  std::thread endpoint;
  if (tracking_listener >= 0)
    endpoint = std::thread([&] {
      int fd = accept(tracking_listener, nullptr, nullptr);
      assert(fd >= 0);
      uint64_t sequence = 0;
      for (;;) {
        std::array<uint8_t, 32> request;
        io(fd, request.data(), request.size(), false);
        if (!memcmp(request.data(), "NFXQ", 4))
          break;
        assert(!memcmp(request.data(), "NFXP", 4));
        MeteorTrackingSample sample;
        sample.epoch = 9;
        sample.sequence = sequence++;
        sample.client_ns = sequence * 1000;
        auto response = MeteorTrackingWire::encode(sample);
        io(fd, response.data(), response.size(), true);
      }
      close(fd);
      close(tracking_listener);
    });
  godot::MeteorXrRelayClient client;
  assert(client.start(config));
  auto deadline = std::chrono::steady_clock::now() +
                  std::chrono::seconds(argc == 4 ? 50 : 15);
  while (!client.idle() && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  assert(client.idle() && !client.failed() && client.connected_lanes() == 2);
  client.stop();
  decoder.join();
  if (endpoint.joinable())
    endpoint.join();
  std::cout
      << "PASS native workers / lease-owned relay / existing wire consumers\n";
}
