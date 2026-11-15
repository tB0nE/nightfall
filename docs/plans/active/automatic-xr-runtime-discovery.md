# Automatic XR runtime discovery

Started 2026-11-13. Goal: connect Nightfall to Meteor, launch an XR application
normally, enter PCVR automatically, and return to the desktop afterward without
Meteor-specific per-game Steam options. Existing game-specific mods/options stay.

## Baseline and constraints

Linux currently uses `tools/meteor_xr.py steam-run` to publish launch intent,
wait for headset preparation, and pass Steam's exact command to a session-owned
runtime. The runtime overrides XDG_RUNTIME_DIR and publishes a private manifest.
Registering that manifest globally alone cannot work: ordinary games look for
the IPC socket in their normal runtime directory and do not publish launch intent.
Keep this working wrapper throughout the migration.

Windows already has a registered SteamVR driver, authenticated activation broker,
and externally owned game/session support. See
[SteamVR integration](meteor-steamvr-driver-integration.md). Do not build another
Windows driver. Automatic installer registration remains gated on acceptance.

Uncommitted virtual-monitor improvements in this checkout are a separate task;
preserve them and keep their testing/release claims separate.

## Implementation sequence

1. Reversible Linux registration foundation. Generate stable installed manifest
   and xrizer registry candidates; acquire an exclusive lease, preserve regular
   files and symlinks exactly, and restore only entries still owned by Meteor.
   Exercise missing configuration, existing WiVRn/SteamVR, repeat acquire,
   competing edits, partial failure and interrupted-operation recovery in temp
   directories. No real user registration until runtime readiness is implemented.
2. Stable IPC and activation. Use a Meteor-specific socket under the real user
   XDG_RUNTIME_DIR, shared by client and server. The current build uses
   `monado_comp_ipc` and has systemd socket activation disabled; do not assume
   LISTEN_FDS already works. Choose explicit inherited listener support or enable
   and package the verified Monado activation path. Preserve SCM_RIGHTS/shared
   memory semantics; a byte-stream proxy is insufficient. Readable socket events
   trigger a bounded authenticated headset handoff, then pass the listening FD
   into the prepared runtime. No idle rendering or permanent polling GPU load.
3. Independent-application lifecycle. Add runtime activation notices alongside
   existing launch intents; no remote argv or executable selection. Session
   state/IPC clients govern teardown. Never terminate a game Meteor did not start.
   Reuse existing transport, tracking, audio, settings and return-to-desktop logic.
4. Integrate opt-in registration while a paired headset is available. Recover
   stale leases on startup, respect changes made by other VR tools, restore on
   shutdown, and handle multiple Meteor instances. Installed paths must survive
   AppImage unmount/update. No global XDG_RUNTIME_DIR override for Steam.
5. Steam integration. Native Steam's pressure-vessel sandbox still requires
   OpenXR import. Prefer one-time Steam-level environment setup with a clear
   restart requirement, not blanket rewriting of game options. Handle Flatpak
   Steam separately with minimum filesystem permissions. Preserve explicit flat
   launch, game mods, and manual wrapper fallback.
6. Windows acceptance/package integration. Validate existing registered driver
   with ordinary Steam launches, two successive sessions, another HMD present,
   disconnect/reconnect and installer/uninstaller ownership. Implement opt-in
   installer registration after these pass. Native OpenXR selection is separate
   from OpenVR driver registration. Linux tests cannot establish Windows success.

## Acceptance

- Temp-directory registration and socket activation tests, bounded timeout,
  duplicate request, disconnect-before-ready, crash recovery and foreign edits.
- Native hello_xr with no XR_RUNTIME_JSON, custom XDG_RUNTIME_DIR or wrapper.
- One Proton/OpenVR game without Meteor options; launch twice, wristwatch,
  desktop return, headset standby and disconnect/reconnect.
- Verify SteamVR/WiVRn registration restores, including pre-existing symlinks.
- Record idle CPU/GPU use and startup latency, not just successful rendering.
- Build relocated AppImage with runtime/xrizer; then clean-account acceptance.
- Windows and Flatpak acceptance explicitly tracked independently.

## Research

