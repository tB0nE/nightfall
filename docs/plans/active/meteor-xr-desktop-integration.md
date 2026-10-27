# Meteor XR: desktop-to-immersive integration

Historical implementation plan, 2026-10-20. For current status and outstanding
work, use the [26 October branch review](meteor-branch-review-20261026.md).
Branch: `feat/meteor-xr-streaming`.
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

### Live-desktop handover entry (2026-10-20, implementation)

Resumed on clean `feat/meteor-xr-streaming` at `a07f7e9`. The other agent's
`fix/pairing` work is isolated in `moonlight-quest-pairing`; no branch switch or
changes there are needed. Added a provisioned DEV-only section at the beginning
of Settings: Connect XR, explicit Accept XR, Cancel XR and control status.
It uses the existing menu viewport, with no new composition layers, and shares
the welcome screen's control instance/lease. Scroll-drag suppresses accidental
button activation. Only `handover_on_ready=true` allows the standby readiness
policy for this entry; other configurations retain the clean-welcome restriction.
Readiness rejection preserves an offered lease rather than silently accepting or
replacing it. The fixed demo and bounded runtime are unchanged.

Validation: all 38 GDScript scripts passed, including shared control identity,
legacy/standby-only versus handover entry policy, explicit acceptance and busy
rejection without losing the offered state. Device and dedicated DEV listener
were available at setup; normal Meteor was not restarted.

Physical gate pending: connect one Sunshine desktop stream, open the menu gear,
use Connect XR then Accept XR, and confirm desktop remains visible until XR is
ready. Exit with a one-second B/Y hold (or demo end). Confirm the same desktop
returns without reconnecting and mouse, keyboard, controller and audio recover.
This change does not establish that live-stream coexistence works until tested.

Built and installed optimized release-signed
`Nightfall-Android-arm64-v8a-dev.apk`, version
`0.8.2-preview.1-dev+a07f7e9-dirty` (code 802), on Quest `2G0YC1ZF8P08QN`.
SHA-256: `b5020287eb03a4bdb108993eb3059df8fc7add37344f58a087b2fc9ef7d5b857`.

### Live stream validated; host-local launcher (2026-10-20)

User confirmed the live Sunshine → XR → same desktop round trip worked perfectly.
This is a physical validation of the preceding entry/handover gate, not yet proof
of arbitrary game compatibility, an in-XR desktop overlay or automatic app discovery.

Next implemented step: optional host-local `.build-cache/meteor-xr/application.json`
selects a direct foreground native OpenXR application instead of the fixed demo.
Its schema is exactly `{"argv": ["/absolute/executable", "argument"], "cwd":
"/absolute/directory"}`. Missing configuration retains the fixed demo; invalid
configuration fails rather than silently selecting a different app. The executable
must exist and be executable. No shell expansion, remote command fields or custom
environment overrides are introduced. This configuration is trusted host-local
code execution; only configure applications you trust. Do not point it at Steam,
shell wrappers or background launchers that forward to already-running processes.

The selected child inherits the managed runtime's private `XR_RUNTIME_JSON` and
IPC directory, optics/tracking and existing capture transport. No system runtime
registration is changed. Demo-specific import, lifecycle autoload and completion
claims are bypassed for an external app. Exit/cancel stops the owned child without
requiring a Nightfall-specific exit hook; overall supervisor deadlines remain.
Normal app completion validates capture byte accounting and encoder/image drain,
while tracking disconnection remains an interrupted outcome, not a fabricated
completed-stream PASS. Runtime-origin begin/end events remain the handover signal.

Local validation: 12 Python application-selection/lifecycle tests passed and six
Rust XR supervisor tests passed. External application GPU/headset validation is
still pending. The next physical gate uses the independently launched Khronos
`hello_xr` executable as the smallest native OpenXR app, then a real native game.
This is explicit app launch after headset acceptance, NOT automatic detection yet:
starting a managed runtime without launching a fixture/app, publishing a scoped
launch environment and negotiating on an observed app session remains later work.
Linux/NVIDIA only for this gate; no Windows or OpenVR/SteamVR claim.

Built optimized Meteor and restarted only the idle dedicated XR DEV listener
(tool session 3167 at setup) on the same `10.0.0.13:47905` endpoint and public pin.
Normal Meteor was not restarted. Local ignored `application.json` selects
`.build-cache/meteor-xr/hello-xr-spike/build/src/tests/hello_xr/hello_xr` with
`-g Vulkan2 -s Stage -bm Opaque`. No app was automatically launched/accepted.
The existing headset build's Settings → Connect XR → Accept XR is the entry;
verify the standalone sample appears and B/Y returns to the existing desktop.
To return to the fixed movement demo, move the local application JSON aside
before the next attempt (or remove the selection with user approval).

### External sample startup: background stdin (2026-10-20)

First physical attempts authenticated and launched HelloXR, but it created then
destroyed its session without a begin event or encoded frames. `probe.log` showed
`Press any key to shutdown...`; source inspection confirmed its input thread
unconditionally treats `getchar()` returning EOF as quit. The background host's
inherited stdin therefore caused exit during initialization, with only the
downstream encoder-no-output error visible in `runtime.log`.

