# Meteor Windows XR development

Release-only workflow for the tested Moss/xrizer and VRChat/SteamVR backends.
See the [checkpoint and release tasks](../plans/active/meteor-windows-vrchat-compat.md).
The Windows installer now includes the built-in host, both XR backends and
setup for installed Moss/VRChat games. See the
[clean-install checkpoint](../plans/active/meteor-windows-clean-install.md).
Manual development setup remains documented below.

Use native Windows PowerShell for MSVC, Cargo, CMake, D3D11/NVENC and adb.
WSL is useful for editing and host Python analysis. Commands below run from
the repository root; substitute the local Steam/library paths as needed.

## Dependencies and prepared layout

- Visual Studio 2022 C++ tools, Windows SDK, CMake, Rust MSVC and Vulkan SDK.
- NVIDIA/NVENC and headers from the custom Vibepollo checkout.
- Steam and SteamVR for the SteamVR backend; original game files.
- Prepared Monado/OpenXR loader build and Windows tracking/encoder probes.
  `test/build_monado_windows.ps1` applies the checked-in capture, tracking and
  controller patches to the prepared checkout and rebuilds Release.
- `test/build_xrizer_windows.ps1` builds/tests the pinned native xrizer fork;
  it also requires LLVM/libclang. Its checked-in test patch is test-only.

Ignored `meteor/target/` contains `windows-monado-src`, its configured build,
`windows-runtime-probe`, `windows-xr-dev`, `windows-xr-steamvr`,
`windows-vibepollo-src` and `windows-ffmpeg`. Creating the full layout on a clean
machine requires building these dependencies before staging an installer;
cloning Nightfall alone is insufficient for a source build. Installed users
do not need these development tools or directories.
The custom Vibepollo multi-monitor checkpoint is commit `4478ec81` in
`tB0nE/Vibepollo`; its checkout is clean and maintained separately.

SteamVR headers use Valve OpenVR SDK v2.15.6 at
`0924064316de3effbcd1acf1e309182a2deb1c05`:

```powershell
git clone https://github.com/ValveSoftware/openvr meteor/target/windows-openvr-driver-src
git -C meteor/target/windows-openvr-driver-src checkout --detach 0924064316de3effbcd1acf1e309182a2deb1c05
cmake -S test/steamvr-driver -B meteor/target/windows-steamvr-build -A x64
cmake --build meteor/target/windows-steamvr-build --config Release --parallel 4
cargo test --manifest-path meteor/Cargo.toml --release --locked --no-default-features --bin nightfall-meteor
cargo build --manifest-path meteor/Cargo.toml --release --locked --no-default-features --features xr-dev-binary --bin nightfall-meteor-xr-dev
./meteor/target/windows-steamvr-build/Release/meteor-steamvr-geometry-test.exe
```

Reuse an existing SDK checkout only after verifying its revision/local changes.
CMake accepts `OPENVR_SDK` and `NV_CODEC_HEADERS` overrides. Stop only the XR
test service before overwriting its executable; preserve the normal desktop
host and its pairing. All build commands use Release.

## Backend configuration and local checks

Each local runtime root has `xr-windows.json` with absolute paths to `manifest`,
`tracking`, `encoder`, `service`, `application`, `arguments` and `library_dirs`.
The adapter validates these before launch. SteamVR additionally uses
`steamvr_driver` and `openvr_runtime`; `steamvr_capture` defaults to `direct`.
The legacy manifest/encoder fields remain required by the DEV schema even for
SteamVR. Remote XR control cannot supply executable paths.

`test/configure_windows_steamvr.ps1` derives a separate SteamVR root from the
prepared Monado config and selects the protected VRChat launcher.
`test/configure_windows_xr_steam.ps1` configures a Steam command-wrapper path;
the executable's `--xr-steam-options --root <root>` output supplies launch
options. These helpers use this development PC's default paths.

Local checks may open SteamVR/game windows but do not use the headset:

```powershell
./test/smoke_windows_xr_application.ps1 -SteamVR -Application 'C:\path\to\VRChat\start_protected_game.exe' -ApplicationArguments @() -SteamAppId 438100
./test/smoke_windows_steamvr_motion.ps1
```

