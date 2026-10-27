# Meteor XR local launcher (Linux DEV)

This is an experimental companion to `feat/meteor-xr-streaming`, not a packaged
game launcher. It does not install xrizer, change Steam launch options, rewrite
OpenXR/OpenVR registrations or start a second streaming server.

## Launch the configured application

For the configured Steam application, the current DEV build also supports
automatic startup: connect the Sunshine desktop stream to the trusted XR host,
then launch the game in VR mode through its existing Steam wrapper. Do not
manually prepare or accept XR first. The wrapper publishes a private bounded
launch intent; Nightfall watches, prepares and accepts it automatically. Desktop
mode flags (`--no-vr`, `--novr`, `-novr`) bypass that path. The dedicated DEV XR
listener must still be running; this is not yet normal-host packaged discovery.
The manual workflow below remains available for diagnostics and native apps.

From the checkout, using an available Python 3 interpreter:

```sh
python3 tools/meteor_xr.py status
python3 tools/meteor_xr.py launch --wait 120
```

The latter may be run before putting on the headset. Connect/accept XR from
Nightfall's DEV settings entry. The launcher discovers the sole live armed
session, requests its selected application and exits. The desktop remains visible
until runtime session activity and a decoded stereo frame trigger handover.
The current host arm window is 30 seconds; `--wait` waits for a session to appear,
not an extension to that window. Existing total DEV session bounds still apply.

An explicit `--session /absolute/session/directory` is also available. Expired,
dead-owner and already-requested tickets are not discoverable. Multiple live
sessions are rejected rather than silently selecting one. The launch request
for the configured native app contains a session generation and action only.
Explicit Steam mode additionally accepts Steam's command from the local wrapper,
bound to the configured app ID; the remote headset protocol cannot supply commands.

## Host application configuration

The ignored local `.build-cache/meteor-xr/application.json` selects a direct
foreground application owned by the existing runtime supervisor:

```json
{
  "argv": ["/absolute/path/to/native-openxr-application", "argument"],
  "cwd": "/absolute/working/directory",
  "launch": "manual"
}
```

Missing `launch` means immediate launch, preserving earlier tests. Configure only
trusted applications. Arguments are passed as an array, without shell expansion.
Do not select an already-running Steam client: it may forward the request to an
existing process that does not inherit the managed runtime environment.

## OpenVR compatibility preparation

WiVRn's reference `docs/steamvr.md` uses xrizer or OpenComposite to translate
OpenVR into OpenXR. We prepare the same child-scoped mechanism:

```sh
python3 tools/meteor_xr.py compat-check /absolute/path/to/xrizer
```

The directory must contain `bin/linux64/vrclient.so`. This check verifies file
layout and the ELF header's x86-64 identity, not dependency loading or functional
compatibility. No library is executed by this command.

Optional application configuration fields:

```json
{
  "argv": ["/absolute/path/to/foreground/application"],
  "cwd": "/absolute/working/directory",
  "launch": "manual",
  "openvr_compat": "/absolute/path/to/xrizer",
  "steam_runtime": true
}
```

These set `VR_OVERRIDE` only for the owned application child. Steam-runtime mode
sets `PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1`. `/usr/...` compatibility paths
are translated to `/run/host/usr/...` for pressure-vessel, following WiVRn's
mapping; other selected tool directories are added to the child-only read-only
filesystem import list. It preserves the managed `XR_RUNTIME_JSON` and IPC scope.
Native OpenXR Steam applications may select `steam_runtime` without an OpenVR tool.

An xrizer library was found inside the local WiVRn Flatpak installation and
passed the file-layout/ELF check. It has **not** been selected for the current
sample, copied, installed or proven loadable outside its Flatpak environment.

## Per-game Steam command wrapper

```sh
python3 tools/meteor_xr.py steam-options --app-id 438100
```

This prints per-game launch options ending in `%command%`. It does not write
Steam's settings. Preserve existing launch options and combine/review them before
changing anything. The wrapper receives Steam's actual foreground launch chain,
publishes a local request, waits for its owned application's result, and returns
its exit code to Steam. It does not start an already-running Steam client.

Select a local host profile with `"launch":"steam"` and matching
`"steam_app_id":"438100"` before arming. `argv` remains required but is not used
in Steam mode; `[/usr/bin/false]` is a safe placeholder. The ordinary `launch`
command is rejected for that profile rather than executing the placeholder.
`steam_runtime` is implied by Steam launch mode. The wrapper waits up to 120
seconds for arming; the host's armed window is still 30 seconds.

