# Current work queue

Reviewed 2026-11-12, after PR #81 merged at `5db3111`. This is the starting point
for current status. Historical plans retain old branch names and unfinished
checkboxes as evidence; they are not independent lists of today's tasks.

## Current baseline

Main includes desktop and browser screens, Meteor host depth, the managed
Vibepollo host, Linux and Windows PCVR, USB Link, multiple monitors, colour-key
passthrough, primary-screen cropping and workspace-origin correction. PR #81
adds measured Auto crop, independent screen-control hover, menu reorganisation,
a scrollable PCVR app library, Proton DLL-override forwarding and diagnostics.
The GDScript, native-unit and repository CI jobs passed. Source-only CI explicitly
skips the native shutdown test without its compiled addon; that test also passed
locally with the addon present.

These are implemented features, not claims of universal hardware acceptance.
Linux Nightfall client restoration and CPU/Vulkan inference shipped earlier;
the old Linux-restoration branch is no longer the continuation branch.

## Release and acceptance work

| Area | Remaining work |
| --- | --- |
| Host cursor | Linux preview.6 is published; uploaded hashes, relocation and Meteor's actual public download/install path passed. The new Meteor pin is included in this maintenance change. A new Meteor application artifact is still needed to deliver that pin to existing users. Windows/macOS require builds containing the cursor implementation; the Linux archive cannot update them. |
| Latest controls | Visual acceptance of PCVR Stream/VR Apps, scrolling and launching; Host Cursor captured-video inclusion; independent top/bottom hover. Automated geometry, hit testing and timing tests already pass. |
| Auto crop | User accepted the measured-edge border correction. GPU time remains unmeasured; CPU analysis time is exposed in `AutoScreenCrop.last_analysis_usec`. Continue watching dark scenes, subtitles, pointer alignment and secondary-screen exclusion. |
| Workspace stability | User reports acceptable behaviour; monitor standby/re-wear and runtime recentering over longer sessions. No guarantee against arbitrary headset tracking relocalisation. |
| Colour-key host wallpaper | KDE apply/restore was tested. Real GNOME, Windows and macOS acceptance remains; macOS changes the visible Spaces only. |
| Linux multi-screen | X11 and KDE demonstrations have worked. Validate GNOME, selection/layout changes, hotplug, mixed-GPU import/encoding, cursor edges and sustained load on the packaged host. The older region-capture and packed-capture notes describe different implementation stages. |
| Linux installation | A genuinely fresh physical machine/account still needs installation-to-game acceptance without development caches. Container relocation and dependency checks are not that test. |
| Windows | Continue clean-install/firewall acceptance, AMD/HDR multi-monitor checks, and uninstall cleanup of Steam launch options/residual host configuration. Preserve pairings unless explicitly doing a reset test. |
| macOS | Live hardened-package audio, input, microphone/BlackHole, multi-screen/depth and firewall checks; Developer ID signing/notarisation for distribution. |
| PCVR stability | New logs preserve native failure details. Earlier intermittent exits were not conclusively diagnosed; investigate fresh reproductions rather than treating old hypotheses as fixes. |

Host release and update procedure: [managed host releases](../../guides/meteor-host-releases.md).
Screen controls: [crop, colour key and placement](../../guides/screen-display-options.md).
Game-specific setup: [compatibility guide](../../guides/game-compatibility.md).

## User reports — next investigation phase

- [#66: frame pacing](https://github.com/tB0nE/nightfall/issues/66): Windows/AMD
  report; not reproduced locally and no established root cause. Separate frame
  arrival, decode and presentation timing from average FPS/network loss.
- [#72: Quest 2 PCVR](https://github.com/tB0nE/nightfall/issues/72): the tester
  confirmed SteamVR works with the refresh-rate fix. Follow up on network
  stuttering and monitors disappearing after layout changes; clarification is
  pending. Do not describe initial headset detection as still unfixed.

The current maintenance pass does not implement new issue fixes.

## Deferred work

- Environments: draft [PR #65](https://github.com/tB0nE/nightfall/pull/65), not
  merged or part of the intended release. Rebase/review the design before resuming.
- Compatibility Linux browser: preserved on `codex/quest-linux-browser-spike`.
  `codex/meteor-depth-fusion-spike` points to the same checkpoint, not a separate
  current fusion implementation. GPU/XR coexistence, packaging, lifecycle,
  sandboxing, resource use and long playback remain experimental.
- Larger screen/UI redesign and per-screen settings: not implemented. Manual
  and Auto crop remain primary-only. Do not extend global options to every screen.
- AMD foveated encoding and further Vulkan optimization: exploratory work was
  intentionally paused. Do not infer modern-card performance from RX480 results.
- Physical-keyboard overlay, equirectangular video, tethered Linux headsets and
  ML Drift: proposals, not release gates.
- Original refactor: dependency narrowing, renderer contracts and native splits
  remain; see [repository cleanup](repository-cleanup.md).

## Branch/worktree housekeeping

Merged unused branches were pruned on 2026-11-12. Four merged local branches
remain attached to clean worktrees: `feat/agent-testing`,
`feat/meteor-bundled-host`, `feat/unified-content-tabs` and `fix/user-feedback`.
Their remote branches were removed. Coordinate with any agent using a worktree
before retiring it; do not delete its build caches or detach its branch silently.

The two browser checkpoint commits formerly only local are now pushed, and both
browser experiment references are preserved on origin. `3d-environments` is an
older superseded branch with unique history; preserve/archive it rather than
merging its obsolete renderer code back into main.
