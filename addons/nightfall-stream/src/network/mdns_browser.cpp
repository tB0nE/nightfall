#include "mdns_browser.h"
#include "nf_log.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <poll.h>
#include <net/if.h>

using namespace godot;

MdnsBrowser::MdnsBrowser() {}
MdnsBrowser::~MdnsBrowser() {}

PackedByteArray MdnsBrowser::_build_ptr_query(const String &service_type) {
    PackedByteArray buf;
    buf.resize(512);
    uint8_t *p = (uint8_t *)buf.ptrw();

    p[0] = 0x00; p[1] = 0x00;
    p[2] = 0x00; p[3] = 0x00;
    p[4] = 0x00; p[5] = 0x01;
    p[6] = 0x00; p[7] = 0x00;
    p[8] = 0x00; p[9] = 0x00;
    p[10] = 0x00; p[11] = 0x00;

    int offset = 12;
    offset = _write_dns_name(p, offset, service_type);
    if (offset < 0) {
        return PackedByteArray();
    }

    p[offset++] = 0x00; p[offset++] = 0x0C;
    p[offset++] = 0x80; p[offset++] = 0x01;

    buf.resize(offset);
    return buf;
}

int MdnsBrowser::_write_dns_name(uint8_t *buf, int offset, const String &name) {
    CharString cs = name.utf8();
    const char *str = cs.get_data();
    const char *dot = str;

    while (*dot) {
        const char *next = strchr(dot, '.');
        int seg_len = next ? (int)(next - dot) : (int)strlen(dot);
        if (seg_len > 63 || offset + 1 + seg_len > 500) return -1;
        buf[offset++] = (uint8_t)seg_len;
        memcpy(buf + offset, dot, seg_len);
        offset += seg_len;
        if (next) {
            dot = next + 1;
        } else {
            break;
        }
    }
    buf[offset++] = 0x00;
    return offset;
}

String MdnsBrowser::_read_dns_name(const uint8_t *data, int len, int offset, int &out_end) {
    String result;
    int jumped = -1;
    int pos = offset;
    int hops = 0;

    while (pos < len && hops < 128) {
        uint8_t b = data[pos];
        if (b == 0) {
            if (jumped < 0) out_end = pos + 1;
            break;
        }
        if ((b & 0xC0) == 0xC0) {
            if (pos + 1 >= len) break;
            if (jumped < 0) out_end = pos + 2;
            pos = ((b & 0x3F) << 8) | data[pos + 1];
            jumped = 1;
            hops++;
            continue;
        }
        int seg_len = b & 0x3F;
        if (pos + 1 + seg_len > len) break;
        if (result.length() > 0) result += ".";
        for (int i = 0; i < seg_len; i++) {
            result += String::chr(data[pos + 1 + i]);
        }
        pos += 1 + seg_len;
        hops++;
    }
    if (jumped < 0) out_end = pos + 1;
    return result;
}

