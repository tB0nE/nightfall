# Windows SteamVR integration and XR processing review

Reviewed 2026-11-05. Scope: SteamVR driver integration and XR frame processing.
Input: `vd_v_n_technical_comparison.md`, current Meteor source, installed Virtual
Desktop driver manifest and binary strings, and Valve's driver documentation.
This is an assessment and proposed implementation sequence; no runtime changes
or headset tests were performed for this review.

## Implementation checkpoint

The first implementation stage removes the 32768-frame diagnostic cap from
both native and Quest validators and the sender. Regression tests cross the
former boundary, retain replay rejection, and finish with an acknowledged END.
Sequence exhaustion at `u64::MAX` remains an overflow guard.

Meteor now exposes a named pipe scoped to the current Windows user SID. Its
protected DACL allows that user only and rejects remote clients. The driver
also checks the pipe server's user identity. A prepared XR session publishes a
bounded allowlist of settings; this channel accepts no commands, game paths or
arbitrary environment keys. Existing managed sessions use it when the broker
is available. Explicit diagnostic launches retain environment configuration.

The provider can load idle, poll for a prepared session, and avoid adding its
HMD when another connected HMD is present. The registered route now also supports repeated connections with the same
display profile. Private session process ownership and Steam wrappers remain
available for existing installations and the Monado/xrizer route.

`meteor/tools/windows-release/SteamVR-Driver.ps1` provides Status, Register,
Unregister and Preview operations through Valve's installed tool. It avoids
duplicate registration, refuses a competing Meteor installation, and removes
only its own driver path. It is staged in release packages, and the uninstaller
cleans up a registration made through it. **Setup does not register the driver
automatically yet.** Normal Steam launch and reconnect checks must pass first.
No actual system registration was changed during this stage.

Direct capture reports windowed mean/peak durations for synchronization,
encoding, packet handoff and the full Present callback. Its dropped-frame
report retains the cumulative synchronization timeout count. Encoding remains
synchronous; measurements precede the GPU ownership/pipeline change.

`test/check_windows_steamvr_integration.ps1` writes
`meteor/target/windows-steamvr-integration/summary.json`. It builds Release,
checks geometry and parsing, runs Windows Rust tests, exercises a native C++
client against the Rust pipe, and previews registration in an isolated fixture.
It does not start SteamVR or use the headset.

Validation on this Windows host: the full WSL unit checker passed (167 Rust
tests and the GDScript suite). The Windows checker passed 157 Rust tests,
geometry and bootstrap checks, native/Rust pipe interoperability and
registration previews. `-Capture` additionally passed a local SteamVR probe
using synthetic tracking, validated encoded frames, and bounded owned-process
cleanup. The vrserver log confirmed `bootstrap settings received`. At
1024 by 1024 per eye, its steady sample window reported mean encoding 2463 us,
mean Present 2615 us, peak Present 6258 us, and zero synchronization drops.
The first frame included approximately 42 ms of startup work. These are local
probe measurements, not a headset/game performance result. No headset action
or system registration change was made. The installer code also compiled
successfully against existing staged files; that validation artifact is not a
refreshed distributable. The final release driver build passed.

### Ordinary SteamVR startup and reconnect

The driver can send a versioned activation request (`MDS2`) when Steam loads it.
Meteor queues a SteamVR connection notice on the authenticated headset's existing
watch channel. The request contains no game ID, executable or arguments. A
host-registered SteamVR profile supplies runtime files; the connection uses
SteamVR's app ID 250820 and never starts that profile's application. Steam
continues to launch the game normally. At least one SteamVR profile is currently
required. Initial driver startup allows eight seconds for the headset handoff.

The external-session adapter attaches to the configured SteamVR server after
checking its executable path and Windows user. Its supervisor owns the local
transport helper only. It leaves the Steam-launched runtime and game outside
its jobs, so game exit does not terminate the connection and disconnect does
not terminate the user's SteamVR. Catalog launches can also attach to an
already running runtime when the bootstrap service is available.

On a new connection generation the driver drains the old transport, releases
its tracking client, binds new settings and restarts encoding while retaining
SteamVR's device objects and shared swapchains. An explicit idle response
marks devices disconnected. A missing or slow control reply leaves a healthy
stream alone; it must not reset that stream's frame sequence/epoch.

Startup activation remains retryable until the first successful headset
initialization. Returning to the desktop does
not repeatedly force the user back into PCVR. Another authenticated connection
can reuse the running driver. Changing resolution, refresh rate, capture mode
or headset optics requires restarting SteamVR and produces an explicit error.
General independent-pose overlay composition is still outstanding.

