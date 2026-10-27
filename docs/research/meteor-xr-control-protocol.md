# XR control protocol: development-only foundation

The Meteor-managed USB lifecycle is working. This increment adds the first
authenticated network negotiation endpoint; it does **not** replace USB video,
run an application, implement the headset UI, or advertise a finished XR feature.
The current APK is unchanged. No listener starts during ordinary Meteor startup.

## Authorization

Discovery's pinned Meteor key authenticates the host for existing side channels,
but does not authorize an arbitrary headset to launch a process. This endpoint
therefore requires an explicit allowlisted client X25519 public key. The client
must already pin the expected Meteor public key and prove possession of its own
private key with an authenticated first message. Merely copying a public key
does not grant access. Provisioning that trust and presenting a real acceptance
prompt on Nightfall remain future work; this CLI is a developer trust setup,
not a user-ready pairing flow. Do not paste private keys into chat or logs.

Explicit opt-in syntax:

```
nightfall-meteor --xr-control-dev 127.0.0.1:0 <server-key-file> <allowed-client-public-hex>
```

Bind an actual LAN address only for an intentional development test. No firewall
rule, discovery advertisement, global OpenXR setting or server process is added
automatically. The private server key uses Meteor's existing key store helper;
the public host pin may be displayed. No arbitrary command/path is accepted.

## Framing and session keys

1. Server sends 72 bytes: `NFXC`, version byte 1, three zero bytes, 32-byte Meteor
   public key, and a fresh 32-byte cryptographic server nonce.
2. Client checks the version and pinned host key, then sends its 32-byte public
   key and a fresh 32-byte cryptographic client nonce. Unknown client keys fail.
3. X25519 shared secret feeds the existing HKDF-SHA256/AES-256-GCM derivation.
   Existing salt is client public key followed by Meteor public key. HKDF info
   is `nightfall-xr-control-v1/`, direction (`client-to-server` or
   `server-to-client`), server nonce, then client nonce. Direction keys differ;
   every handshake derives new keys. Non-contributory shared secrets fail.
4. Each encrypted frame is a four-byte little-endian ciphertext length, then
   ciphertext including the 16-byte GCM tag. Length is authenticated as AAD.
   Each direction uses its own implicit 64-bit counter starting at zero, with
   the existing counter-to-nonce mapping. Counters never wrap. Authentication
   failure ends the connection; no recovery/reuse of a failed counter occurs.
5. First encrypted request must be `{"type":"authenticate"}`. Only then may
   the connection reserve the exclusive control-session slot. Server's encrypted
   reply proves possession of the pinned host private key to the client.

Frames are bounded to 4096 ciphertext bytes before allocation. The full handshake
has a five-second deadline, request reads a 30-second deadline, and writes a
five-second deadline. Four simultaneous connections maximum, one authenticated
control owner. This is a prototype protocol, not an independently audited
security design. Static DH follows existing Meteor channels and does not provide
forward secrecy; review that before product pairing/Internet exposure.

## Explicit negotiation, not implicit launch

Requests use a strict tagged JSON schema; unknown fields/variants are rejected.

- `status`: inspect current connection-owned state.
- `offer`: `width`, `height`, `hz`. Only current diagnostic profiles 256/512
  square and 20/60 Hz are supported. Returns a random session ID and
  `awaiting_acceptance`, expiring after 15 seconds. Repeated offers return busy.
- `accept`: exact session ID required. Transitions to **prepared**, not
  streaming; the control-only lease expires after 30 seconds.
- `stop`: exact session ID required; returns to idle.

All replies include `lan_video_available: false`. There is no `launch` request.
Disconnect drops the offer/prepared state and exclusive slot. The server aborts
connection tasks on shutdown. A second authenticated connection receives an
encrypted busy response, not ownership of another client's state.

Next: implement the client with pinned-key checks and a real explicit exclusive-XR
acceptance UI; negotiate authenticated video/tracking endpoints; connect this
prepared lease to the packaged runtime supervisor only after those endpoints
are ready. Existing USB wire packets are unauthenticated and must NOT simply be
bound to 0.0.0.0. Until then, do not claim end-to-end LAN XR works.

## Tests

Rust tests cover encrypted socket offer/accept/disconnect cleanup, unauthorized
keys, spoofing an allowlisted key without its secret, replay, cross-session and
cross-direction replay, tampering, oversize frames, strict schemas, explicit
matching acceptance, unsupported profiles and expired offers. Tests bind loopback
only. The next client increment below adds a developer-gated headset control
probe, not LAN video presentation.

## Nightfall client and explicit acceptance

`src/meteor_xr_control.gd` is a nonblocking, main-loop-polled TCP control client.
It pins the exact host public key, enforces frame limits/deadlines, and uses a
persistent device identity rather than the ephemeral depth-channel identity.
`MeteorChannelCipher.init_control` uses binary-safe KDF context with separate
direction keys; `seal` and the existing authenticated `open` implement framing.
The old text-context API remains unchanged for microphone/depth callers.

The developer probe is visible only with the DEV feature **and** a manually
provisioned `user://meteor_xr_control.cfg`:

```ini
[host]
address="10.0.0.13"
port=47905
key="<64 hexadecimal characters: independently verified Meteor public key>"
```

The port above is an example, not automatically reserved/opened/advertised.
On Android use the app's actual `user://` directory, not a guessed storage path.
This is manual development provisioning; a pairing/import UI is still needed.
Do not copy the private identity to the host. A generated 32-byte identity lives
in `user://meteor_xr_identity.key`, with Unix permissions set before key bytes
are written. A malformed existing key fails rather than rotating silently.
The probe logs only the **public** device key, for the host's explicit allowlist.

Click Authenticate to request an offer. A second explicit **Accept XR preparation
(no video)** click sends acceptance, only from a clean welcome state. Prepared
never calls PCVRTestController.start or hides content. Cancel closes the control
socket, dropping host ownership. Offer/prepared leases are watched for expiry/
disconnect. Pausing, closing or rebuilding welcome cancels pending operations;
generation checks reject late network results. No new composition layer is used.

Validation: a native OpenSSL client using the production MeteorCipher exchanges
authenticate → offer → accept → stop with the Rust server. It also compares
legacy text-context output byte-for-byte against the new binary-context API.
Android Release native cipher/wrapper objects and the full shared library compile
and link. All 36 GDScript scripts pass, including pin validation/cancellation;
the desktop runner still prints its existing missing Android-only XR-extension
diagnostics (not a claim that the Android runtime has loaded on desktop).

Cross-language reproduction:

```bash
c++ -std=c++17 -O2 -Wall -Wextra -Werror -Iaddons/nightfall-stream/src \
  test/meteor_xr_control_client_test.cpp \
  addons/nightfall-stream/src/network/meteor_cipher.cpp -lcrypto \
  -o /tmp/nightfall-xr-control-cpp-client
NIGHTFALL_XR_CONTROL_CPP_CLIENT=/tmp/nightfall-xr-control-cpp-client \
  cargo test --manifest-path meteor/Cargo.toml --no-default-features \
  openssl_client_interoperability -- --ignored
```

Fixed keys in that native fixture are **tests only**, never pairing credentials.
The client still has not completed a physical control handshake on Quest. More
importantly, authenticated LAN video/tracking and runtime launch integration
remain unimplemented: do not interpret a prepared control lease as working XR.
