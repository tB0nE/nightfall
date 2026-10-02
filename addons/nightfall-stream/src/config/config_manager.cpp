#include "config_manager.h"
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>

#include "nf_log.h"

using namespace godot;

NightfallConfigManager::NightfallConfigManager() {
    config.instantiate();
    config_path = "user://addons/nightfall-stream/config.ini";
    load_config();
}

NightfallConfigManager::~NightfallConfigManager() {
}

void NightfallConfigManager::set_config_path(const String &path) {
    if (config_path != path) {
        config_path = path.is_empty() ? "user://addons/nightfall-stream/config.ini" : path;
        config->clear();
        load_config();
    }
}

String NightfallConfigManager::get_config_path() const {
    return config_path;
}

void NightfallConfigManager::load_config() {
    String dir = config_path.get_base_dir();
    Ref<DirAccess> da = DirAccess::open("user://");
    if (!DirAccess::dir_exists_absolute(dir)) {
        DirAccess::make_dir_recursive_absolute(dir);
    }

    if (config->load(config_path) != OK) {
        NF_LOG("NightfallConfig", "Config load failed, creating new config at %s", config_path.utf8().get_data());
        save_config();
    }
    _check_and_create_certs();
}

void NightfallConfigManager::save_config() {
    config->save(config_path);
}

void NightfallConfigManager::_check_and_create_certs() {
    if (!config->has_section_key("General", "certificate") || !config->has_section_key("General", "key")) {
        NF_LOG("NightfallConfig", "Generating new client cert/key pair");
        Ref<Crypto> crypto;
        crypto.instantiate();

        Ref<CryptoKey> key = crypto->generate_rsa(2048);
        Ref<X509Certificate> cert = crypto->generate_self_signed_certificate(key, "CN=NVIDIA GameStream Client");

        String key_pem = key->save_to_string().replace(String::chr(0), "").strip_edges();
        String cert_pem = cert->save_to_string().replace(String::chr(0), "").strip_edges();

        config->set_value("General", "certificate", cert_pem);
        config->set_value("General", "key", key_pem);
        save_config();
        NF_LOG("NightfallConfig", "Client cert/key generated and saved (cert_len=%d key_len=%d)", cert_pem.length(), key_pem.length());
    } else {
        NF_LOG("NightfallConfig", "Existing client cert/key found (cert_len=%d key_len=%d)", String(config->get_value("General", "certificate")).length(), String(config->get_value("General", "key")).length());
    }
}

Dictionary NightfallConfigManager::get_client_keys() {
    Dictionary d;
    d["certificate"] = config->get_value("General", "certificate");
    d["key"] = config->get_value("General", "key");
    NF_LOG("NightfallConfig", "get_client_keys: cert_len=%d key_len=%d", String(d["certificate"]).length(), String(d["key"]).length());
    return d;
}

Dictionary NightfallConfigManager::get_client_cert_paths() {
    Dictionary d;
    Dictionary keys = get_client_keys();

    String dir = config_path.get_base_dir();
    String cert_path = dir.path_join("clientcert.pem");
    String key_path = dir.path_join("clientkey.pem");

    auto sync_file = [](String path, String content) {
        bool content_matches = false;
        if (FileAccess::file_exists(path)) {
            Ref<FileAccess> f = FileAccess::open(path, FileAccess::READ);
            if (f.is_valid()) {
                if (f->get_as_text() == content) {
                    content_matches = true;
                }
            }
        }

        if (!content_matches) {
            Ref<FileAccess> f = FileAccess::open(path, FileAccess::WRITE);
            if (f.is_valid()) {
                f->store_string(content);
            }
        }
    };

    sync_file(cert_path, keys["certificate"]);
    sync_file(key_path, keys["key"]);

    d["client_cert"] = ProjectSettings::get_singleton()->globalize_path(cert_path);
    d["client_key"] = ProjectSettings::get_singleton()->globalize_path(key_path);
    return d;
}

String NightfallConfigManager::_get_host_prefix(int index) {
    return String::num_int64(index) + "\\";
}

String NightfallConfigManager::_get_app_prefix(int host_index, int app_index) {
    return _get_host_prefix(host_index) + "apps\\" + String::num_int64(app_index) + "\\";
}

