#include "dbus_portal.h"
#include "nf_log.h"

#ifdef NIGHTFALL_HAS_SYSTEMD
#include <systemd/sd-bus.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/eventfd.h>
#include <chrono>
#include <cstdlib>
#include <cstdio>

namespace godot {

// Structure to hold response results
struct PortalResponse {
    bool received = false;
    uint32_t code = 2; // Default to error
    sd_bus_message *results = nullptr;
};

static int on_response_signal(sd_bus_message *m, void *userdata, sd_bus_error *ret_error) {
    PortalResponse *resp = static_cast<PortalResponse*>(userdata);
    uint32_t code;
    int r = sd_bus_message_read(m, "u", &code);
    if (r < 0) {
        NF_LOG("DBusPortal", "Failed to parse response code: %s", strerror(-r));
        resp->code = 2;
    } else {
        resp->code = code;
    }
    resp->received = true;
    resp->results = sd_bus_message_ref(m);
    return 0;
}

DBusPortal::DBusPortal() {
}

DBusPortal::~DBusPortal() {
    close_session();
    if (bus_) {
        sd_bus_unref(bus_);
        bus_ = nullptr;
    }
}

bool DBusPortal::init() {
    if (initialized_) return true;

    const char *dbus_env = getenv("DBUS_SESSION_BUS_ADDRESS");
    NF_LOG("DBusPortal", "DBUS_SESSION_BUS_ADDRESS=%s", dbus_env ? dbus_env : "(not set)");

    int r = sd_bus_default_user(&bus_);
    if (r < 0) {
        NF_LOG("DBusPortal", "sd_bus_default_user failed: %s, trying sd_bus_open_user...", strerror(-r));
        r = sd_bus_open_user(&bus_);
        if (r < 0) {
            NF_LOG("DBusPortal", "sd_bus_open_user also failed: %s", strerror(-r));

            const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
            if (runtime_dir) {
                char addr[512];
                snprintf(addr, sizeof(addr), "unix:path=%s/bus", runtime_dir);
                NF_LOG("DBusPortal", "Trying manual bus address: %s", addr);
                sd_bus *manual_bus = nullptr;
                r = sd_bus_new(&manual_bus);
                if (r >= 0) {
                    r = sd_bus_set_address(manual_bus, addr);
                    if (r >= 0) {
                        r = sd_bus_start(manual_bus);
                    }
                    if (r >= 0) {
                        bus_ = manual_bus;
                        manual_bus = nullptr;
                    } else {
                        sd_bus_unref(manual_bus);
                    }
                }
            }
            if (r < 0 || !bus_) {
                NF_LOG("DBusPortal", "All D-Bus connection methods failed. "
                       "Ensure DBUS_SESSION_BUS_ADDRESS is set when running under WiVRn.");
                return false;
            }
        }
    }

    // Get sender name (needed to build request tokens)
    const char *unique_name = nullptr;
    r = sd_bus_get_unique_name(bus_, &unique_name);
    if (r < 0) {
        NF_LOG("DBusPortal", "Failed to get unique bus name: %s", strerror(-r));
        return false;
    }
    sender_name_ = unique_name;
    // Strip the starting colon and replace dots with underscores for D-Bus paths
    if (!sender_name_.empty() && sender_name_[0] == ':') {
        sender_name_ = sender_name_.substr(1);
    }
    for (char &c : sender_name_) {
        if (c == '.') c = '_';
    }

    // Query ScreenCast version
    uint32_t version = 0;
    r = sd_bus_get_property_trivial(
        bus_,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "version",
        nullptr,
        'u',
        &version
    );
    if (r < 0) {
        NF_LOG("DBusPortal", "Failed to query ScreenCast portal version: %s", strerror(-r));
        return false;
    }

    version_ = version;
    initialized_ = true;
    NF_LOG("DBusPortal", "Initialized ScreenCast portal, version: %d", version_);
    return true;
}

bool DBusPortal::create_session() {
    if (!initialized_) return false;

    // Generate random token for uniqueness
    std::string handle_token = "nightfall_" + std::to_string(getpid());
    std::string session_handle_token = "nightfall_session_" + std::to_string(getpid());

    sd_bus_message *req = nullptr;
    int r = sd_bus_message_new_method_call(
        bus_,
        &req,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "CreateSession"
    );
    if (r < 0) return false;

    r = sd_bus_message_open_container(req, 'a', "{sv}");
    if (r >= 0) {
        sd_bus_message_append(req, "{sv}", "handle_token", "s", handle_token.c_str());
        sd_bus_message_append(req, "{sv}", "session_handle_token", "s", session_handle_token.c_str());
        sd_bus_message_close_container(req);
    }

    sd_bus_message *reply = nullptr;
    r = sd_bus_call(bus_, req, 0, nullptr, &reply);
    sd_bus_message_unref(req);
    if (r < 0) {
        NF_LOG("DBusPortal", "CreateSession call failed: %s", strerror(-r));
        return false;
    }

    const char *request_path = nullptr;
    r = sd_bus_message_read(reply, "o", &request_path);
    if (r < 0) {
        sd_bus_message_unref(reply);
        return false;
    }
    std::string req_path = request_path;
    sd_bus_message_unref(reply);

    // Wait for Response signal
    PortalResponse response;
    std::string match = "type='signal',sender='org.freedesktop.portal.Desktop',path='" + req_path + 
                        "',interface='org.freedesktop.portal.Request',member='Response'";
    
    sd_bus_slot *slot = nullptr;
    r = sd_bus_add_match(bus_, &slot, match.c_str(), on_response_signal, &response);
    if (r < 0) return false;

    // Process loop (timeout 120 seconds)
    auto start_time = std::chrono::steady_clock::now();
    while (!response.received) {
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start_time).count();
        if (elapsed > 120) {
            NF_LOG("DBusPortal", "Timeout waiting for CreateSession response");
            break;
        }
        sd_bus_process(bus_, nullptr);
        if (!response.received) {
            sd_bus_wait(bus_, 100000); // 100ms
        }
    }

