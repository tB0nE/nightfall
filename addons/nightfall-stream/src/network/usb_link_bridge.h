#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// JNI bridge to Java's UsbLinkManager (android/src/main/java/com/godot/game/)
// - see docs/plans/active/usb-link-streaming.md. Android-only; every method
// is a no-op/false/empty on other platforms, matching DepthBridge's own
// per-platform convention.
class UsbLinkBridge : public RefCounted {
    GDCLASS(UsbLinkBridge, RefCounted);

protected:
    static void _bind_methods();

public:
    UsbLinkBridge();
    ~UsbLinkBridge();

    bool is_supported();
    bool start();
    void stop();
    bool is_up();
    // Link-local addresses first, as plain text (no scope attached - see
    // UsbLinkManager.getLinkLocalAddresses()'s own comment on why).
    PackedStringArray get_link_local_addresses();
    // Empty while the link is down.
    String get_interface_name();
    // Same as get_interface_name(), for native callers without an instance.
    static String current_interface_name();
    // Appends the USB link's zone to a bare link-local address (host records
    // saved before addresses carried their zone); anything else is returned
    // unchanged.
    static String zone_link_local(const String &addr);
    // "Wi-Fi", "Ethernet", or "" - the default network's transport.
    String get_active_transport();
    String describe_link_properties();
};

} // namespace godot
