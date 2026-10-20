# Meteor XR: desktop-to-immersive integration

Status: Phase 1 in progress; 2026-10-20. Branch: `feat/meteor-xr-streaming`.
Baseline: `adc97b7`. This plan succeeds the isolated
[Monado spike](meteor-xr-monado-spike.md); retain that plan and the
[live-relay evidence](../../research/meteor-xr-live-relays.md) as research history.

## Product outcome

1. Start Meteor on the PC and Nightfall on the headset; pair/connect normally.
2. Connect to Sunshine or a compatible host and use the streamed desktop.
3. Launch an OpenXR game against Meteor's managed runtime.
4. Meteor detects the runtime session and negotiates immersive streaming.
5. Nightfall presents XR as its immersive base, with the desktop hidden.
6. A local action shows/hides the desktop as a floating panel over continuing XR.
7. Closing XR restores the desktop; failures never leave the user trapped in black.

XR is a projection layer, not a video texture placed on the decorative background.
Meteor remains the user's host application; no independently configured dashboard.
Linux/NVIDIA first, while preserving platform interfaces for eventual Windows and
other GPU support. Neither is validated by the current spike.

## Proven baseline versus missing product work

Proven: encrypted developer LAN control/video/tracking, managed isolated Monado
service, actual OpenXR demo images, head and partial Touch input, hardware encode
and Quest decode/projection, bounded ownership/queues and clean teardown. Physical
1024-square-per-eye testing reached a bounded minute with 3,601 encoded/received/
codec-output frames and 59.39-Hz encoded timestamp cadence. This is not measured
presentation FPS, motion-to-photon latency, hours of reliability or broad game support.

Missing: ordinary Meteor integration/pairing, externally launched app lifecycle,
desktop handover/coexistence, XR audio, general game/input coverage and distribution.
Current DEV entry rejects an active desktop/browser and suppresses the normal scene.
It launches a fixed demo and returns to welcome, not to a preserved desktop.

## Non-negotiable boundaries

- Select Meteor's runtime **before** the game creates its OpenXR instance/session.
  Detect runtime/session events, not process names or desktop mirror windows.
- Do not replace the user's global OpenXR runtime without explicit consent. Start
  with a process-local launcher/environment; later offer reversible registration.
- Keep the existing Quest OpenXR frame loop and session; do not start a second one.
- Retain GPU-local encode, bounded queues, authenticated lanes, generation checks,
  fence ownership and exact child-process cleanup. Never fall back to plaintext LAN.
- Keep ordinary Meteor/Sunshine operation intact when XR is unused or unsupported.
- Keep headset-local emergency exit available even if the PC or control link fails.
- Preserve the proven DEV fixture as a regression path, not the product entry point.
- Initial app scope: one native OpenXR Vulkan application. OpenVR/SteamVR support,
  arbitrary layers/graphics APIs, HDR, foveation and multi-client XR are later work.

## State and ownership model

| State | Immersive presentation | Desktop | Exit behavior |
| --- | --- | --- | --- |
| Desktop | Normal Nightfall scene | Visible | Normal app behavior |
| XR preparing | Keep desktop visible until handover ready | Connected | Cancel restores desktop |
| XR active | Remote XR projection | Hidden, minimal background work | Local exit restores desktop |
| XR + desktop | Remote XR projection continues | Visible floating panel | Hide panel returns focus to XR |
| XR stopping/recovering | Ordered projection/resource drain | Restore once safe | Timeout to usable local UI |

One coordinator owns transitions and generation IDs. No overlapping starts or stale
callbacks restoring old state. Preserve desktop host/session identity, placement and
settings. Keep its session alive where practical; determine whether compatible hosts
can suspend/reduce video work before promising host-side pause. Reconnect is a
bounded fallback, not the default for every panel toggle. Do not change user-saved
passthrough/AI-3D preferences just to suppress them temporarily during XR.

## Phase 1 — normal host service and application lifecycle

First implementation slice; no headset test required until host integration passes.

1. Inspect ordinary Meteor discovery, authentication and shutdown ownership alongside
   `xr_control.rs`, `xr_session.rs` and the current fixture launcher.
2. Extract the runtime/relay lifecycle behind an XR service interface. Separate
   `prepare runtime`, `await app session`, `stream`, `stop` from launching the demo.
   Keep the demo as an explicit test application adapter.
