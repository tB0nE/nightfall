# Meteor XR diagnostic frame transport

Experimental v1, 2026-10-18. This is **not a public network service** or the final
XR transport. The Rust receiver binds only `127.0.0.1` on an ephemeral TCP port;
ordinary Meteor builds/discovery do not enable it. There is no authentication or
encryption. Do not expose it through port forwarding. Future headset delivery
requires pairing/authentication, encrypted channels and explicit session consent.

## What runs

`tools/build_support/probe_xr_transport.sh` compiles/tests the standard-library-only
Rust framing module and diagnostic receiver, then runs the actual Monado/NVENC
probe with a native encoded-packet callback. The Python harness starts the
receiver and passes its loopback port to the test service; it does not connect,
start a sender thread or read packet data for delivery in the default direct
mode. The Rust receiver validates before allocation, writes a received H.264
stream/ledger and acknowledges each message. An explicit END closes the session.
Afterward, hashes, metadata and decoded changing-frame markers must match the
source reference artifacts.

The encoded callback receives borrowed NVENC bytes valid only for the duration
of that callback. `meteor_encoded_copy` validates the length (maximum 8 MiB) and
makes one owned copy before returning. After bitstream unlock, encode completion
and Vulkan queue unlock, the compositor sends the owned packet with its copied
frame ID, timestamp and views. It frees the packet after delivery or error. No
spool reads or GPU pixel readback occur in delivery. Reference bitstreams/JSONL
are still written for test comparison, not used as transport input.

One packet is in flight. Each frame header/payload/ack exchange has a common
two-second monotonic deadline with nonblocking sockets/poll; partial reads,
interrupts and stale/wrong acknowledgments are handled explicitly. Socket errors
close the connection; MSG_NOSIGNAL prevents SIGPIPE. The only destination is
127.0.0.1, with a validated port. An epoch is made from OS randomness on connect.
Session shutdown drains the encoder before sending END and checking its count.

This remains a synchronous stop-and-wait diagnostic: network waits are outside
the GPU queue lock, but still delay the compositor callback, and failures remain
fail-fast test-runtime errors rather than production recovery. TCP head-of-line
behavior and diagnostic acknowledgments make these timings unsuitable as headset
streaming performance measurements. A dedicated bounded network worker and
authenticated channels remain necessary for the product.

The former Python live-spool sender is retained under
`NIGHTFALL_XR_TRANSPORT_MODE=spool` only for regression comparison, capped at 240
frames and one payload in memory. Default mode is `direct`.

## Wire format

All integer/IEEE-754 float fields are little-endian. Fixed header: 152 bytes.

| Offset | Field |
| --- | --- |
| 0 | `NFXR` magic, 4 bytes |
| 4 | Version u16 = 1; header size u16 = 152 |
| 8 | Epoch u64, fresh nonzero random session ID (not authentication) |
| 16 | Sequence u64, starts at zero and increments per frame |
| 24 | Compositor frame ID u64 |
| 32 | Host monotonic display timestamp u64, nanoseconds |
| 40 | Encoded payload length u32, maximum 8 MiB |
| 44 | Packed stereo width u16; height u16 |
| 48 | Codec u8 = 1 (H.264 Annex-B) |
| 49 | Flags u8: bit 0 = contains IDR; all others zero |
| 50 | Kind u8: 0 = frame, 1 = END |
| 51 | 13 reserved bytes, all zero |
| 64 | Two views, each 11 f32: position xyz, orientation xyzw, FOV left/right/up/down |
| 152 | Encoded payload, length from offset 40 |

Stereo packing is side-by-side, left first. The first payload must contain SPS,
PPS and IDR; subsequent flags must match actual IDR NAL presence. Dimensions must
be even, 2–8192, and constant during the session. Poses/FOVs must be finite;
quaternions unit length within 0.001; FOV angles ordered and inside ±π/2.
Frame IDs and display times strictly increase (gaps are allowed), sequence is
contiguous, and epoch cannot change on a connection. Maximum diagnostic count:
240 frames. Oversized payloads fail before payload allocation. Short headers,
payloads and EOF without END fail explicitly.

