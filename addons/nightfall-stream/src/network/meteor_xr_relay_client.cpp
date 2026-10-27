#include "meteor_xr_relay_client.h"
#if defined(__linux__) || defined(__ANDROID__)
#include <cerrno>
#include <chrono>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace godot;
namespace {
int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
} // namespace
bool MeteorXrRelayClient::start(const Config &config) {
  stop();
  if (config.address.empty() || !config.video || !config.tracking ||
      !config.local_video || !config.local_tracking ||
      std::all_of(config.session.begin(), config.session.end(),
                  [](uint8_t v) { return v == 0; }))
    return false;
  config_ = config;
  stopping_ = false;
  failure_ = false;
  completed_ = 0;
  connected_ = 0;
  if (pthread_create(
          &video_, nullptr,
          [](void *owner) -> void * {
            static_cast<MeteorXrRelayClient *>(owner)->run(true);
            return nullptr;
          },
          this) != 0) {
    failure_ = true;
    stop();
    completed_ = 2;
    return false;
  }
  video_started_ = true;
  if (pthread_create(
          &tracking_, nullptr,
          [](void *owner) -> void * {
            static_cast<MeteorXrRelayClient *>(owner)->run(false);
            return nullptr;
          },
          this) != 0) {
    failure_ = true;
    stop();
    completed_ = 2;
    return false;
  }
  tracking_started_ = true;
  return true;
}
void MeteorXrRelayClient::interrupt() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (int fd : sockets_)
    shutdown(fd, SHUT_RDWR);
}
void MeteorXrRelayClient::stop() {
  stopping_ = true;
  interrupt();
  if (video_started_) {
    pthread_join(video_, nullptr);
    video_started_ = false;
  }
  if (tracking_started_) {
    pthread_join(tracking_, nullptr);
    tracking_started_ = false;
  }
  std::fill(config_.identity.begin(), config_.identity.end(), 0);
}
void MeteorXrRelayClient::close(int fd) {
  if (fd < 0)
    return;
  std::lock_guard<std::mutex> lock(mutex_);
  sockets_.erase(std::remove(sockets_.begin(), sockets_.end(), fd),
                 sockets_.end());
  ::close(fd);
}
int MeteorXrRelayClient::connect(const std::string &address, uint16_t port) {
  addrinfo hints{};
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
  addrinfo *resolved = nullptr;
  auto service = std::to_string(port);
  if (getaddrinfo(address.c_str(), service.c_str(), &hints, &resolved))
    return -1;
  int fd = socket(resolved->ai_family,
                  SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    freeaddrinfo(resolved);
    return -1;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    sockets_.push_back(fd);
  }
  int result = ::connect(fd, resolved->ai_addr, resolved->ai_addrlen);
  freeaddrinfo(resolved);
  if (result < 0 && errno != EINPROGRESS) {
    close(fd);
    return -1;
  }
  const int64_t deadline = now_ms() + 5000;
  while (result < 0 && !stopping_ && now_ms() < deadline) {
    pollfd item{fd, POLLOUT, 0};
    int ready = poll(&item, 1, 20);
    if (ready < 0 && errno == EINTR)
      continue;
    if (ready <= 0)
      continue;
    int error = 0;
    socklen_t length = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) || error)
      break;
    result = 0;
  }
  if (result < 0 || stopping_) {
    close(fd);
    return -1;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  return fd;
}
bool MeteorXrRelayClient::io(int fd, uint8_t *bytes, size_t length,
                             bool writing, int timeout_ms) {
  const int64_t deadline = now_ms() + timeout_ms;
  while (length && !stopping_ && now_ms() < deadline) {
    pollfd item{fd, short(writing ? POLLOUT : POLLIN), 0};
    int ready = poll(&item, 1, 20);
    if (ready < 0 && errno == EINTR)
      continue;
    if (ready < 0)
      return false;
    if (!ready)
      continue;
    auto count = writing ? send(fd, bytes, length, MSG_NOSIGNAL)
                         : recv(fd, bytes, length, 0);
    if (count < 0 &&
        (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
      continue;
    if (count <= 0)
      return false;
    bytes += count;
    length -= size_t(count);
  }
  return length == 0;
}
void MeteorXrRelayClient::run(bool video) {
  using Secure = MeteorXrDataCipher;
  int remote = -1, local = -1;
  bool success = [&]() {
    remote = connect(config_.address, video ? config_.video : config_.tracking);
    if (remote < 0)
      return false;
    std::array<uint8_t, 32> binding{};
    if (!io(remote, binding.data(), binding.size(), false))
      return false;
    Secure attach, tx, rx;
    auto init = [&](Secure &cipher, Secure::Kind kind) {
      return cipher.init(config_.host, config_.identity, config_.server_nonce,
                         config_.client_nonce, config_.session, kind, &binding);
    };
    if (!init(attach, video ? Secure::Kind::AttachVideo
                            : Secure::Kind::AttachTracking) ||
        !init(tx, video ? Secure::Kind::VideoFeedback
                        : Secure::Kind::HeadsetTracking) ||
        !init(rx, video ? Secure::Kind::Video : Secure::Kind::HostTracking))
      return false;
    std::vector<uint8_t> proof(32), encrypted;
    memcpy(proof.data(), "NFXB", 4);
    proof[4] = video ? 1 : 2;
    std::copy(config_.session.begin(), config_.session.end(),
              proof.begin() + 8);
    if (!attach.seal(proof, encrypted) ||
        !io(remote, encrypted.data(), encrypted.size(), true))
      return false;
    bool first = true;
    for (;;) {
      std::array<uint8_t, Secure::HEADER> header{};
      if (!io(remote, header.data(), header.size(), false,
              first ? 45000 : 5000))
        return false;
      first = false;
      size_t size = 0;
      if (!rx.payload_length(header, size))
        return false;
      std::vector<uint8_t> body(size), plain;
      if (!io(remote, body.data(), body.size(), false) ||
          !rx.open(header, std::move(body), plain))
        return false;
      if (video) {
        if (plain.size() < 152 || memcmp(plain.data(), "NFXR", 4))
          return false;
      } else if (plain.size() != 32)
        return false;
      // Attach only when authenticated traffic is ready, so local endpoint
      // read deadlines do not include host compilation/import startup time.
      if (local < 0) {
        const int64_t deadline = now_ms() + 5000;
        while (!stopping_ && now_ms() < deadline && local < 0) {
          local = connect("127.0.0.1",
                          video ? config_.local_video : config_.local_tracking);
          if (local < 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        if (local < 0)
          return false;
        ++connected_;
      }
      if (!io(local, plain.data(), plain.size(), true))
        return false;
      bool end = false;
      size_t response = 0;
      if (video) {
        end = plain[50] != 0;
        response = end ? 12 : 20;
      } else {
        if (!memcmp(plain.data(), "NFXQ", 4))
          return true;
        if (!memcmp(plain.data(), "NFXP", 4))
          response = 64;
        else if (!memcmp(plain.data(), "NFXO", 4))
          response = 112;
        else if (!memcmp(plain.data(), "NFXJ", 4))
          response = 192;
        else if (!memcmp(plain.data(), "NFXC", 4) ||
                 !memcmp(plain.data(), "NFXH", 4))
          response = 32;
        else
          return false;
      }
      std::vector<uint8_t> feedback(response);
      if (!io(local, feedback.data(), feedback.size(), false) ||
          !tx.seal(feedback, encrypted) ||
          !io(remote, encrypted.data(), encrypted.size(), true))
        return false;
      if (end)
        return true;
    }
  }();
  close(remote);
  close(local);
  if (!success && !stopping_) {
    failure_ = true;
    stopping_ = true;
    interrupt();
  }
  ++completed_;
}
#endif