    sd_bus_slot_unref(slot);

    if (!response.received || response.code != 0 || !response.results) {
        NF_LOG("DBusPortal", "CreateSession response failed or cancelled. Code: %d", response.code);
        if (response.results) sd_bus_message_unref(response.results);
        return false;
    }

    // Read session_handle from results dict
    r = sd_bus_message_enter_container(response.results, 'a', "{sv}");
    if (r < 0) {
        sd_bus_message_unref(response.results);
        return false;
    }

    const char *sess_handle = nullptr;
    while (sd_bus_message_enter_container(response.results, 'e', "sv") > 0) {
        const char *key = nullptr;
        sd_bus_message_read(response.results, "s", &key);
        if (key && std::string(key) == "session_handle") {
            sd_bus_message_read(response.results, "v", "s", &sess_handle);
        } else {
            sd_bus_message_skip(response.results, "v");
        }
        sd_bus_message_exit_container(response.results);
    }
    sd_bus_message_exit_container(response.results);
    sd_bus_message_unref(response.results);

    if (!sess_handle) {
        NF_LOG("DBusPortal", "session_handle missing from Response");
        return false;
    }

    session_handle_ = sess_handle;
    NF_LOG("DBusPortal", "Session created successfully: %s", session_handle_.c_str());
    return true;
}

bool DBusPortal::select_sources(const std::string &restore_token) {
    if (session_handle_.empty()) return false;

    std::string handle_token = "nightfall_select_" + std::to_string(getpid());

    sd_bus_message *req = nullptr;
    int r = sd_bus_message_new_method_call(
        bus_,
        &req,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "SelectSources"
    );
    if (r < 0) return false;

    r = sd_bus_message_append(req, "o", session_handle_.c_str());
    if (r < 0) {
        sd_bus_message_unref(req);
        return false;
    }

    r = sd_bus_message_open_container(req, 'a', "{sv}");
    if (r >= 0) {
        sd_bus_message_append(req, "{sv}", "handle_token", "s", handle_token.c_str());
        sd_bus_message_append(req, "{sv}", "types", "u", 1); // 1 = MONITOR
        sd_bus_message_append(req, "{sv}", "multiple", "b", false);
        sd_bus_message_append(req, "{sv}", "cursor_mode", "u", 2); // 2 = Embedded (baked in)
        
        if (version_ >= 4) {
            sd_bus_message_append(req, "{sv}", "persist_mode", "u", 2); // 2 = until revoked
            if (!restore_token.empty()) {
                sd_bus_message_append(req, "{sv}", "restore_token", "s", restore_token.c_str());
                NF_LOG("DBusPortal", "Passing saved restore token");
            }
        }
        sd_bus_message_close_container(req);
    }

    sd_bus_message *reply = nullptr;
    r = sd_bus_call(bus_, req, 0, nullptr, &reply);
    sd_bus_message_unref(req);
    if (r < 0) {
        NF_LOG("DBusPortal", "SelectSources call failed: %s", strerror(-r));
        return false;
    }

    const char *request_path = nullptr;
    r = sd_bus_message_read(reply, "o", &request_path);
    if (r < 0) {
        sd_bus_message_unref(reply);
        return false;
    }
    std::string req_path = request_path;
    sd_bus_message_unref(reply);

    PortalResponse response;
    std::string match = "type='signal',sender='org.freedesktop.portal.Desktop',path='" + req_path + 
                        "',interface='org.freedesktop.portal.Request',member='Response'";
    
    sd_bus_slot *slot = nullptr;
    r = sd_bus_add_match(bus_, &slot, match.c_str(), on_response_signal, &response);
    if (r < 0) return false;

    // Timeout is longer (120 seconds) because user has to pick display
    auto start_time = std::chrono::steady_clock::now();
    while (!response.received) {
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start_time).count();
        if (elapsed > 120) {
            NF_LOG("DBusPortal", "Timeout waiting for SelectSources response");
            break;
        }
        sd_bus_process(bus_, nullptr);
        if (!response.received) {
            sd_bus_wait(bus_, 100000); // 100ms
        }
    }

    sd_bus_slot_unref(slot);

    if (!response.received || response.code != 0) {
        NF_LOG("DBusPortal", "SelectSources response failed or cancelled. Code: %d", response.code);
        if (response.results) sd_bus_message_unref(response.results);
        return false;
    }

    if (response.results) sd_bus_message_unref(response.results);
    NF_LOG("DBusPortal", "Sources selected successfully");
    return true;
}

