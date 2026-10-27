# Meteor Linux installation and XR distribution

Branch: `feat/meteor-xr-streaming`. Started 26 October 2026.

## Intended installation

With a functioning Sunshine-compatible host, the user installs the Quest APK,
runs Meteor's AppImage, pairs, and can stream the desktop. Optional host depth
and managed XR are configured in Meteor without a source checkout, compiler,
Python virtual environment, separate WiVRN/ALVR service, or global runtime edits.
Normal desktop streaming must continue if optional XR prerequisites fail.

Depth GPU selection, Sunshine capture/encoding, and XR rendering/encoding are
independent. Do not silently treat AMD depth support as AMD XR support.

## Implementation order and acceptance

1. **Extract a relocatable game runtime.** Package the patched Monado service,
   OpenXR library, validated encoding/tracking bridges, launch supervision and
   Steam/library helpers. No Git checks, compilation, Godot editor, test fixture
   import, developer identities or prior sessions may be required to launch a
   real game. Keep the diagnostic checkout launcher available separately.
2. **Finish runtime packaging.** Audit ELF dependencies and the oldest supported
   glibc baseline; bundle eligible libraries and third-party notices, never GPU
   drivers. Install immutable assets separately from per-user configuration,
   locks, launch requests and diagnostics. Define runtime upgrade/rollback and
   enforce agreement between the host, runtime and bridge versions. AppImage
   mounts are read-only: do not run the current writable staging layout there.
3. **Normal startup and trust.** Advertise XR only when the service is usable.
   Persist explicitly authorized headset identities; never authorize the first
   LAN connection automatically. Integrate runtime readiness and actionable
   errors in the tray/client. Retain authenticated session ownership, cancellation
   and shutdown. Avoid starting a GPU compositor merely to advertise readiness.
4. **Steam setup.** Provide supported per-game wrappers and OpenVR compatibility
   installation/selection. Never copy developer-specific xrizer paths. OpenXR
   selection stays process-local; no global runtime replacement. Verify launch,
   exit and relaunch from the desktop, not only from diagnostic fixtures.
5. **Model distribution.** Keep EdgePad 512/256 bundled. Add explicit delivery of
   both Vulkan VDA exports (518x294 and 392x224), with manifest/checksum checking,
   licensing, interruption recovery and understandable missing-model status.
   The existing TensorRT downloader is not a Vulkan model installer. Resolve the
   AppImage's 100 MB size policy before adding large optional models.
6. **GPU readiness and AMD XR.** Show rendering/encoding selection separately
   from depth selection. Validate NVIDIA-only and AMD-desktop/NVIDIA-XR setups.
   Investigate an AMD-compatible image-transfer/encoder backend, preserving the
   working NVENC path; prototype and measure it before advertising AMD XR.
7. **Clean-install acceptance.** Test an isolated installation without checkout
   access, then real NVIDIA and AMD hardware where applicable. Test desktop
   pairing, depth, missing drivers/models, XR authorization, Steam/OpenVR launch,
   audio, input, wristwatch, exit/relaunch, suspend/re-wear and upgrades.

XR audio currently uses the retained Sunshine stream. Standalone XR audio is a
separate enhancement and must not be implied by successful XR video packaging.

## First implementation checkpoint

Added `tools/build_support/stage_meteor_xr_runtime.py` and
`tools/meteor_xr_runtime.py`. Staging copies the local Python import closure,
patched Monado binaries and two bridges from a validated build cache. It writes
checksums and a fresh Steam wildcard application configuration, omitting host
keys, trust records, old sessions and developer compatibility paths. Staging
refuses an existing destination rather than overwriting an installation.

The installed launcher verifies its files before creating a session and invokes
the existing application supervisor without Git/compiler preflight. The Rust
runtime adapter selects it only when an installed manifest and application
configuration exist; checkout diagnostic launch remains available. Installed
runtime validation does not require the diagnostic Godot editor.

This is a writable **staging layout**, not a finished redistributable runtime.
Python modules retain their historical `test/` location for now to avoid changing
validated supervision behavior during extraction. Python 3 remains a host runtime
dependency until explicitly bundled or replaced. System library/license audits,
read-only AppImage layout, trust/startup and AMD encoding remain outstanding.
The fresh config intentionally does not enable OpenVR compatibility: setup must
supply a valid installed implementation for OpenVR applications.