Read `meteor/target/windows-xr-application/smoke-summary.json`. Bounded capture
is not graceful exit acceptance; use `-NaturalExit` with the finite reference
probe to check END. The motion helper prints its artifact directory. Use host
`/usr/bin/python3 test/verify_windows_steamvr_motion.py --help` for analysis;
pair each recording with its own metadata. Do not mix artifacts from runs.

## Authorized Quest trials

Ask before installing, launching or streaming on the headset. Keep Nightfall
awake and foregrounded; a bridge timeout often means sleep or lost focus.
For an authorized trial, substitute the runtime root and reachable LAN IP:

```powershell
./test/run_windows_xr_scene.ps1 -RuntimeRoot 'C:\path\to\nightfall\meteor\target\windows-xr-steamvr' -Application 'C:\path\to\VRChat\start_protected_game.exe' -ApplicationArguments @() -SteamAppId 438100 -HostAddress 10.0.0.13 -EyeSize 2048 -BitrateMbps 64 -Seconds 300
```

The timer begins after active video, allows up to five minutes, then cancels.
Temporary video preferences/runtime configuration are restored afterwards.
Existing XR/SteamVR sessions are refused; do not kill unrelated sessions.
Private runtime registration and settings leave global registrations alone.

The bridge uses forwarded port 47950. Trial control/video/tracking ports are
49100/49101/49102. LAN requires the dev executable's firewall rule and pinned
headset identity; loopback mode uses adb reverse. Keep private keys and pairing
credentials outside the repo.

Audio uses the accompanying desktop stream. Check Windows output volume and
Quest media volume. The read-only `meteor-audio-probe` CMake target reports
endpoint defaults and per-app mute/volume/peaks. Quest `[AUDIO-LEVEL]` reports
decoded/output signal and write errors; signal alone does not prove audibility.

Record image stability, controller angle/buttons/haptics, audible game sound,
receive/projected rates, reconnect and exit. Use
`test/summarize_windows_xr_scene.py` with the matching per-session `runtime.log`
and `windows-xr-headset-trial.jsonl`. Requested refresh is not measured delivery;
timed cancellation does not establish acknowledged END.

## Native Windows catalog integration (2026-11-05)

Normal `xr.enabled` startup now works without Linux Python. After rebuilding,
import the two prepared/tested runtimes and enable the service:

```powershell
./test/setup_windows_xr_catalog.ps1 -Enable
```

This writes per-user profiles and enables PCVR in `meteor.toml`, retaining other
settings and a backup. It references prepared runtime builds; it does not yet
download or bundle them. Restart normal Meteor. Its **PCVR** tray menu shows
readiness, opens profiles, approves/rejects a headset's displayed code, opens
VR Apps in Nightfall, and saves each registered game's backend. If profiles
exist but PCVR is disabled, **Enable PCVR (restarts Meteor)** activates it.
Unavailable backend registrations are disabled; there is no automatic fallback.

Moss selects Monado/xrizer and VRChat selects SteamVR. When both profiles are
registered for one game, setup preserves its saved backend when reimporting.
The explicit host choice applies to subsequent launches. Profiles include the Steam app ID
and use direct configured application launch (`steam_launch = false`). Import
another prepared profile with:

```powershell
./meteor/target/release/nightfall-meteor.exe --xr-windows-register --root 'C:\absolute\catalog' --profile 'C:\absolute\profile' --name 'Game name'
```

Nightfall's existing VR Apps list displays registered games and launches by ID.
Meteor queues a short-lived host-local intent; the authenticated headset claims
it, and the runtime receives an immutable snapshot of that game's profile.
Claims are single-use and bound to root and generation. Headsets cannot supply
executable paths or arguments. Automatic Steam-library import and downloadable
runtime bundles remain follow-up work.

Steam can use the same catalog and headset handoff. With Meteor running, set
each registered game's launch options to the line printed by:

```powershell
./meteor/target/release/nightfall-meteor.exe --xr-steam-options --root "$env:LOCALAPPDATA\Nightfall Meteor\xr\windows"
```