3. Run opt-in XR service alongside normal proxy/depth/microphone tasks, rather than
   the early-return `--xr-control-dev` path. Give it independent cancellation and
   bounded supervision; XR failure must not kill unrelated desktop functionality.
4. Reuse ordinary paired identity/trust where available. Audit the existing pairing
   protocol before choosing integration; derive purpose-separated XR keys and retain
   session nonces/counters. Manual key files remain DEV-only. Advertise capability
   only when runtime/encoder readiness is known; never imply universal hardware support.
5. Add explicit runtime session notifications and a trusted local launcher for a
   selected executable using process-local runtime configuration. Network requests
   must not become arbitrary command execution or accept arbitrary filesystem paths.
6. Handle app exit, session end, headset refusal/disconnect and runtime failure.
   Define service readiness before app `xrWaitFrame`; bound waits during headset
   negotiation. Keep the app unpresented until optics/tracking are ready.

Gate: normal Meteor desktop/depth operations survive a demo session start/end,
rejection, disconnect and runtime failure; two successive launches work without
global runtime changes or manually starting the separate XR listener. Add unit and
integration tests for lifecycle events, stale generations and cancellation.

## Phase 2 — real desktop-to-XR handover

1. Introduce the client coordinator around the existing native projection API;
   stop using the clean-welcome restriction for the new integrated entry only.
2. Snapshot the active desktop context. Temporarily suppress AI depth, ambient,
   passthrough and ordinary screen layers at the presentation boundary. Avoid
   stopping/destroying resources indiscriminately via the current exclusive helper.
3. Switch presentation only after authenticated transport and the first usable XR
   frame are ready. Startup timeout/refusal leaves the desktop usable.
4. Restore desktop on XR exit/failure, including audio and pointer ownership.
5. Launch one real native OpenXR application, not just our fixture. Record its
   required graphics bindings, layers, actions and reference spaces; implement or
   explicitly reject unsupported features rather than claiming general compatibility.

Gate: from an active Sunshine desktop, launch the selected app, enter XR, exit and
return to the same desktop. Repeat; test startup failure, host disappearance,
headset removal and local emergency exit. Initial XR may remain visually exclusive.
Use an optimized/release-signed DEV APK per BUILD.md, never debug for performance.

## Phase 3 — desktop overlay and input focus

1. Permit the existing desktop screen layer over the native XR projection, starting
   with one panel and no browser/multi-screen expansion. Audit composition-layer
   budget and native/Godot submission ownership before enabling coexistence.
2. Add a deliberate show/hide action usable during XR, with local fallback UI.
3. Route pointer/controller interaction to the panel while focused; prevent the
   same click reaching both desktop and game. Keep tracking updates continuous;
   define neutral/released game action states on focus changes to avoid stuck input.
4. Resume desktop video work when shown; measure hidden versus visible GPU/decoder/
   network costs. Do not keep full-rate hidden decoding without a reason.
5. Defer desktop AI-3D in this mode until simple overlay performance is validated.

Gate: show/hide repeatedly without interrupting XR tracking, losing world lock,
double input, stale images, leaked layers or needing to reconnect the desktop.

## Phase 4 — audio, completeness and product hardening

- Add authenticated, clocked XR game audio; specify game/desktop audio policy when
  the panel is visible or hidden. Do not assume ordinary desktop audio is suitable
  or enable both paths and duplicate it. Microphone routing is a separate decision.
- Validate controller mappings, analog inputs, haptics, recentering and app focus.
- Replace finite fixture frame targets with supervised session lifetime. Retain
  bounded startup/shutdown and disconnect watchdogs; do not simply remove all bounds.
- Run longer sessions and repeated launches, standby, decoder reset, network loss,
  reconnect and application/runtime crashes. Record generation, frame accounting,
  queue/fence diagnostics and stage timings; distinguish cadence from latency.
- Package pinned runtime/helpers and notices, eliminating checkout/Python/compiler
  requirements for users. Review copied WiVRn code and redistribution obligations.
- Follow with Windows runtime/IPC/graphics/encoder adapters and AMD/Intel support as
  explicit compatibility tracks. Do not couple Linux-specific paths into the protocol.

## Preparation / next working step

