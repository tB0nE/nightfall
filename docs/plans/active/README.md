# Active plans and proposals

Start with the [current work queue](current-work.md). This index separates
implemented features awaiting acceptance from proposals; the presence of a file
here does not mean its entire original implementation is unfinished.

## Acceptance and maintenance

| Plan | Current purpose |
| --- | --- |
| [Repository cleanup](repository-cleanup.md) | Dependency narrowing, renderer ownership and native subsystem splits. |
| [Agent testing](agent-testing.md) | Extend the existing tools; scripted poses, display latency, install/download coverage. |
| [Browser testing](browser-testing.md) | Remaining mixed-screen, lifecycle, input and media acceptance. |
| [Unified screens and tabs](unified-content-tabs.md) | Implemented workspace history plus future screen organization; broader UI redesign deferred. |
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