Validation: staged real Monado/bridge assets under `/tmp` and checked manifest
integrity. Automated relocation deletes the original source before validating
the installed copy; corruption and invalid helper caches are rejected before
session creation. The authenticated XR control suite passes (23 tests, one
optional C++ interoperability test ignored). This does not establish driver
compatibility, game launch or headset behavior for the new installed layout.

## Installation and configured startup checkpoint

`tools/meteor_xr_install.py` now installs verified package files into versioned
subdirectories under `~/.local/share/nightfall-meteor/xr` (respecting
`XDG_DATA_HOME`). Stable links select the active tools, Python modules, bridges
and Monado binaries. Configuration, session locks, requests and logs stay in the
shared `.build-cache/meteor-xr` state directory. The previous version is retained;
a failed link switch rolls back. Updates refuse an active managed-session lock.
No existing Steam options, headset keys or OpenVR compatibility paths are copied
or rewritten.

The AppImage build accepts `METEOR_XR_BUNDLE=/path/to/staged-bundle`. Only
manifest-listed files are exported into `usr/share/nightfall-meteor/xr-bundle`;
local configuration, keys and session files are excluded. Its existing size cap
and library/license requirements still apply. After packaging, the host command
is:

```sh
./Nightfall-Meteor.AppImage --install-xr-runtime
# Or explicitly install a separately staged bundle:
./nightfall-meteor --install-xr-runtime /path/to/staged-bundle
```

This installs files only. Until the setup UI is implemented, normal service
startup is opt-in through `~/.config/nightfall-meteor/meteor.toml`:

```toml
[xr]
enabled = true
listen = "0.0.0.0:47910"
# Optional legacy explicit authorization; otherwise approve in the tray.
# allowed_client = "AUTHORIZED_HEADSET_64_CHARACTER_PUBLIC_KEY"
# runtime_root is optional; defaults to the installed user-data path.
```

Invalid configured authorization, missing files or listener availability disable XR and
leave the desktop proxy available. The installed package gets a bounded file
integrity check before binding. The bound configured control port is advertised
as `xr` in discovery; legacy DEV listeners retain their existing behavior and
are not advertised. This advertises a control service, not verified GPU driver
or game readiness. The following checkpoint adds headset discovery consumption and local tray
approval; this installation checkpoint alone did not provide them. Firewall diagnostics also still need XR control/data coverage.

Tray VR Apps requests now use the active service's runtime location instead of
the build-time checkout path. Installed launchers preserve that stable location
when tools are selected through version links.

Validation: nine packaging/install tests pass, covering relocation, corruption,
state preservation across upgrades, active-session rejection and exclusion of
private/unlisted files during export. Real local Monado/bridge files were staged,
installed to a temporary user-data root, checked, and used to print stable Steam
launch options. Full optimized Rust suite: 135 passed, 18 optional tests ignored.
No running services or headset installation were changed. A fresh AppImage,
clean-system dynamic-library audit and real-game installed-runtime test remain
outstanding.

## Headset discovery and local approval checkpoint

Nightfall now consumes the XR control endpoint from Meteor's existing discovery
response, after the existing host-key trust check. It uses an in-memory host
configuration rather than writing the developer config file. The automatic
watcher uses that configuration while the matching Sunshine desktop is streaming;
legacy explicitly configured hosts remain supported. Switching away from a
watched host clears its idle watcher.

For configured normal XR startup, `xr.allowed_client` is now optional. Without
it, a headset must complete the encrypted Authenticate proof and obtain local
approval before it can reserve the control session, request an application launch
or open video/tracking transport. Meteor holds at most one pending request for
60 seconds. The tray shows Approve/Reject with an eight-character SHA-256 identity
fingerprint; Nightfall independently computes and displays the matching code in
its status area. The user must compare them before approving. Repeated automatic
connection attempts pick up approval without restarting either app.

