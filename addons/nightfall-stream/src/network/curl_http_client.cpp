#include "curl_http_client.h"
#include <cstring>
#include <vector>
#include <net/if.h>

namespace nightfall {

std::once_flag CurlHttpClient::curl_init_flag_;

CurlHttpClient::CurlHttpClient() {
    std::call_once(curl_init_flag_, []() {
        curl_global_init(CURL_GLOBAL_ALL);
    });
}

CurlHttpClient::~CurlHttpClient() {}

size_t CurlHttpClient::_write_cb(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t real_size = size * nmemb;
    auto* mem = static_cast<std::vector<uint8_t>*>(userp);
    mem->insert(mem->end(), static_cast<uint8_t*>(contents), static_cast<uint8_t*>(contents) + real_size);
    return real_size;
}

size_t CurlHttpClient::_header_cb(char* buffer, size_t size, size_t nitems, void* userdata) {
    size_t real_size = size * nitems;
    return real_size;
}

HttpResponse CurlHttpClient::_perform(const std::string& url, const std::string& method, const std::string& content_type, const std::vector<uint8_t>& body) {
    HttpResponse resp;
    CURL* curl = curl_easy_init();
    if (!curl) {
        resp.status_code = -1;
        resp.body = "Failed to init curl";
        return resp;
    }

    std::vector<uint8_t> body_buffer;
    curl_slist* chunk = nullptr;

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());

    if (method == "GET") {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    } else if (method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        if (!body.empty()) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.data());
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
        } else {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0L);
        }
    }

    if (!content_type.empty()) {
        std::string ct_header = "Content-Type: " + content_type;
        chunk = curl_slist_append(chunk, ct_header.c_str());
    }
    if (chunk) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, chunk);
    }

    if (!verify_peer_) {
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
    } else if (!server_cert_pem_.empty()) {
        curl_blob blob;
        blob.data = const_cast<void*>(static_cast<const void*>(server_cert_pem_.c_str()));
        blob.len = server_cert_pem_.size();
        blob.flags = CURL_BLOB_COPY;
        curl_easy_setopt(curl, CURLOPT_CAINFO_BLOB, &blob);
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    }

    if (!client_cert_pem_.empty()) {
        curl_blob blob;
        blob.data = const_cast<void*>(static_cast<const void*>(client_cert_pem_.c_str()));
        blob.len = client_cert_pem_.size();
        blob.flags = CURL_BLOB_COPY;
        curl_easy_setopt(curl, CURLOPT_SSLCERT_BLOB, &blob);
        curl_easy_setopt(curl, CURLOPT_SSLCERTTYPE, "PEM");
    }

    if (!client_key_pem_.empty()) {
        curl_blob blob;
        blob.data = const_cast<void*>(static_cast<const void*>(client_key_pem_.c_str()));
        blob.len = client_key_pem_.size();
        blob.flags = CURL_BLOB_COPY;
        curl_easy_setopt(curl, CURLOPT_SSLKEY_BLOB, &blob);
        curl_easy_setopt(curl, CURLOPT_SSLKEYTYPE, "PEM");
    }

    if (!bind_iface_.empty()) {
        curl_easy_setopt(curl, CURLOPT_INTERFACE, bind_iface_.c_str());
        unsigned int ifindex = if_nametoindex(bind_iface_.c_str());
        if (ifindex != 0) {
            curl_easy_setopt(curl, CURLOPT_ADDRESS_SCOPE, static_cast<long>(ifindex));
        }
    }

    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, static_cast<long>(timeout_ms_));

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, _write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body_buffer);

    CURLcode res = curl_easy_perform(curl);

    if (res != CURLE_OK) {
        resp.status_code = -1;
        resp.body = curl_easy_strerror(res);
    } else {
        long code = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
        resp.status_code = static_cast<int>(code);
        resp.data.assign(body_buffer.begin(), body_buffer.end());
        resp.body = std::string(body_buffer.begin(), body_buffer.end());
    }

    curl_easy_cleanup(curl);
    if (chunk) curl_slist_free_all(chunk);

    return resp;
}

HttpResponse CurlHttpClient::get(const std::string& url) {
    return _perform(url, "GET", "", {});
}

HttpResponse CurlHttpClient::post(const std::string& url, const std::string& content_type, const std::vector<uint8_t>& body) {
    return _perform(url, "POST", content_type, body);
}

void CurlHttpClient::set_client_cert(const std::string& cert_pem, const std::string& key_pem) {
    client_cert_pem_ = cert_pem;
    client_key_pem_ = key_pem;
}

void CurlHttpClient::set_server_cert_pin(const std::string& cert_pem) {
    server_cert_pem_ = cert_pem;
}

void CurlHttpClient::set_verify_peer(bool verify) {
    verify_peer_ = verify;
}

void CurlHttpClient::set_timeout_ms(int ms) {
    timeout_ms_ = ms;
}

void CurlHttpClient::set_bind_interface(const std::string& iface) {
    bind_iface_ = iface;
}

std::string CurlHttpClient::get_backend_name() const {
    return "cURL";
}

} // namespace nightfall
