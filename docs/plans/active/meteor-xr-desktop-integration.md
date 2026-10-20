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