Approvals persist in `~/.config/nightfall-meteor/xr-trusted-headsets.json` with
private file permissions on Linux (respecting `XDG_CONFIG_HOME`). Up to eight
headsets are retained. Existing explicit allowlisted keys and DEV configuration
continue to work. No approval is inferred merely from discovery, knowledge of a
public key or Sunshine pairing. Startup still requires `[xr] enabled = true` and
an installed runtime; this checkpoint does not enable XR on every Meteor install.
Removing saved approvals currently requires editing/removing the trust file and
restarting Meteor; a richer device-management UI remains future work.

The headset must currently have a desktop stream open for automatic discovery and
approval retries. Headset OS presentation and actual tray interaction still need
physical testing; native-extension loading is not covered by headless script
checks. The host file-integrity check does not prove GPU-driver readiness.

Validation: 138 optimized Rust tests passed, 18 optional tests ignored. A new
socket integration test verifies that a public-key-only request creates no
pending approval, a proven but unapproved key receives no session/relay, and local
approval enables a subsequent authenticated connection. Project parse and all
GDScript test scripts passed; Linux headless runs report the existing absence of
the Android-only native XR extension. No APK deployment or live-service restart
was performed.

## Fixed ports and baseline-compatible packaging checkpoint

Configured normal XR now uses TCP control/video/tracking ports 47910/47911/47912
by default. `[xr] video_port` and `tracking_port` can override the data ports.
They must be distinct, nonzero, separate from the bound control port, and not
overlap Meteor's existing TCP desktop services. Data listeners are opened only
for an accepted authenticated session. An occupied configured port fails instead
of choosing an unreported random port. Development fixtures retain ephemeral
ports; private runtime IPC remains loopback-only.

The normal service's actual control port and configured data ports are included
in the tray firewall check and its existing user-initiated Allow action. This
work does not change the machine's firewall automatically.

A static ELF audit found the original Ubuntu 24.04-built Monado service required
GLIBC_2.38 and an unbundled `libcjson.so.1`. That bundle cannot meet the Meteor
AppImage's advertised glibc 2.35 baseline. The optional-XR AppImage path now runs
`tools/audit_meteor_xr_runtime.py` and rejects such a bundle before copying it.
The audit does not execute ELF files or load graphics drivers. It reports glibc,
C++ symbol versions, architecture, library dependencies and non-relocatable
search paths. Its `static_audit_passed` field is not a gameplay or licensing
certification.

`tools/build_support/build_meteor_xr_bundle.sh` now builds the patched Monado
service/OpenXR library and validated bridges in an isolated Ubuntu 22.04 image.
It uses the existing pinned Monado/WiVRn revisions and checked-in hook patches;
no host package installation or global XR registration is performed. The new
package-only mode avoids building/importing Godot or a diagnostic XR application.
The default Ubuntu 24.04 development build remains unchanged.

The baseline bundle includes the baseline-built cJSON library in a private
`xr-runtime/lib` directory. The installed launcher adds that directory to the
owned processes' library search path. GPU drivers, Vulkan loader, libudev and
host C/C++ runtimes remain host dependencies. Python 3 is still required.
Upstream Monado license texts, cJSON's MIT notice, NVIDIA/ffnvcodec header
notices, and baseline Eigen/cJSON copyright metadata are retained and hashed.
A complete compiled-component attribution review remains required before release.

### Actual validation

- Baseline rebuild succeeded; maximum required glibc symbol version is 2.34,
  within the AppImage's 2.35 floor. Maximum reported GLIBCXX requirement is
  3.4.30; supported installations need a corresponding current C++ runtime.
- Static audit found no missing non-system dependencies or absolute build search
  paths after bundling cJSON.
- `tools/build_support/check_meteor_xr_bundle.sh` loaded the OpenXR library and
  both bridges in a read-only, network-disabled minimal Ubuntu 22.04 container.
  It deliberately has no compiler, Git, Godot or system cJSON package. Python
  parsing, manifest validation, service dependency resolution and selection of
  the private cJSON library passed. No GPU or game was started by that check.
- Full optimized Rust suite: 140 passed, 18 optional tests ignored. New tests
  cover the exact firewall set and fixed data-port binding/occupation behavior.
- Thirteen Python package/install/audit tests passed, including rejection of
  newer glibc builds, missing private dependencies, wrong architecture and
  developer search paths.
