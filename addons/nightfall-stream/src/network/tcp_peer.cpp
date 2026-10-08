#include "tcp_peer.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#ifndef _WIN32
#include <cerrno>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

using namespace godot;

NightfallTcpPeer::~NightfallTcpPeer() {
    disconnect_from_host();
}

#ifndef _WIN32

int NightfallTcpPeer::connect_to_host(const String &host, int port) {
    disconnect_from_host();
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo *found = nullptr;
    // getaddrinfo reads the zone of "fe80::1%usb0" into sin6_scope_id.
    if (getaddrinfo(host.utf8().get_data(), String::num_int64(port).utf8().get_data(), &hints, &found) != 0 || !found) {
        return ERR_CANT_RESOLVE;
    }
    fd_ = ::socket(found->ai_family, found->ai_socktype, found->ai_protocol);
    if (fd_ < 0) {
        freeaddrinfo(found);
        return ERR_CANT_CREATE;
    }
    fcntl(fd_, F_SETFL, fcntl(fd_, F_GETFL, 0) | O_NONBLOCK);
    int result = ::connect(fd_, found->ai_addr, found->ai_addrlen);
    freeaddrinfo(found);
    if (result == 0) {
        status_ = STATUS_CONNECTED;
    } else if (errno == EINPROGRESS) {
        status_ = STATUS_CONNECTING;
    } else {
        disconnect_from_host();
        status_ = STATUS_ERROR;
        return ERR_CANT_CONNECT;
    }
    return OK;
}

void NightfallTcpPeer::poll() {
    if (status_ == STATUS_CONNECTING) {
        pollfd p{fd_, POLLOUT, 0};
        if (::poll(&p, 1, 0) <= 0) return;
        int err = 0;
        socklen_t len = sizeof(err);
        getsockopt(fd_, SOL_SOCKET, SO_ERROR, &err, &len);
        status_ = err == 0 ? STATUS_CONNECTED : STATUS_ERROR;
    } else if (status_ == STATUS_CONNECTED) {
        // Readable with nothing to read means the other end closed.
        pollfd p{fd_, POLLIN, 0};
        char probe;
        if (::poll(&p, 1, 0) > 0 && (p.revents & (POLLERR | POLLHUP) || recv(fd_, &probe, 1, MSG_PEEK) == 0)) {
            status_ = STATUS_ERROR;
        }
    }
}

void NightfallTcpPeer::set_no_delay(bool enabled) {
    if (fd_ < 0) return;
    int value = enabled ? 1 : 0;
    setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &value, sizeof(value));
}

int NightfallTcpPeer::get_available_bytes() const {
    if (status_ != STATUS_CONNECTED) return 0;
    int available = 0;
    return ioctl(fd_, FIONREAD, &available) == 0 ? available : 0;
}

Array NightfallTcpPeer::get_partial_data(int bytes) {
    Array result;
    PackedByteArray data;
    if (status_ != STATUS_CONNECTED || bytes <= 0) {
        result.append(status_ == STATUS_CONNECTED ? OK : ERR_UNCONFIGURED);
        result.append(data);
        return result;
    }
    data.resize(bytes);
    ssize_t got = recv(fd_, data.ptrw(), bytes, 0);
    if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        got = 0;
    } else if (got <= 0) {
        // 0 is the other end closing (callers only read what's available).
        status_ = STATUS_ERROR;
        result.append(ERR_FILE_EOF);
        result.append(PackedByteArray());
        return result;
    }
    data.resize(static_cast<int64_t>(got));
    result.append(OK);
    result.append(data);
    return result;
}

void NightfallTcpPeer::disconnect_from_host() {
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
    status_ = STATUS_NONE;
}

#else

int NightfallTcpPeer::connect_to_host(const String &, int) {
    return ERR_UNAVAILABLE;
}
void NightfallTcpPeer::poll() {}
void NightfallTcpPeer::set_no_delay(bool) {}
int NightfallTcpPeer::get_available_bytes() const { return 0; }
Array NightfallTcpPeer::get_partial_data(int) {
    Array result;
    result.append(ERR_UNAVAILABLE);
    result.append(PackedByteArray());
    return result;
}
void NightfallTcpPeer::disconnect_from_host() {}

#endif

void NightfallTcpPeer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("connect_to_host", "host", "port"), &NightfallTcpPeer::connect_to_host);
    ClassDB::bind_method(D_METHOD("poll"), &NightfallTcpPeer::poll);
    ClassDB::bind_method(D_METHOD("get_status"), &NightfallTcpPeer::get_status);
    ClassDB::bind_method(D_METHOD("set_no_delay", "enabled"), &NightfallTcpPeer::set_no_delay);
    ClassDB::bind_method(D_METHOD("get_available_bytes"), &NightfallTcpPeer::get_available_bytes);
    ClassDB::bind_method(D_METHOD("get_partial_data", "bytes"), &NightfallTcpPeer::get_partial_data);
    ClassDB::bind_method(D_METHOD("disconnect_from_host"), &NightfallTcpPeer::disconnect_from_host);
}
