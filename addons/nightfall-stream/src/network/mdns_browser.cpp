#include "mdns_browser.h"
#include "nf_log.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <poll.h>

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

// Records are accumulated across every response packet in the browse window:
// responders may split PTR/SRV/TXT/A across packets, and most (Windows dnsapi,
// used by Apollo/Vibepollo/Vibeshine, and macOS mDNSResponder) put SRV/TXT/A
// in the additional section rather than the answer section.
void MdnsBrowser::_parse_dns_response(const uint8_t *data, int len, const String &source_ip, MdnsRecords &records) {
    if (len < 12) return;

    int qdcount = (data[4] << 8) | data[5];
    int rrcount = ((data[6] << 8) | data[7]) + ((data[8] << 8) | data[9]) + ((data[10] << 8) | data[11]);

    int offset = 12;

    for (int i = 0; i < qdcount && offset < len; i++) {
        int end = 0;
        _read_dns_name(data, len, offset, end);
        offset = end;
        offset += 4;
    }

    for (int i = 0; i < rrcount && offset < len; i++) {
        int name_end = 0;
        String name = _read_dns_name(data, len, offset, name_end);
        offset = name_end;

        if (offset + 10 > len) break;

        int rtype = (data[offset] << 8) | data[offset + 1];
        int rdlength = (data[offset + 8] << 8) | data[offset + 9];
        offset += 10;

        if (offset + rdlength > len) break;

        if (rtype == 12) {
            if (name.to_lower().trim_suffix(".") == "_nvstream._tcp.local") {
                int target_end = 0;
                String instance = _read_dns_name(data, len, offset, target_end);
                records.instances[instance.to_lower()] = instance;
                if (!source_ip.is_empty()) records.source_ips[instance.to_lower()] = source_ip;
            }
        } else if (rtype == 33) {
            if (rdlength >= 6) {
                int port = (data[offset + 4] << 8) | data[offset + 5];
                int target_end = 0;
                String target = _read_dns_name(data, len, offset + 6, target_end);
                Dictionary srv;
                srv["port"] = port;
                srv["target"] = target;
                records.srv[name.to_lower()] = srv;
            }
        } else if (rtype == 1) {
            // IPv4 only: AAAA records share the hostname and would otherwise
            // replace the usable A record.
            if (rdlength == 4) {
                String ip = String::num_int64(data[offset]) + "." +
                        String::num_int64(data[offset + 1]) + "." +
                        String::num_int64(data[offset + 2]) + "." +
                        String::num_int64(data[offset + 3]);
                records.a[name.to_lower()] = ip;
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
            records.txt[name.to_lower()] = txt;
        }

        offset += rdlength;
    }
}

Array MdnsBrowser::_resolve_hosts(const MdnsRecords &records) {
    Array hosts;

    Array keys = records.instances.keys();
    for (int i = 0; i < keys.size(); i++) {
        String key = keys[i];
        String instance_name = records.instances[key];

        Dictionary host;
        host["instance"] = instance_name;
        host["ip"] = "";

        if (records.srv.has(key)) {
            Dictionary srv = records.srv[key];
            host["port"] = srv["port"];
            String target = srv["target"];
            String target_lower = target.to_lower();
            String short_target = target_lower.trim_suffix(".").trim_suffix(".local");
            if (records.a.has(target_lower)) {
                host["ip"] = records.a[target_lower];
            } else if (records.a.has(target_lower.trim_suffix("."))) {
                host["ip"] = records.a[target_lower.trim_suffix(".")];
            } else if (records.a.has(short_target)) {
                host["ip"] = records.a[short_target];
            }
            host["hostname"] = target;
        } else {
            host["port"] = 47989;
        }

        // A responder that sent no A record is still the host itself.
        if (String(host["ip"]).is_empty() && records.source_ips.has(key)) {
            host["ip"] = records.source_ips[key];
        }

        if (records.txt.has(key)) {
            Dictionary txt = records.txt[key];
            if (txt.has("id")) host["id"] = txt["id"];
            if (txt.has("nm")) host["friendly_name"] = txt["nm"];
        }
        if (!host.has("friendly_name")) {
            // Instance names are "<host name>._nvstream._tcp.local"; Windows
            // hosts publish an empty TXT record with no "nm".
            host["friendly_name"] = instance_name.get_slice("._nvstream", 0);
        }

        if (host["ip"] != "") {
            hosts.append(host);
        }
    }

    return hosts;
}

Array MdnsBrowser::browse(float timeout) {
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

    MdnsRecords records;
    uint8_t recv_buf[9000];

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

        char from_ip[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &from.sin_addr, from_ip, sizeof(from_ip));
        _parse_dns_response(recv_buf, (int)n, String(from_ip), records);
    }

    Array found = _resolve_hosts(records);
    Dictionary seen_ips;
    for (int i = 0; i < found.size(); i++) {
        Dictionary host = found[i];
        String ip = host["ip"];
        if (!seen_ips.has(ip)) {
            seen_ips[ip] = true;
            results.append(host);
        }
    }
    NF_LOG("MdnsBrowser", "Browse finished: %d instance(s), %d host(s)",
           (int)records.instances.size(), (int)results.size());

    close(sock);
    return results;
}

void MdnsBrowser::_bind_methods() {
    ClassDB::bind_method(D_METHOD("browse", "timeout"), &MdnsBrowser::browse, DEFVAL(3.0));
}
