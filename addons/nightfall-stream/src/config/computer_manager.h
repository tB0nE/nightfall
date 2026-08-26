#pragma once

#include "config/config_manager.h"
#include "network/http_requester.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/aes_context.hpp>
#include <godot_cpp/classes/crypto.hpp>
#include <godot_cpp/classes/crypto_key.hpp>
#include <godot_cpp/classes/hashing_context.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/x509_certificate.hpp>

namespace godot {

class NightfallComputerManager : public RefCounted {
    GDCLASS(NightfallComputerManager, RefCounted);

private:
    Ref<NightfallConfigManager> config_manager;
    HttpRequester *http_requester = nullptr;

    enum PairState {
        PAIR_IDLE,
        PAIR_STAGE_0_PREFLIGHT,
        PAIR_STAGE_1_GET_CERT,
        PAIR_STAGE_2_CLIENT_CHALLENGE,
        PAIR_STAGE_3_SERVER_RESPONSE,
        PAIR_STAGE_4_CLIENT_SECRET,
        PAIR_STAGE_5_HTTPS_CHALLENGE,
        PAIR_FINISHED,
        PAIR_ERROR
    };

    PairState pair_state = PAIR_IDLE;
    String pair_ip;
    int pair_port;
    int pair_https_port = 47984;
    String pair_pin;
    PackedByteArray pair_salt;
    PackedByteArray pair_aes_key;
    String unique_id;
    String current_uuid;

    String server_unique_id;
    String server_cert_pem;
    String pair_mac;
    PackedByteArray client_secret_random;
    PackedByteArray server_challenge;
    PackedByteArray server_secret;
    PackedByteArray client_pairing_secret;
    bool is_requesting = false;

    bool owns_requester = false;

    Dictionary cached_https_ports;

    Node *parent_node_ = nullptr;

    uint64_t pair_start_time = 0;

    void _reset_pairing();
    void _step_pair();
    void _schedule_retry(int step);

    PackedByteArray _generate_random_bytes(int size);
    String _bytes_to_hex(const PackedByteArray &bytes);
    PackedByteArray _hex_to_bytes(const String &hex);
    PackedByteArray _calculate_aes_key(const PackedByteArray &salt, const String &pin);
    PackedByteArray _encrypt_aes_ecb(const PackedByteArray &data, const PackedByteArray &key);
    PackedByteArray _decrypt_aes_ecb(const PackedByteArray &data, const PackedByteArray &key);
    PackedByteArray _sign_data(const PackedByteArray &data);
    PackedByteArray _sha256(const PackedByteArray &data);
    PackedByteArray _extract_signature_from_der(const PackedByteArray &der);

    String _get_unique_id();
    String _get_uuid();
    Dictionary _get_ssl_options();

    void _on_pair_request_completed(int code, PackedByteArray body, Dictionary headers, String error, int step);
    void _on_server_info_completed(int code, PackedByteArray body, Dictionary headers, String error, Callable callback, String ip);
    void _on_app_list_completed(int code, PackedByteArray body, Dictionary headers, String error, int host_id, Callable callback);
    void _on_app_cover_completed(int code, PackedByteArray body, Dictionary headers, String error, Callable callback);
    void _on_simple_request_completed(int code, PackedByteArray body, Dictionary headers, String error, Callable callback);

    void _on_launch_serverinfo_completed(int code, PackedByteArray body, Dictionary headers, String error, Dictionary ctx);
    void _perform_launch_request(Dictionary ctx, String command);
    void _on_launch_request_completed(int code, PackedByteArray body, Dictionary headers, String error, Dictionary ctx);
    void _fetch_display_manifest(Dictionary response, Callable callback, String ip, int port);
    void _on_display_manifest_completed(int code, PackedByteArray body, Dictionary headers, String error, Dictionary response, Callable callback, String ip, int port);
    void _fetch_session_status(Dictionary response, Callable callback, String ip, int port);
    void _on_session_status_completed(int code, PackedByteArray body, Dictionary headers, String error, Dictionary response, Callable callback);
    void _on_set_cursor_visible_completed(int code, PackedByteArray body, Dictionary headers, String error, Callable callback);
    void _on_prelaunch_manifest_completed(int code, PackedByteArray body, Dictionary headers, String error, Callable callback);

    String _extract_xml_value(const String &xml, const String &tag);
    String _extract_xml_attr(const String &xml, const String &attr);

protected:
    static void _bind_methods();

public:
    NightfallComputerManager();
    ~NightfallComputerManager();

    void set_config_manager(Object *cm);
    void set_http_requester(Object *req);
    void set_parent_node(Node *node);

    String start_pair(String ip, int port = 47989);
    void cancel_pair();
    void unpair(int host_id);
    String get_last_paired_unique_id();

    void connect_to_computer(String ip, int port = 47989, Callable callback = Callable());

    void get_app_list(int host_id, Callable callback = Callable());
    void get_app_cover(int host_id, int app_id, Callable callback);

    void establish_stream(int host_id, int app_id, Dictionary options, Callable callback);
    void fetch_display_manifest(int host_id, Callable callback);
    void stop_stream(int host_id, Callable callback);
    void cancel_host_stream(int host_id, String ip, int port);
    void set_cursor_visible(int host_id, bool visible, Callable callback);
};

} // namespace godot