- Final local bundle with notices:
  `.build-cache/meteor-xr/portable-package/bundle-with-notices`.
  Static report: `.build-cache/meteor-xr/portable-package/runtime-audit-with-notices.json`.
  A fresh run of the build script includes the notices in its ordinary `bundle`.

The full Meteor AppImage has not been rebuilt with XR yet. Its size policy,
optional Vulkan VDA delivery, OpenVR compatibility installation, one-click XR
setup and driver readiness still need finishing. AMD XR encoding remains a
separate implementation task. The baseline-runtime container smoke test does
not replace a real installed-runtime NVIDIA/dual-GPU game and headset test.
No live service, headset installation or firewall rule was changed.

## Full XR AppImage and installed-runtime launch checkpoint

Built `meteor/target/appimage/Nightfall-Meteor-0.1.1-XR-DEV-x86_64.AppImage`:
60,541,432 bytes (60.5 MB), release-optimized, SHA-256
`f744a6e72d3db2af8d7f6c072e71c6281a963122f8f05374c9751734f98e99b1`.
The distinct preview filename preserves the existing local ordinary AppImage.
No release upload, version tag, user configuration or live service was changed.

The builder now supports Docker's user mapping separately from Podman's
`keep-id`. XR integrity/ELF compatibility is checked before the container build.
Vulkan VDA exports require explicit `METEOR_BUNDLE_VDA_VULKAN=1`: a developer's
installed optional models must not silently add ~430 MB to a default package.
The ordinary package keeps EdgePad-512/256 and the existing 100 MB size cap.
Installed user VDA models remain usable; a separate Vulkan model downloader is
still outstanding. This preview includes the baseline-built managed XR bundle
and component notices.

`test/check_meteor_xr_appimage.py` copies and runs the actual AppImage with
isolated XDG settings/data/cache/state, uses extract-and-run without FUSE, and
keeps its report and logs. It verifies:

- Current CLI, installation directly from the AppImage's bundled runtime,
  installed checksums and stable Steam wrapper paths.
- Both bundled EdgePad models and absence of local application/session state.
- Normal configured XR startup/discovery and cross-language encrypted
  authentication using fixed test-only identities.
- Desktop proxy forwarding, XR bind-failure isolation, XR-disabled startup,
  and clean signal shutdown. Runtime acceptance is intentionally not requested
  by these non-GPU control checks.

Process-level smoke tests now set their own log level and retain case logs when
requested. An initial shutdown-log assertion was hidden by the inherited
`RUST_LOG=warn`; the harness now explicitly sets `info`. No application change
was needed for that assertion.

The installed runtime extracted from that exact AppImage then launched the
native OpenXR hello_xr sample on the RTX 3090 using synthetic tracking and a local
transport receiver. Direct installed launch captured 63 frames. A second run
through the installed Steam-wrapper code captured 65. Both intentionally ended
after capture by signalling a synthetic client disconnect and verified owned
application cleanup. Both remained idle without encoding before launch. There
was no development helper compilation inside the installed launcher.

These rendering checks use development-built test publishers/receivers and an
external sample application. Those are test equipment, not shipped runtime
requirements. They are not evidence that Steam/Proton itself or a real game ran,
or that headset presentation, real input/audio, frame timing or a complete
normal-stream drain passed. Physical headset and actual game acceptance remain
outstanding.

Evidence:

- `.build-cache/meteor-xr/appimage-validation-20261026-r2/report.json`
- `.build-cache/meteor-xr/appimage-validation-20261026-r2/cases/*.log`
- `.build-cache/meteor-xr/external-smoke-de_0y4nc/` (direct installed launch)
- `.build-cache/meteor-xr/external-smoke-4qh9hbgb/` (installed Steam wrapper)

Repeat packaged checks after compiling the existing OpenSSL test client with
`--authenticate-only` support:

```sh
/usr/bin/python3 test/check_meteor_xr_appimage.py \
  meteor/target/appimage/Nightfall-Meteor-0.1.1-XR-DEV-x86_64.AppImage \
  /path/to/nightfall-xr-control-cpp-client --work-dir /new/isolated/output
/usr/bin/python3 test/smoke_xr_local_application.py "$PWD" \
  --installed-runtime /path/to/isolated/data/nightfall-meteor/xr
# Add --steam-wrapper to exercise that owned-launch path with the sample.
```