Array NightfallConfigManager::get_hosts() {
    Array hosts;
    int size = config->get_value("hosts", "size", 0);
    for (int i = 1; i <= size; i++) {
        Dictionary host;
        String prefix = _get_host_prefix(i);
        host["id"] = i;

        String uuid_key = prefix + "uuid";
        if (config->has_section_key("hosts", uuid_key)) {
            host["uuid"] = config->get_value("hosts", uuid_key);
            host["hostname"] = config->get_value("hosts", prefix + "hostname", "");
            host["mac"] = config->get_value("hosts", prefix + "mac", "");
            host["localaddress"] = config->get_value("hosts", prefix + "localaddress", "");
            host["usb_address"] = config->get_value("hosts", prefix + "usb_address", "");
            host["https_port"] = config->get_value("hosts", prefix + "https_port", 47984);
            host["srvcert"] = config->get_value("hosts", prefix + "srvcert", "");
            host["server_unique_id"] = config->get_value("hosts", prefix + "server_unique_id", "");
            hosts.append(host);
        }
    }
    return hosts;
}

int NightfallConfigManager::add_host(const Dictionary &data) {
    int size = config->get_value("hosts", "size", 0);
    int new_idx = size + 1;
    config->set_value("hosts", "size", new_idx);

    update_host(new_idx, data);
    return new_idx;
}

void NightfallConfigManager::update_host(int index, const Dictionary &data) {
    String prefix = _get_host_prefix(index);
    Array keys = data.keys();
    for (int i = 0; i < keys.size(); i++) {
        String key = keys[i];
        if (key != "id") {
            config->set_value("hosts", prefix + key, data[key]);
        }
    }
    save_config();
}

void NightfallConfigManager::remove_host(int index) {
    if (!config->has_section("hosts"))
        return;

    int size = config->get_value("hosts", "size", 0);
    if (index < 1 || index > size)
        return;

    PackedStringArray keys = config->get_section_keys("hosts");
    Dictionary new_data;

    for (const String &key : keys) {
        int slash_pos = key.find("\\");
        bool processed = false;

        if (slash_pos > 0) {
            String index_str = key.substr(0, slash_pos);
            if (index_str.is_valid_int()) {
                int key_idx = index_str.to_int();
                String suffix = key.substr(slash_pos);

                if (key_idx == index) {
                    processed = true;
                } else if (key_idx > index) {
                    String new_key = String::num_int64(key_idx - 1) + suffix;
                    new_data[new_key] = config->get_value("hosts", key);
                    processed = true;
                } else {
                    new_data[key] = config->get_value("hosts", key);
                    processed = true;
                }
            }
        }

        if (!processed) {
            if (key == "size") {
                new_data[key] = size - 1;
            } else {
                new_data[key] = config->get_value("hosts", key);
            }
        }
    }

    config->erase_section("hosts");
    Array new_keys = new_data.keys();
    for (int i = 0; i < new_keys.size(); i++) {
        String k = new_keys[i];
        config->set_value("hosts", k, new_data[k]);
    }
    save_config();
}

void NightfallConfigManager::clear_hosts() {
    if (!config->has_section("hosts"))
        return;
    config->erase_section("hosts");
    save_config();
}

Array NightfallConfigManager::get_apps(int host_index) {
    Array apps;
    String base_prefix = _get_host_prefix(host_index);
    int size = config->get_value("hosts", base_prefix + "apps\\size", 0);

    for (int i = 1; i <= size; i++) {
        Dictionary app;
        String prefix = _get_app_prefix(host_index, i);
        String name_key = prefix + "name";
        if (config->has_section_key("hosts", name_key)) {
            app["index"] = i;
            app["name"] = config->get_value("hosts", name_key);
            app["id"] = config->get_value("hosts", prefix + "id", 0);
            apps.append(app);
        }
    }
    return apps;
}

void NightfallConfigManager::add_app(int host_index, const Dictionary &data) {
    String base_prefix = _get_host_prefix(host_index);
    int size = config->get_value("hosts", base_prefix + "apps\\size", 0);
    int new_idx = size + 1;
    config->set_value("hosts", base_prefix + "apps\\size", new_idx);

    String prefix = _get_app_prefix(host_index, new_idx);
    Array keys = data.keys();
    for (int i = 0; i < keys.size(); i++) {
        String key = keys[i];
        config->set_value("hosts", prefix + key, data[key]);
    }
    save_config();
}

