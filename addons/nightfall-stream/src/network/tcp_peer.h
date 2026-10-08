#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// A TCP client that can reach a zoned IPv6 link-local address
// ("fe80::1%usb0", USB Link), which Godot's StreamPeerTCP can't. It offers
// the part of StreamPeerTCP's interface that MeteorDepthReceiver uses, with
// the same status values, so the receiver can use either. POSIX only; on
// other platforms connect_to_host() returns ERR_UNAVAILABLE.
class NightfallTcpPeer : public RefCounted {
    GDCLASS(NightfallTcpPeer, RefCounted);

public:
    // StreamPeerTCP::Status.
    enum Status { STATUS_NONE = 0, STATUS_CONNECTING = 1, STATUS_CONNECTED = 2, STATUS_ERROR = 3 };

    ~NightfallTcpPeer();

    // Starts a non-blocking connect. host may carry a zone.
    int connect_to_host(const String &host, int port);
    void poll();
    int get_status() const { return status_; }
    void set_no_delay(bool enabled);
    int get_available_bytes() const;
    // [Error, PackedByteArray], as StreamPeer.get_partial_data().
    Array get_partial_data(int bytes);
    // Sends all of data (small messages only; waits up to a second).
    int put_data(const PackedByteArray &data);
    void disconnect_from_host();

protected:
    static void _bind_methods();

private:
    int fd_ = -1;
    Status status_ = STATUS_NONE;
};

} // namespace godot