For this machine's Moss and VRChat registrations,
`test/configure_windows_steam_catalog.ps1` previews the changes; `-Apply` backs
up the active user's settings, gracefully restarts Steam, and updates only
those two launch options. Existing custom options are refused for manual review.
The wrapper preserves Steam's executable, arguments and working directory,
uses the saved backend, and waits for the headset to claim the launch. Start
Nightfall's desktop stream first. Explicit `--no-vr` or `-nohmd` arguments run
directly in desktop mode. Unknown games fail without starting an XR runtime.

`smoke_windows_xr_catalog.ps1 -SteamWrapper -Codec h265 -EyeWidth 2064
-EyeHeight 2208` checks this broker handoff without a headset. The November 5
check decoded 354 Moss and 364 VRChat frames at 4128×2208 and verified bounded
owned-process cleanup and wrapper cancellation status 130.

Local acceptance commands, without a headset:

```powershell
./test/smoke_windows_xr_normal_startup.ps1
./test/smoke_windows_xr_catalog.ps1 -Root 'C:\Users\Ty\AppData\Local\Nightfall Meteor\xr\windows'
```

The normal-startup check uses isolated settings/ports and starts no game.
The catalog check starts the registered Moss/VRChat profiles using a fresh
synthetic tracking fixture for each. Read `windows-normal-xr-summary.json` and
`windows-catalog-summary.json` in `meteor/target/`.

## Client-requested resolution and HEVC

Windows advertises H.264 and HEVC. Quest 3's existing codec preference selects
HEVC when supported, preserving the client's requested per-eye width and
height. The native SteamVR encoder queries NVENC limits for the selected codec.
H.264's 4096-pixel packed-width limit on the tested GPU cannot fit a 2064-pixel
per-eye request; HEVC supports that 4128×2208 stereo case without resizing.
The native Monado Vulkan encoder also supports HEVC. No APK or saved client
resolution change is needed. Physical throughput remains a separate check.

A local native-catalog check at the exact client dimensions:

```powershell
./test/smoke_windows_xr_catalog.ps1 -Root 'C:\Users\Ty\AppData\Local\Nightfall Meteor\xr\windows' -Codec h265 -EyeWidth 2064 -EyeHeight 2208
```

The helper preserves each game's capture and uses ffprobe to verify actual
codec, dimensions and decoded frame count. One Moss run hit an upstream xrizer
initialization race before rendering; a subsequent run passed. See the active
checkpoint rather than treating a successful retry as proof of zero flakiness.

## Session lifetime

Normal desktop streams and Meteor XR game sessions have no fixed play-time
limit. The Windows application supervisor waits for game exit, explicit stop,
disconnect or failure. SteamVR runs in `--service` mode until its stop marker;
the standalone mirror utility's timed mode is only a diagnostic. The headset
bypasses its diagnostic projection timer when running Meteor. Active XR control
status requests renew the host's idle lease, so its 360-second value is not a
maximum session duration.

Startup, unclaimed-launch, stalled-I/O and shutdown deadlines remain bounded.
These detect abandoned or failed connections rather than limit playing time.
Timed smoke-test helpers intentionally stop their own sessions; use normal
Meteor and the Steam/VR Apps launch flow for unrestricted play.

## Windows multi-monitor startup

Windows multi-monitor capture currently needs the experimental bundled-host
flag. Persist it in `meteor.toml` so normal tray restarts retain support:

```toml
[host_env]
METEOR_WINDOWS_MULTIMONITOR = "1"
```

Restart Meteor and reconnect/reselect the host to refresh its display manifest.
Without this flag, the Screens tab is disabled because the host supplies no
multi-monitor manifest. This backend currently targets SDR DXGI capture.

## Steam crash-protection recovery

Meteor requests normal shutdown of its owned SteamVR monitor before using job
termination as a bounded fallback. This avoids treating every session exit as
a runtime crash. Unrelated SteamVR processes are not closed.

If Steam itself retains the specific stale initialization flag after earlier
forced trials, `test/repair_windows_steamvr_crash_marker.ps1` is an explicit
one-time repair. It refuses an active VR game/runtime, gracefully restarts
Steam, backs up its config, and clears only the known VR/AttemptingInit marker.
It does not disable crash protection or edit add-on blocking. Do not run it on
every launch or use it to conceal a recurring real crash.
