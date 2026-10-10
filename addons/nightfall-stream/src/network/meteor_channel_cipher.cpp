#include "meteor_channel_cipher.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

String MeteorChannelCipher::init(const String &meteor_key, const String &info) {
    uint8_t meteor_public[MeteorCipher::KEY_BYTES];
    if (!parse_hex_key(meteor_key.utf8().get_data(), meteor_public)) return "not a valid Meteor key";
    return String::utf8(cipher_.init(meteor_public, info.utf8().get_data()).c_str());
}

PackedByteArray MeteorChannelCipher::get_public_key() const {
    PackedByteArray key;
    key.resize(MeteorCipher::KEY_BYTES);
    memcpy(key.ptrw(), cipher_.public_key(), MeteorCipher::KEY_BYTES);
    return key;
}

PackedByteArray MeteorChannelCipher::open(int64_t counter, const PackedByteArray &header, const PackedByteArray &payload) {
    if (payload.size() < static_cast<int64_t>(MeteorCipher::TAG_BYTES)) return PackedByteArray();
    PackedByteArray body = payload;
    if (!cipher_.open(static_cast<uint64_t>(counter), header.ptr(), header.size(), body.ptrw(), body.size())) {
        return PackedByteArray();
    }
    body.resize(body.size() - MeteorCipher::TAG_BYTES);
    return body;
}

void MeteorChannelCipher::_bind_methods() {
    ClassDB::bind_method(D_METHOD("init", "meteor_key", "info"), &MeteorChannelCipher::init);
    ClassDB::bind_method(D_METHOD("get_public_key"), &MeteorChannelCipher::get_public_key);
    ClassDB::bind_method(D_METHOD("open", "counter", "header", "payload"), &MeteorChannelCipher::open);
}
