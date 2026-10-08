#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

struct evp_cipher_ctx_st;

namespace godot {

// Encrypts microphone packets for Nightfall Meteor (version 2 in
// meteor/src/mic.rs): an X25519 key pair per session, a key shared with
// Meteor's published public key through HKDF-SHA256, and AES-256-GCM with
// the sequence number as the nonce and the 48-byte header as additional data.
class MicCipher {
public:
    static constexpr size_t KEY_BYTES = 32;
    static constexpr size_t TAG_BYTES = 16;

    MicCipher() = default;
    ~MicCipher();
    MicCipher(const MicCipher &) = delete;
    MicCipher &operator=(const MicCipher &) = delete;

    // Makes this session's key pair and derives the key for Meteor's public
    // key, replacing any earlier session. private_key fixes the key pair
    // (tests only). Returns an empty string, or why it failed.
    std::string init(const uint8_t meteor_public[KEY_BYTES], const uint8_t *private_key = nullptr);
    const uint8_t *public_key() const { return public_key_; }

    // Encrypts body (body_len bytes) in place and writes the tag after it.
    // header is the packet's first header_len bytes, authenticated as is.
    bool seal(uint32_t seq, const uint8_t *header, size_t header_len, uint8_t *body, size_t body_len);

private:
    uint8_t public_key_[KEY_BYTES] = {};
    uint8_t key_[KEY_BYTES] = {};
    evp_cipher_ctx_st *ctx_ = nullptr;
};

// "0a1b..." (64 hex digits) to 32 bytes.
bool parse_hex_key(const std::string &hex, uint8_t out[MicCipher::KEY_BYTES]);

} // namespace godot
