#pragma once

#include "platform_http.h"
#include <curl/curl.h>
#include <mutex>

namespace nightfall {

class CurlHttpClient : public PlatformHttp {
public:
    CurlHttpClient();
    ~CurlHttpClient() override;

    HttpResponse get(const std::string& url) override;
    HttpResponse post(const std::string& url, const std::string& content_type, const std::vector<uint8_t>& body) override;

    void set_client_cert(const std::string& cert_pem, const std::string& key_pem) override;
    void set_server_cert_pin(const std::string& cert_pem) override;
    void set_verify_peer(bool verify) override;
    void set_timeout_ms(int ms) override;
    void set_bind_interface(const std::string& iface) override;

    std::string get_backend_name() const override;

private:
    HttpResponse _perform(const std::string& url, const std::string& method, const std::string& content_type, const std::vector<uint8_t>& body);

    std::string client_cert_pem_;
    std::string client_key_pem_;
    std::string server_cert_pem_;
    int timeout_ms_ = 10000;
    bool verify_peer_ = true;
    std::string bind_iface_;

    static std::once_flag curl_init_flag_;
    static size_t _write_cb(void* contents, size_t size, size_t nmemb, void* userp);
    static size_t _header_cb(char* buffer, size_t size, size_t nitems, void* userdata);
};

} // namespace nightfall
