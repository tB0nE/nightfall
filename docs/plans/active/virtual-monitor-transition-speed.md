# Faster virtual-monitor transitions

Branch: `codex/virtual-monitor-transition-speed`, from `main` after PR #82.
Scope: shorten transitions safely on all clients; investigate issue #72's
monitor disappearance without assuming a Quest 2 hardware cause.

## Findings

The client waited 0.8 seconds after explicit Apply, then 4 seconds for ordinary
virtual-count changes or 15 seconds for a full host restart, plus the normal
0.5-second reconnect settling. Host cancellation was only treated as answered,
not validated as successful: GameStream can encode permission/busy errors in
HTTP-200 XML. Separately, the runtime applied-count cache started at zero even
when a saved virtual count had already been launched successfully. The first
layout-only Apply could therefore trigger an unnecessary monitor restart.
The layout-only path also rebuilt from a staged layout with virtual placeholders
removed; without a reconnect, no new host manifest would restore the deleted
virtual screens. It now applies positions to the existing actual screens only.

The current managed host's paired `/cancel` handler synchronously terminates
RTSP session threads and cleans idle virtual displays before writing its reply.
That acknowledgement is the ordinary transition readiness signal. Virtual
outputs for the new session are then created during launch; do not wait for
them to exist before sending that launch.

## Implementation

- Explicit monitor Apply has no extra cycling debounce. Regular FPS/resolution
  cycling retains its existing debounce.
- Ordinary virtual changes wait for a **successful paired cancellation XML**,
  not a fixed 4-second sleep. Explicit rejection fails rather than launching
  against an uncleared session. Network/busy responses retry within a deadline.
- Native renderer deactivation, clearing old shader textures, two frame yields,
  synchronous decoder stop and the existing **0.5-second reconnect settling**
  remain. This is not a sub-100-ms transition claim.
- Full-host-restart fallback returns a process-instance identifier. Meteor's
  read-only `/meteor/host-status` lets the client wait for a different running
  process, then confirm actual paired-host readiness with cancellation. Process
  liveness alone does not prove that HTTPS/capture is ready.
- Windows fallback waits for actual old-host exit before restarting, rather
  than sleeping two seconds and potentially racing a still-running process.
- Older Meteor versions lacking the restart-status protocol retain their
  conservative 15-second full-restart fallback. Normal changes still benefit.
- One restart worker serializes cancel/launch work. Newer requests supersede
  stale preflight work; host changes or explicit disconnect prevent relaunch.
  Outstanding cancellation is drained before a replacement can launch.
- Virtual-count POSTs are serialized and intermediate queued counts coalesced.
  A parallel FPS/codec request waits for configuration work to settle; it must
  retain a required fresh-session launch rather than resuming old virtuals.
- A successful initial stream synchronizes the applied virtual count, so an
  unchanged-count layout Apply does not invent a host configuration change.
- The existing pre-launch capture plan uses the same frozen monitor selection
  as the launch. Late obsolete plan replies cannot mutate the current size.
  Invalid/unavailable plans retain compatibility fallback and the existing
  bounded correction retry; genuine host dimension changes can still need it.

No protocol replacement, extra video stream, display preallocation or persistent
virtual-output pool is introduced. The rare Windows host-restart improvement
needs a new Meteor build; the ordinary client improvement uses the existing host.

## Timings

`[MONITOR-TIMING]` logs id, stage and elapsed milliseconds from Apply:
configuration reply, client drain/stop, replacement process (when needed),
paired host-session end, reconnect-ready, capture plan, launch request/response,
stream-start and first submitted video frame. Old-stream frames cannot complete
these timings. First submitted frame is **not** a measured photon/display time.
`stream_manager.monitor_transition` keeps the latest record for dev inspection.

## Validation and acceptance

Regression tests exercise cancellation XML, old/stopped/replacement instances,
strict frame dimensions, serialized cancellation, superseding requests,
disconnect during a wait, explicit permission rejection, saved-count sync,
POST coalescing, stale plan replies and timing arming. The Rust test covers the
actual read-only HTTP endpoint as well as instance semantics.

Remaining live checks:

- Add/remove virtual monitors and compare stage timings, without changing any
  other setting. Restore the initial count afterward.
- Change only screen layout with an already active saved virtual count: no
  host restart or disappearing video should occur.
- Apply rapid successive counts; only the latest desired layout should remain.
- Disconnect during a transition; the client must stay disconnected.
- Check pointer edges, audio, browser coexistence and XR round trips afterward.
- Repeat on Windows, including config-reload fallback; obtain Quest 2 feedback.

Use release-optimized DEV builds per BUILD.md. Do not use gamescope/Vulkan UI
probes on this workstation: prior tests reset its graphics session.

## Current checkpoint

The release-optimized DEV APK was built and installed in place. The matching
optimized Meteor is running, and its managed-host liveness endpoint was checked
successfully. Existing settings and pairings were retained. Full unit verification
passed 200 Rust tests; the final GDScript suite, including layout-only preservation
and concurrent configuration tests, passed. No live transition latency has been
measured yet. The headset paused during desk checks; do not substitute a welcome
screen/bridge check for a virtual-monitor acceptance test. Windows fallback logic
has not been exercised on Windows in this Linux session.