bool DBusPortal::start(std::vector<StreamInfo> &out_streams, std::string &out_restore_token) {
    if (session_handle_.empty()) return false;

    std::string handle_token = "nightfall_start_" + std::to_string(getpid());

    sd_bus_message *req = nullptr;
    int r = sd_bus_message_new_method_call(
        bus_,
        &req,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "Start"
    );
    if (r < 0) return false;

    r = sd_bus_message_append(req, "os", session_handle_.c_str(), ""); // parent_window = ""
    if (r < 0) {
        sd_bus_message_unref(req);
        return false;
    }

    r = sd_bus_message_open_container(req, 'a', "{sv}");
    if (r >= 0) {
        sd_bus_message_append(req, "{sv}", "handle_token", "s", handle_token.c_str());
        sd_bus_message_close_container(req);
    }

    sd_bus_message *reply = nullptr;
    r = sd_bus_call(bus_, req, 0, nullptr, &reply);
    sd_bus_message_unref(req);
    if (r < 0) {
        NF_LOG("DBusPortal", "Start call failed: %s", strerror(-r));
        return false;
    }

    const char *request_path = nullptr;
    r = sd_bus_message_read(reply, "o", &request_path);
    if (r < 0) {
        sd_bus_message_unref(reply);
        return false;
    }
    std::string req_path = request_path;
    sd_bus_message_unref(reply);

    PortalResponse response;
    std::string match = "type='signal',sender='org.freedesktop.portal.Desktop',path='" + req_path + 
                        "',interface='org.freedesktop.portal.Request',member='Response'";
    
    sd_bus_slot *slot = nullptr;
    r = sd_bus_add_match(bus_, &slot, match.c_str(), on_response_signal, &response);
    if (r < 0) return false;

    auto start_time = std::chrono::steady_clock::now();
    while (!response.received) {
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start_time).count();
        if (elapsed > 120) {
            NF_LOG("DBusPortal", "Timeout waiting for Start response");
            break;
        }
        sd_bus_process(bus_, nullptr);
        if (!response.received) {
            sd_bus_wait(bus_, 100000); // 100ms
        }
    }

    sd_bus_slot_unref(slot);

    if (!response.received || response.code != 0 || !response.results) {
        NF_LOG("DBusPortal", "Start response failed or cancelled. Code: %d", response.code);
        if (response.results) sd_bus_message_unref(response.results);
        return false;
    }

    // Parse streams and restore_token
    r = sd_bus_message_enter_container(response.results, 'a', "{sv}");
    if (r < 0) {
        sd_bus_message_unref(response.results);
        return false;
    }

    while (sd_bus_message_enter_container(response.results, 'e', "sv") > 0) {
        const char *key = nullptr;
        sd_bus_message_read(response.results, "s", &key);
        if (key && std::string(key) == "restore_token") {
            const char *tok = nullptr;
            sd_bus_message_read(response.results, "v", "s", &tok);
            if (tok) out_restore_token = tok;
        } else if (key && std::string(key) == "streams") {
            // Read array of streams: a(ua{sv})
            sd_bus_message_enter_container(response.results, 'v', "a(ua{sv})");
            sd_bus_message_enter_container(response.results, 'a', "(ua{sv})");
            while (sd_bus_message_enter_container(response.results, 'r', "ua{sv}") > 0) {
                StreamInfo info;
                sd_bus_message_read(response.results, "u", &info.node_id);
                
                // Read properties dictionary: a{sv}
                sd_bus_message_enter_container(response.results, 'a', "{sv}");
                while (sd_bus_message_enter_container(response.results, 'e', "sv") > 0) {
                    const char *p_key = nullptr;
                    sd_bus_message_read(response.results, "s", &p_key);
                    if (p_key && std::string(p_key) == "pipewire-serial") {
                        sd_bus_message_read(response.results, "v", "t", &info.serial);
                    } else if (p_key && std::string(p_key) == "size") {
                        int w, h;
                        sd_bus_message_enter_container(response.results, 'v', "(ii)");
                        sd_bus_message_read(response.results, "(ii)", &w, &h);
                        sd_bus_message_exit_container(response.results);
                        info.width = w;
                        info.height = h;
                    } else if (p_key && std::string(p_key) == "id") {
                        const char *s_id = nullptr;
                        sd_bus_message_read(response.results, "v", "s", &s_id);
                        if (s_id) info.id = s_id;
                    } else {
                        sd_bus_message_skip(response.results, "v");
                    }
                    sd_bus_message_exit_container(response.results);
                }
                sd_bus_message_exit_container(response.results); // close a{sv}
                sd_bus_message_exit_container(response.results); // close struct
                out_streams.push_back(info);
            }
            sd_bus_message_exit_container(response.results); // close array
            sd_bus_message_exit_container(response.results); // close variant
        } else {
            sd_bus_message_skip(response.results, "v");
        }
        sd_bus_message_exit_container(response.results);
    }
    sd_bus_message_exit_container(response.results);
    sd_bus_message_unref(response.results);

    NF_LOG("DBusPortal", "Start completed, parsed %d streams", (int)out_streams.size());
    return !out_streams.empty();
}