Next acceptance needs a release APK containing the discovery/approval changes,
then a headset/game test of the packaged host. One-click XR enable/install,
OpenVR compatibility setup, full attribution review, generic driver readiness,
Vulkan VDA delivery and AMD XR encoding remain future implementation work.

## Quest release-optimized APK checkpoint

Built `Nightfall-Android-arm64-v8a-dev.apk` through the documented
`build.sh --dev` path, including the release native-XR rebuild and patched Godot
runtime. DEV here means release-signed and optimized, with development features;
it is not a debug binary. Version name is
`0.8.2-preview.1-dev+c9421f1-dirty`, version code 802, package
`app.nightfall.quest`, arm64-v8a. The APK includes the new discovered-host and
approval client scripts plus the release streaming/XR and Meta vendor libraries.

Signature verification passed and the certificate matches the previous local
release APK, so signing permits an in-place update without deleting settings.
Archive/manifest inspection confirmed the release libraries and no debuggable
application flag. Compilation uses Android SDK 36; the existing target SDK 32
was retained. No version tag or public release was created.

APK size: 110,374,231 bytes. SHA-256: `57ab2fbc96f9a2056261191dee43b54810145ead79cc8ed9596a38adb1fc92b0`.

ADB reported no connected devices, so the APK has not been installed or
physically tested. Headset discovery/tray approval, actual Steam/Proton game
launch, XR handover, input/audio and suspend/reconnect acceptance remain pending.

## Local preview enabled for headset testing

Replaced the running Meteor 0.1.0 with the verified 0.1.1 XR preview AppImage.
It runs as the transient user service `nightfall-meteor-xr-preview.service`.
Installed the verified runtime into the user's default Meteor data directory,
enabled `[xr] enabled = true`, and retained the already installed xrizer path in
the local runtime application configuration. No global OpenXR setting, Steam
configuration or headset authorization was overwritten. The existing autostart
entry was updated by Meteor's normal startup behavior to the new AppImage.

Verified normal discovery advertises XR on TCP 47910, Sunshine is available,
firewall diagnostics report the configured ports open, and the saved Vulkan
EdgePad-672 choice loads on the RTX 3090. Model selection was preserved.

The existing Steam options still invoke the checkout launcher. That launcher now
forwards non-diagnostic commands to the verified installed wrapper when the local
Meteor configuration explicitly enables installed XR. Explicit `--session`
diagnostic commands retain their chosen source setup. Installed launchers do not
redirect again. No Steam restart or launch-option edits were needed. Validated
forwarding with the exact existing Python environment and tested three routing
cases plus the four existing Steam launcher tests. This migration aid is not a
replacement for configuring installed-wrapper paths on fresh Steam setups.

The installed APK was confirmed on the connected Quest 3 before enabling the
host. First desktop connection should request local matching-code approval;
real-game/headset acceptance is still pending.


## Independent xrizer and reconnect checkpoint (2026-10-26)

The preceding WiVRN dependency and pending deployment notes are superseded by
this checkpoint. The user confirmed that local approval launched VRChat correctly
with the packaged host. The game, Monado and NVIDIA encoder used the RTX 3090;
the OS desktop remained on the RX480.

### Owned OpenVR compatibility runtime

- Pin upstream Supreeeme/xrizer commit
  `a1216c7b53fb562a5bc4de473163e97a483042af` (0.6.0), matching the WiVRN reference.
- Build the untouched checkout independently on Ubuntu 22.04 with the pinned
  Meteor Rust toolchain, `monado,static-openxr`, release optimization and explicit
  version metadata. No WiVRN-installed binary is copied.
- Jammy supplies glslangValidator rather than glslc. A build-only wrapper passes
  xrizer's INPUT / -o OUTPUT shader commands through `glslangValidator -V`.
- Include vrclient.so, GPL license, dependency notices, Cargo.lock, source URL
  and upstream revision under `xr-runtime/xrizer`, all covered by manifest hashes.
  License generation copies the upstream root GPL notice into the three local
  workspace crates in a disposable metadata copy; compiled sources stay untouched.
- Fresh installs select our stable installed xrizer path. Upgrade migrates the
  known system WiVRN Flatpak path, with a configuration backup. Explicit custom
  compatibility choices are retained.