External child launch now supplies an isolated stdin pipe whose writer stays open
for that child's lifetime. It neither consumes host terminal input nor sees an
immediate EOF; normal cancellation still terminates/reaps the exact child. All
13 Python application/lifecycle tests pass, including a regression checking stdin
is not readable/EOF. The dedicated listener reads these scripts on each attempt,
so no APK or listener rebuild/restart is needed. Physical retry remains pending.

### External projection-with-depth capture correction (2026-10-20)

After stdin isolation, device attempts reached a real runtime session-begin event
but `service.log` ended with `METEOR_CAPTURE_FAILED`. The unadapted sample enables
`XR_KHR_composition_layer_depth`: our capture hook accepted only ordinary
projection layers. Added colour-only normalization of two-view depth projections
for encoding, retaining original poses/FOV/subimages/chroma-key metadata. The
transport still does not send game depth buffers or implement depth reprojection.

Depth-bearing submissions now acquire colour-image reservations in the
multi-compositor's depth-projection submission path as well as releasing them on
slot retirement. A local GPU smoke test exposed the missing acquisition hook as
a three-frame stall; fixed before the next physical retry. Added depth-image
selection/lease unit coverage, rebuilt the managed runtime, and validated the
actual standalone sample with synthetic tracking: 64 encoded frames through the
same 1024-eye/60-Hz target, Touch, asynchronous encode/delivery profile. Test was
intentionally interrupted, so this proves sustained startup/capture/transport,
not physical presentation or completed-stream drain. Diagnostics retained under
`.build-cache/meteor-xr/external-smoke-25gw0gb5/`; script:
`test/smoke_xr_local_application.py`. No headset update or listener restart needed;
the existing listener starts the newly rebuilt managed runtime on its next lease.

### Wristwatch desktop reveal prototype (2026-10-20)

User confirmed independent OpenXR app launch/streaming works on the headset,
then selected a wristwatch rather than a game-button combination for desktop
reveal. Added a controller-first left-wrist watch: face it toward the headset
for 0.2 seconds to reveal a 24-hour local clock and monitor icon. Point the right
controller at the lower button and press its trigger to show/hide the existing
desktop workspace. Looking alone does not select it; held triggers cannot repeat
or click through into the revealed desktop. Watch location/reveal/hit geometry
uses the exact Quest LOCAL head/grip/aim poses sampled for Meteor, not Godot's
possibly recentered/STAGE-relative transforms. Tracking loss hides the watch.

The watch is shaded directly into the existing native Meteor projection copy,
with no added composition layer, viewport, texture or XR session/frame loop.
Its small procedural display is a prototype, not final watch artwork. XR base
projection now sorts behind Nightfall's existing desktop/UI layers. Showing the
workspace resumes ordinary desktop/UI processing and native video presentation
while keeping Godot's base projection disabled and the XR environment opaque.
Hiding it suspends desktop presentation again without reconnecting Sunshine.
Snapshot restoration on XR exit remains gated on native idle.

This first version gives the visible desktop input focus: native XR controller
poses continue, but game action values are neutral while it is open or the watch
button is targeted/clicked. Haptics are discarded during that focus. After hiding,
game actions remain neutral until controls are released, avoiding held-click
replay. Desktop held inputs are released on both focus transitions. Desktop
audio/microphone remain paused by the existing handover policy; XR audio is not
implemented. No hand-tracking watch gestures, wrist preference, in-XR browser or
multi-screen expansion, hidden-stream bandwidth optimization, or automatic app
detection is claimed here. Existing DEV B/Y-hold exit remains a recovery path.

Validation: 39 GDScript scripts passed, including watch-facing/ray geometry,
reveal without activation, click latching/release, tracking loss, ordinary game
trigger use away from watch, and desktop show/hide ownership/projection checks.
The actual embedded GLES fragment shader compiled using glslangValidator in the
existing build container. Native Android release extension and optimized
release-signed DEV APK builds passed. Physical alignment, comfort, menu/keyboard
interaction, layer budget and repeated desktop reveal still require headset
testing; script/shader compilation is not proof of physical usability.

APK: `Nightfall-Android-arm64-v8a-dev.apk`, code 802,
`0.8.2-preview.1-dev+a07f7e9-dirty`.
SHA-256: `13f263f88f4e5e1607b25778ad970767fde275157a28d439b472a987d44a6853`.

### Watch feedback and cursor ordering (2026-10-20)

User confirmed the watch works and desktop reveal succeeds. Feedback: mounting
required turning the left wrist to the right, menu movement lacked animation,
and menu cursor was invisible although screen cursor worked. Rolled the mount
60 degrees around controller-local Z toward the outside of the left wrist,
including its face offset, as an initial down-left ergonomic adjustment. Physical
confirmation of that interpretation is still needed.

