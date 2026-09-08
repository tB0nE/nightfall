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

- [Repository cleanup](plans/active/repository-cleanup.md)
- [Physical keyboard overlay](plans/active/physical-keyboard-overlay.md)
- [Microphone passthrough](plans/active/microphone-passthrough.md)
- [Equirectangular SBS video](plans/active/equirect-sbs-vr-video.md)
- [LiteRT ML Drift migration](plans/active/litert-ml-drift-migration.md)
- [ZipDepth sharp mobile head experiment](plans/active/zipdepth-sharp-mobile-head.md)
- [Sunshine raw-frame passthrough](plans/active/sunshine-raw-frame-passthrough.md)
- [Feature pipeline](plans/active/feature-pipeline.md)
- [Future-feature research](plans/active/future-features.md)

## Architecture notes

- [Settings ownership](architecture/settings-ownership.md)
- [Session lifecycle](architecture/session-lifecycle.md)
- [Multi-monitor encode budget and layout](architecture/multi-monitor-encode-budget-and-layout.md)

## Document lifecycle

New plans must include a status near the title: `Active proposal`, `Active`,
`Blocked`, `Implemented`, or `Superseded`. When work finishes or its assumptions
become stale, move the document to `archive/` and update this index. Avoid adding
session handoffs, agent prompts, or PR reviews at the repository root.