Array MdnsBrowser::_parse_dns_response(const uint8_t *data, int len, bool want_v6) {
    Array hosts;

    if (len < 12) return hosts;

    int qdcount = (data[4] << 8) | data[5];
    int ancount = (data[6] << 8) | data[7];

    int offset = 12;

    for (int i = 0; i < qdcount && offset < len; i++) {
        int end = 0;
        _read_dns_name(data, len, offset, end);
        offset = end;
        offset += 4;
    }

    Dictionary ptr_targets;
    Dictionary srv_records;
    Dictionary a_records;
    Dictionary aaaa_records;
    Dictionary txt_records;

    for (int i = 0; i < ancount && offset < len; i++) {
        int name_end = 0;
        String name = _read_dns_name(data, len, offset, name_end);
        offset = name_end;

        if (offset + 10 > len) break;

        int rtype = (data[offset] << 8) | data[offset + 1];
        int rdlength = (data[offset + 8] << 8) | data[offset + 9];
        offset += 10;

        if (offset + rdlength > len) break;

        if (rtype == 12) {
            int target_end = 0;
            String target = _read_dns_name(data, len, offset, target_end);
            ptr_targets[name] = target;
        } else if (rtype == 33) {
            if (rdlength >= 6) {
                int port = (data[offset + 4] << 8) | data[offset + 5];
                int target_end = 0;
                String target = _read_dns_name(data, len, offset + 6, target_end);
                Dictionary srv;
                srv["port"] = port;
                srv["target"] = target;
                srv_records[name] = srv;
            }
        } else if (rtype == 1) {
            if (rdlength == 4) {
                String ip = String::num_int64(data[offset]) + "." +
                        String::num_int64(data[offset + 1]) + "." +
                        String::num_int64(data[offset + 2]) + "." +
                        String::num_int64(data[offset + 3]);
                a_records[name.to_lower()] = ip;
            }
        } else if (rtype == 28) {
            if (rdlength == 16) {
                char buf[INET6_ADDRSTRLEN];
                if (inet_ntop(AF_INET6, data + offset, buf, sizeof(buf))) {
                    String addr(buf);
                    // A host announces several AAAA records; for the link,
                    // the link-local one is the one guaranteed reachable.
                    String key = name.to_lower();
                    if (!aaaa_records.has(key) || addr.to_lower().begins_with("fe80:") == want_v6) {
                        aaaa_records[key] = addr;
                    }
                }
            }
        } else if (rtype == 16) {
            Dictionary txt;
            int pos = offset;
            int end_pos = offset + rdlength;
            while (pos < end_pos) {
                int tlen = data[pos++];
                if (tlen == 0 || pos + tlen > end_pos) break;
                String kv;
                kv.resize(tlen);
                for (int j = 0; j < tlen; j++) {
                    kv[j] = (char32_t)data[pos + j];
                }
                int eq = kv.find("=");
                if (eq > 0) {
                    txt[kv.substr(0, eq)] = kv.substr(eq + 1);
                }
                pos += tlen;
            }
            txt_records[name] = txt;
        }

        offset += rdlength;
    }

    Array ptr_keys = ptr_targets.keys();
    for (int i = 0; i < ptr_keys.size(); i++) {
        String ptr_name = ptr_keys[i];
        String instance_name = ptr_targets[ptr_name];

        Dictionary host;
        host["instance"] = instance_name;

        if (srv_records.has(instance_name)) {
            Dictionary srv = srv_records[instance_name];
            host["port"] = srv["port"];
            String target = srv["target"];
            String target_lower = target.to_lower();
            String short_target = target_lower.replace(".local.", "").replace(".local", "");
            auto lookup = [&](const Dictionary &records) -> String {
                if (records.has(target_lower)) return records[target_lower];
                if (records.has(short_target)) return records[short_target];
                return String();
            };
            String ip;
            if (want_v6) {
                ip = lookup(aaaa_records);
            } else {
                ip = lookup(a_records);
                if (ip.is_empty()) {
                    // A zone-less link-local address is unusable off the USB path.
                    String v6 = lookup(aaaa_records);
                    if (!v6.to_lower().begins_with("fe80:")) ip = v6;
                }
            }
            host["ip"] = ip;
            host["hostname"] = target;
        }

        if (txt_records.has(instance_name)) {
            Dictionary txt = txt_records[instance_name];
            if (txt.has("id")) host["id"] = txt["id"];
            if (txt.has("nm")) host["friendly_name"] = txt["nm"];
        }

        if (host.has("ip") && host["ip"] != "") {
            hosts.append(host);
        }
    }

    return hosts;
}

Array MdnsBrowser::browse(float timeout) {
    return _browse_v4(timeout);
}

