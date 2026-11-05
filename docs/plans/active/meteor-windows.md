# Nightfall Meteor: Windows

Current checkpoint (2026-11-04): bundled-host multi-monitor streaming, Moss
through xrizer/Monado, and VRChat through the Meteor SteamVR driver have been
physically tested on Quest. Audio is audible after increasing desktop volume;
controller angle improved after the model-origin correction. Keep SteamVR's
waiting environment; Room Setup no longer launches. XR remains a development
integration. The new November 5 installer includes the runtime components;
see the [clean-install checkpoint](meteor-windows-clean-install.md) for setup,
isolated package checks and the upcoming user test.

Read the [current compatibility checkpoint](meteor-windows-vrchat-compat.md)
and [build/test guide](../../guides/meteor-windows-xr.md) first. The chronology
below includes superseded intermediate failures and proposed directions.

Latest direct-runtime investigation (2026-11-04): Windows System popup event 26
confirms EAC rejects xrizer's `bin/vrclient_x64.dll`, including with normal
runtime registration and no OpenVR environment overrides. The same DLL and
VRChat's original Valve API loader pass an unprotected stereo control test.
[Upstream/support report draft](meteor-windows-vrchat-support-draft.md) is ready,
not submitted. Signing/approval requirements remain unresolved and are deferred.

VRChat/EAC solution research (2026-11-04):
[Windows VRChat compatibility options](meteor-windows-vrchat-compat.md).
User authorized an optional SteamVR driver prototype for protected Windows
games. Local driver, stereo mirror capture, NVENC and acknowledged Meteor frame
transport proofs passed. VRChat initialized against the Meteor SteamVR HMD and
exited without a visible EAC error. Managed VRChat capture then passed with
1,283 validated encoded frames across a 20-second observation and a captured
stereo world image. Natural scene exit/END and all 148 Windows unit tests pass.
Quest validation remains; working Monado/xrizer remains available.

> Status: In progress. The inventory below describes the 2026-10-07
> starting point. See the current status below for the Windows work since then.
>
> Date: 2026-10-05
>
> Related: [meteor-host-depth.md](meteor-host-depth.md) (host depth),
> [meteor-appimage.md](meteor-appimage.md) (the Linux release this
> mirrors), [meteor-microphone.md](meteor-microphone.md) (microphone).
>
> Scope: Windows 10/11 x64 hosts with NVIDIA or AMD GPUs, running Sunshine,
> Apollo, Vibepollo or Vibeshine. NVIDIA keeps NVDEC; AMD uses D3D11VA and
> ncnn Vulkan for EdgePad.

## Windows compatibility update (2026-10-29)

November 4 direction change: user requested switching away from Moss to
VRChat, then explicitly preferred using xrizer consistently with Linux.
Pause further Moss-specific compatibility work. Target architecture is
OpenVR game → xrizer → OpenXR/Monado → Meteor on both platforms; native
OpenXR applications do not need the OpenVR translation layer.
The installed VRChat build has XRSDKOpenVR/openvr_api.dll, no installed
OpenXR plugin; SteamVR and a Windows xrizer runtime are absent.

November 4 GitHub investigation found existing Windows D3D11 implementations:

- [webhead2oo9/xrizer, feat/windows-d3d11](https://github.com/webhead2oo9/xrizer/tree/feat/windows-d3d11),
  pinned candidate `ee62d2647bb84dd0969be91a6ff430bba4f72090`.
  Includes runtime-LUID adapter queries, D3D11 texture-copy/MSAA/bounds tests,
  overlay ownership and bounded session shutdown. Its README reports Wine
  tests, explicitly not native Windows or live headset coverage.
- [NikNakk/xrizer, windows-openxr-d3d11](https://github.com/NikNakk/xrizer/tree/windows-openxr-d3d11),
  reviewed `e469039f1254331727be717644865c9ac000d256`.
  Documents Alyx through Wine/DXMT and Monado on macOS, with Windows cross-build
  CI, D3D11 timing and a loading-stage implementation. Its documentation still
  lists temporary-device default-adapter selection as a limitation.
- Also found `ImSapphire/xrizer:win32`; not yet reviewed.

Reuse and validate an existing port before writing another. First candidate is
webhead2oo9's pinned branch, using native MSVC rather than Wine. New helper
`test/build_xrizer_windows.ps1` clones a separate ignored checkout, checks its
exact revision/cleanliness, builds both packager and DLL in Release with the
lockfile, runs release library tests, and writes `nightfall-build.json` only
on success. Windows LLVM 23.1.5 was installed for bindgen; Vulkan SDK supplies
glslc. Native MSVC Release DLL built successfully. Initial library suite was
26 passed / 79 failed / 2 ignored: its fake OpenXR runtime only implements
Vulkan while Windows selected D3D11 for the temporary session. A tracked
test-only patch (`test/xrizer_windows_tests.patch`) selects Vulkan for that
fixture; production still selects D3D11. With that patch all **105 tests pass,
2 ignored**, including real D3D11 texture-copy and MSAA tests. Build provenance
is in the ignored runtime's `target/release/nightfall-build.json`.
The Linux upstream pin remains unchanged.

`test/windows_openvr_probe.cpp` exercises Valve's original OpenVR loader from
the installed VRChat files, without modifying that game, and submits distinct
D3D11 eye textures. `smoke_windows_xr_application.ps1 -OpenVrRuntime ...` scopes
`VR_OVERRIDE` and a private `VR_PATHREG_OVERRIDE` to this host-only check.
The first capture attempt found the missing shared `openxr_loader.dll` (the
existing sample build uses a static loader). Built the same pinned Khronos
source into `meteor/target/windows-openxr-loader-build`, Release, with
`DYNAMIC_LOADER=ON`, `BUILD_TESTS=OFF`, `BUILD_API_LAYERS=OFF`,
`BUILD_CONFORMANCE_TESTS=OFF`, target `openxr_loader`. Its loader directory is
added to the isolated application config.

The host-only OpenVR capture test now **passes**: Valve's unchanged VRChat
OpenVR loader → pinned xrizer DLL → real Monado D3D11 session → Meteor encoded
video. It validates received frame headers, observes another 2 seconds after
the first three frames, and verifies owned-process cancellation. xrizer logs
show temporary-device creation, switching to the probe's D3D11 device, real
session reaching FOCUSED, swapchain creation and Touch controller profiles.
This is bounded host capture, not graceful game exit or decoded image-quality
validation. Steam wrapper integration, VRChat gameplay and headset testing
through xrizer were outstanding at that checkpoint; see the next update.

November 4 native Steam handoff: `--xr-steam-run --root <config> -- %command%`
accepts Steam's command without shell reparsing. A waiting runtime publishes a
short-lived random-token ticket for loopback-only local handoff, validates the
configured Steam app ID and absolute executable/cwd, and launches it inside the
owned Windows job. Remote XR control supplies no executable/argv. Optional
`openvr_runtime` creates a session-private OpenVR registry and scopes
`VR_OVERRIDE`/`VR_PATHREG_OVERRIDE` to the application. `steam_launch=true` waits
for this command; `steam_app_id` optionally binds the session to a specific game.

Host smoke checks with `-SteamCommand` passed cancellation (wrapper exit 130)
and natural exit (wrapper exit 0, 56 validated frames, acknowledged END). Native
release suite passed 146 tests / 19 ignored before the launcher-child follow-up.
A protected-launcher trial exposed that bootstrapper exit must not end its
still-running child game; Windows job accounting now keeps the session alive
until owned application descendants exit. The regression and existing
owned-process cleanup test both pass. Final native Release suite recheck:
**147 passed, 0 failed, 19 ignored**. XR DEV release executable rebuilt with
the launcher-child fix and bounded ticket/message reads.

`test/configure_windows_xr_steam.ps1` prepares isolated
`meteor/target/windows-xr-steam/xr-windows.json` and `steam-launch-options.txt`,
without editing Steam settings. `--xr-steam-options --root ...` prints options.
`start_windows_xr_headset_trial.ps1 -RuntimeRoot ...` selects this config.
This DEV handoff still requires connecting XR in Nightfall while the wrapper
waits (120 seconds); Linux's automatic pending-launch notification/library flow
has not been ported. Normal packaged Meteor does not yet expose Windows XR.
For bootstrap launchers, the wrapper currently returns the launcher's status
after its owned descendants finish; it does not yet recover an independently
exited child game's exact exit code. The host smoke writes
`meteor/target/windows-xr-application/smoke-summary.json` with its actual result.

VRChat is currently a compatibility blocker: the user reported Easy Anti-Cheat
flagging xrizer during the protected-launcher test. No protection was disabled
or bypassed. The second trial kept the child alive correctly, but delivered no
XR frames within 45 seconds. VRChat log
`output_log_2026-11-04_15-25-52.txt` reports
`Could not initialize OpenVR. Error code: Init_VRClientDLLNotFound` at 15:25:58;
xrizer's log was not entered for that launch. The EAC bootstrap log only records
successful EAC startup, not the popup's specific rejection reason. The exact
EAC rejection is user-reported, consistent with the DLL-load failure, rather
than independently confirmed by a matching EAC log line. The test was stopped
and no VRChat/EAC processes remained. Do not call VRChat compatible; use an
unprotected OpenVR application to validate the next headset step.

November 4 Moss follow-up: normal `-vr -dx11` startup passed 15 seconds through
the Steam wrapper, but selected native OpenXR (xrizer's log unchanged). It is
not an xrizer validation. Explicit `-hmd=SteamVR` initially crashed at startup
with `0xc06d007e`. Testing Moss's original OpenVR 1.5.17 DLL in the native probe
then isolated an older-loader discovery requirement: error 110 and
`Unable to read VR Path Registry from ...\Local\openvr\openvrpaths.vrpath`.
That DLL supports `VR_OVERRIDE`, but ignores `VR_PATHREG_OVERRIDE`.

Added `test/register_windows_openvr.ps1`, which creates the missing standard
per-user registry pointing to the pinned Windows xrizer runtime. It never
replaces an existing registry, and does not change OpenXR registration. It was
run on this PC; this deliberately makes xrizer the default per-user OpenVR
runtime where none was registered before. Retest of the same old Valve DLL
through the native probe now passes: real xrizer capture, 2-second observation,
wrapper cancellation 130. Retesting Moss OpenVR next. This older-loader
registration prerequisite must be included in future Windows XR installation.

Quest check at this point: USB serial 2G0YC1ZF8P08QN connected, headset asleep,
Nightfall not running. Restored USB adb forward on tcp:47950, but no dev bridge
response until Nightfall is brought back up. No headset trial has run yet.

Further Moss isolation: after the registry fix, its SteamVR mode still crashed
with a delay-load DLL exception. Adding its existing
`Engine/Binaries/ThirdParty/OpenVR/OpenVRv1_5_17/Win64` directory to this test's
PATH got it into xrizer (temporary D3D11 session READY), but it then crashed
at startup with a null access violation; no video within 45 seconds. Do not
equate that with a passing game test or keep changing Moss-specific behavior.

Added `--scene` to `meteor-openvr-probe`: D3D11 world-space checkerboard floor,
three coloured spheres, actual OpenVR eye/head transforms and controller-role
pose spheres. The default solid-colour probe remains available. Builds in
Release, and the scene passed the local real-xrizer capture test through Moss's
unchanged old Valve DLL. Decoded stereo image inspected at
`meteor/target/windows-xr-application/openvr-scene.png`. This is an unprotected
OpenVR application suitable for the next headset pipeline check. Nightfall was
reopened, but the first headset attempt stopped at its paused/unresponsive dev
bridge before changing any XR configuration or starting a stream.
The retry also failed at that first bridge query, including after temporarily
broadcasting `com.oculus.vrpowermanager.prox_close`. The outer trial command
restored `com.oculus.vrpowermanager.automation_disable` in `finally`; no Guardian
property was changed. Need Nightfall actively running/foreground in the worn
headset before retrying. Do not count these attempts as XR streaming results.
Final ADB check: Quest awake, Nightfall PID 15913, but its activity is explicitly
listed as paused; ClearActivity and Quest shell panels are resumed. This is
evidence of app focus loss, not evidence that a Guardian dialog is visible.

**November 4 user-ready headset validation succeeded.** First live attempt
exposed the diagnostic probe's fixed 512-pixel eyes versus the negotiated
1024-pixel projection, correctly rejected by the client. Scene mode now queries
OpenVR's recommended width/height and renders to that viewport/texture size;
the solid-colour diagnostic remains fixed at 512. The headset runner now treats
a native receiver error as a failure even if XR control has already gone idle.

Retest ran ~60 seconds of live scene over Wi-Fi, host 10.0.0.13 to Quest
10.0.0.12 (USB ADB only, `usb_reverse=False`). Real Windows D3D11 OpenVR →
xrizer → Monado/NVENC → encrypted Meteor relay → Quest decoder/projection.
User confirmed seeing everything, including Nightfall's wristwatch overlay.
4,208 frames received, 4,207 decoded, 3,979 projected; receiver error empty.
Active observed rates ~69.65 received/s and ~65.92 projected/s; app reported
~72 fps. Thus successful video/overlay/tracking validation, not proof of every
source frame being presented at 72 Hz. 227 frames superseded before selection.
Real head motion and both controller inputs reached the host: head position
changed in all axes, both controller flags reached 15, and each trigger/squeeze
ranged from 0 to 1. Do not infer every action binding or haptics from this.

Session artifacts:
`%LOCALAPPDATA%\Nightfall Meteor\xr\windows-sessions\1793806256853691800`,
`meteor/target/windows-xr-headset-trial.jsonl`, and
`meteor/target/windows-xrizer-headset-summary.json`. Median NVENC submit/lock
2.141 ms (p95 3.926 ms); relay ACK 4.403 ms (p95 6.543 ms, maximum 160.635 ms).
These are stage timings, not end-to-end headset latency.
The planned 60-second stop cancels the owned runtime; no acknowledged END marker
was written. The summary's strict `transport_ok` is therefore false, despite
successful live video and an empty decoder error. Graceful END acceptance is
covered separately by the host-only natural-exit smoke; do not claim it for
this cancelled headset run. Script restores the original client preferences
and runtime config after the trial. VRChat/EAC and Moss game compatibility
remain separate unresolved issues.

November 4 Moss investigation resumed at the user's request. Startup crash
context `UE4CC-Windows-027D046A46F759AB6EDCAA940BAAFE64_0000` shows a null indirect
call returning to executable RVA `0xa9eeae`. Read-only disassembly resolves this
to the plugin's cached `VR_GetGenericInterface` function pointer, called for
`IVRSystem_020` and then `IVRCompositor_022`. The plugin itself reads
`VR_OVERRIDE` as an SDK root, constructs `bin\win64\openvr_api.dll`, and resolves
`VR_IsHmdPresent`/`VR_GetGenericInterface` from that DLL. Our runtime-only override
lacked this SDK layout. This explains a likely null-pointer startup path;
confirmation requires the real application retest.

Added optional Windows config `openvr_loader` (absolute path to a local Valve
DLL, requires `openvr_runtime`). Before launching, the adapter stages an owned
session directory containing both `bin/vrclient_x64.dll` (pinned xrizer) and
`bin/win64/openvr_api.dll` (unchanged local Valve loader). It applies the staged
override and DLL search path to the application only. No game file is replaced
and no upstream xrizer source is changed. Both local/headset application smoke
scripts accept `-OpenVrLoader`. Real Moss OpenVR capture test is in progress.
The real test now **passes**: 15-second startup observation, real game textures
through xrizer, Focused D3D11 session and Touch profiles. No game files or
xrizer upstream source were modified. Artifact session
`1793806630424139300`, local `smoke-summary.json` successful, wrapper cancellation
130. This confirms the SDK/runtime layout mismatch caused the initial null-call
failure. Release unit/build checks and a physical-headset Moss trial follow;
do not yet claim gameplay or long-session stability. xrizer also logs some
unsupported Vive binding paths/pose types, which are not evidence that the
active Touch bindings failed.
Final native release unit recheck: 147 passed, 19 ignored. XR DEV release
executable rebuilt successfully with the loader staging change. Captured first
frame black and a 10-second frame showing dark loading geometry; no claim of
menus/gameplay from those images. Artifacts `moss-xrizer-startup.png` and
`moss-xrizer-late.png` under `windows-xr-application`.

The subsequent Moss headset attempt stopped at the initial dev-bridge read
timeout before launching the service/game. Headset must have Nightfall active
again; no real headset Moss/xrizer gameplay has yet been validated.
`configure_windows_xr_steam.ps1` now also accepts `-OpenVrLoader`; prepared the
isolated `windows-xr-steam` configuration for Moss app 846470 with its own Valve
loader. Previous VRChat configuration was backed up by that helper. Steam's
userdata/launch options remain untouched; copyable options are in
`windows-xr-steam/steam-launch-options.txt`.

**November 4 Moss physical-headset trial completed after user said ready.**
Used `run_windows_xr_scene.ps1 -EyeSize 1024 -Seconds 60` with Moss arguments
`-vr -dx11 -hmd=SteamVR`, pinned xrizer runtime, Moss's original Valve DLL via
`-OpenVrLoader`, host 10.0.0.13; USB ADB management, video/tracking over Wi-Fi.
Session `1793808240248851100` staged the loader, launched Moss, encoded its first
frame and remained active until the planned stop. 4,329 received and decoded,
4,118 projected, 210 superseded before selection, receiver error empty. Observed
60.39-second delivery interval: ~71.57 received/s, ~68.12 projected/s. App reported
72 fps. Median NVENC submit/lock 2.445 ms (p95 5.577); relay ACK 4.772 ms
(p95 8.087, max 26.554). As with the scene test, the forced cancellation does
not produce acknowledged END; strict summary `transport_ok=false` must not be
misrepresented as graceful-exit acceptance. Artifact
`meteor/target/windows-moss-xrizer-headset-summary.json`. Await user confirmation
of visible menus, controller bindings and gameplay; video transport alone does
not validate them. The earlier Moss startup crash through xrizer is resolved.
User subsequently confirmed Moss ran great; the remaining complaint was low
resolution. That successful trial explicitly forced `-EyeSize 1024` and 32 Mbps,
temporarily setting client `resolution_percent=0`. This was a diagnostic-runner
override, not a host limitation or ignored negotiation. Checked source path:
client effective dimensions → offer width/height → Windows adapter
`METEOR_XR_EYE_SIZE`/`METEOR_XR_EYE_HEIGHT` → Monado recommended view dimensions →
xrizer `GetRecommendedRenderTargetSize` → Moss render targets. Rectangular
per-eye dimensions are supported. Current source's Quest 3 reference at 100%
is 2064×2208 per eye. Saved client percentage could not be read after the test
because the dev bridge had paused again.

Changed `run_windows_xr_scene.ps1` defaults: `EyeSize=0` follows client selection,
`BitrateMbps=-1` follows saved client bitrate. Only explicit positive `-EyeSize`
forces square/custom resolution; explicit `-BitrateMbps` overrides bitrate.
Foveated encoding remains disabled for this Windows DEV backend. Prior client
preferences are still restored afterward. PowerShell syntax check passed;
no new high-resolution headset trial has been performed yet. For the next Moss
quality check, omit `-EyeSize` and `-BitrateMbps` to validate client-led
resolution/bitrate negotiation end to end.

November 4 VRChat revisited after the successful Moss headset trial. Repeated
normal `start_protected_game.exe` launch with app 438100, anti-cheat enabled,
current per-user OpenVR registry and session-local loader staging using VRChat's
own `VRChat_Data/Plugins/x86_64/openvr_api.dll`. Game starts in desktop mode
(user confirmed), but no XR frames within 45 seconds. New client log
`output_log_2026-11-04_17-16-38.txt` still reports
`Init_VRClientDLLNotFound`; xrizer's initialization log is not reached.
First retry session `1793808991938411700`. Reproduction remained desktop-only.

Control experiment with the exact same VRChat Valve loader, staged xrizer
files, app ID and Steam wrapper, but our unprotected OpenVR scene instead of
the protected game, passes the 2-second real-capture check. Thus the files and
generic loader setup work; the remaining failure is specific to loading the
runtime from VRChat's process. Valve loader version 2.2.3 has a valid Valve
Authenticode signature; locally built xrizer is unsigned. Windows Code
Integrity Operational logs had no matching VRChat/xrizer/vrclient rejection.
New read-only helper `read_windows_vrchat_dialogs.ps1` enumerated visible
VRChat/EAC windows and found only the VRChat window, no rejection text. No
debugger, injection, anti-cheat disabling or game-file modification was used.
Anti-cheat rejection remains plausible given the user's earlier popup, but
the new diagnostics do not independently confirm its exact reason. Do not
claim that unsigned status alone proves EAC rejected this DLL.

Valve's matching loader source returns `Init_VRClientDLLNotFound` when
`SharedLib_Load` fails, before `VRClientCoreFactory` is called; it does not
distinguish an absent file, dependency load failure or policy denial:
https://github.com/ValveSoftware/openvr/blob/v2.2.3/src/openvr_api_public.cpp
No working native Windows VRChat/xrizer integration was found in this search.
Linux/Virtual Desktop successes do not establish the same native DLL-loading
path; identify the actual backend before using those as an equivalent control.

**November 4 VRChat rejection confirmed from user screenshot.** User clarified
that the EAC popup appears on normal game exit, after working desktop gameplay.
Restarted the normal protected launcher with no automatic shutdown; game log
`output_log_2026-11-04_17-31-57.txt` again recorded OpenVR DLL-load failure and
successful anti-cheat session startup. User quit normally and saved
`C:\Users\Ty\Pictures\Screenshots\Screenshot 2026-11-04 173236.png`.
Inspected screenshot: Windows Explorer alert, Easy Anti-Cheat,
**Untrusted system file**, naming the build under
`...\Users\Ty\Development\nightfall\meteor\target\windows-xrizer-d3d11-src\target\release`.
The visible text truncates before the final DLL filename, so do not invent the
full path. This is independent evidence of EAC rejecting the custom runtime;
the delayed popup does not indicate the VR initialization succeeded earlier.
It explains the runtime-load failure/desktop fallback, rather than a general
game launch failure or capture/encoding failure.

VRChat/EAC text reader could not capture this alert because it is owned/titled
Windows Explorer, not the game/EAC windows that reader filters. The screenshot
is the evidence; the game/bootstrap logs do not contain that popup text.
No protections were disabled and no game binaries replaced. Native Windows
VRChat support now needs an EAC-accepted integration; signing alone must not
be assumed sufficient without checking the game's policy. Existing Linux
xrizer and Windows Virtual Desktop success are not proof that this locally
built Windows xrizer DLL is accepted.

Prepared headset scene command (PowerShell; scopes the runtime config and
restores preferences on exit):

```powershell
& .\test\run_windows_xr_scene.ps1 -EyeSize 1024 -Seconds 60 `
  -Application "$PWD\meteor\target\windows-runtime-probe\Release\meteor-openvr-probe.exe" `
  -ApplicationArguments @('C:\Program Files (x86)\Steam\steamapps\common\Moss\Engine\Binaries\ThirdParty\OpenVR\OpenVRv1_5_17\Win64\openvr_api.dll','7200','--scene') `
  -SteamAppId 846470 `
  -OpenVrRuntime "$PWD\meteor\target\windows-xrizer-d3d11-src\target\release" `
  -HostAddress 10.0.0.13
```

Checked out Nightfall's exact Linux xrizer pin
`a1216c7b53fb562a5bc4de473163e97a483042af` into ignored
`meteor/target/windows-xrizer-src`, without modifying it. At this revision,
`src/graphics_backends.rs` supports Vulkan/OpenGL only and rejects DirectX
textures. OpenGL imports GLX/dlopen unconditionally, and `xbuild` assumes
`.so` files and Unix symlinks. `build.rs` already recognizes Windows runtime
directory/library names, but that is not a working Direct3D implementation.
Prioritize a Windows xrizer build/graphics port and equivalent scoped Steam
wrapper instead of testing OpenVR games through the current OpenXR-only
launcher. Native release-profile check is logged in
`meteor/target/windows-xrizer-check.log`; it is an initial feasibility check,
not a successful xrizer/VRChat compatibility result.
The first native check stopped in OpenVR bindgen because Windows libclang
(`clang.dll`/`libclang.dll`) was not found. Thus core Windows compilation has
not yet been validated. Next: supply native libclang, isolate Unix build/GLX
assumptions, add native Direct3D texture support, and implement the shared
Steam wrapper/environment path. Use xrizer for OpenVR games rather than
forcing alternate native OpenXR launch modes; retain direct native OpenXR
support for applications that already use it. The user's priority is parity
with Linux, not further Moss-specific workarounds.

November 4 pose/lifecycle follow-up: Windows now translates view-relative
projection poses through the tracked head into world space, including colour
projections normalized from projection-with-depth. No height offset was added.
A wire-level standard Hello XR / D3D11 / `-AppSpace View` regression reproduced
the old error (`centre_y=0`, expected synthetic head `0.5`). After correction,
673 frames passed the expected-height check with clean END. Pose flags and
input/output centre heights are logged once per mode change.

Moss itself used world-space projection (`view_space=0`, input/output y=0.5)
in the local check, so do not claim the view-space fix resolves Moss's reported
low splash screen. Earlier Wi-Fi logs show actual headset height changing
from ~0.773 m during startup to ~1.542 m later. An initial-pose-anchored loading
screen could therefore appear low after the headset is raised; this is an
inference requiring a repeat with the user wearing it BEFORE launch.

Longer local Moss test now uses neutral controllers (the original fixture
holds synthetic buttons/axes on). It also monitors premature video closure,
not just the first three frames. `-ObserveSeconds 40` passed: 2,830 encoded
frames, application and stream remained alive, and supervisor cancellation
found the child still running. Later decoded capture reached Moss's controls
screen: `meteor/target/windows-xr-application/moss-neutral-late.png`.
The unexplained early Wi-Fi exit did not reproduce in that local run.

New diagnostics: each Windows session directory has `supervisor.log` with
UTC timestamps, service/application PIDs, first frame, application exit,
video END while application remains alive, and cancellation child state.
Monado logs matching `METEOR_WINDOWS_LIFECYCLE` UTC events for session end,
encoder shutdown/start and compositor destruction. This distinguishes a game
exit from a session/transport teardown on the next actual headset run.
The updated capture patch remains reproducible through the build helper.
Release adapter rebuilt; native Windows Rust suite still 145 passed/19 ignored.
User was asked to reply ready while wearing the headset and leave controls
untouched for the first 15 seconds of the next logged Wi-Fi Moss run.

November 4 wireless XR: USB is no longer required for test data/control once
wireless ADB is configured. Using USB once, `adb -s 2G0YC1ZF8P08QN tcpip 5555`
enabled Wi-Fi ADB; the Quest's current Wi-Fi address is 10.0.0.12. Connected
with `adb connect 10.0.0.12:5555`, then forwarded the dev bridge explicitly via
`adb -s 10.0.0.12:5555 forward tcp:47950 tcp:47950`. After a Quest restart,
check this connection again; enabling it may require USB again.

The trial scripts accept `-HostAddress 10.0.0.13`, bind control to the actual
PC LAN address and use it in the headset's temporary config. This skips USB
reverse forwarding entirely; video/tracking bind the accepted connection's
LAN address. The native headset receiver's internal loopback endpoint remains
local to the authenticated relay; its old "USB diagnostic" status text does
not describe the actual network path.
`test/enable_windows_xr_wifi.ps1` was elevated with Windows UAC to create
`NightfallMeteorXRWirelessTrial`: inbound TCP 49100–49102, release XR DEV
executable only, local 10.0.0.13, remote Quest 10.0.0.12. Rule is enabled;
normal firewall/network policy was not disabled.

Moss reached the Quest via Wi-Fi at 2048x2048/eye. The service reported
`host=10.0.0.13 usb_reverse=False`, and native netstat showed the tracking
connection between 10.0.0.13 and 10.0.0.12. Received/decoded 1,386 frames,
projected 1,188, 198 superseded; no decoder error and acknowledged END.
Observed sampled interval approximately 63 received/54 projected fps. It
ended after about 30s, before the requested 60-second timer, and the desktop
returned at 72 fps. User feedback on menu/gameplay and why Moss exited is
pending. Do not claim a complete 60-second game acceptance test.
Artifact: `meteor/target/windows-xr-moss-wifi-summary.json`. Headset preferences
and original runtime JSON were restored. Add `-HostAddress 10.0.0.13` to the
prepared Moss headset command below for subsequent wireless trials.

November 4 application compatibility checkpoint: installed games are Moss VR
(Steam 846470, executable includes OpenXRHMD) and VRChat (installed OpenVR
plugin; separate compatibility work). The unchanged Khronos Hello XR app
initially submitted no captured frames because the Windows adapter ignored
`XRT_LAYER_PROJECTION_DEPTH`. This was not a proven `shouldRender` problem.
Windows now normalizes projection-with-depth to its colour projection exactly
as Linux does, retaining colour subimages, poses/FOV and chroma data; scene
depth is not transported. Hello XR / Direct3D 11 then passed: 687 validated
2048x1024 frames over roughly 10s, clean END, exit zero. A decoded image shows
both eye cube views: `meteor/target/windows-runtime-probe/local-scene/hello-d3d11.png`.

Moss local startup also passed using process-scoped OpenXR configuration:
the runtime identified `Moss1.2023.10.114435`, delivered validated stereo frames
at 1024x1024/eye, and stayed running for the 10s observation after first frames.
709 encoded packets were logged. Captured imagery shows the Unreal startup
screen; this is startup evidence, not proof of gameplay/menu compatibility.
Artifact: `meteor/target/windows-xr-application/application-startup.h264`,
decoded frame `moss-startup.png`. The test cancels the owned process tree;
it does not establish graceful game exit. Steam started as part of this launch.
Windows' registered OpenXR runtime and game files were not changed.

Application launches now use the executable's parent as working directory.
`test/run_windows_xr_scene.ps1` accepts `-Application`, `-SteamAppId`, and
`-ApplicationArguments`; it restores the original runtime JSON, headset video
preferences, discovered-host object and watcher state afterward. For an
application, `-Seconds` is a timed cancellation after first active projection,
with up to 45s additional startup time. Prepared headset command:
`powershell.exe -NoProfile -File test/run_windows_xr_scene.ps1 -EyeSize 2048 -Seconds 60 -Application 'C:\Program Files (x86)\Steam\steamapps\common\Moss\Moss\Binaries\Win64\Moss-Win64-Shipping.exe' -SteamAppId 846470`.
This headset game trial has not run yet. The local application proof is
`test/smoke_windows_xr_application.ps1`; SDK capture uses
`test/smoke_windows_xr_scene.ps1 -HelloXr -Graphics D3D11`.
Updated release XR executable built; native Windows Rust suite: 145 passed,
19 ignored. Trial PowerShell scripts parse, and `git diff --check` is clean.

November 4 physical controller acceptance: the user-worn 15-second repeat with
the corrected observer recorded active press AND release transitions for both
thumbstick clicks, left Y and right B through the real Quest → authenticated
tracking relay → Windows Monado → OpenXR action path. Session events reached
FOCUSED (5). All four requested physical actions are now verified; scene
buttons deliberately have no visual effect. Transport ended cleanly (1,054
decoded, 939 projected, 115 superseded), and the desktop resumed at 72 fps.
This validates these buttons, not every analog/pose/haptic interaction or game.
Summary: `meteor/target/windows-xr-buttons-summary.json`. Remaining work includes
sustained presentation pacing, real application compatibility and packaging.

November 4 user-worn 60-second XR trial at 2048x2048/eye: 4,272 frames decoded,
4,168 copied for projection, 104 superseded, clean END and desktop restoration,
no decoder error. Observed active-interval rates were about 71.3 received and
69.6 fresh projections/s. User feedback: "It looked good" and many buttons were
pressed; the scene has no button-driven visual behavior, only action logging.
The original input observer did not poll post-begin OpenXR events while
rendering, so its inactive actions are not evidence that physical input failed.
It now polls/logs session events before syncing actions. Local synthetic scene
observation passed for both controllers' stick-click and B/Y actions, alongside
349 wire-validated frames and clean END. Physical transitions need a short repeat
with the corrected observer. Artifact: `meteor/target/windows-xr-2048-60s-summary.json`.

November 4 full-resolution headset checkpoint: confirmed Nightfall's actual
Android focused app and live 72 fps desktop stream before testing. The user
reports no visible Guardian dialog; an activity-list entry alone is not proof
of a visible boundary interruption. The cause of the reported pauses remains
unconfirmed; do not attribute them to a headset update without evidence.

The 30-second 2048x2048/eye H.264 USB trial passed transport and handover:
2,119 frames received/decoded, 2,083 copied for projection, 36 superseded,
acknowledged END, no decoder error, and the desktop resumed at 72 fps.
Observed active-interval rates were approximately 70.8 received and 69.7 fresh
projections/s. Full-resolution summary: `meteor/target/windows-xr-2048-summary.json`.
The scene runner now pauses/restores the automatic watcher and uses a fresh
saved config object so the discovered host's original config is not mutated.
Controller actions remained inactive in the logs; user confirmation of actual
button testing is pending, so physical controller support is not validated.

After restoring desktop preferences, the client retried its saved Linux XR
endpoint (10.0.0.13:47905, different pinned public key) every five seconds and
reported handshake timeout/key mismatch. For the current test session only,
`welcome_screen._auto_suppressed` was set true and the watcher cancelled.
Saved pairing/config files were not changed. This stops stale automatic
retries, but is not proof of the cause of user-visible pauses. The separate
Windows USB XR service uses loopback port 49100 and the Windows Meteor key.

November 4 restart recovery: normal Meteor was relaunched (PID 10540 at this
checkpoint); discovery on 49900 and proxy serverinfo on 50989 both returned
HTTP 200. Quest USB serial 2G0YC1ZF8P08QN reconnected and bridge forwarding was
restored. GuardianDialogActivity appeared in an activity list while the bridge
was unresponsive, and the user was asked about the boundary dialog. This did
not establish that a Guardian prompt was visibly covering the app. See the
later focused-app/full-resolution checkpoint above for the completed trial.

Independent host proof `test/smoke_windows_xr_scene.ps1 -EyeSize 2048 -Seconds 10`
passed: 720 source submissions, 693 wire-validated H.264 frames at 4096x2048,
sample exit zero, no capture failures, all 693 delivery packets drained and
acknowledged END. Synthetic head pose was applied. This excludes Android
decode/presentation and physical input. Local fixtures now request ephemeral
ports and publish readiness, avoiding fixed-port conflicts after reboot.
Native FFprobe confirmed H.264 4096x2048/yuv420p, and FFmpeg decoded the first
three received frames with `-xerror` successfully.
Artifacts are under `meteor/target/windows-runtime-probe/local-scene/` and
`meteor/target/windows-monado-vcpkg-build/meteor-windows-smoke/`.

November 4 pacing follow-up: Windows now ports Linux's bounded compressed
delivery worker using native SRW locks, condition variables and a Win32 thread.
It retains two pending packets plus one in flight, preserves every encoded
interframe, waits at most two seconds for a slot during decoder cold start,
and drains the acknowledged END before runtime shutdown. The Windows DEV
adapter enables this by default; `xr-windows.json` can set `async_delivery`
false for comparisons. The scene runner also accepts `-AsyncDelivery:$false`.
No system GPU power policy was changed.

Comparable 30-second 1024x1024/eye USB trials with headset timing telemetry:
synchronous received 2,025 and projected 2,024 frames (67.7/67.8 fps within the
sampled active interval); asynchronous received/decoded 2,106 and projected
2,054 (70.3/68.7 fps). Endpoint differences and polling make these approximate
rates. The async queue drained all 2,106 packets, peak pending two, no failure.
The earlier 58 fps presentation result did not repeat consistently: this is
an incremental improvement, not proof that sustained pacing is solved.
Headset app telemetry remained at 72 fps/72 Hz. RTX 3090 telemetry showed
P8 clocks around 210–375 MHz during much of this offscreen workload; current
headset thermal status was normal. Clock behavior is a lead, not a proven
cause. Next investigate capture/encode scheduling independently of compositor
work, then test higher resolutions and physical input/game compatibility.

Local comparison artifacts: `meteor/target/windows-xr-{sync,async}-summary.json`,
`windows-xr-{sync,async}-telemetry.jsonl`, and `windows-xr-{sync,async}-gpu.csv`.
Native Windows queue regression passed delayed first ACK (150 ms), four
preserved frames, incorrect-ACK rejection, restart, and acknowledged END.
The shared Linux queue regression passed as well (requires unsandboxed local
socket sends here). Native five-frame stop-and-wait pixel/wire validation passed.

November 4 sustained GPU scene: `test/run_windows_xr_scene.ps1` now runs the
existing tracked GPU scene with explicit 72 Hz handover, no pixel readbacks,
and no per-frame file wait. It restores the original headset preferences and
discovered host afterward. At 1024x1024 per eye, H.264/32 Mbps over USB, the
30-second matched trial decoded 2,026 frames and projected 1,728; 298 were
superseded before selection. Approximate rates were 67.6 decoded and 57.6 fresh
projected frames/s. The short 10-second matched trial projected 692/694 decoded
frames, but that improvement did not persist. Logs confirmed 72 Hz timing;
do not attribute the longer-run pacing issue solely to refresh mismatch.
Both trials acknowledged END and returned to idle without decoder error.
Median timings in the longer trial: GPU eye 0.369 ms, app render 1.88 ms,
GPU packing 1.247 ms, NVENC submit-to-lock 6.682 ms, delivery ACK 1.483 ms
(ACK p95 2.404 ms, max 60.955 ms). These are diagnostic stage timings, not
end-to-end motion latency. Pacing and real game compatibility remain open.
`test/summarize_windows_xr_scene.py` separates received/decoded/projected
counts. Latest local artifact: `meteor/target/windows-xr-scene-1024-summary.json`.

Live stick-click/B/Y observation is available in scene mode. All physical
actions remained inactive during the unattended tests; physical input is not
validated. The deterministic native OpenXR controller check still passed all
10 phases and both hand haptic acknowledgements. Native Windows Rust tests:
145 passed, 18 ignored. The WSL `tools/verify.py unit` wrapper cannot find Cargo;
its failed summary is in `build/verify/unit-20261104-072221/summary.json`.

November 4 headset checkpoint: the isolated Windows XR DEV service delivered
two H.264 stereo frames through authenticated encrypted USB relays to the
Quest hardware decoder and enabled projection. Real headset optics and head
tracking reached Monado. Fixed missing runtime generation/sequence metadata,
disabled Monado console polling with `XRT_NO_STDIN`, and explicitly quiesced
the tracking lane before terminating the owned runtime. The short trial now
returns to idle with no decoder/tracking error. This is a diagnostic at
256x256 per eye, not an image-quality or sustained-rate acceptance result.
The longer fixture also needs per-frame timestamp acknowledgements; the
Windows readback hook now writes those when continuous mode is requested.
Windows QPC conversion rounds timestamps; the probe accepts less than 1 us
of difference for the same capture acknowledgement. The completed 240-frame
headset trial received, decoded and projected all 240 frames, reported no
decoder error, returned to idle, and wrote the acknowledged session END marker.
This stop-and-wait fixture is not a 72 fps throughput measurement. Original
headset video preferences and discovered configuration were restored afterward.

November 3 acceptance: the user confirmed that both Windows monitors display
correctly after the manifest capability/resolution correction. Live switching
between one and two monitors passed. Windows multi-monitor remains an
experimental SDR/same-adapter/unrotated path; packaging is still pending.

Open input issue (deferred at the user's request): grip right-click feels too
sensitive or like a simultaneous left-click with Follow pointer enabled;
turning Follow pointer off avoids it. A Windows low-level hook recorded six
grip presses as right down/up only, with no left-button events. Do not treat
this as a proven duplicate-click bug; investigate pointer motion/click target
stability separately after the main Windows XR work.

Next priority: Windows XR sustained pacing, physical controller interaction,
and actual game compatibility. Native Monado stereo capture, runtime
supervision, authenticated delivery, and synthetic tracking/controller/haptic
proofs pass. Do not describe the diagnostic adapter as a finished XR streaming
implementation.

November 3 XR delivery checkpoint: `monado_direct_transport.h` now has a
Winsock path with nonblocking sockets, bounded polling and random per-session
epochs. The Windows Monado adapter copies encoded callback data and sends it
outside the Vulkan queue lock, including actual projection poses/FOV. Its
shutdown sends the wire END before unloading the encoder. The isolated
`smoke_windows_xr_delivery.ps1` passed: two 512x256 H.264 frames, validated by
Meteor's actual Rust `xr_wire::Reader`, followed by a clean acknowledged END.
The received video also passed decoded stereo-pattern checks (initial green=0,
final green=255). The later server readback saw a newer intermediate marker
after transport acknowledgement, so this free-running fixture does not prove
per-frame marker alignment between encode and subsequent readback. This validates
local delivery framing, not the running Meteor service/headset relay yet.

Windows XR lifecycle groundwork is now compiled into Meteor as
`xr_runtime_windows::Session`: it owns a configured runtime and application
in a kill-on-close Windows Job, rejects duplicate application launches and
detects premature runtime exit. The native Windows release test confirmed
that dropping a session terminates/reaps both children promptly. Five shared
XR relay admission/cancellation/drain tests also passed on Windows; the native
live-worker test remains ignored without its fixture. The session owner is
not yet wired into authenticated runtime startup: tracking integration and
runtime configuration validation must precede enabling that launch path.

Windows tracking bridge groundwork: the existing head/optics/controller/haptic
bridge now builds as `meteor-windows-tracking.dll` using Winsock, preserving
the Linux implementation behind platform guards. Its actual pose/controller
contention regression passed on MSVC with assertions enabled. Monado's virtual
HMD tracking hook and DLL loader now compile natively too, with a reproducible
`monado_windows_tracking.patch`. Without an explicit tracking bridge it retains
the isolated simulated diagnostic mode; no live headset tracking has been
validated yet. The next gate is clock sync, pose validity and disconnect
behavior through the socket, then controller-driver/haptic hookup.

Windows tracking socket checks now pass against the actual bridge with
assertions enabled: an independently offset synthetic clock (+5 seconds)
mapped with about 11 microseconds uncertainty, expected head and both-hand
poses/buttons/analogs arrived, and both haptic commands were clamped to 0.5
amplitude/150 ms and acknowledged. A 350 ms tracking pause invalidated head
and controller state, resumption recovered, and disconnect invalidated poses
and stopped promptly. This is synthetic loopback protocol coverage; real
headset tracking and Monado controller-device integration are still pending.

Monado controller-device integration subsequently passed on Windows:
`smoke_windows_xr_controllers.ps1` verified ten independent left/right
stick-click and B/Y transitions through real OpenXR action bindings. The
application also requested haptics for both hands through OpenXR; Monado's
output callback forwarded them and the synthetic endpoint acknowledged each
0.4-amplitude/50 ms pulse. `smoke_windows_xr_tracking.ps1` separately verified
the published head pose reaching Monado while stereo encoding remained active.
These are native Windows runtime checks with synthetic input, not real
headset tracking acceptance.

Windows DEV runtime startup is now connected to the shared authenticated relay
supervisor, gated by an explicit local `xr-windows.json` configuration. It
starts only after both lanes attach, launches Monado and one configured app
inside an owned Job, scopes the OpenXR runtime/DLL paths to those children,
and records session activity only after a captured frame. H.264 is the only
advertised Windows codec at this checkpoint; live bitrate/foveation and Steam
launch intents remain unavailable. Normal packaged XR startup stays disabled.
The native adapter integration test passed with the synthetic tracking source:
Monado/app startup, a validated stereo frame, acknowledged END and cleanup.
It caught and fixed a shutdown race: app exit now allows a bounded Monado
encoder drain before its Job is closed. No headset XR acceptance yet.

- The Windows release build compiles from main on branch
  `feat/meteor-windows-compat`. An XR profile validator was moved into shared
  code because the Windows control module could not reference Linux-only
  `xr_session`.
- Auto decoder choice on a selected AMD GPU now tries FFmpeg D3D11VA, then
  software. The advanced decode menu exposes D3D11VA on Windows. FFmpeg's
  `vendor_id` device option selects the RX 480 in a multi-GPU machine.
- A 20-frame H.264 and HEVC B-frame replay passed through both software and
  RX 480 D3D11VA, preserving frame IDs and matching RGB output. The Windows
  release Rust suite passed: 131 tests, 16 ignored.
- EdgePad 512x288 produced finite depth on the RX 480 and RTX 3090. On a
  synthetic frame, ten warm GPU inferences averaged 28.5 ms on RX 480 versus
  2.2 ms on RTX 3090. This is model-only timing; it does not measure a stream.
- A 360-frame, 120 fps Windows host replay with EdgePad 512 at 20 Hz selected
  RX 480 D3D11VA decoding, ncnn Vulkan inference and Vulkan postprocessing:
  60 maps, 0 skipped, 43.7 ms median and 49.6 ms p95 frame-to-map latency.
  Selecting RTX 3090 in a separate state selected NVDEC and NVIDIA inference:
  58 maps, 9.6 ms median and 11.9 ms p95. These are replay measurements,
  not headset streaming results. The cached ncnn SDK built the optional
  Vulkan DLL after fixing MSVC include paths and Windows min/max macros.
- ncnn listed the RX 480 three times in Vulkan enumeration on this PC. The
  GPU choice list now keeps one entry per name so the tray does not repeat it.
- The release and installer scripts now stage four pinned FFmpeg 8 LGPL DLLs
  and their licence. The installer also includes the 256 EdgePad model and
  Vulkan VDA DLL that the previous installer script omitted. Packaging syntax
  has been checked, but a full installer build still needs the new 256 model
  files, which are absent from the older Windows model folder.
- A live RX 480 stream to the headset remains to be checked.
  Headset checks require user approval under `docs/guides/agent-testing.md`.
- Windows XR remains the next major compatibility task. The Linux runtime,
  Vulkan capture and encoder path are not Windows artifacts. First validate a
  native Windows OpenXR session with a candidate runtime; then add Windows
  capture and managed lifecycle adapters. Keep OpenVR compatibility as a
  separate acceptance check. Today `xr_control::validate_runtime_root` rejects
  Windows and runtime startup is Linux-gated, so a live Windows XR stream is
  not available yet.
- One active 2560x1440 display was present on this Windows PC during the
  October 29 check. On October 30 the RX 480 was removed and Windows reported
  two active displays: 2560x1440 primary and 1920x1080 secondary, both on the
  RTX 3090. The fork's `/polaris/v1/display/manifest` still returns a layout
  only on Linux, so Windows multi-monitor streaming needs host capture and
  manifest work before these displays can be validated end to end.

## Bundled host and XR checkpoint (2026-10-30)

- `origin/main` remained at `e5dd63c`; the bundled host was on
  `origin/feat/meteor-bundled-host` at `95dc0a2`. That branch was merged into
  `feat/meteor-windows-compat`, retaining the Windows depth fixes.
- Meteor now compiles the bundled-host controller on Windows, shows its choice
  and lifecycle in the Windows tray, and uses an isolated Windows host config
  beside the dedicated host executable. It refuses to adopt a non-Meteor host
  config in that directory. The host process supervisor and restart path are
  native Windows code. This is integration code, not a validated stream yet.
- The fork's development branch `codex/meteor-vibepollo-baseline` at `b6efac1`
  was cloned into ignored `meteor/target/windows-vibepollo-src`. MSYS2 UCRT64
  and the fork's documented Windows dependencies were installed. A Release
  `sunshine.exe` build reports `2.0.0-meteor.win.dev` and that revision. Its
  current Windows `appdata()` is relative to its executable, so package the
  host in its own directory. Meteor sets `system_tray = false` for the managed
  copy; the host still needs its tray implementation linked to build.
- The Windows tray's Game streaming host menu exposes the managed host's
  status, start/stop, web page, generated login file, and host folder. The
  web login file is needed for manual pairing until the one-click flow lands.
- Isolated Windows host smoke: the managed host started on base 51989, Meteor
  advertised `host.kind = meteor-vibepollo` on discovery port 51900, its proxy
  returned HTTP 200 for `/serverinfo` on 52989, and the Windows job object
  terminated the host after Meteor was killed. The normal Windows profile was
  backed up and configured to use this development host; Meteor and host were
  left running at those ports for manual desktop-stream testing. Apollo was
  left running on its own stack.
- The updated Windows release passed 144 Rust tests (16 ignored, one known
  GPU fixture skipped), plus 12 host-specific tests including job cleanup.
  EdgePad 512 replay on RTX 3090 produced 58 maps from a 360-frame 120 fps
  fixture at a selected 20 Hz rate: 7.9 ms median and 11.6 ms p95
  frame-to-map latency, with NVDEC and NVIDIA Vulkan inference. This is a
  replay, not a client stream.
- The fork's DXGI tool sees both active displays, but the Windows host
  manifest endpoint is Linux-gated and Windows capture selects one output.
  The client's `outputs=` multi-monitor flow therefore has no matching
  Windows host implementation yet.
- Pinned Monado `eab5ff02` and Khronos `hello_xr` build natively on Windows.
  With a process-local `XR_RUNTIME_JSON` and simulated HMD, `hello_xr`
  created both 640x720 eye swapchains. This proves local OpenXR session
  creation, not Nightfall XR capture, encoding or headset streaming. Meteor's
  managed XR runtime path remains Linux-gated.

## XR capture and Windows monitor work (2026-10-30)

- Added a reproducible Windows null-compositor capture hook in
  `test/monado_windows_capture.h`, with a patch and build script beside it.
  The native Release `monado-service.exe` compiles with it. The hook validates
  that a submitted stereo projection references two live Vulkan swapchain
  images and logs their formats, image indices and subrects. It currently
  stops at metadata: there is no Windows image readback, encoder bridge,
  tracking transport, or Meteor runtime supervisor yet.
- In a local simulated-HMD run, `hello_xr` created two 640x720 eye
  swapchains and the patched service reached the hook, but the sample only
  triggered an empty layer commit during a 25-second run. Stereo submission
  is therefore **not proven yet**. A deterministic Windows OpenXR probe that
  submits a coloured stereo pattern is the next XR gate; reuse the Linux
  `monado_runtime_probe.cpp` after replacing its POSIX time conversion.
- October 31: the deterministic probe now builds with MSVC using the OpenXR
  Win32 performance-counter time extension. Its initial `0xc0000409` startup
  failure was caused by buffered stdout initialization with a zero buffer
  size; unbuffered stdout fixed it. A local run submitted five stereo frames
  with app-side pixel verification. The service logged 18 eye-image
  references and zero capture validation failures. These logs prove stereo
  layer delivery to the server; server-side pixel readback and encoding are
  still pending. `test/windows-probe/CMakeLists.txt` builds the probe, and
  `test/smoke_monado_windows.ps1 -HelloXr <probe.exe>` runs it locally.
- Server-side pixel verification now passes on Windows with
  `METEOR_WINDOWS_PIXEL_PROBE=1`: the probe exits successfully, both eye
  patterns pass Vulkan readback in Monado, and the final green=255 marker
  reaches both eyes. The opt-in diagnostic saves server-eye PPMs and writes
  the completion marker. It uses synchronous GPU readback for proof only;
  production capture still needs the encoder bridge and asynchronous delivery.
- Native Windows Vulkan → CUDA → NVENC interop now builds and passes on the
  RTX 3090. The probe exports opaque Win32 memory, imports it into CUDA on
  the same UUID-matched GPU, and encodes five 512x256 H.264 frames without
  CPU pixel readback. NVENC submit-to-lock was 0.44–0.94 ms for this tiny
  fixture; this is not an XR performance measurement. The Windows path
  closes the exported handle after CUDA import, as CUDA retains no ownership
  of opaque Win32 handles. Connecting this encoder to Monado remains pending.
- The diagnostic Windows Monado encoder adapter now passes a local stereo
  encode/decode check. With `METEOR_WINDOWS_ENCODER` pointing at
  `meteor-windows-nvenc.dll`, Monado packs live eye images on the GPU and
  calls NVENC. Two captured frames decoded correctly with left/right eye
  identity, RGB channel order, spatial steps and green markers 64/255.
  The source probe exited successfully and both server pixel checks passed.
  Session end/destruction drains the encoder worker before unloading its DLL.
  This adapter supports one opaque projection; overlay composition, tracking,
  transport and Meteor's Windows runtime lifecycle still need integration.
- A standalone DXGI composition prototype now builds and runs on Windows:
  `meteor-dxgi-composite.exe` enumerates active outputs on the first adapter,
  duplicates each output and submits GPU copies into a shared desktop-sized
  surface. The one-display check captured DISPLAY1 at 2560x1440. Two-display
  capture, pixel verification, frame pacing and Vibepollo integration remain
  pending. The prototype currently supports SDR, unrotated, same-adapter
  outputs only and is not used by the streaming host yet.
- With the second monitor connected, the DXGI prototype captured DISPLAY1
  2560x1440 at (0,0) and DISPLAY2 1920x1080 at (2560,0), producing a
  4480x1440 GPU surface. Mapping a staging copy completed successfully;
  both monitor regions contained nonblack pixels and distinct checksums.
  This verifies actual two-output GPU capture/composition, but does not yet
  verify continuous capture or stream it through Vibepollo.
- Continuous prototype check: 600 polling ticks in 5008.9 ms at a requested
  120 Hz, preserving each monitor's previous pixels when DXGI reports idle.
  DISPLAY1 delivered 333 updates and DISPLAY2 67; these are desktop-change
  updates, not encoded fps. CPU capture/copy submission took 117.0 us median,
  279.3 us p95. Final GPU readback verified populated regions on both outputs.
  Encoder integration, cursor composition, mode-change recovery and HDR
  remain pending in the streaming host.
- Checked the fork's previously untracked `master` at `0f213e6f` before host
  integration. Relative to the Meteor baseline, its Windows platform changes
  are in Playnite integration; it does not provide the missing multi-output
  capture backend. The built host remains on the dedicated Meteor baseline.
- The fork now builds an experimental `display_multi_t` backend using the
  existing `display_vram_t` encoder buffers and keyed-mutex synchronization.
  `METEOR_WINDOWS_MULTIMONITOR=1` selects it explicitly for DXGI encoders.
  The Release host build passed. The durable source patch is
  `test/vibepollo_windows_multimonitor.patch`. This is not enabled in the
  running profile and has not been stream-tested. It currently captures all
  active outputs on one adapter, supports SDR/unrotated displays, and omits
  cursor composition. Manifest/selection support, HDR, mode-change handling
  and a host encode smoke remain required before normal use.
- An isolated Meteor-managed host startup with the experimental flag passed:
  discovery and proxied `/serverinfo` returned HTTP 200, H.264/HEVC NVENC
  initialization passed, and the host died with Meteor. This exercised the
  fork's synthetic encoder validation, not `display_multi_t`: startup could
  not acquire a temporary virtual-display lease and selected synthetic
  surfaces. A real capture-to-encoder check is still required; do not treat
  this startup smoke as multi-monitor encoding validation.
- Real-backend encoder validation now passes with both
  `METEOR_WINDOWS_MULTIMONITOR=1` and `METEOR_WINDOWS_MULTIMONITOR_PROBE=1`.
  The host initialized two-output 4480x1440 capture and explicitly supplied
  captured desktop pixels to its encoder probe; H.264 and HEVC NVENC passed.
  AV1 failed as expected on RTX 3090. This checks capture/conversion/encoding
  compatibility using the probe's output configurations, not sustained
  streaming at native combined resolution. Layout metadata, cursor support,
  output selection and an actual client stream remain pending.
- Windows manifest and selection implementation added behind the experimental
  flag: `/polaris/v1/display/manifest` uses the same geometry policy as the
  DXGI compositor, and `/launch`/`resume` output names select which monitors
  are copied. Unknown outputs, unsupported layouts and multiple active GPU
  adapters are rejected. Software capture is refused while the flag is on,
  so it cannot silently supply a single-output stream with a multi-output
  manifest. The manifest implementation compiled successfully; authenticated
  endpoint and selection behavior still need runtime checks. Cursor support
  remains pending.
- Live Windows selection checks passed via the host's
  `--meteor-display-layout` diagnostic: DISPLAY1 alone is 2560x1440,
  DISPLAY2 alone is 1920x1080 with its frame origin reset to (0,0), both are
  4480x1440, and an unknown name exits with an error. This exercises the
  geometry helper shared by capture and the authenticated manifest endpoint.
- Cursor composition was added using a separate GDI-compatible GPU surface
  and the Windows cursor hotspot, preserving the cursor-free persistent
  desktop to avoid trails. The host rebuilt and repeated its captured-pixel
  H.264/HEVC encoder checks successfully with cursor composition enabled.
  Cursor appearance and movement across both screens still need visual
  verification, as does the authenticated manifest endpoint/client stream.
- November 3 headset check: the physical-display-only trial now streams
  both monitors. The authenticated host manifest reached Nightfall with a
  4480x1440 frame, DISPLAY1 2560x1440 at (0,0), DISPLAY2 1920x1080 at
  (2560,0), both enabled. The client reports two visible screens, HEVC HW,
  72 fps and about 3 ms network latency. Negotiated video output remains
  2560x1440, so native combined-resolution quality is not validated yet.
  The multi-output backend now populates DXGI-derived frame and pacing
  timestamps; no missing-timestamp warnings appeared after the rebuild.
  User visual checks for monitor content, aspect and cursor remain pending.
- The initial two-monitor view was vertically compressed because the client
  retained `is_polaris_host=false` despite a valid launch manifest. That
  disabled monitor controls and selected a 2560x1440 preset for the 4480x1440
  capture, introducing host letterboxing absent from the manifest's UVs.
  The launch-response handler now treats a validated manifest as authoritative
  capability evidence and stores its capture size. Applying equivalent live
  state produced a 4480x1440 HEVC stream with two screens. Reducing to one
  monitor then passed at 2560x1440/72 fps. The source change needs packaging
  in a future APK; live host settings were saved for this test. The required
  unit runner could not start because WSL lacks cargo (see unit verification
  summary dated 2026-11-03); runtime behavior was checked through the bridge.
- Vibepollo Windows presently chooses a single `IDXGIOutput` during
  `display_base_t::init` and makes one `IDXGIOutputDuplication`. Its
  `/polaris/v1/display/manifest` endpoint is Linux-only. Windows support
  needs a capture surface spanning selected DXGI outputs, each output copied
  at its desktop offset (or packed frame offset when the decoder limit is
  exceeded). Only after this is implemented should the endpoint advertise a
  Windows layout or accept a multi-output `outputs=` request. The current
  monitor names are `\\.\DISPLAY1` and `\\.\DISPLAY2` in the fork's DXGI
  enumeration. The active Windows profile still captures one monitor.

## Current Windows status (2026-10-09)

- The Windows release exe proxies a Quest 3 stream and runs EdgePad on ncnn
  and VDA on TensorRT. VDA's 75-frame parity test passed. A fresh download
  of the VDA graphs and NVIDIA's Windows DLLs passed SHA-256 verification;
  after a first engine build, the 1440p replay made 3775 maps from 3796
  frames at 120 fps, with 6.2 ms median and 7.3 ms p95 frame-to-map latency.
- The Windows tray has the Nightfall icon, model, rate, smoothing, edge
  softening, microphone, VDA download/progress/cancel/remove, autostart and
  basic stream status controls. VB-CABLE output, an isolated tone test, and
  a real headset-microphone application test work (user confirmed 2026-10-09).
- The Quest's USB depth connection previously had repeated 230-275 ms
  blocked writes. A larger TCP receive buffer removed those stalls in a
  three-minute USB run. Longer USB testing and Wi-Fi/IPv4 validation remain.
- The Windows PowerShell release script builds a 28.8 MiB zip with EdgePad
  and notices. Its default path fetched and hash-checked ncnn, and the
  extracted zip processed a 360-frame H.264 replay: 352 maps at 120 fps,
  5.4 ms median and 6.4 ms p95 frame-to-map (2026-10-09). An Inno Setup 7
  script builds a 28.9 MiB per-user installer. A silent install/uninstall
  test verified the files and registry entry, and left `meteor.key` intact.
  Windows firewall checking and setup, notifications, no-console startup,
  the Visual C++ prerequisite, and the TensorRT engine-build Job object
  remain.
- Windows VDA download hashes are pinned for the sm86 resource used by the
  RTX 3090. Other NVIDIA GPU resources need signed-file hashes before their
  downloads can be offered.

## Pre-release handoff (2026-10-09)

The 0.1.0 installer is suitable for a small tester pre-release on Windows
10/11 x64 with an NVIDIA GPU, Sunshine-compatible host, and the Microsoft
Visual C++ x64 Redistributable. VB-CABLE is an optional separate install for
microphone use. Quit any portable Meteor before starting the installed copy:
only one instance can own the ports. The installer is per-user, makes Start
menu and uninstall entries, and leaves `%LOCALAPPDATA%\Nightfall Meteor`
(including `meteor.key`, models, and VDA downloads) and the roaming settings
in place on uninstall. It is unsigned and does not add Windows Firewall
rules; accept the private-network prompt when Windows shows one. The
installer is built by `meteor/tools/build_windows_installer.ps1` into
`meteor/target/windows-release/` and was copied to the Windows/Linux share
at `G:\Temp\nightfall-windows-build` for handoff. The copied bytes were
verified against the build with SHA-256.

Before a wider release, test the installed app on a clean Windows PC,
including missing Visual C++ runtime and firewall behavior; test longer USB
and Wi-Fi/IPv4 headset sessions; start Meteor without a console and handle
Windows logoff/shutdown; stop a TensorRT engine-build child when Meteor exits;
and add firewall status/setup, code signing, and published checksums. The
Windows VDA download is currently verified for sm86 only; other NVIDIA GPU
builders need hashes and testing. Notifications and DLL search hardening
remain lower-priority follow-ups.

## Goal

Meteor does on Windows what it does on Linux:
- proxy the stream;
- run host depth on the GPU: EdgePad on Vulkan out of the box, and VDA
  after a download from the tray;
- present the Quest's microphone as a PC microphone;
- show a tray icon.

The Quest app needs no changes; it can't tell which OS Meteor runs on.

## The runtimes, as built on Linux

The Windows release should match the Linux one
([meteor-appimage.md](meteor-appimage.md)):

| | What | Linux | Windows |
| --- | --- | --- | --- |
| EdgePad (default) | ncnn on Vulkan (`ncnn.rs`), `<name>.ncnn.param`/`.bin` | `libncnn.so.1`, 20 MB | `ncnn.dll` from `ncnn-20260526-windows-vs2022-shared.zip` (x64), 13 MB |
| VDA (on request) | Native TensorRT (`tensorrt.rs`, shim `native/tensorrt.cpp`), engines built in a child process | Downloaded from NVIDIA's `manylinux` wheel: 0.4 to 0.55 GB | NVIDIA's `win_amd64` wheel (1.9 GB) has the same files: `nvinfer_10.dll` 193 MB compressed, `nvonnxparser_10.dll` 1.3 MB, builder resources 94 MB (sm75) to 235 MB (sm120). About 0.29 to 0.43 GB per GPU |
| Development only | ONNX Runtime (`onnxruntime` feature) | `target/bench-venv` | `target\bench-venv` (layout below) |

The release builds without the `onnxruntime` feature
(`--no-default-features`).

## Where we start

Most of Meteor is portable. These are the parts that need work, checked
against the code on 2026-10-07:

| Part | Windows today |
| --- | --- |
| Proxy, discovery, depth and mic ports (`proxy.rs`, `discovery.rs`, `depth_server.rs`, `mic.rs`) | **Broken for IPv4.** Every listener binds `::`, relying on Linux's dual-stack default. Windows sockets default to `IPV6_V6ONLY`, so a Quest on IPv4 would reach none of them. Discovery's fallback to `0.0.0.0` would also let a second Meteor start, because the single-instance lock is the discovery port. Fix: bind through `socket2` with `set_only_v6(false)` (already a dependency) |
| Decoding (`nvdec.rs`) | Loads `nvcuda.dll` and `nvcuvid.dll`; NVDEC and CUDA work the same there. Untested |
| Kernels (`kernels/*.ptx`) | Portable: PTX, JIT-compiled by the driver |
| Post-processing (`gpu_post.rs`, `postprocess.rs`) | Portable |
| ncnn (`ncnn.rs`) | Looks for `ncnn.dll` next to the exe, in `../lib`, `target/ncnn/lib`, or on the search path. **Four GPU functions are found by their GCC (Itanium) names, which MSVC's `ncnn.dll` doesn't export.** On Windows they are `?create_gpu_instance@ncnn@@YAHPEBD@Z`, `?get_gpu_count@ncnn@@YAHXZ`, `?get_default_gpu_index@ncnn@@YAHXZ`, `?get_gpu_info@ncnn@@YAAEBVGpuInfo@1@H@Z` and `?device_name@GpuInfo@ncnn@@QEBAPEBDXZ` (checked in the 20260526 DLL). `ncnn.dll` imports the MSVC runtime and `VCOMP140.DLL` (OpenMP) |
| TensorRT shim (`native/tensorrt.cpp`, `build.rs`) | **Doesn't compile on Windows:** `<dlfcn.h>`, `dlopen` and `dlsym`. Needs `LoadLibraryW` and `GetProcAddress`, with `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` so `nvinfer_10.dll` finds its builder resource next to it. `build.rs` passes GCC's `-isystem`; MSVC needs `/external:I` (or `.include()`). The `_INTERNAL` factory functions are the same names on both |
| TensorRT lookup (`tensorrt.rs`) | Library names are Linux-only (`libnvinfer.so.10`, `libnvonnxparser.so.10`), and the venv path is the Unix layout. Windows: `nvinfer_10.dll`, `nvonnxparser_10.dll`, and `target\bench-venv\Lib\site-packages\tensorrt_libs` |
| Engine-build child (`tensorrt.rs`) | `--build-tensorrt` in a child process works as is, but it only dies with Meteor on Linux (`PR_SET_PDEATHSIG`). Windows: put it in a Job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` |
| VDA download (`download.rs`) | Pins the Linux wheel and file names. Windows needs the `win_amd64` wheel's URL, sizes, SHA-256s and `.dll` names, and `GetDiskFreeSpaceExW` (today free space isn't checked off Unix). The zip reader handles both: the Windows wheel has no zip64 record. **The Windows wheel's `RECORD` hashes can't be used:** NVIDIA signs the DLLs after writing it. `nvinfer_10.dll` carries a 10,352-byte Authenticode table past `RECORD`'s size (found 2026-10-07; the zip's CRC-32 matched). Pin our own SHA-256s of the signed files instead |
| Data folder (`config.rs`) | `data_dir()` is `%APPDATA%` (roaming) on Windows, so models and the 1 GB TensorRT download would land in the roaming profile. Move it to `%LOCALAPPDATA%\Nightfall Meteor` |
| ONNX Runtime (`onnx/runtime.rs`, development only) | `find_dev_runtime()` and `preload_cuda_libraries()` are Unix-only, as before |
| Shutdown (`main.rs`) | `exit_now()` skips the libraries' exit handlers with `_exit` on Unix (the Linux crash fix). Off Unix it falls back to `std::process::exit`, which runs DLL detach and static destructors: the same race. Use `TerminateProcess(GetCurrentProcess(), code)` after the cleanup. Ctrl+C only (no SIGTERM on Windows) |
| Logging (`logfile.rs`) | Done: `%LOCALAPPDATA%\Nightfall Meteor\meteor.log`, rotated at 5 MB, as well as stderr |
| Single instance (`main.rs`) | The discovery port is the lock, taken before the models load. It works once the dual-stack bind is fixed (above). A named mutex isn't needed |
| Firewall check (`firewall.rs`) | Compiled everywhere, but it queries firewalld and ufw, so on Windows it always reports open. Make it Linux-only, and use Windows Firewall (Phase 4) |
| Autostart and notifications (`desktop.rs`) | Linux-only: `~/.config/autostart` and D-Bus. Windows: the `HKCU\...\Run` key and toast notifications (Phase 4) |
| Tray (`tray.rs`, `ksni`) | Linux-only. The menu has grown: the Model menu with the VDA download offer and progress, the firewall warning and Allow, Start with my computer, Open log. Windows logs "No tray icon on this platform yet" and waits for Ctrl+C |
| Microphone (`mic.rs`) | `VirtualMic::create()` returns "not supported yet"; the receiver, jitter buffer and drift control are portable |
| Packaging | Linux has `tools/build_appimage.sh`. Windows has nothing yet (Phase 4) |

A Windows type-check from Linux (`cargo check --target
x86_64-pc-windows-gnu`, 2026-10-05) stopped at `zstd-sys`, which needs a
Windows C compiler. It now also needs the shim to compile, so do the first
check on Windows.

## Where to develop

Develop and test on Windows. Building can happen on either OS, but every
piece that needs work (DLL loading, NVDEC on the Windows driver, Vulkan,
audio, the tray) can only be tested on Windows.

Windows setup:

1. Rust 1.92.0 with the MSVC toolchain (`rustup`, plus Visual Studio Build
   Tools with the "Desktop development with C++" workload, which also
   compiles the TensorRT shim), and CMake on the path: `audiopus_sys` builds
   libopus from its bundled source for the microphone's Opus decoder
   (2026-10-08). `.cargo/config.toml` sets `CMAKE_POLICY_VERSION_MINIMUM`
   for CMake 4; its lib64 workaround applies to Linux only.
   Meteor's key (`meteor.key`, 2026-10-08) lives in `data_dir()`.
2. NVIDIA driver: `nvcuda.dll`, `nvcuvid.dll` and the Vulkan driver.
3. ncnn: unpack `ncnn-20260526-windows-vs2022-shared.zip` and copy
   `x64\bin\ncnn.dll` into `meteor\target\ncnn\lib\` (`tools/fetch_ncnn.sh`
   does this on Linux; a PowerShell twin is part of Phase 2).
4. The models in `%APPDATA%\Nightfall Meteor\models` (or wherever
   `data_dir()` points after the fix above), copied from the Linux
   machine's `~/.local/share/nightfall-meteor/models`:
   - `zipdepth_wide_512x288.ncnn.param` and `.bin`, the default;
   - the VDA graphs, or let the VDA download fetch them.

   `models/convert_ncnn.py` runs on Windows too, with `pip install pnnx`.
5. TensorRT for VDA, either:
   - a Python 3.12 venv at `meteor\target\bench-venv` with
     `tensorrt-cu13<11`, which Meteor finds in
     `Lib\site-packages\tensorrt_libs` once the lookup is ported; or
   - `tensorrt_dir` in `meteor.toml`; or
   - the VDA download, once ported.

   Add `onnxruntime-gpu` to the venv only to compare with ONNX Runtime.
6. Sunshine (or a fork), streaming to the Quest as usual.
7. VB-CABLE (Phase 3).

Cross-building from Linux is optional, for CI or release builds:
- `cargo-xwin` (the MSVC target; it downloads the Windows SDK and CRT,
  which means accepting Microsoft's licence); or
- `mingw-w64` (the GNU target; it can't link against MSVC's `ncnn.dll`
  import library, but the DLLs are loaded at run time anyway).

Run either in a container, as the AppImage build does.

## Phases

### Phase 1: builds and proxies

- Fix the dual-stack binds (above) on every listener, then check the Quest
  connects over IPv4 and a second Meteor exits.
- Make the TensorRT shim compile on Windows (`LoadLibraryW`,
  `GetProcAddress`, MSVC include flags), so `cargo build --release` works.
  Fix whatever else the build finds.
- `exit_now()` on Windows: `TerminateProcess` after the cleanup.
- Run Meteor in a console with `--no-depth --no-mic`, connect the Quest
  through it, and stream.
- Windows Firewall: allow Meteor's proxy ports and the depth (47901) and
  microphone (47902) ports, for private networks only. For development,
  accept the first-run prompt; the installer adds rules later (Phase 4).

Done when: the Quest streams through Meteor on Windows with no visible
difference from connecting to Sunshine directly.

### Phase 2: host depth

EdgePad on ncnn first, since it's the default and needs only the driver:

- Pick the ncnn GPU function names per platform (the MSVC names above).
- Look for `ncnn.dll` next to the exe (the release layout) and in
  `target\ncnn\lib` (development), and check `VCOMP140.DLL` and the MSVC
  runtime are found.
- Check NVDEC: the decoder log line ("NVDEC: 2560x1440 codec 8 8-bit,
  decoding ..., reduced to 512x288") and
  `nvdec::tests::gpu_reduction_matches_the_cpu`.
- The parity test, `cargo test --release -- --ignored edgepad` with
  `EDGEPAD_TEST_DATA`. Linux: 0.061% mean error, 0.72% worst.
- The replay benchmark on a recorded dump (`--replay <file> --fps 120`).
  Compare with Linux on the RTX 3090: EdgePad on ncnn 5.2 to 6 ms frame to
  map; VDA 5.1 ms.

Then VDA on native TensorRT:

- Port the TensorRT lookup: DLL names, venv path, `tensorrt_dir`.
- Check that the engine-build child finds `nvinfer_10.dll`'s builder
  resource, and that its plan lands in `%LOCALAPPDATA%\Nightfall
  Meteor\tensorrt` and is reused.
- The Job object for the build child; quitting mid-build must leave no
  build process.
- Check whether `nvinfer_10.dll` needs anything beyond the driver. On Linux
  it needs nothing: it links CUDA's runtime statically.
- The VDA parity test (`cargo test --release -- --ignored vda`, with the
  researcher's data). Linux: correlation 0.99995 mean, 0.99965 worst.

Then the VDA download:

- Pin the `win_amd64` wheel (URL, size, and each signed DLL's SHA-256,
  measured ourselves; not `RECORD`'s), chosen by platform in `download.rs`.
  Free space through `GetDiskFreeSpaceExW`. Measured 2026-10-07, checked
  against the zip's CRC-32:
  - `nvinfer_10.dll`
    `73fd99ba7448ebe7b75f3a97bca5fd996f166fa75760f616c0b0eda5c2f7005b`
    (375,812,208 bytes);
  - `nvonnxparser_10.dll`
    `4474757aac9e6abe12b3086fa2ed95f97e93e7b26cc5e89dbada2670842f471e`;
  - `nvinfer_builder_resource_sm86_10.dll`
    `35331ca0164b785b85a9f3d48bb7be1195af9d5ccb760033c0854e133f53b621`.
- Test it end to end, as on Linux (`--download-vda`, then a replay).

Finally `cargo test --release`, and `--quit-after` during a replay and
during an engine build, which must exit cleanly.

Done when: the Quest shows host depth with Depth Sync on (EdgePad out of
the box, VDA after the download), and the replay timings are close to
Linux.

### Phase 3: microphone through VB-CABLE

Windows can't create a microphone without a kernel driver. Writing and
signing our own is out of scope (an EV certificate plus Microsoft's driver
signing). VB-CABLE is free for users to install and is the usual answer:

```text
Meteor ─► WASAPI render (shared mode) ─► "CABLE Input" ─┐
                                                          │ VB-CABLE
apps record from ◄────────────── "CABLE Output" ◄────────┘
```

- Add a Windows `VirtualMic` (`mic.rs`) with the same three methods as Linux:
  - `create()`: finds the "CABLE Input" render endpoint by name through
    `IMMDeviceEnumerator`; returns an error naming VB-CABLE if it isn't
    installed.
  - `write()`: feeds PCM into an `IAudioClient` / `IAudioRenderClient` in
    shared mode, event-driven, with a small buffer (aim for 10-20 ms).
  - `fill()`: reports the endpoint's queued frames
    (`GetCurrentPadding`), so the existing drift control keeps working.
- Use the `windows` crate for WASAPI rather than a cross-platform audio
  library, to keep control of buffer sizes.
- Formats: the Quest sends 48 kHz mono 16-bit; convert to the endpoint's
  shared-mode mix format (usually 48 kHz stereo float).
- Default device: Windows has no public API to change the default recording
  device (only the undocumented `IPolicyConfig`). Don't use it. Instead, the
  tray says which device to choose ("Choose CABLE Output as your
  microphone") and links to the Sound control panel. Apps such as Discord
  can pick CABLE Output directly.
- Not installed: the tray shows "Microphone: install VB-CABLE" with the
  download link; everything else keeps working.
- Measure latency the same way as on Linux (8 ms write to recorder there)
  and listen for crackles under game load.

Done when: Discord or a game hears the Quest's microphone, with latency and
quality comparable to Linux.

Licensing: VB-CABLE is donationware. Users install it themselves. Meteor
doesn't bundle it without a distribution agreement with VB-Audio.

### Phase 4: tray, packaging and startup

Mirror the Linux first-run work ([meteor-appimage.md](meteor-appimage.md),
Phase 4):

- **Tray:** replace `ksni` on Windows with a Win32 tray (the `tray-icon`
  crate, or `Shell_NotifyIconW` through the `windows` crate). It needs its
  own thread with a Win32 message loop.
  - Split `tray.rs` into a shared menu model and per-platform hosts. The
    menu model covers the status lines, the Model menu (with the VDA
    download offer, progress, Cancel and Remove), Rate, smoothing, edge
    softening, the microphone, the firewall warning, Start with my
    computer, Open log, Open settings file and Quit.
  - `icon.rs` already draws RGBA pixels, which become an `HICON`. Use a
    white glyph; the Windows taskbar is dark by default. Consider an
    outlined variant for the light theme later.
- **No console:** build as a Windows-subsystem app
  (`#![cfg_attr(windows, windows_subsystem = "windows")]`); the log file
  already exists. Keep a `--console` flag for development.
- **Notifications:** a toast for "already running" and for a missing tray,
  as `desktop::notify` does on Linux.
- **Shutdown:** handle `WM_QUERYENDSESSION` and `WM_ENDSESSION` (logoff and
  shutdown) through `quit()`, and close the console or Ctrl+C in
  `--console` mode.
- **Start with Windows:** a tray toggle that writes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, turned on once at
  the first run, like the AppImage. It follows the exe if it moves.
- **Firewall:** the installer adds the rules (`netsh advfirewall`, private
  profile). For the zip, the tray checks the rules and offers to add them
  through one elevated `netsh` (UAC prompt), like Linux's `pkexec`.
- **Packaging:** start with a zip, then an Inno Setup or MSIX installer
  that also adds the firewall rules and the Start menu entry. Both build
  from a script like `tools/build_appimage.sh`. Contents:
  - `nightfall-meteor.exe` (no ONNX Runtime);
  - `ncnn.dll`;
  - the MSVC runtime and `vcomp140.dll` next to it (app-local, allowed by
    Microsoft's redistributable terms), or the VC++ Redistributable as an
    installer prerequisite;
  - EdgePad 512 for ncnn;
  - README, LICENSE and THIRD_PARTY_NOTICES (cargo-about, as for the
    AppImage).

  About 30 MB.

Done when: a fresh Windows machine with Sunshine and an NVIDIA driver can
install Meteor, see its tray icon, stream with host depth (and download
VDA) and the microphone, without touching a terminal.

## Decisions

1. **GPU runtime distribution** (decided 2026-10-05, built on Linux
   2026-10-07; see [meteor-appimage.md](meteor-appimage.md)):
   - EdgePad runs on ncnn (Vulkan), shipped with Meteor; the release is
     about 30 MB and needs only the GPU driver.
   - VDA is downloaded from the tray on request: TensorRT's files straight
     from NVIDIA's wheel (only the ones this GPU needs, 0.29 to 0.43 GB
     on Windows) and the VDA graphs from our release. Meteor then builds
     the engines and switches to VDA while EdgePad serves.
   - ONNX Runtime isn't shipped.
   - VDA's files are published (release `meteor-vda-s-518x294`,
     2026-10-08). NVIDIA's answer on fetching the wheel's files this way
     isn't a blocker
     (meteor-appimage.md, Open questions); a Windows installer that
     bundled TensorRT would make it one.
2. **Microphone driver.** VB-CABLE (recommended) or another virtual cable
   (Virtual Audio Cable, VoiceMeeter). The code only needs an endpoint name,
   so supporting a list of known names is cheap.
3. **Default recording device.** Leave it to the user (recommended), or use
   the undocumented `IPolicyConfig` behind an opt-in tray item.

## Risks

| Risk | Mitigation |
| --- | --- |
| DLL search order picks up a different `ncnn.dll`, MSVC runtime or TensorRT from `PATH` (another app's install) | `SetDefaultDllDirectories` plus explicit paths for our DLLs; log the loaded DLL paths at startup, as Linux logs TensorRT's |
| ncnn's C++ names change with its compiler or version | They're pinned with the ncnn version; `ncnn.rs` fails with the missing symbol's name; the version bump checks them |
| Dual-stack sockets behave differently (some adapters, IPv6 disabled) | Bind with `only_v6(false)`, fall back to `0.0.0.0` on failure, and log which one |
| NVDEC behaves differently on the Windows driver (surface limits, pitch) | Phase 2's GPU-vs-CPU reduction test and replay comparison |
| Vulkan interop with a game running (another Vulkan or DX12 app on the GPU) | Measure ncnn timings under game load in Phase 2 |
| WASAPI shared mode adds latency or crackles under load | Event-driven mode, an MMCSS "Pro Audio" thread priority (`AvSetMmThreadCharacteristicsW`), measured in Phase 3 |
| VB-CABLE missing or renamed | Find endpoints by name, accept several known names, and show a clear tray message |
| Antivirus flags an unsigned exe that opens ports, loads DLLs and downloads more | Code-sign release builds; publish hashes; downloads are verified against pinned SHA-256s |
| Firewall blocks the depth or microphone port, so the Quest silently falls back to on-device depth | Installer rules; the tray's firewall check |