Found independent cursor sort order 999 versus menu 1000 (keyboard also 999).
Placed the existing primary/secondary cursor layers above both panels, deriving
the value from shared panel-order constants, without adding layers. Added an
actual layer-construction/order regression; all 40 GDScript scripts pass.

Movement was not changed in this follow-up: grabbing directly updates transforms;
there is no tween/animation. The menu's saved screen-relative anchor is restored
when opened, rather than continuously following a moved screen. Layer transform
sync also precedes grab handling in the normal frame loop (one-frame delay).
Clarify whether the feedback means missing smoothing/anchored follow versus
missing live movement of the grabbed panel before changing interaction semantics.

Follow-up feedback: movement is working fine and cursor correction is confirmed.
The 60-degree watch tilt still put its face on the wrong side of the wrist.
Moved its face offset to the opposite wrist surface, reversed the face normal,
and rotated the display 90 degrees in its plane, per the user's clarification.
Updated mounting tests verify the opposite surface/normal and quarter-turn.
This ergonomic correction still needs physical confirmation; movement/cursor
behavior was deliberately left unchanged.

### Temporary wrist placement markers (2026-10-20)

Opposite-side mounting still required an unnatural palm-up/bent-wrist posture.
User requested coloured candidate balls instead of more guessed rotations.
Added temporary DEV calibration mode (instance `calibration_markers=true`) replacing
the watch display with 24 numbered spheres around the raw left controller grip.
This is a controller pose, not an anatomical wrist joint. Candidate centres are
radius 7 cm in controller-local XY at Z=-8 cm, +4 cm and +16 cm, eight positions
per ring (45-degree steps); sphere radius 1.4 cm. Each ring uses red, orange,
yellow, green, cyan, blue, purple, pink in order. Labels 1–8, 9–16 and 17–24
distinguish the rings; all are visible without the wrist-facing/gaze gate.

Markers use the existing native projection shader, not extra composition layers,
and are non-interactive: no watch click or game input capture. Normal watch
interaction remains covered by tests with calibration disabled. Once the user
identifies the preferred number, convert that raw-grip-relative position into the
mount, calibrate face/text orientation separately, and disable the markers.
The ordinary controller-tracking validity and XR-session lifetime still apply.

User selected **marker 13** as right on the wrist. Locked the normal watch mount
to that exact raw-grip-relative position `(-0.07, 0, 0.04)` metres. Face normal is
controller-local -X (radially outward from that ring); text top is +Z (towards
forearm), with a right-handed orthonormal basis. Calibration markers default off;
the mode/shader remain available for future diagnostics. Updated regression tests
assert the selected location and independent face/text axes. Position is now
user-selected; face/text orientation still requires confirmation on headset and
should be adjusted without moving this selected position.

User confirmed marker-13 placement is perfect and requested only a 90-degree
clockwise rotation of the wrist menu. Applied a local -PI/2 rotation about the
display's outward normal, preserving position `(-0.07,0,0.04)` and normal -X.
Updated orientation assertions: display right is controller-local -Z and display
up is -Y. Physical confirmation of the final text orientation remains pending.

Latest orientation adjustment: user requested moving back "45% counter clock wise",
interpreted explicitly as 45 degrees counter-clockwise from the preceding build.
Net display roll is now -PI/4 relative to the marker-13 baseline. Wrist position
and outward normal are unchanged; orientation tests assert the new diagonal axes.

Latest placement refinement: marker 13 should meet the watch's right edge rather
than its centre. Kept the calibrated basis/roll and moved its centre left by half
the 16 cm display width in display-local space. The anchor relation is now
`centre + basis.x * 0.08 == (-0.07,0,0.04)` in raw grip coordinates, covered by
the mounting regression. No independent rotation or vertical offset was added.

### Committed-work checkpoint: wristwatch confirmed (2026-10-20)

User confirmed the final right-edge-at-marker-13 placement and 45-degree net
clockwise display roll are perfect. Earlier feedback confirmed desktop movement
and restored menu cursor. Live desktop handover, independent sample streaming
and wristwatch desktop reveal have all received physical user confirmation.
The latest optimized release-signed DEV APK is installed on Quest
`2G0YC1ZF8P08QN`; all 40 GDScript scripts pass. Shader compilation, Python
application/lifecycle tests, native image-lease regression, Rust supervisor tests
and local asynchronous external-app capture were validated during this work.
This is not a completed stability/performance/audio/game-compatibility matrix.

On resumption check branch/worktree first: XR work belongs to
`feat/meteor-xr-streaming`, not the other agent's separate pairing worktree.
Host-local application selection is still the ignored `.build-cache/meteor-xr/application.json`
and currently selects HelloXR; private keys/config are not committed. The dedicated
DEV listener and device configuration need checking after any restart. No automatic
enrollment/app discovery, Windows integration or SteamVR/OpenVR support is implied.

