# USB tracking and clock-exchange diagnostic

Branch: `feat/meteor-xr-streaming`, 2026-10-18.

The headset DEV projection path now samples a dedicated OpenXR `LOCAL` reference
space before attempting to acquire any decoded image. A `VIEW` space located
relative to that `LOCAL` space provides the head pose. `CLOCK_MONOTONIC` is
explicitly converted with `XR_KHR_convert_timespec_time` for the locate call;
the packet timestamp remains client monotonic nanoseconds, not raw `XrTime`.
Missing extension/functions fail entry rather than guessing the clock epoch.

The first device attempt rejected entry because the early clock-extension wrapper
was still guarded by the retired ALVR feature flag. Registration now happens at
CORE for Android independently of ALVR, before OpenXR instance creation. Merely
requesting the extension on the later scene-created projection object is too
late. Rejection logs distinguish a busy projector from a missing clock extension.

This is a diagnostic head-pose path, **not production PCVR**. The standalone host
probe validates and records poses. An optional shared-library bridge now feeds
live samples into the isolated Monado HMD. A separate tracked-scene fixture uses
host render poses/FOV, explicitly mapped as described below. Controllers, velocities,
prediction, recenter/origin generations, clock drift updates, real FOV/IPD
negotiation and authenticated transport remain outstanding.

## Ownership and bounds

`MeteorTrackingEndpoint` binds only `127.0.0.1:49091`, accessed through an
authorized ADB forward. The existing video endpoint stays on `49090` with its
unchanged ACK protocol. No new discovery or LAN listener is enabled.

The render thread publishes a latest-only sample using a try-lock: no socket
calls or waiting for the host, no growing sample queue. The worker accepts one
connection, handles partial I/O with two-second per-request deadlines and checks
stop every 10 ms. Poll requests wait for a new sample, rejecting samples older
than 250 ms or dated in the future. Stop is requested during the existing
exclusive-test teardown; the frame loop waits for idle without joining a live
worker on the render thread. A new entry creates a new monotonic session epoch.
No automatic reconnection or implicit origin reuse is implemented.

## Wire format

All fields are little endian; floats are IEEE float32. All requests are 32 bytes:

| Offset | Field |
| --- | --- |
| 0 | Four-byte kind: `NFXC` clock, `NFXP` pose poll, `NFXQ` clean close |
| 4 | Version u16 = 1 |
| 6 | Size u16 = 32 |
| 8 | Host send timestamp u64 for clock exchange |
| 16 | Reserved zero u64 in requests |
| 24 | Reserved zero u64 in requests |

Clock response echoes its header and host timestamp, filling offset 16 with
client receive time and 24 with client send time. The host captures its receive
time and computes the difference of clock midpoints. The lowest-delay of eight
valid exchanges supplies the mapping; half its network RTT is reported as an
uncertainty estimate. This does not eliminate systematic network asymmetry.
Exchanges with negative elapsed/network time or network RTT over 100 ms fail.

Pose response is 64 bytes: `NFXT`, version u16=1, size u16=64, epoch u64 at 8,
contiguous response sequence u64 at 16, client sample time u64 at 24, position
xyz and quaternion xyzw (seven floats) at 32, four reserved zero bytes at 60.
Positions are metres, with right-handed OpenXR axes. Invalid/replayed sequences,
changed epochs, nonfinite values and non-unit quaternions are rejected. A clock
mapping is not an origin mapping: host integration must explicitly adopt/map the
Quest LOCAL origin before using these poses. Recenter/standby are not validated.

## Tests and use

```bash
# Pure packet/clock tests (no Android or sockets needed):
c++ -std=c++17 -Wall -Wextra -Werror \
  -Iextensions/nightfall-xr/include test/pcvr_meteor_tracking_test.cpp \
  -o /tmp/nightfall-meteor-tracking-test
/tmp/nightfall-meteor-tracking-test

# Real endpoint with a synthetic publisher: clock + 120 samples,
# malformed reserved bytes, truncated request / disconnect:
python3 test/test_meteor_tracking_endpoint.py

# With the new DEV build's decoded-stereo test already active:
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  bash tools/build_support/probe_xr_tracking.sh
```

The combined `probe_headset_xr_projection.sh` now runs the tracking probe before
sending any video, avoiding a decoder-startup dependency. It writes 120 mapped
pose records to `.build-cache/meteor-xr/tracking-spike/head-poses.jsonl` and then
runs the existing 120-frame Monado/NVENC video fixture. Synthetic socket tests
passed on Linux; the optimized Android extension compiles. Real headset collection
also passed: 120 fresh LOCAL poses with estimated clock uncertainty 144,298 ns,
followed by 120 decoded video frames. The user confirmed the head-following stripe
pattern. This does not establish a world-locked scene.

## Monado device and scene

`meteor_tracking_client_bridge.cpp` builds a diagnostic shared library with a
small C ABI. A dedicated worker performs the clock exchange and continually
receives poses; device initialization waits for the first valid sample. Pose
callbacks use a try-lock, never network I/O. A broken connection, a sample older
than 250 ms or a query more than 250 ms from the sample returns an invalid
relation. No velocity prediction or simulated fallback is substituted. The
device destructor stops/joins the worker before unloading the library.

The pinned Monado patch adds this optional hook to the simulated HMD, enabled only
by process-local `METEOR_TRACKING_BRIDGE`/`METEOR_TRACKING_PORT`. Normal Meteor and
system runtime registration remain unchanged. Device coordinates explicitly
adopt Quest LOCAL metres/axes, ignoring the original simulated motion.

Monado application LOCAL recenters at startup: fixed injected x=0.25 appeared near
x=0 in application views. Therefore its LOCAL poses cannot be presented directly
as Quest LOCAL. The diagnostic scene instead uses Monado STAGE, the root space
for this pinned simulated device. An automated moving-pose test checks that the
application's stereo midpoint preserves the injected root coordinates, not the
recentered ones. This mapping is specific to this isolated device, not a claim
that arbitrary hosts' STAGE and Quest LOCAL are interchangeable.

The scene app CPU-renders three colored spheres and a floor into its tiny eye
swapchains. This is a correctness/reference renderer, not a production rendering
path or benchmark. GPU packing/NVENC and hardware headset decode remain the same.
App readbacks must match generated pixels, and decoded video is compared with
per-eye RGB references. Tracked-scene video sets NFXR flags bit 1 (value 2) to
identify render poses in the explicitly adopted Quest LOCAL origin. Bit 0 remains
IDR. The mode cannot change within a stream, and END flags remain zero. In this
mode Nightfall submits the received render poses/FOV in its dedicated LOCAL
space, rather than attaching the image to its latest local views. The original
stripe fixture remains available and unchanged in meaning.

```bash
# After rebuilding the isolated runtime:
python3 test/run_monado_tracking_spike.py "$PWD"

# With headset ready and the latest optimized DEV APK installed:
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  bash tools/build_support/probe_headset_xr_tracking_runtime.sh
```

Five socket/bridge tests passed, including query limits and disconnect invalidation.
Changing injected poses reached a real application's `xrLocateViews` across 32
encoded frames; the original software capture regression also passed. The
tracked scene adds root-origin and encoded-image reference checks. Final visual
scene test succeeded on Quest 3 (“Nice like magic”); 120 frames passed with clean
teardown, decoded-reference mean byte error 1.158 and clock uncertainty estimate
133,676 ns. The simulated HMD's fixed FOV/IPD,
latest-only tracking, low frame rate/resolution, initial-only clock calibration,
and no recenter/standby negotiation remain diagnostic limitations.
