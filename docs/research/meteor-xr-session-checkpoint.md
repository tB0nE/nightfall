# Meteor XR checkpoint — 2026-10-18

Branch: `feat/meteor-xr-streaming`. Latest installed headset artifact:
`Nightfall-Android-arm64-v8a-dev.apk`, optimized/release-signed DEV, ALVR OFF.
Latest build/install log: `/tmp/nightfall-xr-profile-apk.log` (temporary).
Tracked-scene checkpoint commit: `f86bace`.

## Current result

The user successfully viewed a tracked host-rendered scene on Quest 3: three
colored spheres and a floor responded to head movement. Feedback: “Nice like
magic”. The combined fixture passed 120 encoded/decoded frames; the decoded
scene's mean byte error against app-side references was 1.158/255. Hardware
decoder shutdown and render-resource retirement completed without replacing the
Godot OpenXR session. Tracking clock uncertainty estimate was 133,676 ns.

This is a real **USB tracked-scene proof**, not a game-ready Meteor feature or a
performance benchmark. There is no normal Meteor pairing/discovery integration,
LAN streaming, audio, controller input or Windows proof yet. No SteamVR/ALVR is
required or running as part of this path. No system runtime was registered.

## Steps completed, in order

1. Retired the ALVR experiment while retaining its source/artifacts. Preserved
   user Steam/ALVR preferences and restored only our temporary host changes.
2. Preserved the local synthetic Quest projection and exclusive lifecycle.
   Uses Godot's existing frame loop, not a second wait/begin/end sequence.
3. Pinned Monado and WiVRn references; built an isolated Monado service/runtime in
   Docker. The Monado input stays clean; our patch applies to an output copy.
4. Proved separate-service IPC, simulated-HMD session lifecycle and actual stereo
   swapchain capture, matching app/service readbacks byte-for-byte.
5. Proved Vulkan image -> CUDA array -> NVENC, then integrated actual Monado eye
   images with GPU stereo packing. One persistent encoder/surface, bounded
   backpressure, metadata and clean drain; no service image readback.
6. Added bounded versioned NFXR framing, first via diagnostic spool forwarding,
   then direct owned-bitstream transport after encoder/Vulkan queue unlock.
   Rust receiver and malformed/truncated/order tests cover the loopback protocol.
7. Added USB-only Android receiver, Qualcomm MediaCodec, ImageReader and fenced
   AHardwareBuffer import. Standalone device tests passed 32 and 120 buffers.
8. Presented decoded stereo through one Quest projection layer. User confirmed
   vertical left-eye and horizontal right-eye patterns. Flashing was intentional
   changing-green test data, not evidence of a presentation fault.
9. Added a separate USB tracking endpoint with latest-only LOCAL head poses and
   explicit monotonic-to-OpenXR conversion. Fixed early clock-extension
   registration accidentally left behind the retired ALVR feature flag.
10. Proved 120 real headset poses and explicit four-timestamp host/client clock
    mapping before video. No assumption that clock epochs match.
11. Added a live worker/C-ABI bridge to the isolated Monado virtual HMD. Invalid,
    stale or disconnected tracking does not silently use simulated motion.
12. Verified changing injected poses through application `xrLocateViews`.
    Discovered Monado LOCAL startup recentering; explicitly used its root STAGE
    for this pinned diagnostic device, adopting Quest LOCAL coordinates.
13. Added the pose-responsive scene, app pixel references and lossy decode checks.
    NFXR flags bit 1 identifies the explicitly adopted Quest LOCAL render poses.
    Quest submits received render poses/FOV in its dedicated LOCAL space.
14. User visually tested the complete USB path successfully; logs confirm 120
    frames, hardware codec, live poses and clean teardown.
