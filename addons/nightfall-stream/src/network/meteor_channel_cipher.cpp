#include "meteor_channel_cipher.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

String MeteorChannelCipher::init(const String &meteor_key, const String &info) {
    uint8_t meteor_public[MeteorCipher::KEY_BYTES];
    if (!parse_hex_key(meteor_key.utf8().get_data(), meteor_public)) return "not a valid Meteor key";
    return String::utf8(cipher_.init(meteor_public, info.utf8().get_data()).c_str());
}

String MeteorChannelCipher::init_control(const String &meteor_key, const PackedByteArray &server_nonce,
        const PackedByteArray &client_nonce, const PackedByteArray &identity, bool sending) {
    uint8_t public_key[32];
    if (!parse_hex_key(meteor_key.utf8().get_data(), public_key) || server_nonce.size()!=32 || client_nonce.size()!=32 || identity.size()!=32)
        return "Invalid control key or nonce size";
    std::string info = std::string("nightfall-xr-control-v1/") + (sending ? "client-to-server" : "server-to-client");
    info.append(reinterpret_cast<const char *>(server_nonce.ptr()),32);
    info.append(reinterpret_cast<const char *>(client_nonce.ptr()),32);
    return String::utf8(cipher_.init_bytes(public_key,reinterpret_cast<const uint8_t *>(info.data()),info.size(),identity.ptr()).c_str());
}

PackedByteArray MeteorChannelCipher::identity_public(const PackedByteArray &identity) const {
    PackedByteArray out;
    if (identity.size()!=32) return out;
    out.resize(32);
    if (!MeteorCipher::identity_public(identity.ptr(),out.ptrw())) return PackedByteArray();
    return out;
}

PackedByteArray MeteorChannelCipher::seal(int64_t counter, const PackedByteArray &header, const PackedByteArray &payload) {
    if (counter<0 || payload.size()>4080) return PackedByteArray();
    PackedByteArray body=payload; body.resize(payload.size()+MeteorCipher::TAG_BYTES);
    if (!cipher_.seal(static_cast<uint64_t>(counter),header.ptr(),header.size(),body.ptrw(),payload.size())) return PackedByteArray();
    return body;
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
    ClassDB::bind_method(D_METHOD("init_control", "meteor_key", "server_nonce", "client_nonce", "identity", "sending"), &MeteorChannelCipher::init_control);
    ClassDB::bind_method(D_METHOD("identity_public", "identity"), &MeteorChannelCipher::identity_public);
    ClassDB::bind_method(D_METHOD("seal", "counter", "header", "payload"), &MeteorChannelCipher::seal);
    ClassDB::bind_method(D_METHOD("init", "meteor_key", "info"), &MeteorChannelCipher::init);
    ClassDB::bind_method(D_METHOD("get_public_key"), &MeteorChannelCipher::get_public_key);
    ClassDB::bind_method(D_METHOD("open", "counter", "header", "payload"), &MeteorChannelCipher::open);
}