The local `-ExternalCapture` test uses a private registration file, starts
SteamVR without Meteor session environment variables or launch wrappers,
observes two video connections against the same runtime, injects a slow
control response, and checks that an incompatible resolution change reports
Restart SteamVR while preserving the runtime. It uses synthetic tracking and
no headset. The existing `-Capture` path separately checks owned launches.

Next: package and validate the registered route with the real headset and the
installed Steam configuration, including other registered HMD drivers. Then
consider enabling automatic installer registration and removing obsolete
SteamVR launch options. Setup still leaves automatic registration disabled;
installed applications and headset APK have not been replaced by these tests.

## Findings from the comparison

### Installed acceptance build after the power outage

Follow-up to the first real failure: SteamVR loaded Meteor but reported HMD not
found. The desktop and authenticated control watcher were alive. Reissuing the
startup request exposed an accepted 2064x2208/72 Hz offer, then an Android
activity pause during the desktop/display timing transition. Main's pause
handler cancelled the lease before native standby and LAN endpoints started.
The existing active-session pause guard did not cover this preparation phase.

The client now retains the accepted lease only while preparing handover timing;
normal idle/watch pauses still cancel as before. A regression covers that
boundary. All 54 GDScript scripts pass. Windows also discards abandoned,
unconsumed startup claims when their control connection closes. Before its
first successful HMD initialization, the driver can reissue startup activation
without leaving a failed claim stuck until expiry. This does not repeatedly
force an already-used headset back into XR after returning to desktop.
Windows release checks pass (159 tests plus native pipe/geometry checks).
Targeted host logs now record launch queueing, watch, delivery and claim.

The installed Meteor and driver received these fixes with a normal shutdown
of the failed SteamVR instance and Meteor restart. Rollback:
meteor/target/windows-steamvr-release/before-handoff-fix-20261105-213716.
The updated APK was verified and deployed in place, then Nightfall restarted.
Its SHA-256 is
60310405c52fd9dc0bea44adf3ce8c55a7eb5580cb68ae3a7e804e505af5d983.
The refreshed installer SHA-256 is
4f3bb68f305f26e6f17a7a18d098b7198aaeef6358343f5c772e947f517f17d7.
Real headset acceptance after this fix remains pending.

Desktop recovery follow-up: the user then reported black desktop video before
any new XR session. Client logs showed zero video updates after overlapping
launch/resume attempts; the host reported a duplicate plaintext RTSP launch
and control-packet tag verification failure. Nightfall and the Meteor-owned
host were cleanly restarted together to clear volatile launch/session state.
Pairing data was retained.

The host logs also exposed omitted display/capture helpers. The built
sunshine_display_helper.exe and sunshine_wgc_capture.exe were restored to
runtime/host/tools, and release staging now requires both. Their imports use
Windows system libraries. Package checks require their presence. The restart
helper now waits for the actual saved host port rather than a fixed delay
before starting Nightfall. Desktop frame reception must be confirmed before
resuming the SteamVR acceptance test; the restart alone is not acceptance.

The rebuilt 0.1.1 installer was applied to the existing per-user installation.
The upgraded Meteor and bundled host are running on the saved base port 47989,
with managed XR on 47910. Meteor, Steam and Sunshine were checked to be
unelevated. Meteor's key and XR headset approvals remained byte-for-byte
unchanged. The SteamVR driver is registered alongside Virtual Desktop's existing
registration. Only Meteor's VRChat wrapper was cleared; Moss retains xrizer.

Installer SHA-256:
5ed500e782ce2a303e4ae6178de0ebf861c5ce3410f1a5073395b2308ad03f83.
The matching signed 0.8.2 release APK was rebuilt with the native frame-limit
fix; its SHA-256 is
817f66460d63828c7a4dff9626ec4882604ff4610921b74c78f6c9a11c68d462.
APK v2 signature verification and archive CRC checks passed. Its patched Godot
Build ID remains f6a4d257d7211f4104b97206aa9704f0be1a8e47.
The user approved headset installation and launch. The release APK was updated
in place with adb and Nightfall restarted successfully (version 0.8.2, code 802).
The startup check found its process alive and zero fatal log entries. Pairing
data was retained. The real desktop connection and ordinary-Steam VRChat test
still await the user connecting the stream; no live XR acceptance is claimed.

The package check found that GUI-subsystem CLI commands need explicit process
waiting in PowerShell. Meteor-Cli.ps1 now owns the child process and drains
stdout/stderr concurrently, preserving exit codes and quoted arguments.
Setup tests cover complete output and failing commands. The host smoke check
also probes a free port block because the former fixed test ports were
unavailable after reboot. Relocated setup, eight runtime DLL loads, bundled
host startup and managed XR startup passed.