15. Added an opt-in free-running app mode, leaving the proven stop-and-wait mode
    as default. Removed per-frame app file-ACK waits only in the new mode; final
    exact-timestamp acknowledgment is mandatory before swapchain destruction.
    The isolated scene test initially passed (32 submitted / 28 encoded, four
    skips, final drained, mean byte error 1.054), but the stronger changing-stripe
    regression **failed**: first encoded timestamp referred to submitted frame 0,
    while green=217 corresponded to later source content instead of frame 0's
    green=0. This is evidence of an image-lifetime/metadata association problem,
    not merely legitimate frame dropping. The smooth scene's average-error test
    was not sensitive enough to expose it. Six pure accounting tests pass, but
    free-running image correctness is NOT established. Keep this opt-in mode as
    a failing diagnostic reproducer, not a supported streaming option. The
    headset remains on the proven scene APK and stop-and-wait default.
16. Corrected the ownership failure in the isolated Monado patch: stereo
    multi-compositor slots reserve each image until dropped/retired; synchronous
    native capture keeps those slots alive through consumption. Fixed the pinned
    image-use decrement's double-unlock. Strict changing-stripe regressions now
    pass: 32 submitted / 27 encoded and 120 submitted / 108 encoded, with all
    skipped app frames accounted for and final drain verified. The original
    32-frame mode and five-frame interrupted-app run also pass with balanced
    image reservations. No headset APK changes. See the
    [ownership report](meteor-xr-image-ownership.md) for the temporary system-lock
    tradeoff and why this is still not asynchronous streaming.
    The software capture regression also passed, and the free-running tracked
    scene passed 32 submitted / 31 encoded with root-origin checks and decoded
    reference mean byte error 1.046. Free-running USB visual confirmation then
    passed: user saw the spheres remain world-locked, while noting very low
    resolution/frame rate. Logs show 120 submitted / 120 encoded frames, no
    compositor skips, final drain, decoded-reference mean byte error 1.123 and
    clean hardware-decoder/render-resource teardown. This confirms correctness,
    not acceptable streaming quality or sustained-rate performance.
17. Added opt-in bounded asynchronous compressed-packet delivery. A worker owns
    two pending packets plus one in flight, with no borrowed GPU handles. The
    120-submission loopback stripe run delivered all 103 encoded packets (17
    compositor skips), exact bytes/metadata/source markers and clean drain;
    peak pending was one. Original synchronous 32-frame transfer still passed.
    Stalled-peer/overflow tests verify bounded failure and ownership cleanup.
    This decouples network delivery only; GPU packing/NVENC still block capture.
    See the [async delivery report](meteor-xr-async-delivery.md). No APK changes.
    User then tested async USB delivery and reported the same stable scene:
    120 submitted / 117 encoded/delivered, three compositor skips, all packets
    drained, peak pending one, decoded-reference mean byte error 1.095 and device
    EOS after sequence 116. No latency or quality improvement was measured.
18. Added a raw encode worker with independent image reservations, swapchain
    references, saved render metadata/frame ID, one active and one newest-only
    pending job. The compositor no longer waits for GPU packing/NVENC in this
    opt-in mode. Full stripe run passed 120 submissions / 106 accepted raw jobs /
    one pending replacement / 105 encoded and delivered. Tracked-scene host run
    passed 32 accepted / 31 encoded, mean reference error 1.053. Original 32-frame
    transport and software pixel-capture regressions passed. See the
    [raw worker report](meteor-xr-async-encoding.md). No APK changes; new-mode USB
    confirmation and hardware failure/standby cases remain outstanding.
    Update: the user confirmed the full worker-driven USB scene was stable.
    All 120 submissions were accepted, encoded and delivered, with no replacements
    or skips, network peak pending one, mean reference error 1.182, final drain
    and clean teardown in the unchanged OpenXR session. Hardware failure/standby
    recovery and realistic resolution/rate remain unproven.
19. Added bounded 256/512-per-eye decoder profiles and 20/60-Hz host targets.
    Installed the optimized DEV APK. The 512/60-target stripe run passed 120
    frames; tracked scene passed 119 of 120 submissions with one raw replacement;
    standalone Quest decoding passed 32 1024x512 buffers. Fixed unspecified
    color-matrix signaling exposed by the wider stream, without relaxing RGB
    tests. Optimized the reference app and added detailed stage timings: median
    both-eye app work 12.776 ms, pack 0.195 ms, encode/copy 0.761 ms. Host scheduled
    display cadence was approximately 46.9 Hz, **not proven 60 Hz headset output**.
    Larger-profile USB test completed 240 submissions / 239 decoded frames,
    one raw replacement, mean reference error 0.888 and clean shutdown. User
    feedback was tentative; this does not establish sustained 60 Hz. See the
    [profile/timing report](meteor-xr-resolution-rate-profiles.md).
