# Windows XR development handoff — 2026-10-27

## Start here

Repository: https://github.com/tB0nE/nightfall

Branch: **feat/meteor-xr-streaming**. Fetch this branch from origin; do not start
from main or the older Windows binaries on the shared drive. The accompanying
`WINDOWS_XR_CHECKPOINT.json` records the exact pushed commit and copied APK hash.
The branch includes considerable XR work not yet merged to main.

```powershell
git fetch origin
git switch feat/meteor-xr-streaming
git pull --ff-only origin feat/meteor-xr-streaming
git status --short
```

If this branch is checked out elsewhere, use an appropriate separate checkout
rather than disturbing another agent's work. Preserve local Windows changes;
do not reset a dirty checkout to force the commands above through.

**Current priority: Windows XR support, then release preparation.** AMD Linux
optimization is parked pending preview-user feedback. Do not resume RX480 speed
tuning, depth-model experiments or spatial foveation as the next task.
Quest 2, Quest 3 and Quest 3S are intended supported clients. Quest 3 has the
physical acceptance coverage here; obtain preview feedback for the others.

## Product goal and implemented Linux experience

The user runs a Sunshine-compatible host and Meteor on the PC, then Nightfall
on Quest. They connect the ordinary desktop stream and launch an XR game from
that desktop. Meteor starts the managed XR session automatically. The XR scene
becomes the environment, with the desktop hidden until requested from a wrist
watch. The watch also opens PCVR settings without showing the desktop.
Exiting the XR app returns to the ordinary desktop workflow.

Do not require users to manually run ALVR, WiVRN, SteamVR and several helpers.
The abandoned ALVR spike is not the architecture to revive. Linux packages its
own patched Monado and independently built xrizer; WiVRN is a source reference,
not a runtime dependency. A Windows adapter may need a different compatibility
route, but assess and explain that explicitly rather than promising Linux
binaries or Wine/Proton wrappers will work on Windows.

Linux functionality implemented and exercised on this branch:

- Managed runtime install/enable/restart, integrity checks and dependency notices.
- One-time headset authorization, visible Approve/Reject notification and tray
  fallback; approval and Meteor host identity persist across restarts.
- Copyable per-user Steam launch options in the tray; launch intent starts XR
  without a separate manual priming step.
- Encoded stereo projection, tracking/reprojection, controller poses, buttons,
  stick clicks and haptics; real VRChat and Half-Life: Alyx testing succeeded.
- Additional composition-layer work and lifecycle fixes: consult the layer plans
  below for exact supported flags/extensions instead of assuming universal support.
- Wristwatch clock, desktop visibility, dedicated PCVR menu and desktop/menu links.
- Rectangular eye sizes, headset-derived resolution percentages, status reporting,
  refresh-rate coordination with the desktop stream, sharpening and supersampling.
- NVIDIA live bitrate and fixed-center QP-map foveation. These preserve encoded
  dimensions; they are not WiVRN-style spatial compression.
- Exit/relaunch, disconnect/reconnect and controller startup fixes. Accidental
  hold-B/Y quit behavior and the old five-minute XR test limit were removed.
- XR audio currently relies on retaining the Sunshine connection; microphone
  uses the existing Meteor path. An independent XR audio transport is optional
  future work, not an already implemented host feature.
- Generic Vulkan VDA downloads and hardware-grouped depth selection, alongside
  NVIDIA TensorRT. Do not conflate the depth GPU with the XR encoder GPU.

## What Windows has, and what it does not

Existing Windows Meteor desktop proxy/depth/microphone/tray and installer work
predates this XR integration. `docs/plans/active/meteor-windows.md` contains an
October 9 checkpoint and historical starting inventory; some of its early
"broken/not implemented" entries are superseded, and its NVIDIA-only scope is
not a current cross-platform GPU policy. Reinspect current source.

**Windows XR is not implemented or validated.** Concrete Linux assumptions:

- `meteor/src/xr_control.rs::validate_runtime_root` explicitly rejects non-Linux.
- Runtime startup/supervision in `meteor/src/xr_relay.rs` is Linux-gated.
- `meteor/src/xr_encoder.rs` invokes `/usr/bin/python3` and the Linux selector.
- `xr_launch_intent.rs`, Steam launch wrappers, runtime install/setup and manifest
  validation assume Linux paths, processes and IPC.
- The NVENC bridge uses Linux Vulkan/CUDA interop; AMD VA-API/DRM/DMA-BUF is Linux
  only. Windows needs actual Windows interop/encoder support, not a renamed DLL.
- Managed Monado, xrizer, `.so` library layout and Linux audio routes are not
  portable runtime artifacts. WSL can build Android, but cannot substitute for
  native Windows XR graphics, process management and GPU validation.

Do not merely bypass platform guards. Establish the runtime and graphics path
first, then integrate it behind platform adapters while preserving the protocol.

