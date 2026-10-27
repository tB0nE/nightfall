# XR diagnostic: bounded asynchronous packet delivery

2026-10-18, `feat/meteor-xr-streaming`. Builds on the
[image-ownership correction](meteor-xr-image-ownership.md).

## What changed

Opt-in `NIGHTFALL_XR_ASYNC_DELIVERY=1` moves direct compressed-packet delivery and
ACK waiting to a separate pthread worker. It requires a direct loopback/USB
receiver, not the legacy spool sender. Normal behavior remains synchronous.

After encoding completes and the Vulkan queue mutex is released, enqueue moves
owned compressed bytes into two pending slots. The worker owns one additional
in-flight packet. Only frame identity, host time and pose/FOV floats cross this
boundary; borrowed GPU handles, callback pointers and file-path pointers are
explicitly erased. Queue access uses a short mutex. The synchronous compositor
caller never waits for capacity; the later raw encode worker may apply bounded
backpressure (see below). The compositor still blocks on GPU packing/NVENC
unless the raw encode worker is enabled; this is the transport
stage of decoupling, not a completely asynchronous renderer.

The queue owns at most 24 MiB of payload (two pending packets plus one in flight,
8 MiB each), plus at most one 8 MiB producer-side packet before enqueue. It cannot
grow. Port changes and worker I/O failure are explicit errors.
Do not discard arbitrary H.264 packets: later interframes can depend on them.
Without `METEOR_XR_ASYNC_ENCODE`, saturation remains fail-fast. With the raw
encode worker, enqueue waits at most two seconds for capacity before failing.
Delivery dequeue/failure wakes the waiter. This permits a cold hardware decoder
to initialize without aborting just because both pending slots fill. Queue
limits and encoded-packet order are unchanged. Only the raw worker's newest
pending job can be replaced before encoding. The wait occurs after releasing
the Vulkan queue mutex, not on the compositor or headset render thread.
Production reconnect/IDR recovery policy remains future work.

All socket operations remain subject to the existing two-second per-packet
deadline. Normal shutdown joins/drains queued delivery, sends END, verifies its
ACK, then closes the socket. At full capacity the transport drain can take up to
roughly eight seconds (three packet deadlines plus END), not an unbounded wait.
Failure discards/frees pending owned buffers and is reported; a stalled-peer
overflow test confirms finish returns in under three seconds for that case.
Native session teardown may wait for drain, but normal frame submission does
not wait for network ACKs. No socket wait uses the Vulkan queue mutex. The
temporary system list/timing lock remains around synchronous native capture,
but no longer surrounds normal network delivery in this mode.

The app's final capture acknowledgment now means GPU encoding and enqueue
completed. GPU resources may retire because the network worker only owns bytes
and copied metadata. The host harness separately requires successful delivery
drain and END acknowledgment before declaring the entire run passed.

## Validation

2026-10-19 startup correction: the first real-optics headset attempt failed
after three packet enqueues while the first decoder ACK was outstanding.
The optics handshake succeeded (62.464 mm eye separation); no decoded frame
appeared before fatal stream shutdown. This exposed fail-fast queue saturation
during cold decoder startup. A new socket regression delays the first ACK by
150 ms, fills both pending slots and confirms all four encoded packets arrive
in order, with END/drain succeeding. A permanently stalled peer still fails
with rejected-packet ownership preserved. The full negotiated-optics host
regression passed 120 submissions / 119 delivered, final frame drained.
The real-headset retry then passed: 237 frames delivered and decoded with final
drain, and the user reported smooth playback. Actual service logs contain no
delivery rejection; preflight negative-test rejection logs are expected.

- Unit test: transfer ownership, actual ACK/END, bounded two-packet pending queue,
  stalled peer/overflow, rejected-packet ownership retained by caller, bounded
  failure cleanup, empty reset state.
- Integrated free-running stripe run: 120 submitted, 103 encoded/delivered,
  17 compositor skips; exact bitstream hashes, poses/FOVs/timestamps, correct
  source stripe markers, final frame drain and balanced image leases.
- Queue peak in that run: one pending packet; all 103 packets acknowledged.
- Original synchronous 32-frame loopback regression still passed.
- Deliberate app termination passed: five encoded packets drained and matched
  through the receiver, with balanced image reservations and clean release.
- Six transport helper tests, six frame-accounting tests and 12 Rust wire tests
  passed as part of the test sequence.

The transport harness now derives stripe markers from app submission timestamps,
not packet ordinal, since a free-running compositor may legitimately skip app
frames. The worker logs `METEOR_DIRECT_OK` only after an actual receiver ACK;
`METEOR_ASYNC_QUEUED` is not treated as proof of delivery. Scene RGB-reference
checks remain in the parent host harness, not the stripe-only oracle.

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  NIGHTFALL_XR_PROBE_FRAMES=120 bash tools/build_support/probe_xr_transport.sh

# USB visual test; arm only when the tester is ready:
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_headset_xr_tracking_runtime.sh
```

No APK changes were needed. Asynchronous USB delivery was subsequently tested:
the user reported it looked the same as the previous stable scene. The host
accounted for 120 submissions / 117 encoded packets / three compositor skips,
drained all 117 packets with peak pending=1, and passed decoded-reference checks
(mean byte error 1.095). Device logs reached final sequence 116 and clean EOS.
This confirms no reported visual regression, not a measured latency improvement
or higher resolution/frame rate.
Next: independently owned raw-frame/image jobs, bounded pre-encode queue,
completion fences and NVENC decoupling, then realistic stereo dimensions/rate.
Keep the tiny CPU-reference renderer clearly diagnostic, not a performance target.
