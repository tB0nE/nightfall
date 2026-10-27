# Meteor XR: managed Monado runtime spike

Next phase (2026-10-20): [desktop-to-immersive integration](meteor-xr-desktop-integration.md).
The isolated LAN path has now passed a physical one-minute 1024-per-eye test;
historical progress entries below retain the evidence and limitations at each step.

Active 2026-10-18, `feat/meteor-xr-streaming`. Supersedes the
[ALVR-first spike](meteor-xr-streaming-spike.md), retained as historical research.

Latest: **user-confirmed tracked USB scene**, 120 frames, clean teardown. See the
[session checkpoint](../../research/meteor-xr-session-checkpoint.md) for completed
steps, evidence, reproduction and ordered next gates. This is not production XR.

## Product contract

Install Meteor, run Nightfall, pair once. Meteor manages the supporting runtime
and service. A separate supporting service is acceptable; a separately configured
dashboard is not the product. Linux is the immediate spike; Windows is required,
not an optional afterthought. Several managed binaries can live in one installer.

An XR application selects Meteor's Monado-based OpenXR runtime. When it creates a
session, Meteor negotiates remote presentation with Nightfall. Do not detect an
arbitrary XR process and assume its output can be captured: runtime selection
must happen before the application creates its OpenXR instance/session.

Native OpenXR needs no mandatory SteamVR. OpenVR compatibility is a later explicit
track: xrizer/OpenComposite or optional SteamVR, not universal compatibility
promised by this first spike. Steam as a launcher is distinct from SteamVR.

## Boundaries

| Component | Responsibility |
| --- | --- |
| Meteor | Pairing, discovery, policy, service lifecycle, diagnostics and XR negotiation |
| Monado-based runtime | OpenXR API, virtual devices, app pacing, swapchains and composition |
| Streaming backend | GPU-image handoff, encoding, transport, render metadata and feedback |
| Nightfall | Local Quest OpenXR session, tracking/input, decoding, projection and local exit |

Keep the runtime as a native service behind Meteor's Rust control interface.
Do not reimplement OpenXR semantics in Meteor's depth server. Isolate Linux
FDs/systemd/D-Bus and Windows handles/service management behind platform adapters.

## Reuse and licensing

- Pin upstream Monado with a small recorded patch set/streaming target. Its main
  code uses BSL-1.0, permitting modification and redistribution. Review individual
  files, dependencies and notices before distributing a fork.
- WiVRn is the reference for virtual devices, tracking history, clock sync,
  compositor output, encoder handoff and reprojection. Reused GPLv3-or-later code
  retains its attribution/source obligations; do not describe copied work as a
  clean-room implementation.
- Keep Nightfall's successful synthetic projection, exclusive lifecycle and tests.
  ALVR source/artifacts remain research material, not a dependency of the new path.

## Stage 0: retire the detour safely

Remove the ALVR remote button and reject legacy entry. Ordinary builds must not
initialize/package ALVR. Stop only our temporary host processes, unregister only
our driver, and restore compositor files after verifying our wrapper and backups.
Preserve the user's reset ALVR preferences and active OpenXR runtime selections.
Retain logs and source for reference rather than deleting the research.

## Stage 1: isolated Linux runtime/service proof

Pin official Monado and WiVRn reference revisions. Build inside a container, with
no host package installation. Use a simulated HMD, isolated IPC socket and
process-local `XR_RUNTIME_JSON`: no global runtime registration, SteamVR, network,
physical-device/GPU passthrough or encoder.

Run a tiny OpenXR app against the separate service: enumerate the runtime,
discover an HMD, create an offscreen Vulkan-bound session, observe READY, begin/wait/end five
frames, locate stereo views, request exit and destroy resources. Bound waits,
stop the exact child service on failure, and repeat to verify socket cleanup.

Gate: reproducible runtime + IPC + session lifecycle. This does not prove pixels,
hardware encode speed, remote tracking, Windows operation or XR streaming.

## Stage 2: real app images, without networking

Implement a Meteor-specific compositor output/target guided by WiVRn; do not
capture a desktop mirror. Run a Vulkan OpenXR sample and obtain real eye images
and submitted layers. Validate pose, FOV, image origin, color/alpha and fences.
Start with one app, SDR, fixed dimensions/rate, no foveation or audio.

A debug readback is acceptable for correctness only. The production path must
hand GPU-local images to an encoder without a full-resolution CPU round trip.
Gate: correct, deterministic stereo output through our runtime target.

