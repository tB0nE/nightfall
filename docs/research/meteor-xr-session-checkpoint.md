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
23. Added optional Vulkan raster workload (`NIGHTFALL_XR_RASTER_SCENE=1`):
    25 rotating cubes and checkerboard, direct color-attachment rendering,
    real D32 depth testing and negotiated asymmetric eye projection. Host
    32- and 120-submission runs passed content smoke checks, transport,
    image accounting and final drain. Longer run delivered 118 frames;
    median both-eye app wall 285.5 us, per-eye GPU raster 7.424 us.
    This remains our lightweight diagnostic app, not independent game support.
    No APK rebuild needed. Headset confirmation pending. See
    [raster workload](meteor-xr-raster-scene.md).
    Headset confirmation: user saw the cubes and reported smoothness. 240
    submissions / 236 encoded and headset-decoded frames, three pre-worker
    skips plus one raw replacement, final frame drained. Host scheduled cadence
    58.02 Hz (not measured headset FPS); both-eye app wall median 678.5 us,
    per-eye GPU raster 7.616 us. Host shutdown passed; device log ends holding
    the final picture. Next gate is an independent OpenXR application.
24. Pinned/built Khronos `hello_xr` (SDK 1.1.65, commit
    `a9f14c416e383d05c142f5a2539a91fe3931b52a`), using its own Vulkan renderer
    and session loop. Explicit adapter limits swapchains/format, adds timestamp
    logging and final drain/exit, and disables unattended keyboard quit.
    Host 32- and 120-submission runs passed; longer run delivered 118 frames
    with balanced image ownership, matched timestamps, negotiated optics and
    clean shutdown. No pixel-oracle/game/controller claim. No APK rebuild
    needed. Headset confirmation pending. See
    [independent sample](meteor-xr-hello-xr.md).
    Quest test passed: user reported everything looked correct. 240 submitted /
    236 encoded and headset-decoded frames, four pre-worker skips, zero raw
    replacements, final frame drained, clean host shutdown. Host scheduled
    cadence 57.79 Hz (not measured Quest FPS). Packing median 284 us,
    encode/packet-copy 708 us. Device log ends holding the final picture.
25. Added optional two-controller pose/trigger/squeeze levels over the existing
    USB tracking channel, with validated epoch/sequence/freshness and cleared
    disconnected state. Quest samples existing Godot actions without another
    action set or sync. Monado WinMR stand-in devices consume grip/aim and
    trigger/squeeze-click; local menu/B/Y stay reserved, haptics not forwarded.
    Eight socket tests plus native malformed-packet tests pass. Synthetic input
    reached hello_xr's actual hand positions and squeeze-driven rendered scale;
    120 submissions / 116 delivered with clean drain. Optimized DEV APK rebuilt;
    real headset controller confirmation pending. See
    [controller diagnostic](meteor-xr-controller-spike.md).
    First Quest run delivered 235 frames with final drain. Actual sample logs
    show changing positions for both hands and left squeeze changing its cube
    to 0.05 m (right unsqueezed 0.1 m). User missed most of the live interval;
    visual confirmation and explicit right-squeeze test remain pending.
    Retry passed: user confirmed the behavior; both hands logged both 0.05 m
    and 0.1 m cube scales. 240 submitted / 237 delivered and headset-decoded,
    two pre-worker skips and one pending replacement, final drain and clean
    host shutdown. Device log ends at final-picture hold. First controller
    tracking/squeeze milestone is confirmed; full Touch mapping/haptics remain.
26. Checkpointed all validated raster/independent-app/controller work in
    `1dc0d23`. Began partial native Touch profile, opt-in via
    `NIGHTFALL_XR_CONTROLLER_PROFILE=touch`: grip/aim and trigger/continuous
    squeeze now use actual Touch bindings instead of WinMR click conversion.
    Host 120-submission test delivered 118 frames and verified each hand's
    intermediate 7.5 cm cube scale as well as 5/10 cm; actual Touch bindings
    appeared in upstream logs. No wire/ABI/APK change. Headset confirmation,
    buttons/sticks and haptics remain pending. This increment is uncommitted.
    Quest confirmation passed: user reported intended behavior; logs show both
    native Touch squeeze bindings and many intermediate hand-cube sizes on
    each hand. 240 submitted / 237 delivered and decoded, three pre-worker
    skips, no raw replacements, final drain and clean host shutdown. Device
    log ends at final-picture hold. Buttons/sticks/haptics remain outstanding.

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
# Extended Touch increment — 2026-10-19