Repository was clean at the start of this planning step. Do not rebuild or redeploy
the unchanged app just for this document. Existing proven fixture remains usable.

Next: map normal Meteor task/trust ownership and implement Phase 1's service
boundary plus host lifecycle tests. Read repository instructions and BUILD.md before
any build. First handover test should exercise the complete user workflow with a
real app; avoid asking for another sequence of tiny rendering-only confirmations.

Open decisions to resolve from code/measurements: ordinary pairing reuse, compatible
host video suspension, chosen first real app, desktop reveal action, audio focus
policy and eventual runtime registration UX. None blocks starting the host service
refactor; record decisions here as they are made.

## Phase 1 progress — reusable control service

Implemented the first service boundary in `meteor/src/xr_control.rs`: a caller-owned
listener, explicit local authorization/fixture configuration and watch-channel
cancellation. The existing DEV CLI is now a wrapper that owns signal handling.
The service drains connection tasks on cancellation, sender loss or accept failure;
connection teardown retains the existing relay cancellation behavior. It rejects
missing authorization and runtime configuration without relays. No new public
capability, port, normal-startup behavior or headset behavior is enabled yet.

Tests verify cancellation during an accepted but incomplete handshake, socket
release/rebind, sender-loss shutdown and invalid configuration. Full Meteor tests:
96 passed, 10 ignored (specialized fixtures/benchmarks); no headset deployment.

Inspection findings driving the next slice:

- Ordinary Meteor `quit()` ends via immediate `_exit`/TerminateProcess to avoid
  unsafe GPU-library exit handlers. The relay currently starts a detached runtime
  task that cleans up asynchronously. Before wiring into normal startup, introduce
  explicit awaitable runtime/service drain and route all normal quit paths through
  a bounded supervisor without reintroducing unsafe library destructors.
- Ordinary side channels advertise a host public key and restrict clients by
  streaming peer IP; this is not the XR persistent client-public-key allowlist.
  Do not silently replace XR authorization with discovery or an IP check. Define
  an explicit enrollment/trust interface before exposing integrated XR negotiation.
- Fixed fixture launch remains inside the current runtime adapter. The next
  refactor must separate that adapter and runtime supervision from application
  launch; arbitrary external game lifecycle is not implemented by this increment.

## Phase 1 progress — awaitable runtime drain

The reusable control service now owns a registry of runtime tasks. Aborting and
joining its control connections first drops their relays and signals runtime
cancellation. It then awaits registered runtime tasks under a shared 26-second
budget (existing four-second graceful app exit plus up to twenty seconds of
post-run validation, with margin). Tasks exceeding that budget are aborted and
joined so their owned-process cleanup runs before the service returns; the caller
receives a timeout error. This is cooperative async cancellation, not a guarantee
against a permanently blocked executor/native call.

The existing direct fixture helpers remain available; the service-owned path
registers its runtime tasks explicitly. No wire format, application profile,
headset code or normal Meteor quit behavior changed. The new service must still be
wired into a normal-startup shutdown coordinator before the hard-exit path is safe
for integrated XR; this change does not claim that integration is complete.

Full Meteor tests: 100 passed, 10 ignored. New coverage checks cooperative drain,
timeout/abort destructor completion, cancellation before authenticated lane
attachment and an actual owned child being reaped before drain returns. Existing
socket authentication, negotiation and relay tests still pass. GPU runtime fixture
integration was not rerun; no build was installed on the headset.

Next slice: introduce a normal Meteor shutdown coordinator that handles tray and
signal quit through bounded service drain before retaining the existing immediate
process exit. Then add opt-in coexistence with explicit local XR authorization;
normal enrollment and externally launched app detection remain subsequent work.

## Phase 1 progress — normal-process coexistence wiring

Implemented `shutdown.rs` with sticky, thread-safe exit requests. Normal Meteor
registers the coordinator before exposing tray controls. Tray Quit now requests
shutdown instead of immediately ending the process; Ctrl+C/SIGTERM use the same
request. Main awaits the optional XR service (including runtime drain), then
removes the microphone and retains `_exit`/TerminateProcess. Replay retains its
previous immediate-exit behavior because it has no integrated XR service.