Evidence: meteor/target/windows-steamvr-release/prepare-summary.json,
acceptance-install-summary.json, windows-packaged-setup-summary.json and
windows-packaged-host-summary.json. Rollback files are under
meteor/target/windows-steamvr-release/rollback-20261105-195336.
**Keep rollback files private: they include pairing credentials and keys.**

The comparison's distinction between a Virtual Desktop "shim" and Meteor's
"native driver" is not established by the evidence provided. Class names alone
do not establish which device is wrapped or how frames are captured.

| Claim | Verified evidence and conclusion |
| --- | --- |
| VD wraps any existing SteamVR HMD and only reads mirrored compositor output | Its installed DLL contains `CHMDShimDriver`, `IVRVirtualDisplay`, and `IVRDriverDirectModeComponent_009`. These strings establish neither the active capture path nor arbitrary-HMD wrapping. Further runtime evidence would be needed. |
| `alwaysActivate` proves wrapping | Valve defines it as activating the driver even when another driver's HMD is active. It does not specify interception. |
| `redirectsDisplay` proves mirror capture | Valve defines it as exposing display-redirect devices. The manifest alone does not identify the path used for a particular session. |
| Meteor must restart SteamVR because it uses direct mode | Current launch code requires session-specific configuration and rejects existing SteamVR processes. This is a lifecycle constraint in our implementation. |
| xrizer handles native OpenXR games | xrizer translates OpenVR to OpenXR. Native OpenXR applications use the selected OpenXR runtime directly. |
| Driver signing guarantees anti-cheat acceptance | The comparison supplies no evidence for this guarantee. Keep the tested SteamVR route for VRChat. |

VD's installed manifest has `alwaysActivate: true`, `redirectsDisplay: true`,
and `hmd_presence: ["*.*"]`. Its Streamer executable contains `vrpathreg.exe`
and an `adddriver` command string. Persistent driver registration is therefore
a useful integration model to investigate, without copying its implementation.

