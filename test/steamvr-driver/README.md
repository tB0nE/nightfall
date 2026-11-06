# Windows SteamVR compatibility driver

This is the Windows compatibility path for protected OpenVR games. It is bundled
in Windows packages and does not modify game binaries. The Monado/xrizer path
remains available.
The first mirror-based Quest trial failed image geometry/comfort acceptance.
Direct-mode capture and the vertical FOV correction pass local moving-image
checks and physical VRChat trials on Quest. The user reports good image,
improved controller angle and audible world music after increasing desktop
volume. See the [current checkpoint](../../docs/plans/active/meteor-windows-vrchat-compat.md)
for remaining performance, lifecycle and packaging work.

Requires installed SteamVR, MSVC/CMake, Vulkan SDK (shared transport declarations),
NVIDIA NVENC headers from the existing Vibepollo checkout, and Valve OpenVR SDK
v2.15.6 at commit `0924064316de3effbcd1acf1e309182a2deb1c05` in
`meteor/target/windows-openvr-driver-src`.

From native PowerShell in the repository:

```powershell
cmake -S test/steamvr-driver -B meteor/target/windows-steamvr-build -A x64
cmake --build meteor/target/windows-steamvr-build --config Release --parallel 4
./test/smoke_windows_steamvr.ps1 -Encode
./test/smoke_windows_steamvr.ps1 -VRChat
```

The bounded smoke test rejects existing SteamVR sessions, uses private paths
and settings, and closes only processes started by its trial. The VRChat check
starts the normal protected launcher, observes 40 seconds, and requests normal
window closure. It does not open a Quest session. Read
`meteor/target/windows-steamvr-trial/summary.json`; eye images and H.264 are
diagnostic artifacts beside it. Tests may open SteamVR/game windows.

The HMD/Touch provider loads in vrserver. Direct mode retains SteamVR's shared
eye texture handles, bounds and submitted head pose together, acquires the
keyed synchronization texture, packs the eyes on the GPU and encodes with
NVENC. The service starts owned SteamVR processes and supervises readiness;
it does not acquire compositor mirror textures in direct mode. Compressed
packets use Meteor's existing bounded queue and ACK/END protocol.

The corrected projection mapping is `top = tan(down)`, `bottom = tan(up)`.
`meteor-steamvr-geometry-test.exe` validates matrix/projection conversions.
`./test/smoke_windows_steamvr_motion.ps1` records a moving reference scene;
`test/verify_windows_steamvr_motion.py` checks decoded landmarks against each
frame's own metadata. See the active compatibility plan for recorded results.

Only NVIDIA/NVENC is implemented. Multiple layers with independently different
head poses fail explicitly; general layer reprojection is not implemented.
Controller feel, physical motion latency and high-resolution codec limits
remain acceptance gates.

For Meteor session integration, an explicit `steamvr_driver` directory in
`xr-windows.json` selects this experimental path. `steamvr_capture` defaults to `direct`;
`mirror` explicitly selects the old diagnostic. Set `service` to the mirror
executable and `openvr_runtime` to the installed SteamVR root. Do not specify
`openvr_loader`: the installed original Valve runtime is used directly.
The existing DEV schema still requires the legacy `manifest` and `encoder`
paths, though this backend does not use them. Runtime configuration is private
per session; game and runtime descendants are owned separately.

`./test/configure_windows_steamvr.ps1` prepares the separate
`meteor/target/windows-xr-steamvr` root for the installed protected VRChat
launcher. A later headset check can pass that directory with `-RuntimeRoot`
to `run_windows_xr_scene.ps1`. Use a deliberate 1024-per-eye override for the
first diagnostic; high-resolution codec limits, pose alignment and comfort
still need checking. Do not equate encoded compositor frame count with newly
rendered game FPS. Static/loading images may be repeated to maintain delivery.

Managed sessions can receive their settings over Meteor's user-scoped named
pipe. Without a prepared session, the provider loads idle; explicit synthetic
smokes retain environment configuration. The registered route supports ordinary SteamVR startup and reconnects with
the same display profile. Automatic installation remains staged pending headset
and competing-driver acceptance checks. See the
[integration plan](../../docs/plans/active/meteor-steamvr-driver-integration.md).

Run `test/check_windows_steamvr_integration.ps1` for Release builds, Windows
unit tests, native/Rust pipe interoperability and isolated registration previews.
It writes `meteor/target/windows-steamvr-integration/summary.json` and does not
start SteamVR or use the headset. Capture timing appears in the vrserver log as
`METEOR_STEAMVR_TIMING` (mean/peak microseconds per reporting window).

`test/check_windows_steamvr_integration.ps1 -ExternalCapture` exercises ordinary
SteamVR startup and two connection cycles against one runtime using a private
registration file. It injects a slow bootstrap reply and checks incompatible
resolution rejection. It never connects to the headset or edits system driver
registration. `-Capture` retains the separate owned-runtime regression check.

Resolution, refresh-rate, capture-mode or optics changes currently require a
SteamVR restart. Returning to desktop does not trigger repeated automatic
activation; a new authenticated connection can reuse the existing driver.