New explicit DEV options: `--xr-service-dev <bind-address:port>`, mandatory
`--xr-client-key <public-hex>`, and optional `--xr-runtime-root <checkout>`.
The service uses normal Meteor's host identity, with the existing authenticated
control/relay protocol and explicit headset allowlist. A different previous DEV
host identity requires an explicit public host-pin update. Startup errors disable
only XR and are logged; no automatic firewall or runtime-registration changes,
no discovery capability and no weaker IP-based authorization were added.
The runtime root still selects the fixed demo, not arbitrary application launch.

Full tests: 103 passed, 10 ignored. Additional coverage checks sticky/repeated exit
requests, wakeup of a waiting coordinator, and shutdown of an accepted XR handshake
while an unrelated independently owned listener remains usable. This is host-level
automated coverage, not a physical simultaneous Sunshine/XR test, Windows runtime
validation, or a new headset build. No running host service was replaced.

Next: separate runtime preparation/session observation from fixture launch and
validate the opt-in normal-process path with the real runtime fixture. Then wire
runtime session events to negotiation and the client's desktop handover. Explicit
production client enrollment remains required before broad capability discovery.

## Phase 1 progress — runtime lifecycle separated from fixture launch

Extracted `test/xr_runtime_lifecycle.py` and used it in the real NVENC adapter.
This component owns only the Monado child: startup, IPC-socket readiness,
startup cancellation, bounded terminate/kill and reap, and atomic run-local
`runtime-state.json` diagnostics. It does not launch an application. The existing
fixture orchestration launches/reaps its application inside that runtime scope.
Pre-existing endpoints are rejected instead of accepted as readiness evidence.
App-side failures preserve runtime cleanup, including a service ignoring SIGTERM.

The lifecycle state deliberately reports `application_session_observed: false`:
socket readiness is not session detection. No runtime-origin session notifications
or arbitrary application launch support have been implemented by this extraction.
Also, initial virtual-HMD setup still depends on the existing authenticated
tracking/optics handshake; this is not yet a continuously running product runtime.

Validation: 55 Python XR tests pass, including six new lifecycle regressions.
The real Linux/NVIDIA/native-worker relay integration passed, with 203 stereo
frames encoded/decoded, balanced image leases, encoder drain and clean engine
shutdown. Artifacts: `.build-cache/meteor-xr/lan-sessions/1792471702889833172-27315/`.
Its final runtime lifecycle record is `stopped`. This exercised the adapter through
the existing fixture, not the full normal-process proxy/XR coexistence CLI.
The running host listener and installed headset APK were not replaced.

Next: runtime-origin session events and a host session observer, with generation
binding and explicit readiness/active/stopping distinctions. Resolve how the
managed runtime acquires headset optics/tracking before an externally launched
application creates its session; do not assume a pre-connection simulated device
is equivalent. Then test normal-process coexistence and desktop handover.

## Phase 1 progress — runtime-origin session observation

Added a separate `monado_session_events.patch` applied with zero fuzz after the
existing capture/controller patches. Hooks are in the **per-client** multi
compositor, not the global null compositor. They emit structured `created`,
`begun`, `ended` and `destroyed` records. Creation means an application compositor
exists; begun means its session began, not that a frame reached the headset.
Destroy can occur without end when a client disappears. End/rebegin is allowed.

Each managed runtime attempt gets a random 128-bit generation. Runtime-generated
records have ordered sequence numbers and non-pointer session IDs. A bounded Rust
observer tails the private service log during supervision, validates schema,
generation, sequence and lifecycle transitions, and writes
`runtime-session-events.json`. Incomplete event lines remain pending; malformed,
replayed/out-of-order events, log truncation and oversized lines fail closed.
The observer retains at most 128 session IDs per diagnostic attempt. There is no
network event API or automatic client transition yet. The local generation binds
attempts; it is not a cryptographic trust boundary against other same-user code.

The isolated Monado runtime was rebuilt successfully. Full Meteor tests:
107 passed, 10 ignored. The real native-worker/GPU integration also passed:
201 encoded/decoded stereo frames, balanced leases/encoder drain and clean engine
shutdown. Artifacts:
`.build-cache/meteor-xr/lan-sessions/1792472346353344486-62415/`.
The service emitted exactly four ordered lifecycle records for session 1:
created → begun → ended → destroyed. Host summary reports
`application_session_observed: true`, sequence 4 and session 1 destroyed.