- Generate a private OpenVR registry in the writable runtime cache. Game launches
  use VR_OVERRIDE and VR_PATHREG_OVERRIDE, including Steam's session-local app
  specifications and read-only Pressure Vessel imports. No global OpenVR/OpenXR
  registry or Steam launch option is rewritten.
- Existing source-checkout Steam launch options still forward to the installed
  wrapper. The real user installation now selects our bundled xrizer.

Evidence: 28 Python runtime/install/launcher tests pass, plus the seven Steam
launcher/routing tests. Baseline ELF audit passes (minimum glibc 2.35). A minimal
Ubuntu 22.04 container loads Monado, bridges and xrizer without WiVRN or SteamVR.
Both OpenXR and OpenVR controller probes pass using our independently built
xrizer: `.build-cache/meteor-xr/monado-linux-spike/controller-host-mu8cvjef`.
Final AppImage checks (isolated installation, private registry, bundled notices,
discovery/authentication, proxy forwarding, disabled/bind-failure isolation and
shutdown) pass: `.build-cache/meteor-xr/appimage-validation-20261026-xrizer/report.json`.
These automated tests do not replace real Steam/Proton game acceptance.

Final Meteor AppImage: 65,075,704 bytes;
SHA-256 `099317ee114dc56bc544dcc30d8ecb703f991152920ceffe26035a0011288aa4`.
Installed the runtime and restarted `nightfall-meteor-xr-preview.service` with
that AppImage. Settings, model selection, identity and trust records retained.

### Desktop reconnect candidate fix

Exported diagnostics are retained at
`.build-cache/meteor-xr/reconnect-investigation/diagnostics.txt`.
After ending XR and manually disconnecting the desktop, reconnect at 22:20:23
completed Sunshine negotiation and initialized the native renderer. Video updates
then stayed at zero while the app and Meteor depth updates continued. A second
reconnect did the same; restarting Nightfall restored normal video updates.
This is a stalled client video pipeline, not a failed host negotiation.

Code review found a lifecycle race: decoder setup returned an existing GLES
window immediately from the decoder thread, even if previous connection cleanup
was still queued on the render thread. That could attach MediaCodec to a window
which queued cleanup subsequently abandons. Surface creation now always waits
for render-thread execution after previous cleanup and retires any remaining
surface before creating a fresh one. Creation/destruction addresses are logged.
This closes a concrete race; the exported log does not prove that race caused
the observed incident, so reconnect acceptance remains required.

Rebuilt the streaming extension with Release CMake/Ninja, stripped its release
library and built via `build.sh --dev` (release-signed/optimized, not debug).
Installed in place on Quest 3 `2G0YC1ZF8P08QN` and opened its launcher.
APK: 110,374,335 bytes;
SHA-256 `fcc50b192e9ae2decc250c88540238134c6c60e025d6abd11eeb193489476cfe`.

Next physical checks: desktop connect/disconnect/reconnect, brief headset removal
followed by reconnect, and launch/exit/relaunch VRChat using the owned xrizer.
Approval popup clarity, Steam setup instructions/UI, one-click runtime enable,
AMD XR encoding and Windows remain separate outstanding work.


## User acceptance and setup UI checkpoint (2026-10-26)

User confirmed: connect desktop, launch VRChat, move around, quit, disconnect,
reconnect and launch VRChat again all succeeded. This is acceptance of the
reconnect candidate fix and real Steam/Proton use of the independently bundled
xrizer. Further long-run standby testing remains useful.

Meteor's first tray item is now **Custom Steam Launch Options required: Copy**,
with the edit-copy icon. It copies the stable installed launcher command, using
`--app-id auto`; store games use SteamAppId and non-Steam shortcuts resolve the
32-bit shortcut ID from SteamGameId when SteamAppId is zero. Explicit app IDs
remain supported, and the VR library recognizes both command forms. Confirmation
explains Steam → game Properties → General → Launch Options. Copy uses KDE's
clipboard service, falling back to wl-copy/xclip. It was tested against the real
local clipboard and the resulting installed command was read back successfully.

