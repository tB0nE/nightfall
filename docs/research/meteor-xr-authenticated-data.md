# Authenticated XR data envelopes: local transport core

This follows the authenticated control prototype. Rust `meteor/src/xr_data.rs`
and portable OpenSSL `meteor_xr_data.h` implement session-bound record framing.
They do not yet attach to control leases, start live endpoints, replace USB,
or connect the headset decoder. No public listener or firewall rule was enabled.
The previous DEV APK has not been replaced/deployed for this core-only increment.

## Preserve existing validators

Encrypt the **compressed** existing NFXR packet, including its complete stereo
pose/FOV/timestamp header, rather than changing image or decoder formats. No RGB
image readback is introduced. After authentication, the Rust wire reader/native
MeteorXrWire still validates codec, dimensions, metadata, monotonic frame IDs,
epochs/sequences and explicit END. The diagnostic 240-frame limit remains.

Tracking uses the existing clock/optics/pose/controller/haptic packet formats.
The envelope validates their direction, structural type, version and size.
The existing native semantic validators MUST still check finite poses, controller
flags/ranges, clock mapping, optics and bounded haptics at live consumption.
AEAD integrity does not make an authenticated but malformed pose valid.

## Keys and framing

Each purpose has an independent key and implicit monotonic 64-bit counter:

| Kind | Direction | Maximum plaintext |
| --- | --- | --- |
| 1 Video | Host → headset | 152-byte NFXR header + 8 MiB payload |
| 2 HeadsetTracking | Headset → host | 192 bytes |
| 3 HostTracking | Host → headset | 32 bytes |
| 4 VideoFeedback | Headset → host | 20 bytes |

Use the existing X25519 shared secret and HKDF salt (client public key, then host
public key). Binary HKDF info is `nightfall-xr-data-v1/`, one purpose byte, the
16-byte control session ID, the 32-byte server handshake nonce, and the 32-byte
client handshake nonce. Never derive this from the public session ID alone.
Fresh control handshakes/restarts need fresh nonces. Only a currently accepted,
unexpired control lease may authorize future endpoint attachment; the crypto
constructor itself is not authorization. Static-DH security limits remain as
documented for control (no forward secrecy).

The 24-byte authenticated header is:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `NFXD` |
| 4 | 1 | Version 1 |
| 5 | 1 | Purpose 1–4 |
| 6 | 2 | Zero |
| 8 | 8 | LE record sequence, initially zero per purpose |
| 16 | 4 | LE ciphertext length including 16-byte GCM tag |
| 20 | 4 | Zero |

AES-256-GCM authenticates the entire header as AAD. Nonce uses the existing LE
counter + four zeros. Check the fixed header/purpose/sequence/length **before**
allocating the ciphertext buffer. Fail closed on truncation, authentication,
inner validation or sequence exhaustion. A failed receiver cannot resume or
reuse its counter. Do not put video records through the 4-KiB control framer.
Keep control, video and tracking workers/queues independent to avoid large video
records blocking head pose/exit messages. Those live workers are not added yet.

## Verified local replay

An opt-in Rust/OpenSSL socket test reconstructs eight packets from recorded real
NVENC output plus original pose/FOV metadata. It encrypts them and explicit END
to the C++ client. The client authenticates, runs the existing native wire
validator, and writes recovered H.264. Compressed bytes match the source exactly;
FFprobe decodes/counts eight frames. The client sends encrypted NFXT responses
back while video flows, exercising separate purpose keys/counters. Test tracking
is synthetic, NOT a claim of live headset tracking over LAN.

Native negative checks include wrong session, altered ciphertext, poisoned
receiver reuse and oversized preallocation headers. Rust additionally covers
cross-purpose/session delivery, replay, malformed authenticated payloads,
truncation, counter exhaustion, feedback and host request framing. Fixed test
seeds are fixtures only, never pairing credentials.

```bash
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -Iaddons/nightfall-stream/src -Iextensions/nightfall-xr/include \
  test/meteor_xr_data_client_test.cpp \
  addons/nightfall-stream/src/network/meteor_cipher.cpp -lcrypto \
  -o /tmp/nightfall-xr-data-cpp-client
NIGHTFALL_XR_DATA_CPP_CLIENT=/tmp/nightfall-xr-data-cpp-client \
  NIGHTFALL_XR_DATA_FIXTURE="$PWD/.build-cache/meteor-xr/monado-nvenc-spike" \
  cargo test --manifest-path meteor/Cargo.toml --no-default-features \
  recorded_video_openssl_transport -- --ignored
```

Requires retained monado-stereo.jsonl and monado-stereo.h264 from a successful
NVENC run, plus FFprobe. Test output authenticated-replay.h264 stays beside those
ignored fixtures. No new GPU/headset run is necessary for this replay.

## Remaining integration

Bind endpoint credentials/profile/epoch to the accepted control lease; verify
key possession before spending encoder/decoder resources; stop all associated
workers on lease expiry/disconnect. Build bounded native socket workers with
deadlines/cancellation and latest-frame behavior. Feed authenticated video into
the existing decoder and authenticated tracking through existing semantic/clock
validators. Coordinate receiver-ready → app launch → presentation → local exit.
Then perform one combined real-network headset test. Until those steps exist,
all capability replies must continue to advertise LAN video unavailable.