This proves actual runtime-origin session observation through our managed demo,
not detection of arbitrary external games or desktop handover. No global runtime
registration, running host-listener replacement or headset deployment occurred.
The old running host executable does not acquire the new Rust observer until rebuilt
and restarted; legacy probes without an event generation still run as before.

Next: publish supervised runtime/session state to the normal-process control
service and validate its combined proxy/XR lifecycle. Then introduce a supported
local application launcher/session-driven negotiation and the client handover.
Keep the optics/tracking-before-app-start requirement explicit during that work.

## Phase 1 progress — session state in authenticated control replies

Checkpoint `e8cfcc3` commits the service integration, runtime lifecycle extraction,
session-event hooks/observer, tests and this plan. Subsequent work adds an optional
`runtime` object to control replies, owned by the reply's accepted relay/lease.
It is omitted before acceptance, without a configured runtime, and after stop;
old replies without it still deserialize. Existing `state: prepared`, explicit
acceptance and `lan_video_available: false` semantics are unchanged.

The object reports `phase`, optional runtime `generation`, `event_sequence` and
`active_sessions`. Phases distinguish waiting for authenticated lanes, starting,
session created/active/ended, stopping, completed, cancelled and failed. Activity
comes only from validated per-client runtime events, not socket readiness. Active
session count is cleared after the owned runtime adapter has returned/cleaned up.
Errors may still close the control connection; this is not an unsolicited event
subscription or a reliable final-failure-notification protocol. Reply state does
not prove headset presentation or frame rate. Runtime session deadline expiry now
returns a timeout error rather than looking like successful fixture completion.

Validation: full suite 109 passed, 10 ignored before the final GPU-test assertion
extension. The extended real GPU/native-worker fixture also passes: it observes
an active session while video is running, then a completed runtime with generation,
at least four lifecycle events and zero active sessions. Artifacts:
`.build-cache/meteor-xr/lan-sessions/1792473018188992818-96710/`.
Authenticated socket tests check status before/after acceptance and stop across
two leases, including no stale status on the next offer. No headset code changed.

Next: exercise the normal-process coexistence entry end to end and add the client
consumer for runtime state. The client still uses its existing DEV exclusive entry;
real external-app launching/session-driven offers and desktop handover remain open.

## Phase 1 progress — normal-process validation and client status consumer

Built optimized `meteor/target/release/nightfall-meteor` and ran the new
`test/run_meteor_xr_coexistence.py` against the normal entry point, not the exclusive
control CLI. It isolates XDG settings/data/logs, uses fixed test-only identities,
reserves unused ports and supplies a mock Sunshine HTTP upstream. All three cases
passed: enabled XR with native OpenSSL authentication/offer/accept/stop plus proxy
forwarding before and after; deliberately occupied XR port with proxy remaining
usable; XR disabled. SIGTERM/SIGINT paths exited cleanly. No running service or
user configuration was changed. This verifies process wiring and TCP forwarding,
not full GameStream video, active GPU-runtime shutdown via this CLI, or headset
desktop/XR coexistence. The real GPU/runtime path was tested separately above.

`MeteorXRControl` now consumes the optional runtime object after acceptance and
polls status every 500 ms through its single serialized control-request path.
It validates shape, numeric bounds, phase/activity consistency, runtime generation
and nondecreasing event sequence. A known runtime cannot disappear/change generation
within a lease; old hosts that never supply the field remain compatible. Cancel
clears status, and `runtime_changed` lets later handover logic subscribe without
confusing runtime activity with presentation readiness. No automatic projection
entry, saved preference change or new button was introduced.

All 37 GDScript test scripts passed, including status validation/reset and old-host
compatibility. The headless desktop runner still prints the existing unavailable
Android-only XR-extension diagnostics; these are not a native headset test.
The release host build produced the existing test-helper dead-code warning for
`start_runtime_profile`; it succeeded. Installed APK is unchanged.

Next milestone: connected XR standby and safe presentation handover. Separate
tracking/optics bootstrap from exclusive projection so Meteor can prepare its
virtual HMD while the desktop remains visible. Then launch an explicitly selected
native OpenXR app against that runtime, observe its session, and defer hiding the
desktop until decoded XR video is ready. Keep the DEV fixture as a regression,
preserve desktop context and keep local exit/rollback available throughout.