Authenticated, unapproved headsets now cause one desktop approval notification
per pending request, with the matching code and Approve/Reject actions. The
notification subscribes before posting, filters the returned notification ID,
checks current trust state when approving and closes after tray approval,
rejection or expiration. The tray actions remain available when desktop
notifications are unavailable/disabled. Host notification capabilities include
actions and persistence. The watcher does not repeat a popup on each client retry.

Tests: 141 Rust release tests passed (18 hardware/manual tests ignored); the
separate real-clipboard integration test passed. Thirteen Python Steam launcher,
VR catalog and installed-routing tests passed. Final isolated AppImage checks
passed at `.build-cache/meteor-xr/appimage-validation-20261026-tray/report.json`.
New AppImage: 65,149,432 bytes; SHA-256
`e495381660457ac2e269e06c88b913abf2eee0ca72403c6412221a9b13742222`.

Installed the updated runtime and restarted the Meteor preview user service.
Backed up the real XR trust file, then removed only headset approval C041909F,
so the next connection can test the new popup. Sunshine pairing and other identity
files were not changed. Backup is alongside the trust file with the
`xr-trusted-headsets.before-popup-test-20261026-230532.json` name.
No APK rebuild was needed. User subsequently confirmed matching-code popup
approval, persistence after restarting Nightfall and Meteor, and successful game
launch/return using the copied universal Steam options. This setup flow is
accepted. The implementation is ready to commit.


## Remaining clean-install work after acceptance

1. Add an explicit tray action to install/enable the bundled XR runtime and save
   `[xr] enabled = true`; currently this still requires the install command and
   a configuration edit/restart. Expose readiness and actionable failures.
2. Check the full installation on a fresh user profile/machine with no development
   checkout, WiVRN or SteamVR. Automated isolated checks already cover installation
   and connection setup; physical acceptance so far used this development host.
3. Complete distribution attribution/source instructions and document required host
   Python, graphics drivers and clipboard-tool fallback on non-KDE desktops.
4. Deliver optional Vulkan VDA assets through the download/setup path; default
   packages currently include EdgePad only.
5. AMD XR encoding and Windows XR support remain separate larger implementation
   tasks. Current packaged XR encoding is NVIDIA-only; AMD depth inference is
   independent and already supported.

No further physical approval/copy/relaunch test is outstanding for this batch.
Longer suspend/resume and gameplay coverage can continue during normal use.


## One-click PCVR setup checkpoint (2026-10-26)

Implemented **Enable PCVR — install & restart Meteor** in the tray, below the
Steam launch-options copy action. It installs the bundled verified runtime into
its configured user-data location, enables `[xr] enabled = true`, then drains XR
and restarts Meteor. Existing comments, settings, custom absolute runtime paths
and approvals are retained. The original settings file gets a backup; changes
made by another editor during installation cause setup to stop rather than
silently overwrite them. Duplicate setup clicks are blocked while work runs.

The tray displays setup progress, **PCVR ready (Linux / NVIDIA)**, or a failure
summary with Retry. Detailed errors are logged and shown in a desktop
notification. Missing-bundle builds direct users to the XR-enabled AppImage.
An existing configured XR startup failure now produces a notification as well
as a tray error. Installing while an XR runtime is active remains refused by
the existing installer lock. Setup/restart briefly interrupts desktop streams.

A matching `--enable-xr` command performs install/enable and exits for headless
setup and packaged testing. The older install-only command remains supported.
Settings are modified with toml_edit to retain comments instead of reserializing
the whole user file. Restart re-executes the original AppImage (or standalone
binary), retaining launch arguments; it avoids GPU library exit handlers and
retains the process chain used by the preview's user service.

Validation: 143 Rust release tests pass; 19 hardware/manual integration tests
are ignored. Packaged installation tests now verify enable/configuration backup.
An isolated tray test starts with XR disabled and no runtime in its selected
location, activates that child's actual D-Bus Enable item, verifies a fresh
installation, saved setting, process restart, PCVR-ready menu, restored desktop
forwarding and XR discovery, then quits via that child's tray. It does not send
menu events to the real user's Meteor instance. All final packaged checks pass:
`.build-cache/meteor-xr/appimage-validation-20261026-setup-r3/report.json`.
This covers the packaged standalone executable's restart; physical fresh-machine
setup and the AppImage re-exec path remain useful user acceptance checks.

