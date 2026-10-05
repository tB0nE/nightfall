#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class MdnsBrowser : public RefCounted {
    GDCLASS(MdnsBrowser, RefCounted);

private:
    PackedByteArray _build_ptr_query(const String &service_type);
    struct MdnsRecords {
        // Keyed by lower-cased DNS name.
        Dictionary instances;
        Dictionary source_ips;
        Dictionary srv;
        Dictionary a;
        Dictionary aaaa_link_local;
        Dictionary aaaa_routable;
        Dictionary txt;
    };

    void _parse_dns_response(const uint8_t *data, int len, const String &source_ip, MdnsRecords &records);
    // want_v6: resolve SRV targets to AAAA records only (the USB link has no
    // routable IPv4, so a LAN A record answered over it would be a dead end),
    // preferring link-local; otherwise prefer A and fall back to a
    // non-link-local AAAA.
    Array _resolve_hosts(const MdnsRecords &records, bool want_v6);
    String _read_dns_name(const uint8_t *data, int len, int offset, int &out_end);
    int _write_dns_name(uint8_t *buf, int offset, const String &name);

protected:
    static void _bind_methods();

public:
    Array _browse_v4(float timeout);
    Array _browse_v6_scoped(const String &iface_name, float timeout);

public:
    MdnsBrowser();
    ~MdnsBrowser();

    Array browse(float timeout = 3.0);
    // IPv6 mDNS (ff02::fb) scoped to a single interface by name (e.g. "usb0") -
    // see docs/plans/active/usb-link-streaming.md Step 2. The default-route
    // IPv4 socket in browse() never sees USB Link traffic since usb0 carries
    // no IPv4 address at all, only a link-local IPv6 one.
    Array browse_on_interface(const String &iface_name, float timeout = 3.0);
};

} // namespace godot