20. Added opt-in Vulkan compute rendering of the same tracked scene, retaining
    independent CPU pixel validation before performance work. Initial 32-frame
    host run passed with 31 delivered and one pending replacement. No new APK
    is required. GPU-scene headset confirmation and a measurement-only mode
    remain outstanding. See [GPU scene](meteor-xr-gpu-scene.md).
21. Added separate `NIGHTFALL_XR_GPU_MEASURE=1` opt-in: device-local storage,
    no app CPU oracle/readback/artifacts, per-eye completion fences and GPU
    timestamp queries. 120 submissions yielded 118 decoded frames with all skips
    accounted for and final drain. Median both-eye app work 335.5 us, GPU
    dispatch/copy 33.984 us per eye; host scheduled cadence 55.28 Hz, not Quest
    FPS. Correctness mode remains default. Measurement-path headset confirmation
    and realistic optics/application workloads remain next gates.
    Update: user tested on Quest and reported it felt quite smooth. 240
    submissions / 238 encoded and headset-decoded frames, one pre-worker skip
    and one raw replacement, final frame drained; host scheduled cadence 58.04
    Hz. App both-eye median 815 us; GPU dispatch/copy 33.92 us per eye.
    Host shutdown passed; device log captured the final picture hold, not the
    later local exit. Real optics and realistic workloads remain outstanding.
22. Added opt-in headset optics snapshot (`NIGHTFALL_XR_HEADSET_OPTICS=1`).
    Quest publishes eye poses relative to VIEW and asymmetric FOV; a validated,
    epoch-bound handshake initializes the Monado virtual HMD before use.
    Synthetic optics were verified in actual encoded render metadata, with
    both measurement and full pixel-validation runs passing. Seven socket
    tests plus native malformed-packet tests pass. Rebuilt and installed the
    optimized DEV APK; real-headset optics confirmation remains outstanding.
    See [optics report](meteor-xr-headset-optics.md).
    First headset attempt negotiated valid optics (62.464 mm separation), but
    video startup failed when the encoded delivery queue filled before the
    decoder's first ACK. Added up-to-two-second capacity backpressure only on
    the off-compositor raw encode worker; fixed queue size and encoded order
    retained. Delayed-ACK and stalled-peer regressions pass, as does the full
    120-submission negotiated-optics host run (119 delivered). No APK change
    needed for this host fix; real-headset retry pending.
    Retry succeeded: user reported very smooth playback and FOV filling the
    screen. Real eye separation 62.464 mm; 240 submitted / 237 encoded and
    headset-decoded frames, two pre-worker skips plus one raw replacement,
    final frame drained. Host scheduled cadence 57.27 Hz, not measured Quest
    presentation FPS. App both-eye median 590 us; GPU dispatch/copy 33.984 us
    per eye. Host shutdown clean; device log ends at final-picture hold.

## Architecture and ownership

Quest pose sampling -> loopback port 49091 over authorized ADB -> host clock
mapping/tracking worker -> Monado device callback -> OpenXR app -> actual eye
swapchains -> GPU pack -> persistent NVENC -> owned compressed packet -> loopback
port 49090 over ADB -> MediaCodec/ImageReader -> fenced AHardwareBuffer/GLES import
-> one projection layer in the existing Godot OpenXR session.

Only compressed bytes return from the encoder to CPU. The tiny scene app itself
uses a CPU reference renderer/upload/readback strictly for correctness testing;
do not confuse it with the production compositor's GPU-local video handoff.