Array MdnsBrowser::_browse_v4(float timeout) {
    Array results;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        NF_LOG("MdnsBrowser", "Failed to create socket: %s", strerror(errno));
        return results;
    }

    struct timeval tv;
    tv.tv_sec = (int)timeout;
    tv.tv_usec = (int)((timeout - (int)timeout) * 1000000);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in local_addr;
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family = AF_INET;
    local_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    local_addr.sin_port = htons(0);
    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        NF_LOG("MdnsBrowser", "Failed to bind: %s", strerror(errno));
        close(sock);
        return results;
    }

    struct ip_mreq mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.imr_multiaddr.s_addr = inet_addr("224.0.0.251");
    mreq.imr_interface.s_addr = htonl(INADDR_ANY);
    if (setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
        NF_LOG("MdnsBrowser", "IP_ADD_MEMBERSHIP failed: %s", strerror(errno));
    }

    PackedByteArray query = _build_ptr_query("_nvstream._tcp.local");
    if (query.size() == 0) {
        close(sock);
        return results;
    }

    struct sockaddr_in mcast_addr;
    memset(&mcast_addr, 0, sizeof(mcast_addr));
    mcast_addr.sin_family = AF_INET;
    mcast_addr.sin_addr.s_addr = inet_addr("224.0.0.251");
    mcast_addr.sin_port = htons(5353);

    for (int attempt = 0; attempt < 3; attempt++) {
        sendto(sock, query.ptr(), query.size(), 0,
                (struct sockaddr *)&mcast_addr, sizeof(mcast_addr));
        if (attempt < 2) {
            usleep(200000);
        }
    }

    Dictionary seen_ips;
    uint8_t recv_buf[4096];

    struct timespec ts_start;
    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    double start_time = ts_start.tv_sec + ts_start.tv_nsec / 1e9;
    double end_time = start_time + timeout;

    while (true) {
        struct timespec ts_now;
        clock_gettime(CLOCK_MONOTONIC, &ts_now);
        double now = ts_now.tv_sec + ts_now.tv_nsec / 1e9;
        double remaining = end_time - now;
        if (remaining <= 0) break;

        struct pollfd pfd;
        pfd.fd = sock;
        pfd.events = POLLIN;
        int poll_ms = (int)(remaining * 1000);
        if (poll_ms < 10) poll_ms = 10;

        int ret = poll(&pfd, 1, poll_ms);
        if (ret <= 0) continue;

        struct sockaddr_in from;
        socklen_t from_len = sizeof(from);
        ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0,
                (struct sockaddr *)&from, &from_len);
        if (n <= 12) continue;

        if (!(recv_buf[2] & 0x80)) continue;

        Array found = _parse_dns_response(recv_buf, (int)n, false);
        for (int i = 0; i < found.size(); i++) {
            Dictionary host = found[i];
            if (host.has("ip")) {
                String ip = host["ip"];
                if (!seen_ips.has(ip) && ip != "") {
                    seen_ips[ip] = true;
                    results.append(host);
                }
            }
        }
    }

    close(sock);
    return results;
}

Array MdnsBrowser::browse_on_interface(const String &iface_name, float timeout) {
    return _browse_v6_scoped(iface_name, timeout);
}