After user-confirmed native Touch analog grip, added explicitly versioned V2
controller packets for thumbsticks, A/X, stick clicks and capacitive touches.
B/Y/menu/system remain local and haptics remain unimplemented. Host end-to-end
test passed (120 submitted, 118 delivered, clean drain), with assertions against
actual hello_xr action queries for both hands. Nine socket/bridge tests and
native protocol assertions passed. Updated optimized DEV APK installed.
Next: user headset test, inspect `HELLO_XR_TOUCH` logs for physical inputs;
sticks/buttons now have visual indicators, while grip changes hand cube scale.
See `meteor-xr-controller-spike.md` for protocol details and opt-ins.

The initial four-second physical-input test was too short. Added a 30-second
paced input diagnostic (240 frames, about 8 updates/s) and stick marker/X-A
width/stick-click height feedback in the host sample. No new APK required.
Await user confirmation; do not use this deliberately paced mode for latency.
The 30-second host regression passed: all 240 frames encoded/delivered, no raw
replacement or skipped submissions, clean final drain; both hands' extended
actions and existing pose/grip assertions passed.

User confirmed the longer physical controller test looked correct. Logs contain
226 active samples per hand, stick axes approaching both -1 and +1, and both
pressed/released states for X/A and both stick clicks. Hardware input validation
passed. This run hit the harness's 40-second app timeout after 226 submissions,
so clean final drain is NOT confirmed for this headset run. Increased the app
timeout by the explicit input-test duration to allow startup plus the longer
interaction window; this timeout adjustment awaits another hardware run.

## Next increment: bounded controller haptics

Added opt-in `NIGHTFALL_XR_HAPTICS=1` output forwarding through the tracking
worker (NFXH, epoch/sequence checked, latest-only per hand). OpenXR apply/stop
uses the existing Godot haptic action and hand subaction paths on the XR thread.
Cap .5 amplitude/150 ms, stale expiry, disconnect/teardown stop attempts.
Native protocol assertions and twelve endpoint/bridge tests passed. Optimized
release-signed DEV APK installed; rebuilt isolated Monado runtime. Hardware test
pending: fully squeeze each grip separately, feel rumble in that hand only,
then release/exit and confirm vibration stops. Existing 30-second paced input
fixture remains available. See controller-spike notes for wire and limits.
Host integration passed: real hello_xr vibration commands reached both synthetic
endpoint hands; 120 submitted/119 delivered frames, one pending raw replacement,
clean final drain. This is not yet evidence of physical headset rumble.

User confirmed the physical haptic test succeeded. Device logs show haptic
apply/stop returning XR_SUCCESS (result=0), including 50 ms/.5 amplitude pulses
and zero-duration stops; local resources and decoder were retired after exit.
The captured run ends around decoded sequence 158, before the 240-frame fixture
limit, so this confirms physical feedback/local exit, not a completed host
final-drain sequence. Next checkpoint should preserve the controller/input work,
then test repeat entry/exit, interrupted transport and standby recovery before
expanding beyond the isolated sample into real applications/managed service UX.

## Recovery increment after efba816

Committed controller/input/haptic milestone as `efba816`. Standby now goes
through `PCVRTestController.set_application_paused`: clears the local hold timer,
requests idempotent teardown, blocks new XR entry while paused, and never starts
XR automatically on resume. Resume still waits for native idle before restoring
welcome. Regression tests cover pause in preparation/connection/running, stale
callbacks, repeated pause, resume before teardown, and explicit fresh re-entry.

Added a real-socket native test reusing the SAME tracking endpoint and port over
six sessions: stop before connection, clean close, truncated disconnect, silent
peer timeout, stop during a partial read, and stale epoch rejection. Confirms
bounded exit, pending haptic stops, clearing pending commands on restart, and
reset sequence/epoch handling. All thirteen socket/bridge tests and the complete
GDScript suite passed (desktop logs retain the expected Android-only extension
warning). Optimized release-signed DEV APK built and installed successfully.

Hardware recovery remains unvalidated: run, hold B/Y to exit, re-enter; then
remove headset while running, replace it and confirm welcome/no stuck vibration,
followed by explicit re-entry. A headset-local early exit still interrupts the
host fixture rather than proving a normal 240-frame drain; graceful host-side
early-disconnect accounting remains outstanding. Do not label it a drain pass.

Hardware follow-up: user completed local exit, confirmed standby/re-wear behaved
as expected, then completed explicit post-standby re-entry. Re-entry device logs
show first-frame tracked projection, decoded video through sequence 85, haptic
apply/stop XR_SUCCESS for both hands, then resource/decoder retirement on the
same Godot session (0x1a). No application restart was required. This was another
early local exit, not a completed 240-frame drain. The host fixture still waits
for its app timeout after the headset exits; fixing that coordination is the
next task before treating interrupted runs as clean host lifecycle results.

## Host early-disconnect coordination