- [WiVRn runtime registration](https://github.com/WiVRn/WiVRn/blob/master/server/active_runtime.cpp)
- [WiVRn Steam sandbox notes](https://github.com/WiVRn/WiVRn/blob/master/docs/steamvr.md)
- [WiVRn server/activation](https://github.com/WiVRn/WiVRn/blob/master/server/main.cpp)

## Progress

- Source investigation complete; pinned Monado's systemd activation is disabled.
- Implemented isolated single-entry registration leases in
  `test/xr_runtime_registration.py`, not yet connected to live configuration.
  Eight regression tests cover restoration, foreign edits, repeat acquisition,
  missing targets, partial failure and interrupted installation. Caller-level
  locking, grouped OpenXR/OpenVR transactions and activation integration remain.
- Live default runtime and Steam configuration remain unchanged. No new APK is
  needed for this foundation; there is no wrapper-free game test ready yet.

### Socket activation checkpoint

- Added `test/xr_socket_activation.py`: private Unix listener, exclusive owner
  lock, bounded/cancellable preparation, one activation at a time, explicit FD
  inheritance, and bounded cleanup of only its own runtime child. It never
  accepts or proxies application traffic.
- Added `test/meteor_xr_listen_fd.h` and `test/monado_socket_activation.patch`.
  The normal Monado build applies the patch; without METEOR_XR_LISTEN_FD it
  retains its existing path. With the variable present it validates and adopts
  a listening Unix stream socket, marks it externally owned, and does not unlink
  the broker endpoint on runtime shutdown. No systemd dependency is introduced.
- Eight activation tests cover real native FD handoff (including SCM_RIGHTS),
  repeat sessions, timeouts/cancellation, competing activation and listener
  ownership. Combined with existing lifecycle/launch tests: **36 tests pass**.
  Existing launch fixture subprocesses now use isolated XDG config/data paths
  instead of accidentally redirecting to the developer's installed runtime.
- Patched Monado compiled in a separate offline-container build cache. Two
  real OpenXR probe sessions passed on software Vulkan, discovered through an
  isolated default-runtime registration without XR_RUNTIME_JSON. Each probe
  verified rendered eye pixels. The service used a different XDG runtime dir
  from the app, demonstrating inherited-listener adoption. Registration was
  removed afterward. No host GPU devices, headset or Steam were used.
- Evidence: `.build-cache/meteor-xr/socket-activation-spike/socket-activation-summary.json`;
  build log `/tmp/nightfall-socket-activation-build.log`; real-probe log
  `/tmp/nightfall-socket-discovery-check.log`; regressions log
  `/tmp/nightfall-xr-activation-regressions.log`.

Next: integrate activation notices with Meteor's authenticated headset watcher,
then pass the listener through the Rust supervisor/Python runtime helper and
observe independently launched clients. Add a namespaced installed client socket
and grouped registration/locking/recovery before enabling real-user registration.
The current isolated broker is **not** yet connected to the running Meteor.
Existing launch wrappers and actual Steam configuration remain unchanged.

### Authenticated activation / external-runtime checkpoint

Implemented Linux `meteor/src/xr_activation.rs` with an opt-in
`--xr-auto-runtime` flag. It binds a private, locked listener at
`$XDG_RUNTIME_DIR/nightfall-meteor/monado_comp_ipc`. A queued local connection
creates a random, expiring notice through the existing authenticated pending /
claim protocol. Claims are single-use and canceled if the control connection
ends before the runtime consumes them. The notice uses the same connection-only
SteamVR placeholder ID (250820) as Windows; it never selects a game to launch.
The normal wrapper notices are retained when this feature is off.

The Rust session supervisor takes the claimed listener, inherits only that FD
into its runtime helper, and selects external-runtime mode rather than freezing
or launching application.json. Python passes the listener to Monado and waits
for an unconditional adoption marker, independent of log verbosity. The new
`test/xr_external_runtime.py` observes generation/sequence-checked session events.
It waits for all sessions to be destroyed, not merely xrEndSession (which may
happen during standby), and never starts, signals or kills the external game.
Disconnect stops the owned runtime/helper only. Initial session startup remains
bounded. No per-game wrapper process ownership is required for this mode.

Validation:

- Full Rust suite: **202 passed, 19 ignored** (including two new activation tests).
- Python activation/lifecycle/launch regressions: **42 passed**.
- Runtime package/audit tests pass; Monado patch applies with zero fuzz to pinned
  upstream source and compiles in the separate offline build image.
- Two real software-Vulkan OpenXR runs now include the inherited-FD Python
  supervisor and external-session observer. Both verified rendered eye pixels,
  detected session destruction and cleaned up the owned runtime and isolated
  registration. No hardware GPU, live service or headset was used.

Important remaining integration: the installed OpenXR client still uses the old
`monado_comp_ipc` filename relative to its XDG runtime directory. The new listener
is namespaced to avoid colliding with WiVRn/Monado. **Do not enable global runtime
registration yet:** the installed client must be built for the matching socket
namespace, and grouped ownership-aware registration/recovery plus Steam sandbox
integration must land first. The flag is a DEV hook, not end-user setup.
Current installed APK/Meteor and Steam launch options have not been replaced.

### Namespaced, relocated runtime and registration checkpoint

New Linux builds compile both Monado client and service with
`XRT_IPC_MSG_SOCK_FILENAME=nightfall-meteor/monado_comp_ipc`. The successful build
stamps its socket ABI; installed package manifests carry `ipc_socket`.
`test/xr_runtime_paths.py` centralizes lookup and rejects unknown/traversing paths.
Legacy installed bundles without this metadata retain their original socket, so
existing wrapper sessions and diagnostics continue to work. Private diagnostic
runtime directories now create the namespace parent before normal service startup.

`RegistrationGroup` acquires a private owner lock and journals the generic and
x86-64 OpenXR selectors plus the OpenVR registry as one recoverable group. It
preserves existing files/symlinks and unrelated OpenVR driver keys. A later
selection or in-place edit is retained, including its candidate target and backup;
conflicting recovery blocks registration instead of overwriting it. Partial
failure rolls back prior entries. A process-crash test proves recovery after
os._exit, and the helper restores selections on owner-pipe EOF.

`tools/meteor_xr_register.py` validates the installed bundle and namespace, pins
the immutable installed library/xrizer paths, and holds that group until its
owning pipe closes. The Rust authenticated control connection now owns a shared
registration lease when the DEV activation flag is enabled. The active runtime
also retains that lease, preventing watcher transitions from restoring runtime
selection mid-game. There is no registration when Meteor merely starts idle.
The runtime installer rejects upgrades while a registration lease pins its files.
The helper uses no GPU and blocks on stdin while idle.

Packaged OpenXR clients now have a relocatable $ORIGIN search path to their
private cJSON dependency; ordinary games do not inherit the wrapper's library
path. Packaging checksums are computed after this ELF change.

Validation on 2026-11-13:

- Full Rust suite: **203 passed, 19 ignored**; includes registration-helper
  last-owner/EOF cleanup and malformed-reply rejection.
- Combined Python registration, activation, lifecycle, legacy wrapper, packaging
  and audit suite: **68 passed**.
- New baseline runtime bundle built at
  `.build-cache/meteor-xr/automatic-runtime-package/bundle`. glibc 2.35 ELF audit
  passes with no missing private dependencies and relocatable search paths.
- `test/check_xr_installed_discovery.py` installs that exact bundle into a separate
  container-only user-data directory. Two software-Vulkan OpenXR sessions found
  its temporary default registration, verified rendered pixels and observed
  session destruction. No XR_RUNTIME_JSON or LD_LIBRARY_PATH was supplied.
  Unrelated OpenVR driver keys and both original selectors restored exactly.
- Evidence: `/tmp/nightfall-automatic-runtime-package.log`,
  `/tmp/nightfall-installed-xr-discovery.log`,
  `/tmp/nightfall-xr-discovery-final-python.log`,
  `/tmp/nightfall-xr-registration-rust-all.log`, and
  `.build-cache/meteor-xr/socket-activation-spike/installed-discovery-summary.json`.

The installed discovery check exercises the packaged runtime supervisor; it does
not exercise NVENC/VA-API encoding, a headset, Steam/Proton or Windows. No running
Meteor, installed user runtime, APK or actual Steam settings have been replaced.

Next is Steam-level sandbox setup, followed by a real game without the Meteor
wrapper. Explicitly expose the Meteor IPC directory and runtime/xrizer paths in
addition to OpenXR import; do not assume pressure-vessel's built-in handling of
other runtime sockets covers our new namespace. Keep per-game mods/flat-launch
flags intact. Flatpak permissions and Windows acceptance remain separate work.

### One-time native Steam setup checkpoint

- `tools/meteor_steam_environment.py` installs recoverable per-user Steam menu
  and existing autostart overrides. It wraps the user's existing command rather
  than replacing distro wrappers, keeps all desktop actions and URI field codes,
  and never edits per-game VDF/options. No autostart is added when absent.
- The standalone launcher merges OpenXR import, read-only XR installation access
  and read/write Meteor IPC-directory access at Steam startup. Existing unrelated
  filesystem entries and explicit game/runtime choices are preserved. It falls
  back to the original command if the runtime has been removed. Removal restores
  owned entries; foreign edits retain their backup/helper. Partial installs roll
  back and retry using a setup-phase record.
- An opt-in `xr.automatic_launch` setting and **Automatic XR** Setup row control
  the feature. Enabling/disabling restarts Meteor but does not close Steam.
  Restart-required status reads only selected XR environment fields from the
  same user's Steam process. Install All avoids re-adding wrappers once automatic
  setup is configured. Existing per-game controls remain the fallback.
- The VR library recognizes configured automatic mode only after Steam's current
  environment is ready (or Steam is closed). Catalog startup supplies the
  environment when Steam is not already running.
- Native Steam's installed SteamLinuxRuntime_4 pressure-vessel passed the real
  non-rendering visibility check: the custom socket, runtime/cJSON/xrizer files,
  and imported manifest are visible. Current pressure-vessel publishes translated
  selectors through its XDG_CONFIG_DIRS overrides, not necessarily XR_RUNTIME_JSON
  or /etc/xdg. The check validates the fixture installation in that manifest.
- GIO launched a fixture through the generated desktop entry, validating both
  key-file escaping and Exec field expansion for percent signs, spaces, quotes,
  dollar signs, backticks and Steam URI arguments.
- Evidence: `build/verify/steam-xr-environment/summary.json`,
  `/tmp/nightfall-steam-automatic-python.log`, `/tmp/nightfall-steam-automatic-rust.log`.
  A new bundle including the Steam helper is at
  `.build-cache/meteor-xr/automatic-steam-package/bundle`.
- [User setup/test instructions](../../guides/automatic-xr-launch.md) are recorded.
  Actual user launchers, Steam options, runtime selection and installed services
  have not been changed by the isolated tests. Next: optimized AppImage, then a
  real headset/Proton game without the Meteor wrapper; Windows/Flatpak separately.

### Ready for live acceptance

Final checks: **205 Rust passed (19 ignored), 106 Python passed**, and native
Steam sandbox visibility passed using the final runtime bundle. The final
optimized AppImage is
`meteor/target/appimage/Nightfall-Meteor-0.9.1-preview.1-auto-xr-dev-x86_64.AppImage`
(69 MB; SHA-256
`e6c1ec03e8b298a21d2e81d8c1e49b5e74b351a33fbf664eef81da252c9c8bf1`).
It includes a Python 3.10 compatibility path for the ordinary [xr] boolean table
written by Setup, without introducing a host Python package dependency.

The idle development Meteor was replaced with that optimized build (PID 65593),
preserving its arguments/environment, host selection and pairing data. Its
installed XR runtime was updated to the final verified bundle. Automatic mode
remains disabled until explicitly enabled in Setup; actual user Steam launcher
and per-game configuration files have not been changed. The existing release-
optimized Quest APK is sufficient; no Android protocol change was needed.

Live instructions: Meteor Setup -> Enable automatic XR, exit/reopen Steam via
its desktop launcher, remove only the Meteor wrapper from one game's options,
connect the headset desktop stream, launch/quit/relaunch that game. Keep required
game-specific variables, mods and flags. Follow
[the test guide](../../guides/automatic-xr-launch.md). Full headset/Proton acceptance
and Windows/Flatpak support are not established by the automated checks.

### Setup method choice

User requested the original method stay the default until more testing. Setup
now has one Steam XR method selector: **Steam launch options (Default)** or
**Automatic XR (Experimental)**, with only the chosen method's controls shown.
Selection is a draft until its action is clicked. Existing explicit experimental
configuration is remembered; fresh installs/Install All retain the original
method. Applying the default method from experimental mode first restores the
owned launcher overrides/disables automatic selection, then runs the existing
launch-options update. A running-game preflight prevents switching it underneath
a game. The experimental method retains existing game options for controlled
comparison testing. No active method was changed merely by editing this UI.

Method-choice validation: **206 Rust tests passed (19 ignored)**. The optimized
AppImage was rebuilt and development Meteor reloaded (PID 169903). Its host
readiness check passed on port 49900, and the original method remains selected.
No Steam launcher/options changes were applied while updating the UI.