Array MdnsBrowser::_browse_v6_scoped(const String &iface_name, float timeout) {
    Array results;

    CharString iface_cs = iface_name.utf8();
    unsigned int ifindex = if_nametoindex(iface_cs.get_data());
    if (ifindex == 0) {
        NF_LOG("MdnsBrowser", "Unknown interface '%s': %s", iface_cs.get_data(), strerror(errno));
        return results;
    }

    int sock = socket(AF_INET6, SOCK_DGRAM, 0);
    if (sock < 0) {
        NF_LOG("MdnsBrowser", "Failed to create IPv6 socket: %s", strerror(errno));
        return results;
    }

    struct timeval tv;
    tv.tv_sec = (int)timeout;
    tv.tv_usec = (int)((timeout - (int)timeout) * 1000000);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in6 local_addr;
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin6_family = AF_INET6;
    local_addr.sin6_addr = in6addr_any;
    local_addr.sin6_port = htons(0);
    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        NF_LOG("MdnsBrowser", "Failed to bind IPv6 socket: %s", strerror(errno));
        close(sock);
        return results;
    }

    // Scope both the outgoing multicast egress and the membership join to
    // usb0's interface index - without this the join defaults to the
    // primary (Wi-Fi) route and never sees anything a host only announces
    // on the USB link.
    setsockopt(sock, IPPROTO_IPV6, IPV6_MULTICAST_IF, &ifindex, sizeof(ifindex));

    struct ipv6_mreq mreq;
    memset(&mreq, 0, sizeof(mreq));
    inet_pton(AF_INET6, "ff02::fb", &mreq.ipv6mr_multiaddr);
    mreq.ipv6mr_interface = ifindex;
    if (setsockopt(sock, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
        NF_LOG("MdnsBrowser", "IPV6_ADD_MEMBERSHIP failed: %s", strerror(errno));
    }

    PackedByteArray query = _build_ptr_query("_nvstream._tcp.local");
    if (query.size() == 0) {
        close(sock);
        return results;
    }

    struct sockaddr_in6 mcast_addr;
    memset(&mcast_addr, 0, sizeof(mcast_addr));
    mcast_addr.sin6_family = AF_INET6;
    inet_pton(AF_INET6, "ff02::fb", &mcast_addr.sin6_addr);
    mcast_addr.sin6_port = htons(5353);
    mcast_addr.sin6_scope_id = ifindex;

    for (int attempt = 0; attempt < 3; attempt++) {
        sendto(sock, query.ptr(), query.size(), 0,
                (struct sockaddr *)&mcast_addr, sizeof(mcast_addr));
        if (attempt < 2) {
            usleep(200000);
        }
    }

    Dictionary seen_ips;
    uint8_t recv_buf[4096];

    struct timespec ts_start;
    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    double start_time = ts_start.tv_sec + ts_start.tv_nsec / 1e9;
    double end_time = start_time + timeout;

    while (true) {
        struct timespec ts_now;
        clock_gettime(CLOCK_MONOTONIC, &ts_now);
        double now = ts_now.tv_sec + ts_now.tv_nsec / 1e9;
        double remaining = end_time - now;
        if (remaining <= 0) break;

        struct pollfd pfd;
        pfd.fd = sock;
        pfd.events = POLLIN;
        int poll_ms = (int)(remaining * 1000);
        if (poll_ms < 10) poll_ms = 10;

        int ret = poll(&pfd, 1, poll_ms);
        if (ret <= 0) continue;

        struct sockaddr_in6 from;
        socklen_t from_len = sizeof(from);
        ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0,
                (struct sockaddr *)&from, &from_len);
        if (n <= 12) continue;

        if (!(recv_buf[2] & 0x80)) continue;

        Array found = _parse_dns_response(recv_buf, (int)n, true);
        for (int i = 0; i < found.size(); i++) {
            Dictionary host = found[i];
            if (host.has("ip")) {
                String ip = host["ip"];
                if (!seen_ips.has(ip) && ip != "") {
                    seen_ips[ip] = true;
                    // A link-local address is meaningless without its zone;
                    // carrying it in the address text lets every downstream
                    // consumer (HTTP binding, getaddrinfo in the stream path,
                    // saved host records) recover the interface on its own.
                    if (ip.to_lower().begins_with("fe80:")) {
                        host["ip"] = ip + String("%") + iface_name;
                    }
                    host["iface"] = iface_name;
                    host["scope_id"] = (int)ifindex;
                    results.append(host);
                }
            }
        }
    }

    close(sock);
    return results;
}

void MdnsBrowser::_bind_methods() {
    ClassDB::bind_method(D_METHOD("browse", "timeout"), &MdnsBrowser::browse, DEFVAL(3.0));
    ClassDB::bind_method(D_METHOD("browse_on_interface", "iface_name", "timeout"), &MdnsBrowser::browse_on_interface, DEFVAL(3.0));
}
