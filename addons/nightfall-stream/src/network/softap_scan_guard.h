#pragma once

#include <mutex>
#include <string>
#include <vector>

// Keeps Wi-Fi background scans off the stream's radio while a stream runs.
//
// On the Steam Frame one Wi-Fi chip carries both the home network (wlan0)
// and the hotspot for the PC wireless adapter (wlanap). A scan on either
// interface takes the shared radio off-channel for a moment, which shows up
// as a few seconds of stutter. SteamOS's softapmanager can pin scans to the
// channels in use (cfg80211_block_scans) while a stream runs; Steam's own
// streaming client asks for that through softapmanager's streaming socket,
// and this class does the same for Nightfall.
//
// Protocol (softapmanager, SteamOS 0.5.x): connect to
// /run/softapmanager.streaming.socket and send "streamon\t<ifname>\n" for
// each interface to protect. The protection lasts while the connection stays
// open; closing it clears everything, so a crashed client can't leave scans
// blocked. softapmanager serves one connection at a time and reads one
// message per read() call, so messages must not arrive together.
//
// Everything here is best effort: on systems without softapmanager (any
// normal Linux PC) start() finds no socket and does nothing.
class SoftapScanGuard {
public:
    SoftapScanGuard() = default;
    ~SoftapScanGuard();
    SoftapScanGuard(const SoftapScanGuard &) = delete;
    SoftapScanGuard &operator=(const SoftapScanGuard &) = delete;

    // remotes: the host addresses the stream uses (numeric IPv4/IPv6, the
    // multipath second path included). Empty entries are ignored.
    void start(const std::vector<std::string> &remotes);
    void stop();

    // Interfaces to protect for a set of outgoing interfaces: every wireless
    // one, plus the other wireless interfaces on the same radio (a scan on a
    // sibling interface leaves the shared channel too). Exposed for tests;
    // sysfs_net is normally "/sys/class/net".
    static std::vector<std::string> interfaces_to_protect(
            const std::vector<std::string> &egress, const std::string &sysfs_net);

private:
    std::mutex mutex_;
    int fd_ = -1;
};