Only an allowlist of Steam/Proton environment variables is forwarded. It cannot
replace the supervisor's XR runtime, IPC directory or OpenVR compatibility tool,
and does not forward arbitrary environment secrets. Arguments are arrays, not
shell strings. The supervisor owns/reaps the child. If the wrapper disappears
(for example Steam stops it), its owned child is terminated rather than orphaned.
Game output stays in session diagnostics; no argv/environment dump is printed.

The wrapper/owned-runner/GPU path passed with HelloXR and synthetic tracking,
including intentional interruption and exit propagation. That test did not run
Steam, Proton or VRChat and does not establish sandbox or game compatibility.

Local preflight found VRChat installed on the games drive, Proton 11.0 installed
and requiring Steam Runtime 4. That runtime's libc exports GLIBC_2.41; the current
Monado client requires up to GLIBC_2.38. This makes that installed combination a
candidate, not proof that runtime imports, all dependencies or anti-cheat work.
An older Steam runtime may not satisfy the client library's glibc requirement.

Local setup now selects `.build-cache/meteor-xr/application-vrchat.json` through
`application.json`. With Steam confirmed closed, VRChat's per-game launch options
were updated to wrap `%command%`, preserving its existing environment/video flags
and GE-Proton10-26-rtsp20 selection. No global runtime or other game was changed.
Backups are `.build-cache/meteor-xr/application-helloxr-before-vrchat.json` and
`.build-cache/meteor-xr/steam-localconfig-before-vrchat.vdf` (local/private; do not
commit or publish the Steam configuration). The game has not yet been tested.
The selected GE tool requires Steam runtime 1628350; compatibility with the
current Monado client remains unverified, unlike the newer runtime preflight above.

## Still outstanding for Steam / VRChat

- Restart Steam and perform the coordinated VRChat physical test; keep the
  backed-up native sample profile as rollback.
- Validate runtime manifest, shared libraries and IPC visibility inside that
  launch chain; an environment variable alone is not proof of compatibility.
- Check xrizer dependencies and loading, graphics bindings, input mappings,
  audio and application lifecycle with the real game.
- Test with VRChat; neither this helper nor the native HelloXR test establishes
  VRChat compatibility. It remains a target, following WiVRn's working approach.

No global user configuration should be modified automatically to bypass those
checks. Windows and general automatic application discovery remain separate work.

## Optional live loading diagnostics

The local marker `.build-cache/meteor-xr/process-diagnostics.enabled` enables
external-app diagnostics for new managed sessions. Remove it to disable; this
is not a shipped user setting or a remote control command. No APK change is
required. The supervisor records `process-waits.jsonl` every three seconds,
restricted to its owned application descendants and runtime. It pins process
start times to avoid following a reused PID. Captures are bounded to 64 processes
and 512 threads each; truncation/access failures are explicit. Output is private
(0600) inside the session directory.

Samples contain names, IDs, CPU counters and `/proc` kernel wait channels only:
no debugger attach, process suspension, memory read, environment, arguments or
account data. Names/wait channels help identify which thread is blocked, not a
complete userspace stack trace or proof of a particular game deadlock.
The marker also enables `METEOR_SWAPCHAIN_WAIT` begin/wakeup records in
`service.log`, with runtime thread IDs and image reservation counts so a blocked
image acquisition can be correlated with those samples. Existing timeouts and
the user's Proton selection are not changed. Treat logs as private diagnostics
and review before publishing.

## Current floor origin and long DEV session

The updated Quest client uses floor-relative OpenXR STAGE for head, grip/aim,
wristwatch and returned projection. The host adopts that same origin. No guessed
standing height is added; STAGE creation failure is explicit instead of falling
back to eye-level LOCAL. Configure the headset floor/boundary normally. Historical
`quest_local` wire names now refer to the adopted client origin; use the rebuilt
matching client/host and start a fresh session.

With `long_run=true`, the client limit is five minutes from standby entry,
including startup. Host supervision is bounded to 315s; accepted control lease
and Steam result wait to 360s for cleanup headroom. Wire hard limit: 32,768 frames
(above five minutes at 60Hz). Short profiles and 30s arming are unchanged. Holding
B/Y for one second remains the DEV exit shortcut; short game button presses are
forwarded. Use the wristwatch to show/hide Nightfall's desktop in XR.