END uses the current epoch and next sequence, codec=1, kind=1, with frame ID,
time, length, dimensions, flags and views all zero. A frame acknowledgment is
`NFXA` + sequence u64 + frame ID u64 (20 bytes). END acknowledgment is `NFXE` +
accepted frame count u64 (12 bytes). They are test coordination, not clock sync.

The timestamp is **host CLOCK_MONOTONIC**, not the Quest clock or an interchangeable
OpenXR `XrTime`. Poses/FOVs come from Monado's submitted projection layer; host to
Quest reference-space mapping and predicted local presentation still need to be
implemented. Do not present an image using the latest tracking pose in place of
its recorded render pose. A future tracking protocol must begin before decoded
video arrives and negotiate clock mapping and coordinate origins explicitly.

## Running

```bash
# Prerequisite: the pinned Monado build and NVIDIA encoder probes in BUILD.md.
bash tools/build_support/probe_xr_transport.sh
NIGHTFALL_XR_PROBE_FRAMES=120 bash tools/build_support/probe_xr_transport.sh
NIGHTFALL_XR_PROBE_ABORT=1 bash tools/build_support/probe_xr_transport.sh
NIGHTFALL_XR_TRANSPORT_MODE=spool bash tools/build_support/probe_xr_transport.sh
```

Rust protocol tests need no GPU/network access. Native C sender tests use local
socket pairs (no GPU/listener) and cover owned-copy lifetime, successful delivery/
END, bad acknowledgments, closed peers, invalid ports and deadlines. A restrictive
agent sandbox may need permission for their local send/receive syscalls.
Python harness tests:

```bash
python3 test/test_xr_transport_probe.py
```

Receiver binaries/tests are under `.build-cache/meteor-xr/transport-spike/`.
Source/received artifacts are under `.build-cache/meteor-xr/monado-nvenc-spike/`:
`received.h264`, `received.jsonl`, `received.rgb`, `transport.log`. Known outputs
are replaced on each run. Processes/sockets are private to the diagnostic;
timeouts and teardown stop only children created for it. No headset build,
SteamVR, global runtime registration, discovery, or firewall changes.

## Next boundaries

Direct-mode validation also passed 32 and 120 frames. Evidence:
`/tmp/nightfall-xr-direct-test.log`, `/tmp/nightfall-xr-direct-120.log`.
The five-frame interrupted-app case also passed in direct mode:
`/tmp/nightfall-xr-direct-disconnect.log`. Explicit spool-mode, transport-disabled
NVENC, and isolated software-capture regressions passed after these changes.
The service logs one `METEOR_DIRECT_OK` per delivered frame; the harness requires
these in direct mode and does not silently switch to spool mode on errors.

Validation on RTX 3090 / driver 615.71.09 passed at 32 frames, 120 frames, and a
five-frame valid partial stream after deliberately killing the test OpenXR app.
Payload hashes, frame order/epochs, poses/FOVs, timestamps and received decoded
markers matched. Logs: `/tmp/nightfall-xr-transport-live.log`,
`/tmp/nightfall-xr-transport-120.log`, `/tmp/nightfall-xr-transport-disconnect.log`.
Rust negative tests cover malformed headers, allocation bounds, truncation,
fragmented reads, duplicate/stale frames, epochs, dimensions, missing codec
configuration and explicit END; Python tests check layout and acknowledgments.

Move synchronous delivery onto a bounded network worker while retaining packet
ownership and metadata. Choose a transport with
authenticated session control and appropriate low-latency loss/recovery behavior;
do not drop arbitrary dependent H.264 P frames and assume the decoder recovers.
Add Quest MediaCodec reception, render-pose metadata matching, host/client clock
mapping, tracking-before-video and the existing exclusive projection lifecycle.
Only then claim remote XR streaming. Audio, controllers, realistic dimensions,
hardware/platform compatibility and Windows remain separate gates.