Recommended next phase: split "runtime armed" from "launch selected application".
Keep the managed runtime/transport ready while the Sunshine desktop is in use,
publish a host-local launch environment for a foreground native OpenXR app,
and trigger the existing handover only from observed session activity plus a
decoded stereo frame. Preserve initial authorization; do not replace it with
unrestricted remote execution or globally change the user's active runtime.
Use the watch to reveal/hide desktop during XR and return on app session end.
Then test a real native OpenXR application, repeat app start/exit, cancellation,
headset standby and input-focus transitions before optimizing hidden desktop
work or extending runtime/session duration. XR audio, microphone/audio focus,
automatic product integration, packaging and cross-platform compatibility remain
separate outstanding work.

### Armed runtime / separate PC-side launch (2026-10-20)

WiVRn reference `docs/steamvr.md` confirms its OpenVR compatibility path uses
xrizer or OpenComposite, with `PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1` and
appropriate `VR_OVERRIDE`/sandbox visibility. VRChat is a compatibility target,
not ruled out by our OpenXR runtime. No translator or Steam configuration was
installed/changed by this step; integration/testing remains outstanding.

Added optional `"launch":"manual"` to host-local `application.json` (default
remains immediate). After runtime IPC readiness, this mode publishes a private,
generation-bound `application-ready.json` and waits up to 30 seconds for a local
launch request. `test/request_xr_application.py SESSION_DIRECTORY` publishes an
atomic, non-overwriting request containing only the matching generation/action;
the selected executable/arguments still come exclusively from trusted host config.
It launches inside the existing owned supervisor, not an untracked remote process.
Cancellation/timeout removes readiness; stale/malformed/repeated requests fail.

Host status `ready_for_application` is distinct from session-created/begun/frame
readiness. The headset keeps desktop visible in that state with a bounded wait;
session+decoded-frame still gates handover. Initial video producer attach and
client first encrypted record wait are now 45 seconds; ordinary per-frame I/O
remains 5 seconds. Existing total lease/receiver/runtime bounds are retained:
this is a bounded DEV arm/launch gate, not an indefinitely running product service.
Full automatic arbitrary-app discovery/Steam launch environment remains next.

Local GPU smoke: 3.02 seconds armed with no encoded frames, then 66 frames after
the PC-side launch, asynchronous 1024-eye/60-Hz-target/Touch profile. Short idle
sample for Monado process alone: 75.05 MiB RSS and 6.28% of one CPU core. This
excludes supervisor/Meteor/transport overhead, GPU memory/power and headset cost;
it is not an end-to-end performance result. Diagnostics:
`.build-cache/meteor-xr/external-smoke-7tl8jgfp/armed-idle.json`.
15 Python application/lifecycle tests and 53 Rust XR tests passed (four explicit
interop fixtures ignored); 40 GDScript tests passed. Python/Rust socket tests
require host socket permission. Physical arm/wait/launch test remains pending.

Streaming extension rebuilt using the current Release tree
`addons/nightfall-stream/build/android` and stripped before APK packaging. The
old root `build/android` cache failed compiler detection and was not used for the
artifact. Optimized Meteor rebuilt; ordinary Meteor must remain untouched when
updating the dedicated XR DEV listener. Local ignored application config now uses
manual launch; tests must trigger the PC-side helper within the bounded window.

Deployment: optimized release-signed DEV APK
`0.8.2-preview.1-dev+899cb2d-dirty`, code 802, installed on Quest
`2G0YC1ZF8P08QN`. SHA-256:
`9e65997f59463372cb0508800ad8890441f0b9707e63275c92e8b12db8f6e759`.
Dedicated updated listener is tool session 82218 at setup, same endpoint/pin;
normal Meteor unchanged. No XR acceptance or application launch was automated.
For physical test coordinate readiness with user before acceptance, then run the
local helper against the new session directory while its ready ticket exists.
Expect desktop to remain usable until application session and video become ready.

### Practical local launcher and compatibility scope (2026-10-20)

User confirmed welcome remained visible until the separate PC-side launch entered
XR. They did not start Sunshine or recheck the watch in that armed test; those
combinations remain unverified for the new flow (earlier immediate-launch tests
covered them). Do not upgrade this result to live-Sunshine/wristwatch validation.

Added `tools/meteor_xr.py` with `status`, `launch [--wait 0..120] [--session DIR]`
and `compat-check DIRECTORY`. No manual search for session directories is needed:
discovery chooses the sole live, unexpired, unrequested armed ticket. Multiple
live sessions are rejected, not silently chosen. Ticket expiry is exported by
the host and checked along with owner PID/generation before local publication.
The request remains a local generation+action, not remote command execution.

Host application config can now explicitly select `openvr_compat` and
`steam_runtime`. Validate the selected tool's `bin/linux64/vrclient.so` ELF identity;
apply VR_OVERRIDE, Steam OpenXR import and tool-only filesystem visibility to the
owned application child, not the runtime service, parent shell or global files.
No compatibility tool is selected for the current HelloXR sample.
The locally installed WiVRn Flatpak contains an xrizer binary that passed the
layout/ELF check. `readelf` shows standard C/C++ runtime dependencies; this is
not a dynamic-loading, Proton or game compatibility test. No tool was installed,
copied or globally registered. Full usage/limits:
`docs/development/meteor-xr-launcher.md`.

