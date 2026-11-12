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

## Start here

- [Current work queue](plans/active/current-work.md): implemented baseline,
  remaining acceptance, deferred experiments and the next user reports.
- [Active plan index](plans/active/README.md): scoped follow-ups and proposals.
- [Archived implementation records](archive/plans/README.md): completed,
  superseded and historical plans, preserving measurements and decisions.

Old dated status sections are evidence, not an instruction to redo implemented
features. Check the current queue before treating an unchecked historical item
as outstanding.

## Architecture notes

- [Settings ownership](architecture/settings-ownership.md)
- [Session lifecycle](architecture/session-lifecycle.md)
- [Rendering boundary](architecture/rendering-boundary.md)
- [Multi-monitor encode budget and layout](architecture/multi-monitor-encode-budget-and-layout.md)

## Technical guides

- [Screen crop, colour key and placement](guides/screen-display-options.md)
- [Meteor managed-host releases](guides/meteor-host-releases.md)

- [PCVR game compatibility and game-specific setup](guides/game-compatibility.md)
- [Testing without a person in the headset](guides/agent-testing.md)
- [ZipDepth on Quest GPU](guides/zipdepth-quest-gpu.md)
- [ZipDepth Quest quality tiers and retained experiments](guides/zipdepth-quest-tiers.md)
- [Training the ZipDepth Hybrid-v2 mobile head](guides/zipdepth-hybrid-v2-training.md)

## Document lifecycle

New plans must include a status near the title: `Active proposal`, `Active`,
`Blocked`, `Implemented`, or `Superseded`. When work finishes or its assumptions
become stale, move the document to `archive/` and update this index. Avoid adding
session handoffs, agent prompts, or PR reviews at the repository root.