Primary reference: [Valve driver API documentation](https://github.com/ValveSoftware/openvr/blob/master/docs/Driver_API_Documentation.md).
Valve documents `vrpathreg adddriver` and `removedriver` for external driver
registration. Registration can hot-plug a driver; that does not demonstrate
that Meteor can already switch active HMDs or change render dimensions in an
existing SteamVR session.

## Current Meteor pipeline

`test/steamvr-driver/driver.cpp` registers Meteor's HMD and controllers. Driver
initialization requires `METEOR_STEAMVR_TRIAL=1` and obtains session settings
through environment variables. `meteor/src/xr_session_windows.rs` prepares
private SteamVR configuration and owns the launched process tree.

For direct capture, `test/steamvr-driver/direct.h` receives submitted eye
textures, synchronizes GPU access, and composes/encodes them through
`encoder.h`. Submitted render poses and the configured optics accompany the
encoded frame. SteamVR still participates in application scheduling and input;
"bypasses SteamVR entirely" is too broad a description.

`transport.c` reuses the bounded asynchronous transport in
`test/monado_async_transport.h`. The Quest decoder supplies the source frame's
poses/FOV to its OpenXR projection layer when `quest_local` is set; see
`extensions/nightfall-xr/src/pcvr_projection_test.cpp`. Keep that association
between a decoded image and its rendering pose when changing integration.

## Recommended implementation sequence

1. Register the installed Meteor SteamVR driver using SteamVR's own
   `vrpathreg.exe`. Remove only Meteor's registration during uninstall and
   avoid duplicate registrations during upgrades.
2. Replace environment-only initialization with a user-scoped local control
   connection to Meteor. Supply headset readiness, session credentials,
   optics, requested dimensions/rate, and transport endpoints through it.
   An installed driver must remain harmless when Meteor or a headset is absent.
3. Prepare the receiver and tracking service when the authorized headset is
   ready, so normal Steam launches can discover Meteor without per-game launch
   options for the SteamVR route. Keep the direct Monado/xrizer launcher as a
   separate supported route.
4. Separate headset connection lifetime from game lifetime. Preserve SteamVR
   processes started by the user; explicitly handle disconnect, reconnect,
   game exit, and competing HMD drivers. Existing-session handover needs tests.
5. Retain the working direct capture pipeline while measuring and improving
   its timing. A different capture API is not a prerequisite for smoother launch.

## XR processing work identified

- **Blocking presentation:** direct capture performs composition and NVENC
  encoding inside `Present`, while holding its mutex and the synchronization
  resource. `nvEncLockBitstream` is blocking. Asynchronous packet delivery does
  not make encoding asynchronous. Measure this callback, then move work onto
  a bounded pipeline with explicit GPU texture ownership and frame dropping.
- **Layer composition:** layers with differing render poses currently fail
  with "SteamVR layers require independent pose composition". General support
  needs pose-aware composition or a suitable compositor-output path. Never
  silently blend images rendered from different viewpoints.
- **Timing:** direct frame metadata uses `now_ns()` after encoding;
  `PostPresent` uses a local pacing clock. Audit rendering, prediction,
  encode completion, and intended display timestamps separately, and measure
  the resulting latency before claiming precise display-time correlation.
- **Frame-count limit found during review (now removed):** the sender and both
  frame validators previously rejected sequence 32768. The encrypted relay
  used the same validator, so the diagnostic cap reached real streaming
  sessions (about 7 minutes 35 seconds at 72 delivered fps). The implementation
  above removes the cap consistently, retains ordering and size validation,
  and tests delivery and clean termination beyond the former boundary.

## Validation for implementation

### November 6 external SteamVR game exit

The physical VRChat → Moss → VRChat sequence launched all three sessions.
After the last VRChat exit, the headset remained in SteamVR's waiting room
until SteamVR was closed manually. External sessions watched vrserver's
lifetime, so an independently launched scene application could exit without
ending the headset lease.

The provider now remembers the non-runtime scene application reported by
SteamVR and signals its session when that application disconnects. The
supervisor sends and drains video END using the existing stop protocol, then
releases the lease. SteamVR remains available for another game. Dashboard and
helper disconnections, duplicate events, and an older application's late exit
cannot end the current scene's lease.

The isolated release capture test passed two connection cycles and verified
that terminating the scene application ends the lease without cancellation
or killing external SteamVR. It also retained the slow-control-reply and
incompatible-resolution checks. All 161 regular Windows tests passed.
Physical acceptance passed: the user repeated VRChat → Moss → VRChat → quit,
and game switching and return to desktop worked. SteamVR still displayed a
"Resume" dashboard prompt on the retry; the user accepted that as a remaining
polish issue. No headset APK change was needed for the scene-exit fix.

### Pairing and desktop startup follow-up

The subsequent desktop reconnect investigation found a separate host lifecycle
problem: Meteor's kill-on-close Windows job prohibited explicit child
breakaway, while Vibepollo's keep-alive display helper requests that flag.
Windows rejected the helper with error 5. The job now permits explicit
breakaway, retaining kill-on-close for the host and ordinary descendants.
The display helper may outlive the host to restore display state, as intended
by Vibepollo. A native child-process regression checks helper creation from
inside the actual job; the existing job-close termination test remains.

Client launch failures no longer delete a saved pairing merely because the
response has no session URL. A host-busy response also no longer triggers an
immediate second launch directly to Sunshine. Both paths have GDScript
regression coverage. The observed PIN hash mismatch remains a separate
pairing-attempt failure; these fixes do not bypass PIN verification.

The exported headset log from 23:55 confirmed a remaining startup timeout:
the display helper now starts successfully, but implicit per-client virtual
display creation repeatedly receives access denied from the installed driver.
The client times out after 10 seconds; the host only queues RTSP after about
22 seconds. The installed configuration was backed up and switched to
`virtual_display_mode = disabled` for physical monitor testing. Windows bundled
host defaults now select physical capture when no explicit mode is present;
explicit virtual-display choices remain unchanged. Virtual display driver
permissions and slow-start cancellation still require separate work.

The first ordinary Steam launch of VRChat captured and delivered XR frames.
Launching Moss through Steam subsequently worked through Monado/xrizer. A
second VRChat launch reused the still-running SteamVR provider but did not
request another headset lease. The driver had limited activation requests to
its initial initialization.

The provider now re-arms activation for 30 seconds when another application
connects to SteamVR or becomes its scene application while Meteor is
disconnected. Known SteamVR and Steam helper processes are excluded. A successful
connection clears that request, so returning to the desktop alone does not
reopen XR. The existing authenticated broker and headset approval still govern
the lease; these events cannot launch an arbitrary executable.

Release geometry, bootstrap, Rust unit, native pipe interop, registration
preview, and application build checks passed. The regression checks cover
initial activation, application-triggered retry, timeout, successful connection
clearing the request, and a subsequent application activation. A physical
VRChat → Moss → VRChat retest remains outstanding.

Check install/upgrade/uninstall registration, launch from ordinary Steam with
no Meteor launch options, SteamVR started before and after headset connection,
reconnect and game switching, and coexistence with other registered drivers.
Measure capture/encode duration, queue depth, dropped frames and pose age.
Exercise overlays with independent poses and stream beyond 32768 frames.
Headset comfort, controller alignment, and image-quality checks remain for a
later user-authorized session. Physical multi-monitor testing is deferred.