Validation: 17 Python application/lifecycle tests passed, including expired and
ambiguous discovery, immutable inherited environment, scoped Steam import and
ELF rejection. Actual armed local CLI → asynchronous GPU capture smoke passed
with 60 encoded frames, intentionally interrupted, no pre-launch encoding.
Diagnostics: `.build-cache/meteor-xr/external-smoke-744cimyq/`. No headset rebuild
or listener restart is needed for these host-script-only changes.

Next: integrate the real Steam `%command%`/Proton launch chain into the owned
launcher, preserving the private runtime/IPC environment through pressure-vessel,
and test xrizer with a real OpenVR application/VRChat. Merely launching a running
Steam client or setting an environment variable does not complete this step.
The current helper still launches the foreground application selected in local
host config; general Steam integration/automatic discovery are not yet claimed.

### Steam foreground command handoff implemented (2026-10-20)

Added `steam-options --app-id ID` (prints only) and `steam-run --app-id ID --
%command%` to the local launcher. New explicit host `launch:"steam"` mode binds
the readiness ticket/request to one configured app ID. Only this opt-in mode may
receive an argv/cwd and allowlisted Steam/Proton environment from the local
wrapper. The authenticated headset/control protocol still cannot supply commands.
Runtime/IPC/compatibility environment remains supervisor-owned; no arbitrary
environment or secrets are forwarded/dumped. Requests are atomic and bounded.

The runtime supervisor, not a background Steam client, launches and owns the
foreground chain supplied by Steam. The wrapper stays alive and returns the
game's recorded exit code. Wrapper disappearance cancels/reaps its owned child.
Generation/app-ID checks prevent stale or wrong-game outcome consumption. The
ordinary launch action is rejected for Steam profiles, with no fallback app.

Validation: 17 application/lifecycle Python tests plus three Steam-wrapper tests
passed. Tests cover app/generation binding, environment filtering, no shell
expansion, wrapper exit propagation and cancellation when wrapper owner ends.
Real GPU smoke through this wrapper/owned-runner path captured 64 HelloXR frames
with synthetic tracking, then intentionally interrupted and reported that result
to the wrapper. Diagnostics: `.build-cache/meteor-xr/external-smoke-6rlt08d9/`.
This did not run Steam, Proton, xrizer or VRChat. Host-script-only change; no
additional headset deployment or listener restart required.

Local inspection found installed VRChat at
`/run/media/system/GAMES/SteamLibrary/steamapps/common/VRChat` and Proton 11.0
requiring Steam Runtime 4. Installed Runtime 4 libc exports GLIBC_2.41, whereas
our Monado client requires GLIBC_2.38: a plausible runtime combination, not proof
of loading or container compatibility. Prepared ignored
`.build-cache/meteor-xr/application-vrchat.json` with app ID 438100 and the local
WiVRn Flatpak xrizer directory. It is NOT selected; tested HelloXR configuration
remains current. No game launch, global runtime edits, per-game Steam launch
options or Proton preferences have been changed.

Next physical gate requires reviewing/applying per-game Steam wrapper options,
selecting the prepared host profile and coordinating headset arming/game launch.
Preserve existing Steam options and do not edit Steam's live cached settings or
exit Steam without user coordination. Then validate actual pressure-vessel/Proton
runtime/IPC loading and xrizer graphics/input before claiming VRChat support.

### First Steam/VRChat attempts and probe-session fix (2026-10-20)

After the user exited Steam, applied the per-game wrapper for app 438100 while
preserving all existing launch flags and GE-Proton10-26-rtsp20. Selected the
prepared Steam host profile; saved both native HelloXR profile and original Steam
configuration under ignored `.build-cache/meteor-xr/` (private, not publishable).
No global runtime registration or other game configuration changed.

The first physical attempts reached the managed runtime: `service.log` records
clients named `steam` and `wineopenxr test instance`. Steam created, began, ended
and destroyed a temporary probe session. Headset logs at 13:37:03 and 13:37:20
then reported `XR-HANDOVER Stopping: XR application ended`, cancelling the owned
launch before game presentation. The newest VRChat output log was empty. This
confirms premature handover cancellation, not functional VRChat compatibility.

Changed WAITING handover policy to tolerate `session_ended` before video-backed
handover. The existing startup deadline continues without resetting on session
churn. Supervisor `completed`/`cancelled`/`failed` remain terminal; session end
during DRAINING/ACTIVE still stops and restores the desktop. All 40 GDScript
tests passed, including repeated startup probes, bounded timeout, post-activation
session closure and supervisor terminal outcomes. Optimized DEV deployment and
another physical VRChat attempt are the next gate; Steam/Proton/xrizer and game
compatibility must still be established.

### VRChat world-load crash: seven layers, not Proton (2026-10-21)

