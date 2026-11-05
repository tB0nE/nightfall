# Windows XR compatibility checkpoint

Date: 2026-11-05. Working development checkpoint on RTX 3090 / Quest 3;
The later [clean-install checkpoint](meteor-windows-clean-install.md) supersedes
the packaging status below: the new installer includes these runtime components;
clean-profile user acceptance is next.

## Confirmed behaviour

| Feature | Result |
|---|---|
| Bundled custom Vibepollo host and multiple monitors | Previously tested successfully on Quest; main-repository changes already committed |
| Moss | Works through native Windows xrizer → Monado → Meteor |
| VRChat | Works through original Valve OpenVR → SteamVR → Meteor's direct-mode driver |
| Image geometry | User reports good image after vertical FOV correction; moving-image checks pass |
| Controller origin | Corrected using Valve's Touch model raw/grip transform; user reports improved angle |
| Game audio | User heard YouTube and VRChat world music after raising desktop volume |
| SteamVR Room Setup | Driver-provided standing origin avoids the repeated prompt |
| SteamVR waiting environment | Retained by user preference |

Both XR backends use Meteor's encrypted transport and the existing Nightfall
Quest receiver. Keep Monado/xrizer available for compatible games; SteamVR is
an optional compatibility backend, not a replacement for the Linux path.
Windows xrizer's rejection by VRChat EAC is deferred. There is no established
promise that signing the DLL alone fixes acceptance. The protected SteamVR
launcher uses unchanged game files and Valve's original runtime.

## Implementation

- Native Windows runtime adapter with locally configured executables; remote
  control does not supply an executable path. Steam command handoff uses a
  bounded, authenticated loopback ticket.
- Runtime and application process trees live in separate Windows jobs, with
  suspended spawn → job assignment → resume. Session cancellation owns only
  its children. Existing SteamVR sessions are refused.
- Per-session SteamVR paths, settings and logs leave the global OpenVR/OpenXR
  registrations unchanged. Private audio settings avoid changing Windows
  playback/recording defaults or enabling output mirroring.
- Direct-mode shared D3D11 textures retain bounds and submitted head poses;
  keyed GPU synchronization precedes stereo packing and NVENC. No mirror-frame
  pose guessing in the default path. A legacy mirror mode remains diagnostic.
- Corrected OpenVR vertical FOV mapping: top = tan(down), bottom = tan(up).
- Incoming controller grip poses are converted to the selected Valve Touch
  model's raw origin, including the 20.6° rotation and positional offsets.
- Monado capture, controller input, haptics and bounded asynchronous delivery
  support native Windows primitives. Linux support is retained.

## Verification

- 151 native Windows Rust Release tests pass; 19 hardware/integration tests
  ignored by the default suite. Existing warnings remain.
- Geometry executable: 605 head-pose cases, asymmetric/canted eyes, invalid
  pose rejection and 50 two-hand controller-origin round trips pass.
- Moving encoded reference scene: 56 landmarks, 0.501 radians of head motion,
  maximum UV error 0.001501. Deliberately using metadata 40 frames out of sync
  fails at 0.1368. Initial loading-grid fade is excluded, so this is not a
  startup-transition or latency measurement.
- Protected VRChat capture and owned cleanup pass. Natural reference-scene
  exit delivered 112 validated frames and acknowledged END.
- Local 2048×2048-per-eye H.264 test decodes 361 frames at 4096×2048 packed.
- Physical Quest tests at 2048 per eye / 64 Mbps showed about 54–60 received
  frames/s and 51–57 projected frames/s despite a 72 Hz request. User reports
  smooth play and good image; do not label this a sustained 72-fps result.
- Timed headset cancellation does not prove graceful END. One extended test
  disconnected early at about 231 seconds. Long-session reliability and
  lifecycle acceptance remain open.

Audio investigation initially found Quest media volume at zero and Windows
USB output at 2%. Subsequent nonzero audio meters did not prove audibility.
The user's final desktop-volume experiment confirmed audible game music.
Do not describe this as an unresolved confirmed routing failure. Audio still
relies on an accompanying desktop stream; there is no standalone XR audio lane.

## Outstanding before a packaged release

1. Bundle/version/download the Windows runtime components, tracking bridge,
   encoder and optional SteamVR driver; validate a clean-machine installer.
   Current test scripts require locally prepared ignored build directories.