Progress: a diagnostic hook in an output copy of the pinned null compositor now
captures the actual submitted stereo textures inside the service. Asymmetric
eye patterns match app readbacks byte-for-byte after a bounded final-frame
acknowledgment. Two consecutive runs passed. This establishes raw image handoff,
not a general compositor: transformed subrects, pose/FOV-driven rendering,
blending, color conversion, asynchronous hardware fences and general encoder integration remain
outstanding. Do not treat the complete Stage 2 gate as passed yet.

Encoder feasibility: `probe_vulkan_nvenc.sh` proves independent exportable Vulkan
RGBA8 image → CUDA array → NVENC H.264 interop. `probe_monado_nvenc.sh` now connects
that code to actual Monado eye swapchains, GPU-packs them into one exportable
stereo image, encodes it and validates decoded markers plus exact monotonic
display timestamp. Pose/FOV metadata is recorded. The NVIDIA/Linux diagnostic now
also passes 32- and 120-frame changing-pattern sequences using one persistent
encoder and reusable GPU surface, with capacity-one blocking backpressure and
verified drain/release after normal exit or an intentionally killed app. These
are stop-and-wait correctness runs, not sustained-rate proof. Next: asynchronous
GPU synchronization and realistic stereo dimensions/rate. Keep CPU readback
capture separate from the actual encode path.

## Stage 3: tracking and remote video

Define a versioned XR control/stream protocol separate from GameStream desktop
and Meteor depth delivery. Pair/authenticate; negotiate dimensions, refresh,
codec, generation, clock mapping and capabilities. Specify every timestamp unit
and buffer ownership rule explicitly.

Initial framing proof: a versioned bounded header now transports actual encoded
frames with frame IDs, host monotonic times and both poses/FOVs to a loopback-only
Rust receiver. Live spool-forwarding tests pass 32/120 frames and partial output
after deliberate app disconnect, with byte/metadata/decoded-marker checks.
Direct callback delivery now replaces spool forwarding by default: a bounded
owned packet is copied during bitstream lock, then sent after NVENC and Vulkan
queue unlock. 32/120-frame tests pass. The old spool mode remains diagnostic-only.
This is an unauthenticated loopback test, not a product server or headset
transport. See the [transport report](../../research/meteor-xr-transport-probe.md).
Pairing/encryption, asynchronous delivery, tracking and client clock/reference-
space mapping remain required before remote deployment.

Headset milestone: the DEV client now has a USB-only receiver, Qualcomm hardware
AVC decoder and ImageReader/AHardwareBuffer import into its exclusive projection
test. Standalone device runs passed 32/120 in-order decoded buffers with exact
PTS-to-metadata matching and teardown. User visual testing confirmed the intended
left vertical/right horizontal patterns; logs show 120 decoded frames and a
single projection layer. Changing green deliberately flashes in this fixture.
This uses local test poses, not mapped host render poses; it is not
tracked PCVR. See the [headset decoder report](../../research/meteor-xr-headset-decoder-spike.md).

Tracking foundation: `pcvr_meteor_tracking.h` defines a fixed-size, versioned
LOCAL-space head-pose packet with epoch/sequence/time and quaternion validation,
plus a four-timestamp lowest-RTT clock mapping helper. Standalone native tests
cover replay, malformed packets, invalid poses, clock ordering, uncertainty and
overflow. The headset now publishes explicitly timed LOCAL head poses through a
separate loopback USB worker, independent of video. A host diagnostic performs
eight clock exchanges and validates 120 fresh mapped poses; three synthetic
socket regressions pass, and the optimized Android extension builds. Real
headset collection passed with 120 fresh poses and approximately 0.144 ms clock
uncertainty estimate, followed by 120 video frames. An optional live bridge now
feeds the isolated Monado HMD; changing synthetic poses reached application
`xrLocateViews` across 32 encoded frames. The new sphere/floor scene uses the
explicitly adopted root origin and host render poses/FOV. Automated origin and
encode/decode reference checks pass. User confirmed the live tracked scene on
Quest 3, with all 120 frames and clean teardown. Real-device FOV/IPD negotiation,
sustained-rate streaming and recenter handling remain outstanding. See the
[tracking report](../../research/meteor-xr-tracking-spike.md).

Next pacing experiment: opt-in `NIGHTFALL_XR_FREE_RUNNING=1` removes per-frame app
file waits while retaining final exact-timestamp drain. Changing stripes exposed
reused image pixels paired with older metadata. Explicit per-image reservations
in multi-compositor slots now fix that 32-frame regression without relaxing the
validator. Six accounting tests and image-reservation balancing tests cover the
host path. See the [ownership report](../../research/meteor-xr-image-ownership.md).
The correction conservatively holds a system lock through synchronous native
capture; this is not the final async design or sustained-rate proof. Keep the
stop-and-wait default; free-running USB validation remains outstanding.