The user intentionally returned to known-working GE-Proton10-26-rtsp20 after
trying a newer Proton. Keep that selection unchanged. Sessions
`1792521934591115225-1086187`, `1792524133015683556-1086187`, and
`1792524198599780158-1086187` reached real encoded game frames and then logged
`METEOR_CAPTURE_FAILED`. This was not an intentional short-test completion.

Existing core dump PID 2622604 confirms SIGABRT in
`null_compositor_layer_commit`. Offline disassembly/core inspection recovered
the exact failing accumulator: **seven layers: one projection (type 0), followed
by six quads (type 2)**. Projection views are 1024 square. The single-layer guard
in `test/monado_server_capture.h` rejects the entire frame before encoding it.
This confirms the host failure independently of the disappearing xrizer popup.
The popup's exact panic message is not yet captured; do not claim an independent
xrizer defect or change Proton to address this compositor restriction.

Added structural failure diagnostics (`METEOR_CAPTURE_LAYOUT/LAYER/QUAD/VIEW`)
before the diagnostic abort and immediate `application-live.log` output for
owned external applications. Previously app stdout/stderr lived in supervisor
pipes until normal return; group termination could lose the actual xrizer error.
Live output now survives interruption/timeouts, without logging environment or
command arrays. Python application/lifecycle tests: 19 passed. Host Monado
rebuilt successfully in the existing offline container. This is **diagnostics,
not the composition fix**; no new headset APK is required for these host changes.

Next implementation: real GPU composition of projection plus quad overlays
before NVENC. Do not bypass the single-layer guard by dropping quads: game UI
would silently disappear. Preserve submitted order, per-eye visibility, poses,
view/reference-space handling, subrect/array slice, alpha/premultiplication,
transfer function and swapchain synchronization. Async jobs must retain both
overlay swapchain references and image-use leases until GPU completion, including
replaced jobs and shutdown. Exercise a local projection-plus-six-quads fixture
through the real encoder before another physical VRChat attempt. Keep unsupported
layer types explicit; do not claim a general compositor from a projection-only
or projection-plus-quad test. Production session duration is also still bounded.

The external-app smoke helper now creates its own HelloXR profile instead of
inheriting `application.json`; it must never launch the user's selected Steam
game as a side effect of a diagnostic test.

Post-change real-GPU smoke passed through the Steam wrapper using that isolated
native HelloXR profile: 65 captured frames, then intentional interruption and
wrapper exit propagation. Diagnostics: `.build-cache/meteor-xr/external-smoke-g7yg3b27/`;
`application-live.log` exists and contains the sample output. This validates the
logging/runner changes only, not multi-layer composition or VRChat world entry.

### Projection + quad GPU composition implemented (2026-10-21)

Replaced the one-layer-only encoder intake with an explicit supported sequence:
one stereo projection (optionally depth-bearing colour) followed by up to 127
quads in submitted order. No quad is silently dropped; other layer sequences,
unsupported formats/MSAA and advanced blend/depth flags are rejected explicitly.
This remains a limited compositor, not arbitrary OpenXR composition support.

The NVENC bridge now packs the projection as before, then draws the quads into
the exportable Vulkan image using a load/store colour render pass before CUDA/
NVENC consumes it. No host pixel readback in the streaming path. Supports eye
visibility, view/world poses, perspective clipping, atlas subrects, array slices,
Y flip, opaque/straight/premultiplied alpha and colour scale/bias. SRGB attachments
and sampled image views retain hardware transfer functions. The shaders are built
offline with the runtime; source-hash stamps prevent stale generated shaders
being accepted by the helper cache. Math and projection-only tests remain separate.

Async jobs snapshot overlay data and retain swapchain objects **and image-use
leases** until GPU work completes; replaced jobs also release them. The initial
shared-atlas test exposed missing acquisition in `multi_compositor_layer_quad`:
the common slot cleanup was releasing images that only the worker had reserved.
Added matching acquisition at submission, balancing slot and worker ownership.
The regression now proves 192 acquisitions and 192 releases with shared images.

Real-GPU seven-layer test passed:
`.build-cache/meteor-xr/quad-smoke-1s1321mc/`. One stereo projection plus six quads
sharing one texture, left-only/right-only/both-eye visibility, straight-alpha
blending. Eleven encoded/locally transferred frames decoded; independent sample
checks at all twelve per-eye quad centres matched expected blended/background
pixels. Raw queue replaced one unencoded job and drained successfully. Encoder
released exactly once. Warm pack/compose median 0.244ms, max 0.702ms in this tiny
256-square fixture: **not** a VRChat/1024-square headset performance measurement.

Projection-only Steam wrapper regression also passed: 62 native HelloXR frames,
then deliberate interruption (`external-smoke-m4el8kbn`). No real Steam/game
launch in either smoke. Host runtime/shaders/helper rebuilt; new sessions load
them without replacing/restarting normal Meteor. No headset APK changes needed.
Next physical gate: same known-working GE-Proton10-26-rtsp20, arm Nightfall, start
VRChat in VR mode and check world entry plus overlays/controllers. Existing DEV
session time limits (90s client / 100s host) remain; VRChat compatibility is not
confirmed solely by the synthetic overlay test.

