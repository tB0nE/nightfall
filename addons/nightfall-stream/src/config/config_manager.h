#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/config_file.hpp>
#include <godot_cpp/classes/crypto.hpp>
#include <godot_cpp/classes/crypto_key.hpp>
#include <godot_cpp/classes/x509_certificate.hpp>

namespace godot {

class NightfallConfigManager : public RefCounted {
    GDCLASS(NightfallConfigManager, RefCounted);

private:
    Ref<ConfigFile> config;
    String config_path;

    void _check_and_create_certs();
    String _get_host_prefix(int index);
    String _get_app_prefix(int host_index, int app_index);
    void _remove_duplicate_hosts();

protected:
    static void _bind_methods();

public:
    enum ConfigTarget {
        TARGET_GLOBAL,
        TARGET_HOST,
        TARGET_APP
    };

    NightfallConfigManager();
    ~NightfallConfigManager();

    void set_config_path(const String &path);
    String get_config_path() const;

    void load_config();
    void save_config();

    Dictionary get_client_keys();
    Dictionary get_client_cert_paths();

    Array get_hosts();
    int add_host(const Dictionary &data);
    void update_host(int index, const Dictionary &data);
    void remove_host(int index);
    void remove_superseded_hosts(const String &address, int https_port, const String &server_unique_id);
    void clear_hosts();

    Array get_apps(int host_index);
    void add_app(int host_index, const Dictionary &data);
    void remove_app(int host_index, int app_index);

    void set_custom_data(ConfigTarget target, int host_idx, int app_idx, String key, Variant value);
    Variant get_custom_data(ConfigTarget target, int host_idx, int app_idx, String key, Variant default_value = Variant());

    Ref<ConfigFile> get_config() const { return config; }
};

} // namespace godot

VARIANT_ENUM_CAST(godot::NightfallConfigManager::ConfigTarget);
