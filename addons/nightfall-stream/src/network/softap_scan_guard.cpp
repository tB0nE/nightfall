#include "softap_scan_guard.h"

#include "../nf_log.h"

#if defined(__linux__) && !defined(__ANDROID__)

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <thread>

namespace {

constexpr const char *kStreamingSocket = "/run/softapmanager.streaming.socket";
constexpr const char *kTag = "SCAN-GUARD";

bool same_address(const sockaddr *a, const sockaddr *b) {
    if (!a || !b || a->sa_family != b->sa_family) return false;
    if (a->sa_family == AF_INET) {
        return reinterpret_cast<const sockaddr_in *>(a)->sin_addr.s_addr ==
               reinterpret_cast<const sockaddr_in *>(b)->sin_addr.s_addr;
    }
    if (a->sa_family == AF_INET6) {
        return std::memcmp(&reinterpret_cast<const sockaddr_in6 *>(a)->sin6_addr,
                           &reinterpret_cast<const sockaddr_in6 *>(b)->sin6_addr,
                           sizeof(in6_addr)) == 0;
    }
    return false;
}

// The interface the kernel would send to `remote` from. A connected UDP
// socket picks the route without sending anything.
std::string egress_interface(const std::string &remote) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    addrinfo *res = nullptr;
    if (getaddrinfo(remote.c_str(), "9", &hints, &res) != 0 || !res) return {};

    std::string name;
    int s = socket(res->ai_family, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s >= 0) {
        sockaddr_storage local{};
        socklen_t len = sizeof(local);
        if (connect(s, res->ai_addr, res->ai_addrlen) == 0 &&
            getsockname(s, reinterpret_cast<sockaddr *>(&local), &len) == 0) {
            ifaddrs *ifs = nullptr;
            if (getifaddrs(&ifs) == 0) {
                for (ifaddrs *i = ifs; i; i = i->ifa_next) {
                    if (same_address(i->ifa_addr, reinterpret_cast<sockaddr *>(&local))) {
                        name = i->ifa_name;
                        break;
                    }
                }
                freeifaddrs(ifs);
            }
        }
        close(s);
    }
    freeaddrinfo(res);
    return name;
}

// Target of /sys/class/net/<ifname>/phy80211 ("" for non-wireless interfaces).
std::string radio_of(const std::string &sysfs_net, const std::string &ifname) {
    char buf[PATH_MAX];
    std::string link = sysfs_net + "/" + ifname + "/phy80211";
    ssize_t n = readlink(link.c_str(), buf, sizeof(buf) - 1);
    if (n <= 0) return {};
    buf[n] = '\0';
    const char *slash = std::strrchr(buf, '/');
    return slash ? std::string(slash + 1) : std::string(buf);
}

bool send_all(int fd, const std::string &msg) {
    size_t off = 0;
    while (off < msg.size()) {
        ssize_t n = send(fd, msg.data() + off, msg.size() - off, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

} // namespace

std::vector<std::string> SoftapScanGuard::interfaces_to_protect(
        const std::vector<std::string> &egress, const std::string &sysfs_net) {
    std::vector<std::string> radios;
    for (const auto &ifname : egress) {
        std::string radio = radio_of(sysfs_net, ifname);
        if (!radio.empty() && std::find(radios.begin(), radios.end(), radio) == radios.end()) {
            radios.push_back(radio);
        }
    }

    std::vector<std::string> out;
    if (radios.empty()) return out;

    // Interfaces the stream uses come first, then their radio siblings.
    auto add = [&](const std::string &ifname) {
        if (std::find(out.begin(), out.end(), ifname) == out.end()) out.push_back(ifname);
    };
    for (const auto &ifname : egress) {
        if (!radio_of(sysfs_net, ifname).empty()) add(ifname);
    }
    ifaddrs *ifs = nullptr;
    if (getifaddrs(&ifs) == 0) {
        for (ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_name || !(i->ifa_flags & IFF_UP)) continue;
            std::string radio = radio_of(sysfs_net, i->ifa_name);
            if (!radio.empty() && std::find(radios.begin(), radios.end(), radio) != radios.end()) {
                add(i->ifa_name);
            }
        }
        freeifaddrs(ifs);
    }
    return out;
}

SoftapScanGuard::~SoftapScanGuard() {
    stop();
}

void SoftapScanGuard::start(const std::vector<std::string> &remotes) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }

    struct stat st{};
    if (stat(kStreamingSocket, &st) != 0 || !S_ISSOCK(st.st_mode)) return;

    std::vector<std::string> egress;
    for (const auto &remote : remotes) {
        if (remote.empty()) continue;
        std::string ifname = egress_interface(remote);
        if (!ifname.empty() && std::find(egress.begin(), egress.end(), ifname) == egress.end()) {
            egress.push_back(ifname);
        }
    }
    std::vector<std::string> ifnames = interfaces_to_protect(egress, "/sys/class/net");
    if (ifnames.empty()) {
        NF_LOG(kTag, "No Wi-Fi interface carries the stream; scans left alone");
        return;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, kStreamingSocket, sizeof(addr.sun_path) - 1);
    if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        NF_LOGE(kTag, "Can't reach softapmanager: %s", std::strerror(errno));
        close(fd);
        return;
    }

    // softapmanager handles one message per read and drops anything after the
    // first newline, so messages that arrive together lose all but the first.
    // A short gap keeps them in separate reads (Steam sends them seconds apart).
    std::string joined;
    for (const auto &ifname : ifnames) {
        if (!joined.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(250));
        if (!send_all(fd, "streamon\t" + ifname + "\n")) {
            NF_LOGE(kTag, "softapmanager didn't take streamon for %s", ifname.c_str());
            close(fd);
            return;
        }
        joined += (joined.empty() ? "" : ", ") + ifname;
    }
    fd_ = fd;
    NF_LOG(kTag, "Wi-Fi scans held to the stream's channels on %s", joined.c_str());
}

void SoftapScanGuard::stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (fd_ < 0) return;
    // Closing the connection is what clears the block; no streamoff needed.
    close(fd_);
    fd_ = -1;
    NF_LOG(kTag, "Wi-Fi scans released");
}

#else // not desktop Linux

SoftapScanGuard::~SoftapScanGuard() = default;
void SoftapScanGuard::start(const std::vector<std::string> &) {}
void SoftapScanGuard::stop() {}
std::vector<std::string> SoftapScanGuard::interfaces_to_protect(
        const std::vector<std::string> &, const std::string &) {
    return {};
}

#endif