### Overlay-only loading frames implemented (2026-10-21)

Physical session `1792564460244432895-1086187` got past projection-plus-six-quads
but aborted on frame 277: **eight quads, no projection**. Six quads were 128x128
with flags 6, two were 512x512 with flags 22 (colour scale/bias). Persistent
`application-live.log` captured xrizer's `xrSyncActions` runtime-failure panic
after the host disappeared. This confirms a second unsupported composition case,
not a new Proton or original xrizer failure; leave the user's GE selection alone.

The capture path now also accepts quad-only lists, up to 128 quads. It obtains
current world-space eye poses/FOV from the tracked HMD at the submitted timestamp
and creates metadata only (no fake/borrowed projection texture). The GPU clears
the stereo target to opaque black and renders the submitted quads in order.
Projection images are neither referenced nor image-leased on these frames. Async
jobs still own all actual overlay images. When projection returns, normal copying
resumes; no old image or old head pose is used as a loading-screen backdrop.
Existing source format metadata is retained across projection-less gaps; fresh
overlay-only startup uses the existing RGBA8 default. Mid-session arbitrary
projection source-format changes remain subject to the existing bridge checks.

Expanded regression explicitly starts quad-only and executes
`quad-only -> projection+quads -> quad-only -> projection+quads` using eight
shared-texture overlays. Real Monado/Vulkan/NVENC/loopback test passed in
`.build-cache/meteor-xr/quad-smoke-q01xh_vk/`: 22 decoded frames, all four phases
observed, 352 per-eye overlay-centre colour checks passed, 424 image reservations
acquired/released and clean encoder drain. Checks distinguish cleared black from
the old projection backdrop and verify left/right visibility and alpha blending.
The diagnostic JSON ledger now marks projection presence for this verification;
the headset transport is unchanged. Host runtime/fixture/helper rebuilt; no new
headset APK or normal Meteor restart required. Actual VRChat world entry is still
the next physical gate, with the existing bounded DEV session duration unchanged.

Post-change projection-only wrapper smoke: 64 captured HelloXR frames followed
by intentional interruption (`external-smoke-qa_dbhiz`). All 69 XR Python tests
passed outside the sandbox (local socket tests require that access).

### Static-overlay clock fix (2026-10-21)

Session `1792564968499189189-1086187` got further into loading but failed with
ten quads (including two 800x600). This was within supported composition limits,
with no worker/format rejection. Offline core PID 425976 proved the actual
problem: compositor display time `348559061147028`, first overlay submit time
`348558794480372` (266.667ms old), and last queued/encoded time still equal to
that old overlay timestamp. The live tracking bridge intentionally refuses queries
more than 250ms from its current sample. Retained loading overlays were being
mistaken for the clock at which to locate the current head pose.

Overlay-only capture now uses `layer_accum.data.display_time_ns`, the compositor's
current display clock. It continuously re-renders retained static overlays with
fresh tracking while the game loads. No stale tracking extrapolation is enabled.
A transient unavailable pose skips that frame, without fabricating a pose or
aborting the app; existing transport/lifecycle timeout policies remain active.
When projection rendering returns with a source timestamp older than an already
rendered loading frame, skip it (like a duplicate), rather than aborting or
inserting a non-monotonic frame into the video stream. Source projection poses
and timestamps are otherwise preserved. Added a native timestamp-policy test
using the exact crash values, included in helper-cache validation.

Extended the eight-quad real-GPU regression with a 650ms pause after submitting
static loading overlays, while its independent tracking publisher keeps running.
Passed in `.build-cache/meteor-xr/quad-smoke-awp2uzfq/`: 63 encoded/transferred/
decoded frames, all four overlay/projection phases, 15 frames observed late in
the static hold (400–650ms after submit), 1008 pixel checks and 806/806 balanced
image reservations. This exercises the actual stale-overlay failure, not merely
an increased layer-count cap. Host runtime rebuilt; no new headset APK required.
Actual VRChat world entry remains the physical gate, with Proton unchanged.

### Live loading-stall instrumentation prepared (2026-10-21)

Session `1792565679126846534-1086187` showed no capture failure: 3021 encoded
frames spanning ~51.6s, transitioning to ten quad-only loading overlays without
returning to a projection. VRChat logged room joined, scene finalized and players
spawned at 08:55:10, but stayed on loading until client/session cancellation at
08:55:47. Final delivery failure occurred during shutdown; do not mistake that
for an earlier capture crash. Missing headset logs mean the precise cancellation
trigger is not yet established (do not assert the 90s deadline caused it).

Prepared opt-in automatic host diagnostics for the next test: local ignored
`process-diagnostics.enabled` marker is ON. External app supervision samples
owned process/thread wait states/CPU counters to private `process-waits.jsonl`
every 3s. Runtime swapchain acquisition logs now record begin/wakeup, PID/TID,
image/reservation count and elapsed time. This avoids attaching a debugger to
VRChat/anti-cheat, stopping the process, or capturing memory/argv/environment.
These are kernel wait channels, not full userspace stacks; conclusions must be
correlated with swapchain events, game output and render-phase logs. Marker OFF
disables the optional diagnostics; no global/Proton settings or timeouts changed.