The diagnostic tracking bridge now emits a structured disconnect event after
an established connection fails. The host harness watches that event only for
USB headset runs (or the explicit tracking-loss regression), writes a run-local
sample exit request, and allows three seconds for graceful exit before targeting
only its own sample child for termination. No global runtime/process changes.
The sample checks requests even when tracking loss prevents visible rendering;
the first integration attempt exposed that necessary no-layer handling.

Interrupted outcomes write `lifecycle-outcome.json` with reason, encoded-frame
count, app exit code, forced-termination flag and `final_drain_verified: false`.
Startup failure before live encoded frames remains an error; normal host runs
still enforce their full strict frame/drain checks. No clean user-exit claim can
be inferred from a tracking disconnect alone (transport/protocol faults share
the event). Raw logs remain available. No new headset APK required.

Six lifecycle-helper tests and thirteen endpoint regressions passed. A real
OpenXR/NVENC test deliberately closed synthetic tracking after at least five
encoded frames: sample exited without timeout/forced termination and the run
was reported as interrupted, not full stream success. Hardware early-exit
recheck remains pending. Normal-stream regression passed separately: 120 app
submissions, 118 delivered frames, balanced bounded-worker accounting and clean
final drain; Touch inputs and haptic assertions also passed.

Hardware prompt-exit recheck succeeded: after user B/Y exit, tracking disconnect
was detected, hello_xr logged HELLO_XR_INTERRUPTED, returned code 0 without forced
termination, and the encoder was released. Outcome records 19 encoded frames,
`forced_app_termination: false`, `final_drain_verified: false`. Device retired
projection resources and stopped decoder/receiver on the unchanged session.
This confirms coordinated early exit, not completion of the full frame fixture.

## Application texture-layout preparation

Committed coordinated host exit as `8aec6a3`. Before independent applications,
removed the encoder's full-image eye requirement: bounded square subrects can
now be copied from larger RGBA8 UNORM source images. Output dimensions/wire and
Quest presentation are unchanged. Added native bounds tests and a magenta-padded
asymmetric source-region fixture; initial 512 async loopback test passed with
correct decoded markers and final drain (32 submitted/31 delivered).
See `meteor-xr-eye-subrects.md` for reproduction and remaining array/color/engine
compatibility gates. This is a prerequisite, not a real-game compatibility pass.
Final source-region fixture passed with explicit source-layout log assertions:
32 submissions/27 delivered frames. Original full-image regression passed 32/29.
Both validate decoded markers, bounded ownership/worker accounting and final
drain; do not interpret these short free-running runs as FPS benchmarks.

Texture-array support added next: carries submitted slice indices through the
encoder ABI; source barriers and copies operate on that slice. The fixture uses
one shared two-layer swapchain, reversed left/right slice indices, one acquire/
wait/release per stereo frame and per-slice image initialization. Existing
two-reference image leases remain balanced for shared images. Bounds/sample-count
tests reject invalid slices and multisampled inputs. Combined cropped-array 512
async test passed 32 submitted/29 delivered with decoded marker and final-drain
checks. Source-format support and an engine-native application test remain next.
The 256 shared-array strict run passed all 32 frames. Original separate-eye 512
async regression passed 32 submissions/30 delivered with balanced accounting,
correct decoded markers and final drain. No new APK required for these host-only
source-layout changes; hardware/game/validation-layer coverage is not implied.

## SDR source-format compatibility

Added RGBA/BGRA UNORM and sRGB source handling. RGBA uses direct copies; BGRA
uses a checked nearest GPU blit for channel order, preserving the transfer class
in the packing surface. Sources carry explicit formats through the encoder ABI;
unsupported/mixed-transfer/multisample inputs and mid-session format changes
are rejected. sRGB sources now advertise sRGB H.264 transfer metadata; UNORM
retains the legacy BT.709 policy. Linear-light UNORM and HDR are not auto-converted.

Native format-policy tests passed. The final four-format 512 async matrix used
reversed shared-array slices AND padded source rectangles. All passed app/encoder
format evidence, decoded colors/brightness markers, FFprobe transfer-tag checks,
bounded worker/lease accounting and final drain. Submissions/delivered counts:
RGBA UNORM 32/30, BGRA UNORM 32/27, RGBA sRGB 32/30, BGRA sRGB 32/28. The original
256 separate-image stop-and-wait regression passed all 32 frames. These short
correctness runs are not comparative throughput measurements.

No new APK required. New sRGB metadata interpretation on Quest is still a visual
hardware gate. See `meteor-xr-source-formats.md`. Next: an engine-native OpenXR
fixture with negotiated image size/layout/format, then an independent app; no
SteamVR/global runtime settings changed. Layout/format work remains uncommitted.
