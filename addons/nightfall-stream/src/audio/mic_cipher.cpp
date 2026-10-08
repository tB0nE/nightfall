#include "mic_cipher.h"

#include <cstring>
#include <openssl/evp.h>
#include <openssl/kdf.h>

namespace godot {

namespace {
const char KDF_INFO[] = "nightfall-meteor mic v2";

struct PkeyCtx {
    EVP_PKEY_CTX *ctx;
    ~PkeyCtx() { EVP_PKEY_CTX_free(ctx); }
};
struct Pkey {
    EVP_PKEY *key;
    ~Pkey() { EVP_PKEY_free(key); }
};
} // namespace

MicCipher::~MicCipher() {
    EVP_CIPHER_CTX_free(ctx_);
    std::memset(key_, 0, sizeof(key_));
}

std::string MicCipher::init(const uint8_t meteor_public[KEY_BYTES], const uint8_t *private_key) {
    EVP_CIPHER_CTX_free(ctx_);
    ctx_ = nullptr;
    Pkey ours{nullptr};
    if (private_key) {
        ours.key = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, nullptr, private_key, KEY_BYTES);
    } else {
        PkeyCtx gen{EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, nullptr)};
        if (gen.ctx && EVP_PKEY_keygen_init(gen.ctx) > 0) EVP_PKEY_keygen(gen.ctx, &ours.key);
    }
    size_t len = KEY_BYTES;
    if (!ours.key || EVP_PKEY_get_raw_public_key(ours.key, public_key_, &len) <= 0) return "can't make a key pair";

    Pkey theirs{EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, nullptr, meteor_public, KEY_BYTES)};
    PkeyCtx derive{EVP_PKEY_CTX_new(ours.key, nullptr)};
    uint8_t shared[KEY_BYTES];
    len = sizeof(shared);
    if (!theirs.key || !derive.ctx || EVP_PKEY_derive_init(derive.ctx) <= 0 ||
        EVP_PKEY_derive_set_peer(derive.ctx, theirs.key) <= 0 || EVP_PKEY_derive(derive.ctx, shared, &len) <= 0) {
        return "can't agree a key with Meteor";
    }

    // Salt: our public key, then Meteor's.
    uint8_t salt[KEY_BYTES * 2];
    std::memcpy(salt, public_key_, KEY_BYTES);
    std::memcpy(salt + KEY_BYTES, meteor_public, KEY_BYTES);
    PkeyCtx hkdf{EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, nullptr)};
    len = sizeof(key_);
    bool ok = hkdf.ctx && EVP_PKEY_derive_init(hkdf.ctx) > 0 && EVP_PKEY_CTX_set_hkdf_md(hkdf.ctx, EVP_sha256()) > 0 &&
              EVP_PKEY_CTX_set1_hkdf_salt(hkdf.ctx, salt, sizeof(salt)) > 0 &&
              EVP_PKEY_CTX_set1_hkdf_key(hkdf.ctx, shared, sizeof(shared)) > 0 &&
              EVP_PKEY_CTX_add1_hkdf_info(hkdf.ctx, reinterpret_cast<const unsigned char *>(KDF_INFO), sizeof(KDF_INFO) - 1) > 0 &&
              EVP_PKEY_derive(hkdf.ctx, key_, &len) > 0;
    std::memset(shared, 0, sizeof(shared));
    if (!ok) return "can't derive the session key";

    ctx_ = EVP_CIPHER_CTX_new();
    if (!ctx_ || EVP_EncryptInit_ex(ctx_, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) <= 0 ||
        EVP_CIPHER_CTX_ctrl(ctx_, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) <= 0) {
        return "can't set up AES-256-GCM";
    }
    return "";
}

bool MicCipher::seal(uint32_t seq, const uint8_t *header, size_t header_len, uint8_t *body, size_t body_len) {
    if (!ctx_) return false;
    uint8_t nonce[12] = {};
    nonce[0] = seq & 0xff;
    nonce[1] = (seq >> 8) & 0xff;
    nonce[2] = (seq >> 16) & 0xff;
    nonce[3] = (seq >> 24) & 0xff;
    int out_len = 0;
    return EVP_EncryptInit_ex(ctx_, nullptr, nullptr, key_, nonce) > 0 &&
           EVP_EncryptUpdate(ctx_, nullptr, &out_len, header, static_cast<int>(header_len)) > 0 &&
           EVP_EncryptUpdate(ctx_, body, &out_len, body, static_cast<int>(body_len)) > 0 &&
           EVP_EncryptFinal_ex(ctx_, body + out_len, &out_len) > 0 &&
           EVP_CIPHER_CTX_ctrl(ctx_, EVP_CTRL_GCM_GET_TAG, TAG_BYTES, body + body_len) > 0;
}

bool parse_hex_key(const std::string &hex, uint8_t out[MicCipher::KEY_BYTES]) {
    if (hex.size() != MicCipher::KEY_BYTES * 2) return false;
    auto digit = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < MicCipher::KEY_BYTES; ++i) {
        int hi = digit(hex[2 * i]), lo = digit(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<uint8_t>(hi * 16 + lo);
    }
    return true;
}

} // namespace godot
