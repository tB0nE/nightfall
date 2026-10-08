#pragma once

#include "meteor_cipher.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// MeteorCipher for GDScript: MeteorDepthReceiver decrypts depth maps with it
// (meteor/src/depth_server.rs). One per connection.
class MeteorChannelCipher : public RefCounted {
    GDCLASS(MeteorChannelCipher, RefCounted);

public:
    // Makes this connection's key pair for Meteor's public key (64 hex
    // digits) and the channel's info string. Returns "" or why it failed.
    String init(const String &meteor_key, const String &info);
    PackedByteArray get_public_key() const;
    // The decrypted payload (payload includes the tag), or an empty array if
    // the message doesn't authenticate.
    PackedByteArray open(int64_t counter, const PackedByteArray &header, const PackedByteArray &payload);

protected:
    static void _bind_methods();

private:
    MeteorCipher cipher_;
};

} // namespace godot