## Phase 2 foundation — non-presenting headset standby

Added native `start_meteor_standby()` alongside the unchanged exclusive
`start_meteor_test()` entry. Standby initializes the existing tracking/optics and
decoder path using the same OpenXR session and render-loop callbacks, but its
provider returns zero composition layers. It can prepare/copy decoded frames
without suppressing the ordinary desktop scene. This still allocates a projection
swapchain and performs decode/copy work; it is not a low-power indefinitely idle
service, and its coexistence/performance needs physical validation.

Native status distinguishes `meteor_standby`, `meteor_frame_ready` and
`meteor_projection_enabled`. The separate `activate_meteor_projection()` API
requires a running receiver and a copied frame. No current controller calls it:
the future handover must retire conflicting desktop layers before activation.
Frame readiness alone cannot hide the workspace or submit an immersive layer.
Controller poses continue during standby, but buttons/analog input are neutral
and host haptics are consumed/discarded rather than applied or replayed later.

An explicit `[host] standby_only=true` in the existing DEV headset configuration
selects this diagnostic. Default remains false. It keeps manual authentication/
acceptance and the fixed host demo, not automatic external-game detection. The
standby controller leaves workspace visibility, audio, depth and exclusive-PCVR
policy untouched. Main ticks its timeout/cleanup independently of exclusive mode;
pause, timeout and cancellation drain native resources without restoring welcome
or implicitly restarting on resume. Stable desktop streaming is permitted by the
standby busy check; startup/connection/workspace changes are rejected at entry.

Validation: the presentation/input gate C++ unit test passes; Android release
extension rebuild passes (existing OpenXR aggregate-initializer warnings remain).
All 37 GDScript scripts pass, including no exclusive entry/workspace suppression,
copied-frame readiness without activation, duplicate start/stop, pause/no automatic
resume, timeout and native-idle cleanup. Full native runner remains subject to its
local FFmpeg development-package prerequisite; the new gate test ran standalone.
Neither a new APK nor changed DEV configuration was installed on the headset.

Packaging update: `./build.sh --dev` successfully produced the optimized,
release-signed `Nightfall-Android-arm64-v8a-dev.apk` (106 MB), version
`0.8.2-preview.1-dev+e8cfcc3-dirty`, code 802. The APK contains the release native
XR library. SHA-256:
`14cee0142cd4b91b39d4a1d3cb7d7c8884d43efe929b337750ecb144dc7fd94b`.
Build credentials were restored by the build script. The initial sandbox build
could not access Gradle's cache; the approved build outside it succeeded. This
artifact has not been installed and standby has not been visually verified.

Next physical gate: build an optimized DEV APK, explicitly select standby mode,
and verify the desktop/welcome remains visible while logs show live optics,
runtime session events and decoded stereo readiness, followed by clean stop with
the same workspace intact. Only after that introduce snapshot/layer retirement,
projection activation and rollback into the client handover coordinator.

## Physical standby checkpoint and workspace handover implementation

Standby physical test: `.build-cache/meteor-xr/lan-sessions/1792474738883170441-174125/`.
The user confirmed the welcome screen stayed visible and usable while the host
demo ran. Device logs show decoded stereo readiness with projection disabled and
authenticated `session_active` status. Headset pause at 07:39:26 cancelled the run
after roughly 19 seconds of video; 1,114 host frames were encoded. Host app exited
without forced termination; runtime emitted created/begun/ended/destroyed. This
was an interrupted run, **not** a completed minute/final-delivery-drain PASS.

Implemented opt-in `handover_on_ready=true` (implies standby) using the separate
`PCVRWorkspaceHandover` coordinator. It waits for both validated host session
activity and a copied native frame. The first scope is one welcome/desktop screen,
not browser/multi-screen coexistence. It snapshots root visibility, local projection,
blend/transparency and audio/microphone pause state; neutralizes held host inputs;
then hides the workspace and waits three frame/draw boundaries before explicitly
activating native XR projection. Startup and draw-retirement waits are bounded;
generation checks cancel stale asynchronous callbacks. The developer offer now
identifies handover rather than standby-only/exclusive legacy mode.