Host rebuilt in offline container. All 73 XR Python tests passed (four new sampler
tests cover parsing, owned-tree scope, CPU deltas, PID reuse and access failure).
Real GPU transition/650ms loading-pause smoke passed with diagnostics enabled in
`quad-smoke-5mtsmtju`: process snapshot present (two owned processes), swapchain
wait records present, encoder/overlay pixel/drain checks still pass. No APK
update needed. Next user gate: arm and launch VRChat normally; if it sticks on
joining, leave it running and report promptly so the live samples cover the stall.

### Apparent joining stall is a Wine codec crash (2026-10-21)

Session `1792566576974148453-1086187` captured the missing evidence. Host remained
live and drained 2940 encoded frames without capture failure. Twenty owned-process
snapshots showed VRChat threads largely waiting and UnityCrashHandler becoming
CPU-active. VRChat wrote a minidump at
`AppData/Local/Temp/VRChat/VRChat/Crashes/Crash_2026-10-21_071009375/crash.dmp`.
An earlier joining attempt also left `Crash_2026-10-21_065512765/crash.dmp`.

`application-live.log` line 343 explicitly reports:
`wine: Call from 00006FFFFFC0D217 to unimplemented function winedmo.dll.winedmo_create_color_converter, aborting`.
Offline minidump inspection (no live debugger) found exception 0x80000100 in
kernelbase.dll; its diagnostic arguments point into iyuv_32.dll and resolve to
`winedmo.dll` / `winedmo_create_color_converter` in the installed image.

Concrete mixed-prefix evidence: the launch log selects GE-Proton10-26-rtsp20,
but prefix `drive_c/windows/system32/iyuv_32.dll` is a symlink into
GE-Proton11-7-x86_64 (dated when the user tried that version). The selected GE10
tree contains winedmo.dll but no iyuv_32.dll. Thus the leftover newer codec is
requesting a newer Wine internal export from an older runtime. The on-headset
Joining display is retained loading overlays after the game fault, not evidence
of another compositor crash or a completed world entry.

Next: with Steam/game fully closed, back up and repair/recreate a consistently
versioned per-game Proton prefix. Preserve VRChat data/settings/logins and current
per-game launch options; do not delete the prefix or change Proton silently.
No prefix modifications have been made. Get user direction before that external
state change. Keep optional diagnostics enabled for the validating launch.

### World entry, floor origin and five-minute testing window (2026-10-21)

User switched to newer Proton and confirmed entering VRChat world. Keep their
selection. Session `1792566980057323273-1086187` recorded eye Y from -0.304 to
+0.054m: Quest LOCAL's eye-level origin was being adopted as the desktop floor,
explaining appearing on the ground. Native Meteor tracking now creates STAGE
instead. Head, controllers, wristwatch and returned projection all use that same
origin; no arbitrary height offset. Fail clearly if STAGE unavailable. Historical
`quest_local` wire member/bit retained and documented as adopted client origin;
new matching client/host and fresh session required.

Apparent menu crash coincided with DEV limit: session created 09:16:20.057,
service ended ~89.96s later. Tracking disconnected before delivery failure and
final capture error. Supports timeout, not an unsupported menu frame, as trigger.
Retest the short menu press physically; B/Y held one second still intentionally
exits the DEV session.

Long profile now: client 300s, host supervisor 315s, accepted control lease and
Steam result wait 360s, 18,000 upstream fixture frames / 300s owned-app timeout.
Short and arming windows unchanged. Also found and increased independent
4096-frame sender/Rust/native-receiver cap to 32768 on all ends; otherwise 60Hz
could stop early despite new timers. Boundary tests still reject exceeding cap.
Standby now logs explicit timeout reason/elapsed/limit.

All 40 GDScript scripts passed, including 90s survival/300s bounded stop tests;
53 Rust XR tests passed (4 optional interop tests ignored). Standalone native
wire/tracking/view tests passed. Full native test wrapper unavailable due to
missing FFmpeg development packages; no host packages installed. Optimized,
release-signed DEV APK built/installed with native XR rebuilt, no skip flag.
Release Meteor rebuilt; only dedicated listener PID 1086187 stopped/restarted
(new tool session 54843, same port/pin/allowlist); normal Meteor untouched.
Changes uncommitted on `feat/meteor-xr-streaming`.

Next physical gate: real standing/seated/crouching height, controller placement,
wristwatch/menu alignment, short game menu press, survival past 90s. Expect stop
at five minutes from arming; this is not yet an unbounded production game session.

Final validation also passed all 73 XR Python tests and rebuilt Monado's native
sender (not only Rust). GPU overlay/loading regression passed with that sender:
`quad-smoke-yzz20e0q`. Installed APK SHA256:
`26fc01cb93639133cb245b2159da5dcaf008f66fd9ffbfba50cdc8cfe913a02f`.
