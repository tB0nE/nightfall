# Meteor XR headset decoder/projection spike

2026-10-18, `feat/meteor-xr-streaming`. Builds on the
[Monado image/encoder proof](meteor-xr-monado-integration.md) and
[diagnostic packet transport](meteor-xr-transport-probe.md).

## What exists

The optimized release-signed DEV APK has a new welcome button:
**DEV: Meteor decoded stereo (USB test; not tracked PCVR)**. It enters the same
exclusive lifecycle as the successful synthetic projection: no Sunshine/browser,
passthrough, AI depth, keyboard or menus during the test. It uses Godot's existing
OpenXR session/frame loop and submits one double-wide projection layer. No ALVR
core or SteamVR is needed. The ordinary synthetic button remains for regression.

The listener binds only 127.0.0.1:49090 **after explicit local test entry**. An
authorized ADB USB forward connects the host's direct packet sender to it. No
LAN listener, discovery endpoint, firewall change or authentication bypass for
normal Meteor streaming is introduced. This test is not a public network server.

`PCVRMeteorReceiver` validates the fixed 152-byte NFXR header before payload
allocation (8 MiB maximum; 240 frames; fixed 512×256 SDR H.264 in this first
decoder test). Epoch, sequence, frame/time ordering, finite unit eye poses/FOVs,
Annex-B and initial SPS/PPS/IDR checks mirror the Rust receiver. Decoder input is
bounded; unexpected dimensions/metadata/codec errors fail, not silently fall back.

## Android path and ownership

1. A dedicated worker accepts packets and owns MediaCodec configuration, input,
   output polling and teardown. It explicitly verifies a Qualcomm hardware AVC
   decoder (`qti`/`qcom`); there is no software decoder fallback in this test.
2. The decoder outputs to an NDK AImageReader PRIVATE surface, with GPU-sampling
   usage and four image slots. There is no CPU RGB conversion or image readback.
3. Synthetic codec PTS = `(sequence + 1) * 1000` microseconds. The ImageReader
   nanosecond timestamp is matched exactly to the stored frame metadata. This
   timestamp labels decoder buffers; it is **not host/client clock mapping**.
   Metadata storage is bounded to eight outstanding records.
4. The render thread acquires the latest AImage asynchronously, polls its acquire
   fence without waiting, and imports its AHardwareBuffer through EGL/OES. It
   draws the packed left/right halves into the existing XR test swapchain.
5. A GLES sampling fence retains the AImage until GPU reads finish. Only then
   are the EGL image and AImage released for decoder reuse. No socket/decode wait
   runs on the render thread. Stop submits zero layers, drains GPU ownership,
   retires the XR swapchain, then requests worker/codec teardown and waits via
   status polling before returning to welcome.

END drains decoder EOS, acknowledges the accepted packet count and holds the
final picture until local exit. A disconnect without END fails the test. Hold
B/Y for one second to exit; Escape also works; 45-second automatic exit remains.
First decoded projection timeout is 15 seconds. Being connected/decoder-ready
does not count as RUNNING: at least one projection must actually be rendered.

## Critical limitation: not tracked remote PCVR yet

This is a deterministic image-pipeline test. It records received host poses/FOVs
and matches them to decoded buffers, but deliberately submits **local test viewing
poses/FOVs**, not host poses masquerading as Quest-local coordinates. The image
fills each local eye view and is not a correctly world-locked remote scene.
There is no remote tracking protocol, reference-space origin mapping, clock sync,
late reprojection, audio or controller transport yet. Do not test a game or call
this completed XR streaming. Standby/session-loss behavior and visual color/
orientation validation are additional tests, not established by decoder success.

## Verified automatically on Quest 3

`probe_android_xr_decoder.sh` builds a standalone optimized NDK executable using
the same receiver implementation, pushes it under `/data/local/tmp/`, creates a
temporary ADB forward, and runs actual Monado/NVENC output into the device.
It does not launch Nightfall or enter XR. The helper acquires/releases buffers
without sampling them, checking dimensions and sequence/metadata timestamps.

32-frame and 120-frame runs passed: all respective GPU buffers were acquired in
order, including final sequence 31/119, with hardware decoding and clean teardown.
This establishes reception/decoder/ImageReader metadata ownership, **not visual
OpenXR presentation**. Logs: `/tmp/nightfall-android-xr-decoder.log`,
`/tmp/nightfall-android-xr-decoder-120.log`. Artifacts:
`.build-cache/meteor-xr/android-decoder-spike/` (`decoder-probe`, `device.log`).
The temporary forwarding rule is removed on exit. The explicitly named helper
binary remains on the device for reruns; it does not run in the background.

```bash
NIGHTFALL_ADB=/path/to/adb bash tools/build_support/probe_android_xr_decoder.sh
NIGHTFALL_XR_PROBE_FRAMES=120 bash tools/build_support/probe_android_xr_decoder.sh
```

## Visual projection test

Use a clean welcome screen in the optimized DEV APK. Keep SteamVR/ALVR closed.
Start the fixture **before pressing the button**:

```bash
NIGHTFALL_ADB=/path/to/adb bash tools/build_support/probe_headset_xr_projection.sh
```

The fixture arms a private USB forward and log monitor, then waits up to 60
seconds. Tap the Meteor decoded stereo DEV button. It sends 120 changing frames
and requires an actual decoded-projection first-frame log. Expected: a red
left-eye image with a vertical brightness step and blue right-eye image with a
horizontal step; green changes between frames. This is a diagnostic pattern,
not a comfortable stereoscopic scene. Briefly close one eye at a time to check
identity/orientation. Confirm no residual welcome/menu layers, then hold B/Y to
return to welcome. Check entry/exit a second time. The last image remains after
the host sequence ends until exit or the 45-second deadman. The fixture removes
only its forwarding rule and log-monitor child on completion.

A decoder-only PASS is not a visual PASS. User testing has now confirmed the
intended vertical left-eye / horizontal right-eye split, with deliberately
changing green producing flashing. Logs show all 120 frames decoded and the
first frame presented through one projection layer. This does not establish
tracked PCVR or sustained-rate performance.

The fixture now also runs a separate USB tracking/clock diagnostic before video;
see the [tracking report](meteor-xr-tracking-spike.md). Real headset tracking
collection, Monado injection, reference-space mapping and authenticated session
negotiation must be validated before replacing this USB diagnostic with network
PCVR.
