# Nightfall documentation

This directory is the canonical home for project documentation. `README.md` at
the repository root remains the user-facing introduction and `BUILD.md` remains
the build/deployment entry point.

## Current documentation

- [`architecture/`](architecture/) records constraints and design decisions
  that describe the current system.
- [`guides/`](guides/) contains reproducible technical procedures.
- [`integrations/`](integrations/) contains coordination notes for external
  projects such as Polaris.
- [`research/`](research/) contains comparative or exploratory work that is
  still useful as reference.
- [`plans/active/`](plans/active/) is the only location for proposed or ongoing
  Nightfall work.
- [`archive/`](archive/) preserves implemented, superseded, or historical plans,
  investigations, and reviews. Archived documents are context, not instructions.

## Active plans

- [Nightfall Meteor: host-side depth maps](plans/active/meteor-host-depth.md)
- [Nightfall Meteor: microphone passthrough](plans/active/meteor-microphone.md)
  (supersedes [the in-protocol microphone plan](plans/active/microphone-passthrough.md))
- [Nightfall Meteor: Linux AppImage](plans/active/meteor-appimage.md)
- [Nightfall Meteor: Windows port](plans/active/meteor-windows.md)
- [Nightfall Meteor: AMD and Intel GPUs](plans/active/meteor-amd-intel.md)
- [Nightfall Meteor as a host](plans/active/meteor-host.md): the direction for multiple monitors and XR
- [Research spike: streaming PC VR to Nightfall](plans/active/meteor-xr-streaming-spike.md)
- [USB Link streaming](plans/active/usb-link-streaming.md)
- [PyroWave codec](plans/active/pyrowave-codec.md) and its
  [zero-copy GPU decoder](plans/active/pyrowave-zero-copy-gpu.md) (both done)
- [Repository cleanup](plans/active/repository-cleanup.md)
- [Physical keyboard overlay](plans/active/physical-keyboard-overlay.md)
- [Equirectangular SBS video](plans/active/equirect-sbs-vr-video.md)
- [LiteRT ML Drift migration](plans/active/litert-ml-drift-migration.md)
- [Preserve vanilla ZipDepth sharpness on Quest](plans/active/zipdepth-standard-head-quest.md)
- [ZipDepth sharp mobile head experiment](plans/active/zipdepth-sharp-mobile-head.md)
- [Sunshine raw-frame passthrough](plans/active/sunshine-raw-frame-passthrough.md)
- [WiVRn Nightfall overlay experiment](plans/active/wivrn-nightfall-overlay-experiment.md)
- [Nightfall Gateway experiment](plans/active/nightfall-gateway-experiment.md)
- [Feature pipeline](plans/active/feature-pipeline.md)
- [Future-feature research](plans/active/future-features.md)

## Architecture notes

- [Settings ownership](architecture/settings-ownership.md)
- [Session lifecycle](architecture/session-lifecycle.md)
- [Rendering boundary](architecture/rendering-boundary.md)
- [Multi-monitor encode budget and layout](architecture/multi-monitor-encode-budget-and-layout.md)

## Technical guides

- [ZipDepth on Quest GPU](guides/zipdepth-quest-gpu.md)
- [ZipDepth Quest quality tiers and retained experiments](guides/zipdepth-quest-tiers.md)
- [Training the ZipDepth Hybrid-v2 mobile head](guides/zipdepth-hybrid-v2-training.md)

## Document lifecycle

New plans must include a status near the title: `Active proposal`, `Active`,
`Blocked`, `Implemented`, or `Superseded`. When work finishes or its assumptions
become stale, move the document to `archive/` and update this index. Avoid adding
session handoffs, agent prompts, or PR reviews at the repository root.