2. Extend the native registered-game catalog with automatic Steam-library
   discovery/import and finish physical normal-flow acceptance. Normal startup,
   headset approval, VR Apps launch handoff and saved backend choices now exist.
3. Finish physical HEVC and higher-resolution performance acceptance. Windows
   now supports H.264/HEVC at requested client dimensions, non-foveated encoding
   and 20/60/72 Hz. Codec-specific NVENC limits remain explicit; foveation is open.
4. Improve sustained high-resolution throughput and measure latency, reconnect,
   orderly game exit and longer sessions without transport loss.
5. Validate AMD XR encoding/GPU selection, additional games and a full physical
   controller/haptics/microphone checklist. NVIDIA/NVENC is the current XR path.
6. Support independent-pose multi-layer composition. Current direct capture
   rejects layers with differing head poses rather than combining them wrong.

These are follow-up release tasks, not reasons to lose the working checkpoint.
The older desktop/depth installer does not include these XR components.

## References

- [Windows XR build and test guide](../../guides/meteor-windows-xr.md)
- [Windows development history](meteor-windows.md)
- [Historical investigation and artifacts](../../archive/meteor-windows-vrchat-investigation-2026-11-04.md)
- [Deferred EAC support-report draft](meteor-windows-vrchat-support-draft.md) (not submitted)
- [Valve driver documentation](https://github.com/ValveSoftware/openvr/blob/master/docs/Driver_API_Documentation.md)

## Native integration work (2026-11-05)

Normal Windows XR startup no longer invokes the Linux Python runtime check.
A native host-local game catalog feeds the authenticated VR Apps list and
pending-launch/claim flow. IDs select validated local profile snapshots;
requests cannot supply arbitrary executable paths. The Windows tray adds PCVR
readiness, profiles, enable/restart, headset approval/rejection, VR Apps access,
and persisted backend choices. Monado is preferred when both profiles have been
registered. A setup helper imports prepared Moss/VRChat profiles into user data;
runtime binaries remain local build dependencies. This is native-flow
integration, not completed installer or automatic Steam-discovery work.
Physical normal-flow acceptance is pending.

Native integration acceptance: both registered games passed local synthetic
catalog → launch-intent → runtime checks with validated frames and owned
cleanup. The first combined run exposed the synthetic publisher's one-client
limit; the corrected helper starts a fresh publisher per game. Normal startup
passed with isolated settings/ports and the final Release executable. Actual
native tray readback confirms PCVR ready, Moss, VRChat and both backend menu
entries. Normal Meteor was rebuilt and restarted with the existing bundled
host; discovery advertises XR on port 47910 and platform windows. Protocol-1's
legacy backend token is retained for old clients. Summaries:
`meteor/target/windows-catalog-summary.json`,
`windows-normal-xr-summary.json`, `windows-native-tray-summary.json`.
The prepared per-user catalog is enabled; user/headset normal-flow feedback is
pending. Runtime packaging/downloads and automatic game discovery remain open.

First normal-flow connection diagnosis: Nightfall selected the correct bundled
host (HTTPS 49984), but rejected the Windows Meteor identity because a different
host pin was saved. The desktop stream therefore ran directly without Meteor;
XR retried a stale developer endpoint. After verifying the local Windows Meteor
public identity against the identity used in prior physical tests, only that
host's pin was updated and the stream reconnected. Client reports streaming,
nonempty Meteor discovery and XR port 47910; native logs confirm proxy traffic
and depth delivery. The Windows PCVR menu now displays pending headset approval.
A separate Sunshine/Vibepollo process is also running, but the managed host has
system_tray=false and was not confused with it. Do not clear all host pins or
kill unrelated hosts as a workaround.

HEVC resolution update (2026-11-05): the first normal VRChat launch failed
because the client requested 2064×2208 per eye, yielding 4128 stereo width,
above this GPU's H.264 limit of 4096. The user explicitly requested following
the client, not reducing saved resolution. Windows now advertises h264/h265;
Quest 3's existing codec selector can choose HEVC without an APK change. The
SteamVR D3D11 encoder selects codec-specific capabilities/preset/profile/VUI,
and the native adapter admits HEVC. The Monado Vulkan encoder already contained
HEVC support. Shared transport writes the matching codec identifier.
Local full-resolution captures decode to HEVC 4128×2208: VRChat 362 frames,
Moss 342 frames. First Moss attempt encountered an xrizer initialization race
(Injected<T>::get, clientcore.rs:309); retry passed. No client preferences were
changed. Evidence: `meteor/target/windows-hevc-client-resolution-summary.json`
and per-game `.hevc` recordings. Physical HEVC acceptance remains pending.

## Steam client crash-protection popup (2026-11-05)

The exact popup is Steam's `VR_Error_CrashProtection`, not the SteamVR add-on
block UI. Steam console logs refused initialization and its config VR section
retained AttemptingInit=1 with no successful build recorded. Native runtime
cleanup now closes the application job, requests WM_CLOSE only for vrmonitor
processes verified to belong to Meteor's runtime job, and allows up to four
seconds before job cleanup. Cancel also requests direct-capture stop first.
Unrelated SteamVR sessions are not targeted. A finite scene produced 129 valid
frames, acknowledged END, and vrserver logged Graceful exit.

A one-time recovery helper gracefully stopped Steam with no VR game/runtime
active, backed up config.vdf beside itself, and changed only VR/AttemptingInit
from 1 to 0. Steam was restarted and subsequently recorded BuildIDCompleted for
the installed build itself. The helper does not set a fabricated completed
build, disable crash protection or change add-on blocking. First post-recovery
VRChat launch/cleanup passed with no fresh crash-protection refusals. Further
cancellation/shutdown checks and deployment are being completed.

Repeated post-recovery VRChat check passed with HEVC at the client dimensions.
After adding direct-capture stop before runtime shutdown, vrserver logs Graceful
exit on bounded cancellation as well (session 1793865939705577200). Steam state
remains AttemptingInit=0, BuildIDCompleted=25998080, with no new crash-protection
refusals across the post-recovery starts. Summary:
`meteor/target/windows-steamvr-crash-recovery-summary.json`.
Do not equate graceful SteamVR process exit with acknowledged stream END on
bounded game cancellation; the finite reference scene separately validated END.

## Direct Steam launches (2026-11-05)

Normal Windows Meteor now publishes a localhost authenticated Steam broker for
its registered catalog. The Steam command wrapper preserves the original
executable, arguments and working directory, queues the same single-use launch
intent as VR Apps, and uses the saved per-game backend. Steam waits for session
completion; cancellation returns 130. Explicit --no-vr/-nohmd bypass XR. Broker
tickets are bound to process birth, and disconnected/expired queued requests
are removed. Unknown games fail closed.

Release checks: 154 unit tests passed; isolated normal startup passed. The
Steam-wrapper catalog check captured 354 Moss and 364 VRChat HEVC frames at
4128x2208 without a headset, including bounded owned cleanup. Summary:
`meteor/target/windows-catalog-summary.json` (steam_wrapper=true).
The settings helper passed insertion/escaping/idempotence/custom-option tests.
Moss and VRChat launch options were applied to the active Steam account with
a backup beside localconfig.vdf and a graceful Steam restart. Updated normal
Meteor was started. Direct launches from real Steam with the headset remain
the next user acceptance check; the synthetic test does not establish that.

User acceptance subsequently passed the flow test. Windows multi-monitor
controls initially appeared disabled after a normal Meteor restart because
the experimental host flag had only been set in the old trial shell. Persisted
`METEOR_WINDOWS_MULTIMONITOR = "1"` in the local meteor.toml `[host_env]` table,
with a backup, and restarted Meteor. The bundled host's read-only probe reported
DISPLAY1 2560x1440 and DISPLAY2 1920x1080, combined 4480x1440. User confirmed
the flow test passed after this fix. The per-user setting and backups are local
state; the repository documents how to retain the flag on other installations.

Session-lifetime audit: normal desktop streaming, both Windows XR backends,
Steam wrapper completion and the client Meteor projection path already have
no fixed play-time cap. Diagnostic 45/60/300-second values do not stop active
Meteor game sessions. The 360-second control lease is renewed by status
requests; startup, stalled-I/O and cleanup deadlines are retained. No runtime
or APK changes were required. Release tests still pass (154 passed, 19 ignored).
This audit does not establish long-session reliability or packaged-release
readiness; the release tasks above remain outstanding.
