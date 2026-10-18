# Meteor XR checkpoint — 2026-10-18

Branch: `feat/meteor-xr-streaming`. Latest tested headset artifact:
`Nightfall-Android-arm64-v8a-dev.apk`, optimized/release-signed DEV, ALVR OFF.
Build/install log: `/tmp/nightfall-tracked-scene-apk.log` (temporary).

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
blocks on encoder/network acknowledgments; the app fixture also uses per-frame
file acknowledgment. These deliberate correctness constraints are not a
sustained-rate design. The final file ACK prevents app swapchains being destroyed
before the compositor consumes them.

## Reproduce / important files

Read [BUILD.md](../../BUILD.md) before building. Never substitute a debug APK for
performance testing or skip native rebuilding after C++ changes.

```bash
bash tools/build_support/probe_monado_runtime.sh --build
bash tools/build_support/probe_monado_runtime.sh --test
python3 test/test_meteor_tracking_endpoint.py
python3 test/run_monado_tracking_spike.py "$PWD"
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

1. Remove **per-frame app file ACK pacing** in an opt-in diagnostic mode while
   retaining the final exact-timestamp drain ACK. Account for compositor-dropped
   app frames explicitly and match encoded frames to the correct references.
   Keep the existing stop-and-wait tests as correctness regressions.
2. Decouple compositor/encoder/transport with bounded ownership and newest-frame
   policy, explicit completion fences and drain. Do not merely remove a mutex or
   reuse a surface while the encoder/compositor still owns it.
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