## Suggested Windows implementation sequence

1. **Establish the Windows baseline.** Build current Meteor in release mode;
   smoke-test pairing, Sunshine forwarding, depth, tray and microphone. Check
   Windows-only compile regressions introduced by Linux development. Preserve
   the working Windows data directory and host key.
2. **Resolve the runtime/compatibility design early.** Evaluate the pinned
   Monado source's Windows build, IPC and Vulkan-compositor requirements, plus
   OpenVR application compatibility on Windows. Demonstrate one native OpenXR
   sample creating a session with a packaged development runtime before building
   a product installer around it. Treat SteamVR/OpenVR application compatibility
   as a separate test, not an assumption that Linux xrizer is drop-in portable.
3. **Port NVIDIA first on the available Windows hardware.** Reuse capture,
   transport and lifetime concepts; implement supported Win32 Vulkan/CUDA or
   D3D/NVENC resource sharing and synchronization. Never CPU-copy raw video by
   accident or change GPU silently. Start with ordinary SDR H.264/HEVC, no
   foveation, validated stereo colors/orientation, then head tracking.
4. **Integrate managed lifecycle.** Windows runtime paths, scoped XR selection,
   launch detection/options, readiness/errors, cancellation, process-tree cleanup
   via Job objects and crash/relaunch handling. Preserve authenticated control,
   transport ownership and one-time approvals; no arbitrary remote command exec.
5. **Reach user workflow parity.** Controllers/haptics, composition layers,
   watch/menus, return-to-desktop and Sunshine-backed audio. Test consecutive
   launches, user exits, reconnect and headset removal. Keep shortcuts compatible
   with games; do not restore hold-B/Y exit or short test-session expiry.
6. **Restore supported live controls and report capabilities.** Advertise actual
   codecs, foveation and live bitrate; unsupported controls grey out without
   destroying saved preferences. Do not promise an AMD Windows backend based on
   Linux VA-API results. Add Windows AMD separately after NVIDIA works.
7. **Package for a fresh PC.** Bundle required runtime/compatibility libraries,
   notices and matching sources where required. Handle Visual C++ prerequisites,
   firewall/notifications, user-local paths, install/uninstall and retained keys.
   Avoid global OpenXR hijacking and conflicts with existing runtimes. Validate
   on Windows; Linux cross-compilation alone does not establish compatibility.

Acceptance target: install host/client, approve once, stream desktop, launch an
XR game, use watch/menu/controllers/audio, quit, reconnect and launch again—no
manual helper startup. Show actionable errors at every failed startup stage.

## Source map

Read `BUILD.md` before any headset build, then:

- `docs/plans/active/meteor-linux-installation.md`: chronological Linux packaging
  and current outstanding work; its final AMD section supersedes older lists.
- `docs/plans/active/meteor-amd-xr-encoding.md`: latest AMD state and test incidents.
- `docs/plans/active/meteor-xr-desktop-integration.md`,
  `meteor-pcvr-productization.md`, `meteor-xr-automatic-launch.md`.
- `docs/plans/active/meteor-xr-layer-expansion.md` and
  `meteor-xr-layer-compatibility.md`: layer work and limits.
- `meteor/README.md`, `meteor/RELEASE.md`: current Linux product/build experience,
  redistribution requirements and source-companion instructions.
- `meteor/src/xr_{control,session,relay,data,wire,trust,encoder,setup,launch_intent,library}.rs`:
  control, negotiated session, transport, authorization and lifecycle.
- `meteor/src/tray_windows.rs`, `desktop_windows.rs`, `config.rs`: existing
  Windows UX/configuration adapter points. Port relevant Linux tray features.
- `tools/meteor_xr.py`, `meteor_xr_runtime.py`, `meteor_xr_install.py`,
  `meteor_vr_library.py`: managed Linux installation and Steam integration.
- `test/meteor_vulkan_nvenc_probe.cpp`, `meteor_stereo_compositor.h`,
  `monado_nvenc_bridge.h`, `monado_*dispatch.h`, `monado_*hook.patch`,
  `monado_session_events.patch`, `monado_layer_policy.patch`: production-used
  bridge/capture/input sources despite their historical test/probe names.
- `extensions/nightfall-xr/src/pcvr_meteor_receiver.cpp`,
  `pcvr_projection_test.cpp`: Android decode and projection presentation.
- `src/meteor_xr_control.gd`, `src/pcvr_session.gd`, `src/welcome_screen.gd`,
  `src/ui_controller.gd`: inspect actual module names when following references;
  client handover/control/menu logic is already present.
- `tools/build_support/build_meteor_xr_bundle.sh`,
  `stage_meteor_xr_runtime.py`, `build_meteor_xrizer.sh`,
  `meteor/tools/build_release_sources.sh`: Linux packaging reference.

