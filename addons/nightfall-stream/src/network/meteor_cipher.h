#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

struct evp_cipher_ctx_st;

namespace godot {

// Encryption for Nightfall Meteor's side channels (meteor/src/crypto.rs): an
// X25519 key pair per session, a key shared with Meteor's published public
// key through HKDF-SHA256 (info names the channel), and AES-256-GCM with a
// message counter as the nonce and the message header as additional data.
class MeteorCipher {
public:
    static constexpr size_t KEY_BYTES = 32;
    static constexpr size_t TAG_BYTES = 16;

    MeteorCipher() = default;
    ~MeteorCipher();
    MeteorCipher(const MeteorCipher &) = delete;
    MeteorCipher &operator=(const MeteorCipher &) = delete;

    // Makes this session's key pair and derives the key for Meteor's public
    // key, replacing any earlier session. private_key fixes the key pair
    // (tests only). Returns an empty string, or why it failed.
    std::string init(const uint8_t meteor_public[KEY_BYTES], const char *info, const uint8_t *private_key = nullptr);
    const uint8_t *public_key() const { return public_key_; }

    // Encrypts body (body_len bytes) in place and writes the tag after it.
    // header is the message's first header_len bytes, authenticated as is.
    bool seal(uint64_t counter, const uint8_t *header, size_t header_len, uint8_t *body, size_t body_len);
    // Decrypts body in place; body_len includes the trailing tag. False if
    // anything was changed.
    bool open(uint64_t counter, const uint8_t *header, size_t header_len, uint8_t *body, size_t body_len);

private:
    uint8_t public_key_[KEY_BYTES] = {};
    uint8_t key_[KEY_BYTES] = {};
    evp_cipher_ctx_st *ctx_ = nullptr;
    evp_cipher_ctx_st *open_ctx_ = nullptr;
};

// "0a1b..." (64 hex digits) to 32 bytes.
bool parse_hex_key(const std::string &hex, uint8_t out[MeteorCipher::KEY_BYTES]);

} // namespace godot
