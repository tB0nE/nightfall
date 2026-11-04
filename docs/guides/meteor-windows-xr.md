# Meteor Windows XR development

Release-only workflow for the tested Moss/xrizer and VRChat/SteamVR backends.
See the [checkpoint and release tasks](../plans/active/meteor-windows-vrchat-compat.md).
The existing Windows installer does not include this XR integration.

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
machine is still a packaging task; cloning Nightfall alone is insufficient.
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
