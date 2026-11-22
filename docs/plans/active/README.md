# Active plans and proposals

Start with the [current work queue](current-work.md). This index separates
implemented features awaiting acceptance from proposals; the presence of a file
here does not mean its entire original implementation is unfinished.

## Acceptance and maintenance

| Plan | Current purpose |
| --- | --- |
| [Settings popups and drag scrolling](settings-popups-and-drag-scrolling.md) | Shared choice/slider UI and ambient gain implemented in stages; remaining selectors, high-bitrate validation and thumbstick-free scrolling pending. |
| [Windows PCVR routing](windows-pcvr-routing.md) | Proposed: per-game SteamVR or Monado routing, desktop stream stepping aside during PCVR, attach-mode controllers. Settle before merging fork work. |
| [Automatic XR discovery](automatic-xr-runtime-discovery.md) | Linux activation/registration and Windows registered-driver acceptance; implementation in progress. |
| [Virtual-monitor transitions](virtual-monitor-transition-speed.md) | Readiness-based restart and layout-preservation changes; live headset/Windows acceptance pending. |
| [Repository cleanup](repository-cleanup.md) | Dependency narrowing, renderer ownership and native subsystem splits. |
| [Agent testing](agent-testing.md) | Extend the existing tools; scripted poses, display latency, install/download coverage. |
| [Browser testing](browser-testing.md) | Remaining mixed-screen, lifecycle, input and media acceptance. |
| [Unified screen management](unified-screen-content-management.md) | Active redesign: shared tab model, per-tab resolution/crop, retained source switching, and mixed screens. |
| [Earlier unified screens work](unified-content-tabs.md) | Historical browser/mixed-screen implementation checkpoints. |
| [Linux installation](meteor-linux-installation.md) | Fresh physical installation and sustained XR acceptance; old Windows-not-implemented entries are historical. |
| [Linux screen packing](linux-screen-packing.md) | Cross-desktop packed-capture validation, especially GNOME and hardware combinations. |
| [Wayland multi-monitor](meteor-wayland-multi-monitor.md) | Earlier region-capture evidence; newer packed capture supersedes its original scope. |
| [AMD XR encoding](meteor-amd-xr-encoding.md) | Hardware acceptance; further foveation/optimization deliberately deferred. |
| [Windows checkpoint](meteor-windows-clean-install.md) | Clean install, firewall, uninstall and remaining hardware acceptance. |
| [Windows implementation](meteor-windows.md) | Dated implementation history; read the later clean-install checkpoint first. |
| [Windows VRChat compatibility](meteor-windows-vrchat-compat.md) | Compatibility evidence and platform-specific limitations. |
| [SteamVR integration](meteor-steamvr-driver-integration.md) | Driver evidence and remaining composition/quality work. |
| [Windows support draft](meteor-windows-vrchat-support-draft.md) | Unsubmitted upstream-support draft, not a required implementation task. |
| [macOS](meteor-macos.md) | Live hardened-package acceptance and signed/notarized distribution. |
| [USB Link](usb-link-streaming.md) | Implemented; cross-host/recovery acceptance remains. |
| [October user feedback](user-feedback-2026-10.md) | Historical feedback inventory; current open reports are in the work queue. |

## Deferred proposals

These are choices for later prioritization, not release blockers:

- [Tethered Linux headsets](pc-vr-headsets-linux.md)
- [Physical keyboard overlay](physical-keyboard-overlay.md)
- [Equirectangular SBS video](equirect-sbs-vr-video.md)
- [LiteRT ML Drift migration](litert-ml-drift-migration.md)
- [Sunshine raw-frame passthrough](sunshine-raw-frame-passthrough.md)
- [WiVRn overlay experiment](wivrn-nightfall-overlay-experiment.md)
- [Nightfall Gateway experiment](nightfall-gateway-experiment.md)
- [Future features](future-features.md)

## Historical work

[Archived plans](../../archive/plans/README.md) preserve implementation decisions,
profiling and former acceptance lists. Do not resume their stale branch names,
reinstate removed models or repeat superseded ALVR architecture from those notes.
The compatibility-browser experiment remains on its preserved branch rather
than being merged as part of documentation cleanup.