int DBusPortal::open_pipewire_remote() {
    if (session_handle_.empty()) return -1;

    sd_bus_message *req = nullptr;
    int r = sd_bus_message_new_method_call(
        bus_,
        &req,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "OpenPipeWireRemote"
    );
    if (r < 0) return -1;

    r = sd_bus_message_append(req, "o", session_handle_.c_str());
    if (r < 0) {
        sd_bus_message_unref(req);
        return -1;
    }

    r = sd_bus_message_open_container(req, 'a', "{sv}");
    if (r >= 0) {
        sd_bus_message_close_container(req);
    }

    sd_bus_message *reply = nullptr;
    r = sd_bus_call(bus_, req, 0, nullptr, &reply);
    sd_bus_message_unref(req);
    if (r < 0) {
        NF_LOG("DBusPortal", "OpenPipeWireRemote call failed: %s", strerror(-r));
        return -1;
    }

    int pw_fd = -1;
    r = sd_bus_message_read(reply, "h", &pw_fd);
    if (r < 0 || pw_fd < 0) {
        NF_LOG("DBusPortal", "Failed to read PipeWire FD from reply");
        sd_bus_message_unref(reply);
        return -1;
    }

    int dup_fd = fcntl(pw_fd, F_DUPFD_CLOEXEC, 0);
    sd_bus_message_unref(reply);

    if (dup_fd < 0) {
        NF_LOG("DBusPortal", "Failed to duplicate PipeWire FD");
        return -1;
    }

    NF_LOG("DBusPortal", "PipeWire remote opened, FD: %d", dup_fd);
    return dup_fd;
}

void DBusPortal::close_session() {
    if (session_handle_.empty() || !bus_) return;

    sd_bus_message *req = nullptr;
    int r = sd_bus_message_new_method_call(
        bus_,
        &req,
        "org.freedesktop.portal.Desktop",
        session_handle_.c_str(),
        "org.freedesktop.portal.Session",
        "Close"
    );
    if (r >= 0) {
        sd_bus_call(bus_, req, 0, nullptr, nullptr);
        sd_bus_message_unref(req);
    }
    session_handle_.clear();
    NF_LOG("DBusPortal", "Session closed");
}

} // namespace godot

#else // NIGHTFALL_HAS_SYSTEMD

namespace godot {

DBusPortal::DBusPortal() {}
DBusPortal::~DBusPortal() {}
bool DBusPortal::init() { return false; }
bool DBusPortal::create_session() { return false; }
bool DBusPortal::select_sources(const std::string&) { return false; }
bool DBusPortal::start(std::vector<StreamInfo>&, std::string&) { return false; }
int DBusPortal::open_pipewire_remote() { return -1; }
void DBusPortal::close_session() {}

} // namespace godot

#endif // NIGHTFALL_HAS_SYSTEMD