Added an independent native desktop-renderer presentation-suspend switch. Both
layer count and retrieval return zero while suspended; the desktop decoder and
native swapchain are not destroyed solely for handover. Its eye-query frame counter
does not age while suspended. The manager's refresh is suspended too. Ordinary
Godot composition layers follow parent visibility, verified against the pinned
engine source; Godot's own projection is explicitly disabled during XR. The first
decoded-frame diagnostic now says image copied/presentation requested instead of
incorrectly claiming one layer was submitted during standby.

On local exit, control loss, application end/failure or headset pause, the coordinator
stops the prepared receiver and restores presentation only after native idle. It
never reconnects Sunshine, forces welcome, restores a stale lifecycle state or
overwrites saved preferences. Child visibility/content may change through normal
stream callbacks while hidden and is not overwritten on restoration. Mouse/key/
pad forwarding and independently processing controller/trackpad nodes are gated;
held keys/buttons/modifiers are released and pads neutralized before transfer.
Desktop audio/microphone are paused, not replaced with an XR audio implementation.
Hidden-stream decoder work, inference and bandwidth have not been optimized or
measured by this change. A desktop overlay during XR remains out of scope.

Validation: all **38 GDScript scripts passed**, including real parent-visibility
snapshot behavior using a fake XR interface, frame/session readiness, stale-callback
cancellation, activation/suspend rejection, native-idle ordering, startup/draw timeout,
pause-sensitive microphone restoration and held-input release/gating. Android release
extension and optimized release-signed DEV APK builds succeeded; existing aggregate
initializer and desktop Android-extension warnings remain. These tests do not prove
physical seamless handover, simultaneous live Sunshine/XR, or arbitrary game support.

Installed `Nightfall-Android-arm64-v8a-dev.apk` (code 802,
`0.8.2-preview.1-dev+8a8436e-dirty`) on Quest `2G0YC1ZF8P08QN` and enabled the new
option. SHA-256: `c5eab2e199062f87a8d326edda5bffc48ebf97373951cdbf5c9183384423de44`.
Before-change config backup:
`.build-cache/meteor-xr/handover-config-before-8a8436e.cfg`.
Normal Meteor remains untouched; the existing DEV listener (PID 174125 at setup)
is available at `10.0.0.13:47905`. Its public pin/allowlist are unchanged. Helper
preflight cache was warmed and validated. No XR test was automatically accepted.

Next physical gate: authenticate/accept from welcome, see the existing screen until
XR video is ready, then see the demo. Hold B/Y for one second (or let the bounded
demo end) and confirm return to the same usable workspace. Verify logs before
claiming handover success. Then provide an entry from a live desktop and test stream
preservation, followed by external app/session-driven launch and desktop reveal.

### Handover startup correction (2026-10-20)

Device logs showed successful authentication, host session activation and decoded
stereo readiness, followed by `Cannot safely suspend desktop presentation`.
The coordinator checked a guessed getter name instead of the patched engine's
bound `get_submit_projection_layer()` API. Corrected both coordinator and test
interface to the actual engine API, and added explicit capability-rejection logs.
All 38 GDScript test scripts passed. Physical handover remains to be retested;
this failure occurred before projection activation, not in transport or decoding.

### Validated checkpoint and resume instructions (2026-10-20)

After deploying the corrected optimized, release-signed DEV APK, the user confirmed
that XR started successfully and that exiting returned to the welcome screen.
The welcome → XR → welcome physical gate is therefore user-validated. This does
not yet validate preservation of a live Sunshine stream or automatic XR game launch.

Work is paused here while the user works elsewhere in the repository. Resume on
`feat/meteor-xr-streaming`: first check the current branch and working tree before
editing or switching, preserving any unrelated work. Read this checkpoint before
continuing; do not assume the branch or background services are still active.

Next step: provide/test handover from an active Sunshine desktop stream, then exit
XR and confirm the same stream returns without reconnection, stale input, audio or
presentation problems. Afterwards continue external app/session-driven startup and
desktop reveal. The current fixed demo is not yet the final automatic workflow.
The device DEV config uses `standby_only=true` and `handover_on_ready=true` with
the dedicated XR listener at `10.0.0.13:47905`; verify listener/config availability
on resumption without replacing the user's normal Meteor service. Rebuild using
`./build.sh --dev` when needed, not a debug build.