The headset render thread does not wait on socket I/O. The host compositor still
blocks on encoder/network acknowledgments. The default app fixture also uses
per-frame file acknowledgment; opt-in free-running mode removes that app wait,
but not compositor/encoder/network blocking. Neither is a sustained-rate design.
The final file ACK prevents app swapchains being destroyed before the compositor
consumes them.

## Reproduce / important files

Read [BUILD.md](../../BUILD.md) before building. Never substitute a debug APK for
performance testing or skip native rebuilding after C++ changes.

```bash
bash tools/build_support/probe_monado_runtime.sh --build
bash tools/build_support/probe_monado_runtime.sh --test
python3 test/test_meteor_tracking_endpoint.py
python3 test/run_monado_tracking_spike.py "$PWD"
# EXPERIMENT: host image leases fixed; still synchronous / not production:
NIGHTFALL_XR_FREE_RUNNING=1 python3 test/run_monado_tracking_spike.py "$PWD"
# Stronger changing-stripe regression (now passes with image leases):
NIGHTFALL_XR_FREE_RUNNING=1 bash tools/build_support/probe_monado_nvenc.sh
NIGHTFALL_PCVR_ALVR=OFF ./build.sh --dev --install
# Arm only when the tester is ready; button press deadline is 60 seconds:
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  bash tools/build_support/probe_headset_xr_tracking_runtime.sh
```

Device button: `DEV: Meteor decoded stereo`. Exit: hold B/Y one second. Current
auto-exit is 45 seconds; fixture is bounded to at most 240 frames. Test requires
clean welcome, no active stream/browser. Remove/re-wear/recenter recovery is not
validated. Each fixture removes only its own ADB forwards and logcat process.

Persistent ignored evidence: `.build-cache/meteor-xr/monado-nvenc-spike/`
(service/app logs, H.264, metadata, decoded/reference RGB),
`headset-tracking-runtime-spike/device.log`, `tracking-spike/head-poses.jsonl`.
Runs overwrite their own artifacts, so preserve a run elsewhere before another
test if needed. Host is Linux/NVIDIA RTX 3090; device is Quest 3.

Details: [active plan](../plans/active/meteor-xr-monado-spike.md),
[transport](meteor-xr-transport-probe.md),
[decoder/ownership](meteor-xr-headset-decoder-spike.md),
[tracking/origins](meteor-xr-tracking-spike.md).

## Next work, with gates

1. Free-running changing-stripe correctness and USB world-lock are now confirmed.
   Reproduce the successful USB scene using the same installed APK:
   `NIGHTFALL_XR_FREE_RUNNING=1 bash tools/build_support/probe_headset_xr_tracking_runtime.sh`.
   Next address asynchronous delivery and realistic rendering dimensions/rate,
   rather than treating this tiny CPU-reference scene as a performance result.
   Preserve final drain and stop-and-wait defaults. Free-running app-crash
   accounting is still unsupported; the harness rejects that combination.
2. Network and raw-worker USB testing passed with `NIGHTFALL_XR_ASYNC_ENCODE=1`,
   `NIGHTFALL_XR_ASYNC_DELIVERY=1`, `NIGHTFALL_XR_FREE_RUNNING=1`.
   The 512-eye USB sequence passed; next improve sustained-rate
   measurement, reference rendering and GPU completion fences/pools.
   Do not merely remove a mutex or reuse a surface while encoding still owns it.
3. Negotiate real Quest FOV/IPD/resolution/rate, refresh clock calibration and add
   tracking history/valid velocities/prediction, explicit origin generations,
   recenter and standby handling. Test realistic stereo dimensions/rates.
4. Repeat entry/exit, interrupted transport/app, slow peer and headset standby;
   confirm bounded failure and no residual layers or leaked codec/GPU resources.
5. Integrate authenticated negotiation and managed service lifecycle into Meteor.
   USB-only unauthenticated diagnostic endpoints must not become public LAN APIs.
6. Windows D3D/shared-image/fence/encoder feasibility is a required architecture
   gate; Linux/NVIDIA success is not proof of Windows/AMD/Intel support.
7. Then controller actions/haptics, audio/mic clocks, OpenVR compatibility,
   installer/licensing review and eventual desktop/browser coexistence.