New optimized AppImage: 65,235,448 bytes, SHA-256
`886109cec7861b6cd7e6e243448adc0da4935e94fa49249559a23217fa6b38c1`.
Restarted the real preview host with this artifact after confirming no active XR
session. Existing installed runtime and headset approval were retained; no APK
rebuild was needed. The existing setup should show PCVR ready immediately.

The one-click installation/enabling task in the prior outstanding list is now
implemented. Remaining work: physical clean-machine acceptance, distribution
attribution/source/dependency documentation, optional Vulkan VDA delivery, AMD XR
encoding and Windows support. The one-click setup implementation was subsequently committed as `1d54a32`.


## Release packaging and Vulkan VDA downloads (2026-10-27)

Both requested tasks are implemented. The existing `meteor-vda-s-518x294` model
release now has Vulkan/ncnn Small exports for 518×294 and 392×224, with separate
manifest/license assets, a README and SHA-256 list. Existing TensorRT assets were
retained. All twelve model asset sizes and GitHub digests match the compiled
catalog in `meteor/models/vda-vulkan-downloads.json`.

Meteor offers missing Vulkan variants under GPU / model when a supported Vulkan
GPU/runtime is available. Downloads require no TensorRT/CUDA package and keep
the current model/GPU selected. Shared progress/cancel controls work for both
VDA download paths. A per-model process lock prevents overlapping installations;
partial files are resumed, checked against pinned hashes and installed from an
invisible staging directory only after the complete model verifies. Existing
corrupt model directories are preserved with an actionable error. The CLI also
supports `--download-vda-vulkan 518|392`.

Release packaging now includes complete libgomp distribution copyright/runtime
exception text, GPL text, exact baseline package versions, extended Monado source
attributions, source input hashes and RELEASE.md, available through the tray.
The source companion includes 569 recorded Nightfall source inputs, the actual
patched Monado source, pinned xrizer source, vendored Rust dependencies for both,
Eigen headers, NV codec headers and the exact FFmpeg source archive. Its separate
`.cargo/vendor-config.toml` files preserve original Cargo settings and allow
offline resolution. Signing files, user state and compiler outputs are excluded.

Evidence:
- 147 Rust release tests passed; 19 hardware/manual tests ignored.
- 15 Python packaging/source-selection tests passed.
- Both variants downloaded from public GitHub URLs into isolated model folders;
  all twelve installed files verified, a partial transfer was seeded/resumed,
  and no TensorRT runtime was downloaded.
- Full packaged-host checks passed, including fresh one-click setup/restart,
  pairing/authentication, proxy forwarding, disabled/bind-failure isolation and
  shutdown: `.build-cache/meteor-release-packaging/release-ready-validation`.
- Source archive hashes match its 569 inputs and the AppImage's source manifest;
  both Meteor and xrizer Cargo dependencies resolve offline from extracted source.
  Source validation: `.build-cache/meteor-release-packaging/source-validation-ready`.

Artifacts in `meteor/target/appimage`:
- Nightfall-Meteor-0.1.1-XR-DEV-x86_64.AppImage: 65,333,752 bytes;
  SHA-256 d97f9611af9f848acfa77be74913146cc28d6c092c7f4b9ed753588e11e4652c.
- Nightfall-Meteor-0.1.1-XR-DEV-sources.tar.gz: 136,490,281 bytes;
  SHA-256 d609f46c2faae72364054f1197ac6a927a10024e24c377458adcdd393b8f98ae.
- A matching SHA256SUMS text file and AppImage zsync file are prepared.

The real Meteor preview was updated and is running with PCVR ready, preserving
settings, models and approvals. A final source-record-only repack did not alter
its executable code. Both models already exist on this development PC, so their
download offers are naturally hidden here; public-download acceptance used fresh
isolated directories. No new application release or APK was published. Model
assets are public; application/source artifacts are ready locally for release.

One-click setup is committed as `1d54a32`; release packaging and Vulkan model
downloads are committed with this checkpoint. Outstanding larger work is physical
fresh-machine acceptance, AMD XR encoding and Windows.
Vulkan model inference speed/quality is unchanged: the uploaded files match the
previously tested local exports, and this work adds distribution/installation.