Pinned versions live in `tools/build_support/monado_xr_versions.sh`, currently:
Monado `eab5ff028a10db03200f6f3927a97bb6bb5d27ea`,
xrizer `a1216c7b53fb562a5bc4de473163e97a483042af`.
Use the pin file as authority, not an unpinned clone of upstream main.

## Builds and files supplied

Native Windows Meteor baseline (PowerShell from repo root):

```powershell
cd meteor
cargo test --release --locked --no-default-features
.\tools\build_windows_release.ps1 -ModelsDir '<directory containing current ncnn models>'
.\tools\build_windows_installer.ps1
```

Read each script's parameters/prerequisites first. The release script expects
`zipdepth_wide_512x288` and `zipdepth_edgepad_256` ncnn param/bin pairs, fetches
the pinned Windows ncnn SDK and builds without the development ONNX Runtime
feature. Existing share assets under `meteor/` may be older: verify the expected
model names/hashes instead of replacing current files with historical ones.
A successful existing Windows build does not itself provide XR support.

Shared directory: `/var/srv/media/Temp/nightfall-windows-build/` on Linux;
determine its current Windows drive mapping rather than assuming an old letter.
This handoff and a matching repo checkpoint are copied there, together with
`Nightfall-Android-XR-DEV-2026-10-27-arm64-v8a.apk` and `WINDOWS_XR_SHA256SUMS.txt`.
The copied APK is the latest deployed release-optimized, release-signed DEV APK,
not a newly built debug binary. It was built before the final host-only
diagnostic commits; its embedded revision may therefore say dirty/older commit.

APK SHA-256:
`9546ef3ae559ac9a6ce05da6871e06120d696218789e33ce69e22008a7c3a633`.
Install using the Windows ADB device serial, preserving app data (`adb install -r`).
Do not uninstall to bypass a signing mismatch: find the existing release key.
Keystore/.env were shared earlier; locate them without printing credentials.
No new secrets, trust keys, settings or personal logs are copied by this handoff.
The old `Nightfall-Meteor-0.1.0-Setup-x64.exe` and October 9 handoff in this folder
are historical, not a current XR build. No Windows XR binary exists yet.

For Android changes, `bash build.sh --dev` produces the release-optimized signed
DEV build. The user explicitly rejects performance testing with debug builds.
Read native-XR bootstrap instructions in BUILD.md; do not silently skip C++
rebuilds or use stale libraries. Native dependencies/build caches are not in Git.

## Current Linux checkpoint / known limitations

Recent key commits, oldest first:

- `0c378c8`: managed XR runtime, bundled xrizer, approvals and Steam setup.
- `1d54a32`: one-click PCVR runtime setup/restart.
- `1fb5d1e`: Vulkan VDA downloads and release source packaging.
- `98bcd2d`: GPU-only AMD VA-API encoding and Polaris compositor fixes.
- `473f231`: packaged AMD encoder libraries and encoder GPU selection.
- `0558500`: host-capability gating for foveated encoding.
- This handoff checkpoint also contains diagnostic-only AMD follow-up tools and
  findings; use the accompanying checkpoint JSON for its exact commit.

RX480: H.264 Main works; High produced corrupted output with packaged FFmpeg
8.0.1. Full-size 2048×1024 Main CBR is about 55–57 fps; HEVC is faster. No ROI/QP
foveation or live bitrate on AMD. A VBR diagnostic reset the desktop GPU; do not
ship it or describe AMD crash causes as fixed. The user chose to defer further
AMD work to preview feedback. Spatial foveation is documented, not implemented.
No production tuning was changed by those follow-up experiments.

The development PC uses RX480 for its desktop and RTX3090 for NVIDIA work. XR
rendering/composition and encoding must use the same selected GPU; no hidden
cross-vendor transfer. Auto prefers NVIDIA on a mixed machine. Depth and Sunshine
capture GPU choices are separate. The Windows user's layout may differ.

Latest tested Linux AppImage SHA-256:
`151bf056abb1181bd3f70b674540e990252d652d6e9b168901ebc2c9b03ef320`.
It predates the diagnostic-only follow-up. The older source companion/checksum
file predates AMD integration: regenerate both for the final release, do not
publish that archive as the current build's matching source.

Tests already run for AMD integration: 149 optimized Rust passed (19 manual tests
ignored), 33 Python passed, isolated Godot capability test passed, clean Ubuntu
22.04 package loading/ELF audit passed. Latest follow-up: diagnostic bridge and
standalone compile passed, two Python guard/device-selection tests passed,
H.264 follow-up clips all strictly decoded. These do not replace Windows tests.

Remaining non-Windows release checks: fresh physical Linux install, sustained
AMD real-game use, Quest 2/3S preview coverage, full reconnect/standby regression,
and regenerated release sources/notices/checksums. Passthrough-toggle headset
reboot and an unexplained Subnautica exit need logs if reproduced; no conclusive
root cause has been established. Keep these honest in release notes.
