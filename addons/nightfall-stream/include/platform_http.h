#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace nightfall {

struct HttpResponse {
    int status_code = 0;
    std::string body;
    std::vector<uint8_t> data;
};

class PlatformHttp {
public:
    virtual ~PlatformHttp() = default;

    virtual HttpResponse get(const std::string& url) = 0;
    virtual HttpResponse post(const std::string& url, const std::string& content_type, const std::vector<uint8_t>& body) = 0;

    virtual void set_client_cert(const std::string& cert_pem, const std::string& key_pem) = 0;
    virtual void set_server_cert_pin(const std::string& cert_pem) = 0;
    virtual void set_verify_peer(bool verify) = 0;
    virtual void set_timeout_ms(int ms) = 0;

    // Pins the connection's egress interface and, for a link-local IPv6
    // literal (which has no embedded zone id), its scope - without this a
    // request to a fe80:: address picked up over USB Link can silently
    // route out the default (Wi-Fi) interface instead, or fail to resolve
    // the zone at all. No-op when iface is empty. See
    // docs/plans/active/usb-link-streaming.md Step 3.
    virtual void set_bind_interface(const std::string& iface) = 0;

    virtual std::string get_backend_name() const = 0;
};

} // namespace nightfall