Update: user confirmed the free-running USB scene remained world-locked; all
120 frames were delivered and teardown was clean. Next transport stage adds
opt-in `NIGHTFALL_XR_ASYNC_DELIVERY=1`: two pending owned compressed packets plus
one in flight, no normal network ACK wait in native capture, explicit queue-full
failure rather than dropping dependent H.264 packets. Integrated loopback passed
103 packets from 120 submissions with exact content/metadata, synchronous
regression passed, and interrupted-app drain passed five packets. Async USB visual
validation is next; GPU packing/encoding remain synchronous. See the
[async delivery report](../../research/meteor-xr-async-delivery.md).

Next update: user confirmed asynchronous delivery looked unchanged; 117 packets
from 120 submissions drained correctly. An independently owned raw encode queue
is now host-tested under `NIGHTFALL_XR_ASYNC_ENCODE=1` (requires both existing
opt-ins). It keeps one active and one newest-only pending raw job, preserving
image reservations/references through encoding. Stripe and tracked-scene tests
pass, as do original synchronous and software regressions. New-mode headset
validation is next; resolution/pacing remain diagnostic. See the
[raw worker report](../../research/meteor-xr-async-encoding.md).

The full worker-driven scene was user-confirmed stable: all 120 frames drained.
The next profile now supports 512x512 per eye and a 60-Hz target, with the optimized
APK installed, stripe/scene host checks and standalone Quest decoder checks
passing. Measured host scheduled cadence was ~46.9 Hz, not a proven 60-Hz stream.
Detailed profiling exposed and reduced CPU-reference overhead; explicit color
metadata fixed a larger-profile RGB mismatch. Larger-profile visual confirmation
is next. See the [profile report](../../research/meteor-xr-resolution-rate-profiles.md).

1. Nightfall sends timestamped poses/valid velocities before the first video
   frame, not only after decoder initialization. Avoid a startup dependency loop.
2. Runtime exposes the virtual HMD and predicts app poses for requested times.
3. Output target hands synchronized stereo images to a selected encoder.
4. Frames carry identity, render poses/FOVs and timing metadata.
5. Nightfall decodes GPU buffers and presents through its existing session/frame
   loop. Reuse the projection work, not the ALVR core/context or transport.
6. Keep decoded-image pose distinct from latest tracking; explicitly map clocks
   and fence buffer reuse. Never assume matching clock epochs.

Use a deterministic pattern before a game. Log each stage; black/no decoded frame
is not RUNNING. Software encoding may isolate correctness but must be labelled
diagnostic, never silently substituted for production hardware encoding.

Gate: tracked stereo sample in Nightfall, first-frame evidence, measured encoder
timing, repeat entry/exit, disconnect and bounded recovery.

## Stage 4: Meteor-owned UX

Use the existing exclusive lifecycle. Initially require clean welcome with no
live stream/browser; implement automatic live-content shutdown only after drain
tests. During remote VR submit no desktop/browser/AI depth/ambient/passthrough/
menu/keyboard layers. Preserve Meta system UI and deliberate local exit.
Failure/exit returns welcome without automatically reopening prior content.

Meteor keeps the runtime/service discoverable when XR is enabled and Nightfall
is available, so apps can find a virtual headset before requesting a session.
Session presentation triggers negotiation; obtain headset consent before replacing
its current experience. Installer/runtime activation must be explicit and
reversible. Spikes use process-local runtime selection only.

Expose one XR enable policy with tested automatic encoder/resolution/rate
defaults. Diagnostics belong in developer tools. Fallback is visible and
validated, not a hidden performance change.

## Stage 5: Windows feasibility before product commitment

Build the same pinned runtime/service on Windows. Prove D3D11 first, then D3D12
and Vulkan where relevant; verify actual shared images/fences and encode interop,
not compilation alone. Add portable IPC/service adapters.

Some Monado Windows limitations concern physical displays/headsets our network
target does not need. That is a hypothesis, not proof the remaining path works.
Windows success is an architecture gate: document missing work and cost before
committing to a product or changing foundations again.

## Later gates

Controller actions/tracking/haptics; recenter and bounds; standby recovery;
audio/microphone clocks and permissions; NVIDIA/AMD/Intel driver matrix; Proton/
OpenXR and explicit OpenVR game compatibility; reversible install/uninstall,
updates, notices/source packaging and crash diagnostics. Only then revisit
desktop/browser/passthrough coexistence.

## Current tooling

`tools/build_support/monado_xr_versions.sh` pins inputs.
`probe_monado_runtime.sh --build` builds the isolated release service and app;
`--test` exercises the offscreen lifecycle. Evidence and limitations belong in
[the integration report](../../research/meteor-xr-monado-integration.md).