void NightfallConfigManager::remove_app(int host_index, int app_index) {
    String apps_prefix = _get_host_prefix(host_index) + "apps\\";
    int size = config->get_value("hosts", apps_prefix + "size", 0);

    if (app_index < 1 || app_index > size)
        return;

    PackedStringArray keys = config->get_section_keys("hosts");
    Vector<String> keys_to_erase;
    Dictionary keys_to_set;

    for (const String &key : keys) {
        if (!key.begins_with(apps_prefix))
            continue;

        String sub_key = key.substr(apps_prefix.length());
        int slash_pos = sub_key.find("\\");

        if (slash_pos > 0) {
            String idx_str = sub_key.substr(0, slash_pos);
            if (idx_str.is_valid_int()) {
                int current_idx = idx_str.to_int();
                String suffix = sub_key.substr(slash_pos);

                if (current_idx == app_index) {
                    keys_to_erase.push_back(key);
                } else if (current_idx > app_index) {
                    keys_to_erase.push_back(key);
                    String new_key = apps_prefix + String::num_int64(current_idx - 1) + suffix;
                    keys_to_set[new_key] = config->get_value("hosts", key);
                }
            }
        }
    }

    for (int i = 0; i < keys_to_erase.size(); i++) {
        config->erase_section_key("hosts", keys_to_erase[i]);
    }
    Array set_keys = keys_to_set.keys();
    for (int i = 0; i < set_keys.size(); i++) {
        config->set_value("hosts", set_keys[i], keys_to_set[set_keys[i]]);
    }

    config->set_value("hosts", apps_prefix + "size", size - 1);
    save_config();
}

void NightfallConfigManager::set_custom_data(ConfigTarget target, int host_idx, int app_idx, String key, Variant value) {
    String section;
    String final_key;

    switch (target) {
        case TARGET_GLOBAL:
            section = "General";
            final_key = key;
            break;
        case TARGET_HOST:
            section = "hosts";
            final_key = _get_host_prefix(host_idx) + key;
            break;
        case TARGET_APP:
            section = "hosts";
            final_key = _get_app_prefix(host_idx, app_idx) + key;
            break;
    }

    config->set_value(section, final_key, value);
    save_config();
}

Variant NightfallConfigManager::get_custom_data(ConfigTarget target, int host_idx, int app_idx, String key, Variant default_value) {
    if (config.is_null()) {
        config.instantiate();
        load_config();
    }
    String section;
    String final_key;

    switch (target) {
        case TARGET_GLOBAL:
            section = "General";
            final_key = key;
            break;
        case TARGET_HOST:
            section = "hosts";
            final_key = _get_host_prefix(host_idx) + key;
            break;
        case TARGET_APP:
            section = "hosts";
            final_key = _get_app_prefix(host_idx, app_idx) + key;
            break;
    }

    return config->get_value(section, final_key, default_value);
}

void NightfallConfigManager::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_config_path", "path"), &NightfallConfigManager::set_config_path);
    ClassDB::bind_method(D_METHOD("get_config_path"), &NightfallConfigManager::get_config_path);
    ClassDB::add_property("NightfallConfigManager", PropertyInfo(Variant::STRING, "config_path"), "set_config_path", "get_config_path");

    ClassDB::bind_method(D_METHOD("load_config"), &NightfallConfigManager::load_config);
    ClassDB::bind_method(D_METHOD("save_config"), &NightfallConfigManager::save_config);
    ClassDB::bind_method(D_METHOD("get_client_keys"), &NightfallConfigManager::get_client_keys);
    ClassDB::bind_method(D_METHOD("get_client_cert_paths"), &NightfallConfigManager::get_client_cert_paths);

    ClassDB::bind_method(D_METHOD("get_hosts"), &NightfallConfigManager::get_hosts);
    ClassDB::bind_method(D_METHOD("add_host", "data"), &NightfallConfigManager::add_host);
    ClassDB::bind_method(D_METHOD("update_host", "index", "data"), &NightfallConfigManager::update_host);
    ClassDB::bind_method(D_METHOD("remove_host", "index"), &NightfallConfigManager::remove_host);
    ClassDB::bind_method(D_METHOD("clear_hosts"), &NightfallConfigManager::clear_hosts);

    ClassDB::bind_method(D_METHOD("get_apps", "host_index"), &NightfallConfigManager::get_apps);
    ClassDB::bind_method(D_METHOD("add_app", "host_index", "data"), &NightfallConfigManager::add_app);
    ClassDB::bind_method(D_METHOD("remove_app", "host_index", "app_index"), &NightfallConfigManager::remove_app);

    ClassDB::bind_method(D_METHOD("set_custom_data", "target", "host_idx", "app_idx", "key", "value"), &NightfallConfigManager::set_custom_data);
    ClassDB::bind_method(D_METHOD("get_custom_data", "target", "host_idx", "app_idx", "key", "default_value"), &NightfallConfigManager::get_custom_data, DEFVAL(Variant()));

    BIND_ENUM_CONSTANT(TARGET_GLOBAL);
    BIND_ENUM_CONSTANT(TARGET_HOST);
    BIND_ENUM_CONSTANT(TARGET_APP);
}
