# Windows XR compatibility checkpoint

Date: 2026-11-04. Working development checkpoint on RTX 3090 / Quest 3;
not a packaged Windows XR release.

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

- 148 native Windows Rust Release tests pass; 19 hardware/integration tests
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
2. Integrate per-game backend selection and launch into normal Meteor flows;
   today separate configured runtime roots/test helpers select the backend.
3. Add HEVC and client-resolution capability negotiation. Current Windows XR
   profile supports H.264, non-foveated encoding and 20/60/72 Hz; requests above
   NVENC's queried H.264 width/height limit fail explicitly.
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
