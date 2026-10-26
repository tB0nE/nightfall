# Meteor XR branch review — 26 October 2026

Branch: `feat/meteor-xr-streaming`.
Implementation checkpoint: `bfd9afc` (`feat(meteor): integrate portable GPU depth and XR app support`).
This review supersedes older handoffs and unchecked historical phase lists.

## What is on the branch

The stored `origin/main` reference is `766529e` (Nightfall 0.8.1). Relative to
that reference, the branch also contains the earlier browser/content work:
standalone browser AI 3D, navigation/privacy/blocking, gamepad support, tabs and
up to four content screens. That is inherited scope, not new work in this checkpoint.

### Linux XR streaming

- Managed, isolated Monado runtime with authenticated Meteor control/video/tracking
  transport, NVIDIA hardware encoding and native Quest projection presentation.
- Head/controller poses, buttons, sticks and haptics. VRChat controls, movement
  and menus were confirmed in physical testing; Alyx gameplay was also confirmed.
- Steam application wrappers, trusted launch intent, automatic negotiation and
  first-decoded-frame handover from the desktop. Game exit restores the desktop.
- Desktop overlay and calibrated wristwatch controls; separate PCVR settings and
  desktop menus, including pre-launch settings when Meteor is available.
- Headset-relative rectangular per-eye render scaling, status telemetry, HEVC,
  live bitrate and centre-priority encoding toggles, sharpening and supersampling.
  Resolution changes are pending until restart rather than terminating the game.
- Projection, quad, equirect2 and cylinder composition, colour scale/bias,
  ordered/multiple projections, source cropping and supported SDR formats.
- Steam VR Apps catalog, artwork/placeholders, paging and launch from Nightfall
  or Meteor's tray. Non-Steam VR shortcuts use Steam's 64-bit launch identity.
  The current catalog depends on Steam VR metadata; Lutris support is deferred.
- Real game sessions no longer have the five-minute/315-second diagnostic
  timeouts. Diagnostic fixtures retain bounded durations. Authenticated activity
  renews the host idle lease; disconnect/idle cleanup still exists.
- Ordinary headset pause no longer immediately kills an active Meteor game.
  Pointer recovery rejects stale/untracked poses and requires held input release.
- Menu/discovery work is throttled rather than repeated every render frame.
  The user confirmed desktop rendering reaches 120 app FPS again.

### Portable Meteor depth

- Combined picker with one group per GPU plus CPU. Vulkan and TensorRT choices
  appear together under the appropriate NVIDIA group.
- Independent decoder/inference selection, VAAPI/software compatibility, and four
  EdgePad variants available in the local installation. Release packaging still
  determines which optional assets are actually shipped.
- Full 518×294 and Performance 392×224 temporal VDA through optimized Vulkan;
  existing NVIDIA TensorRT remains the preferred fast NVIDIA VDA path.
- Vulkan frame preparation, softening, temporal/percentile processing and
  alignment/contour cleanup. CPU references remain available.
- Portable EdgePad/VDA raw depth stays on GPU through final processing, with
  owned tensor lifetime and finite-value validation. CPU fallback is logged.
- Reproducible conversion, profiling, comparison and packaging tools; vendor
  headers/notices are checked in, model weights/build outputs are not.

The broad CPU-offload work substantially improved RX 480 complete-pipeline
latency. The final resident-transfer follow-up shortened final processing but
did not produce a consistent overall speedup across all repeated runs. Both
reports retain the actual measurements:

- `tools/model_tester/output/meteor-vulkan-pipeline-20261026/README.md`
- `tools/model_tester/output/meteor-resident-output-20261026/README.md`

Further GPU optimization is deliberately paused. Return to XR streaming.

## Evidence and present state

- Release Rust suite: 132 passed, 18 optional hardware tests ignored by default.
- Resident EdgePad parity/lifetime/invalid-value checks passed on RX 480 and
  RTX 3090. Both VDA sizes passed 80-frame reference comparisons, including
  scene cuts, gaps, history rollover and retained resident output.
- All 17 model/device choices passed the preceding full replay matrix; the final
  resident-output change additionally passed two six-model RX 480 replay batches
  with no CUDA loaded and no reported resident-path fallback.
- Release host binary and default-feature Cargo check passed.
- At this checkpoint, Python library, application-lifecycle and Steam-launcher
  suites were rerun: 5 + 10 + 4 tests passed.
- GDScript and compositor/transport validations from the earlier XR milestones
  are recorded in their plans. They were not rerun merely to create this commit.
- No fresh APK was built for the latest host-only GPU work. Meteor was left
  stopped after testing. No release upload or push is part of this checkpoint.

## What remains

### First: resume and validate the Linux XR baseline

1. Restart the development Meteor/XR services and confirm the correct GPUs with
   the new AMD-desktop/NVIDIA-game arrangement. XR currently remains the
   Linux/NVIDIA encoder/runtime path; AMD depth support is a separate capability.
2. Run Alyx or VRChat from the streamed desktop; check automatic entry, audio,
   input, wristwatch/desktop/settings, exit and immediate relaunch.
3. Recheck headset removal/re-wear, full sleep, long sessions, reconnect and held
   input release. Unlimited game duration does not guarantee survival of an
   arbitrarily long transport suspension.
4. Confirm the latest pointer recovery changes physically. The recurring
   passthrough-toggle headset reboot has no established root cause or verified
   fix; persistent diagnostics were improved for another occurrence.

### Then: make Linux startup and distribution practical

- Consolidate normal Meteor startup/discovery, XR service readiness and trust
  setup. An integrated DEV service exists, but normal installation still needs
  development configuration rather than the intended install-and-run experience.
- Package the managed runtime, launcher/library helpers and dependencies; remove
  checkout/venv path assumptions and provide supported Steam launch setup.
- VR Apps currently needs configured Steam wrappers. A generic runtime broker
  that removes per-game setup is a separate larger step.
- Validate packaged host assets and an optimized DEV APK from this checkpoint
  before final release testing. Optional Vulkan VDA assets are not installed by
  the existing NVIDIA TensorRT download action.

### Remaining validation and optional work

- Validate supersampling's visual effect, live foveation quality, latency and
  sustained performance at the chosen rectangular resolution/refresh settings.
- Broaden real-game coverage. Subnautica's reported unexpected exit is not
  conclusively resolved by this checkpoint; do not attribute every exit to the
  removed timeout.
- Current game audio uses the retained Sunshine/desktop audio path. Independent
  XR audio remains optional work; verify the existing microphone path in games
  before deciding whether a separate XR microphone path is needed.
- Multi-screen/browser coexistence during XR needs explicit acceptance testing;
  the demonstrated overlay path should not imply all content combinations work.
- Optional compositor capabilities include equirect1/cubemaps, depth-aware layers,
  advanced blend extensions and application-requested passthrough.
- Windows XR port, Windows validation of the new Vulkan path, newer AMD/Intel
  hardware and Quest 2/3S acceptance remain outside the validated Linux/Quest 3 baseline.

## Recommended next milestone

One short dual-GPU Alyx/VRChat smoke test, followed by Linux XR startup and
packaging integration. Avoid another depth-model optimization detour.

References: `meteor-pcvr-productization.md`, `meteor-xr-desktop-integration.md`,
`meteor-xr-automatic-launch.md`, `meteor-vr-app-library.md`,
`desktop-stream-performance-investigation.md`, `meteor-vulkan-frame-processing.md`.
