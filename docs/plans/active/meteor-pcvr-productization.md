# Meteor PCVR: outstanding work and implementation order

## Current checkpoint — 26 October 2026

Use the [branch review](meteor-branch-review-20261026.md) for current capabilities,
validation and outstanding work. Alyx and VRChat have since been tested, the VR
app library is implemented, and the fixed gameplay-duration limits were removed.
Further depth optimization is paused; resume Linux XR validation and startup/
packaging integration. Earlier checkpoints below are historical, including their
five-minute limits and unchecked phase lists.

## Historical handoff: core layer expansion ready for application testing

The core [layer expansion](meteor-xr-layer-expansion.md) is now implemented:
cylinders, complete colour scale/bias, ordered projection/overlay stacks and
multiple projections. Independent source crops/resolutions, rotated FOVs and
per-layer orientation are sampled into the negotiated output. The first
projection defines output pose/FOV. Overlay-only frames retain current tracking.

General stacks clear and draw into the existing GPU output image. Ordinary
opaque projections, including identity colour-transform chains, retain direct
copy. Local bridge ABI 4 validates the descriptor stride. Each projection adds
two eye-specific descriptors and retained jobs lease both source images. Up to
128 submitted layers fit a bounded 256-descriptor local array. No headset
layer, network protocol or APK change was required.

Validation: ten H.264/HEVC GPU matrix cases, ten ordered/colour fixture modes,
and 38 Python launch/lifecycle/cache tests passed. Separate ordered-stack runs
passed RGBA sRGB and BGRA sRGB conversion plus 2064×2208-per-eye HEVC output.
The pixel oracle covers straight/premultiplied alpha, clamping, source scaling,
rotated narrower FOVs, overlay ordering and return to direct copy. Image leases,
encoder drain and invalid-frame recovery are checked in the same runs.

The final BGRA sRGB/native-resolution run also passed the new head-locked
projection mode. Tracked head pose is explicitly retained with each encode job
and used to resolve view-space layers independently from application cameras.
Packing/composition wall-time samples are saved in
`.build-cache/meteor-xr/layer-expansion-timing.json`: medians 381.5 us for copy
(four samples), 497 us for a transformed projection (eight), and 578 us for the
mixed stack (21). These are CPU wall times including GPU queue completion, not
isolated GPU timings or a controlled sustained-game performance comparison.

### Physical test handoff

1. Launch Alyx with the existing Meteor Steam wrapper; check loading, gameplay,
   menus/fades and return to desktop on exit. Launch again.
2. Repeat a short VRChat session: world entry, controller menus, wristwatch,
   desktop/PCVR menu switching and exit/relaunch.
3. Watch responsiveness at the usual resolution/bitrate; compare sharpening,
   live bitrate and foveation after basic game startup is confirmed.

The existing five-minute DEV limit remains. Longer standby and sustained-play
testing must wait for bounded diagnostics/recording and coordinated limit
removal; do not misdiagnose that timeout as a game crash.

### Work deliberately outside this layer milestone

- Optional Equirect1/cubemap support, depth-aware composition, advanced blend
  extensions and application-requested passthrough. Local Quest passthrough is
  unaffected; XR still deliberately uses an opaque environment.
- Dedicated XR audio without Sunshine, microphone forwarding, production
  packaging/discovery and Windows support.
- Independent CTS interactive testing and broader geometry/format stress cases.

Historical checkpoints below describe earlier states and are superseded by this
handoff.

## 2026-10-24: cylinders implemented and enabled

The first expansion milestone adds tagged layer metadata, ABI version/stride
checks and a persistent GPU parameter buffer, separating geometry from colour
data within the existing 128-byte push-constant limit. Cylinders now render in
the existing composition pass with balanced swapchain image leases. The
projection-only copy path is unchanged.

The compatibility suite now passes eight H.264/HEVC cases: quads, panoramas,
patterned finite cylinders, and zero/infinite-radius cylinder variants. Actual
decoded UV positions and transparency are checked in both eyes. A separate
2064×2208-per-eye HEVC cylinder run also passed. The high-resolution fixture
uses a bounded 256×256 overlay source to avoid CPU test-image generation
stalling tracking; the encoded output remains native resolution.

Host runtime rebuilt in place; no APK is needed for this addition. Full colour
transforms and flexible/multiple projection ordering remain next. Historical
capability-restriction notes below describe earlier states.

## Next: expand layer support

Follow the [layer expansion plan](meteor-xr-layer-expansion.md): add cylinders,
complete colour transforms and ordered/multiple projection composition using
WiVRn and Monado as references. The existing restrictions are temporary safety
measures. Re-enable capabilities as implementations pass the expanded GPU
compatibility and performance checks. Equirect1 and cubemaps are feasible
optional follow-ups; depth-aware composition and passthrough remain separate.

## 2026-10-24: advertised layer contract and rejection recovery

Added the [layer compatibility inventory and executable GPU matrix](meteor-xr-layer-compatibility.md).
The isolated runtime now advertises only the layer extensions the capture path
can consistently render. Cylinder, depth metadata and colour-transform
extensions are explicitly disabled, alongside the already unsupported types.
OpenXR submissions are checked before IPC; invalid ordering, repeated
projections or mismatched dimensions return a descriptive layer error instead
of reaching a fatal compositor rejection. Unexpected capture failures now use
a marker/error and supervised cleanup rather than `abort()` in the capture hook.

All four H.264/HEVC quad/panorama GPU cases passed, including seven rejected
submissions followed immediately by valid frames in the same sessions. The
host runtime was rebuilt in place; no APK or normal Meteor restart is required.
Game-specific Alyx loading/gameplay remains the next physical check.

## 2026-10-24: Half-Life: Alyx panoramic loading layer

The first Alyx attempt reached a focused XR session and controller discovery,
then submitted `XRT_LAYER_EQUIRECT2` (type 6) alone. Our capture path only
accepted projection/quad layers and aborted. xrizer's subsequent
`ERROR_INSTANCE_LOST` panic was downstream of that compositor failure; the
sound heard during startup is consistent with the game having started.
Evidence: session `1792796603339493046-78375`, `service.log` capture-layout
failure and `application-live.log` runtime-loss panic. This was not the
five-minute cap, supersampling, or a Steam launch-selection failure.

The host compositor now accepts equirect2 layers alongside quads and
projection. Panoramas use fullscreen per-eye rays transformed into layer space,
angular texture mapping, optional finite-radius sphere intersection, submitted
subrect/array slice, eye visibility, alpha and Y flip. They use the existing
GPU composition pass; no headset layer or APK change is required. Swapchain
images are leased at multi-compositor submission and through retained encode
jobs, then released on retirement. Unsupported panorama colour transforms
remain an explicit rejection rather than being silently misrendered.

Validation: isolated runtime rebuilt; projection/panorama ray math and
panoramic image-reference balancing passed. A real Vulkan/HEVC encode/decode
fixture passed equirect2-only loading frames in both eyes, alpha composition,
projection transitions, a 650 ms static loading hold and image/encoder drain.
Full Alyx loading/gameplay still requires the user's next physical launch.

## 2026-10-24: live foveated encoding

Foveated Encode now changes during an active XR session. The saved preference
still controls the next session's initial value. The authenticated control loop
coalesces rapid toggles and submits a session-bound request on its 500 ms tick;
the encoder consumes it between frames and acknowledges the applied value.
Pending/applied status appears alongside the live bitrate message. Invalid or
inactive-session requests cannot alter another session or stop its stream.

NVENC is initialized with delta-QP-map capability for both initial settings.
On uses the existing fixed-centre map; Off supplies a zero-delta map. This
avoids codec reinitialization, IDRs, resolution changes and extra headset work.
AQ remains disabled for QP-map compatibility in either state; the HEVC block
size remains 32. The two maps are reused rather than generated each frame.
This is centre-priority quality allocation, not eye-tracked or spatial foveation.

Validation: Rust XR suite (61 passed, four ignored), full GDScript suite,
session-authorization regression, native latest-command/acknowledgement test,
and real GPU encode/decode composition tests. HEVC exercised Off→On→Off→On→Off
alongside live bitrate changes; H.264 exercised switching from initially On.
Both retained stereo composition, decoded video and clean image/encoder drain.
Headset visual comparison of live switching remains the next user check.

The reboot stopped the dedicated XR listener; restart only that listener using
the updated release binary. Keep the normal Meteor service running.

Updated 2026-10-21. Branch: `feat/meteor-xr-streaming`.
This is the current forward plan; historical evidence and test results remain in
`meteor-xr-desktop-integration.md`. Do not confuse planned controls with supported
runtime capabilities.

## Working baseline

Linux managed Monado runtime, authenticated Meteor transport, hardware encoding,
head/controller tracking, projection plus quad composition, decoded-frame-gated
desktop handover and wristwatch desktop visibility are implemented. User confirmed
VRChat world entry, movement, and desktop/menu interaction. Preserve the selected
Proton version and calibrated watch placement. Recent fixes remain uncommitted;
checkpoint deliberately, without including ignored caches or private logs/keys.

Current development constraints: five-minute long session; 512/1024 square pixels
per eye negotiated by the client; 20/60 FPS profiles, long profile requires 60;
H.264/NVENC, bitrate computed in encoder (64 Mbps at 1024 per eye). These are not
the finished product limits. Video FPS and physical headset Hz are distinct.

## Phase 1: dedicated PCVR settings presentation

- [ ] Reuse existing settings viewport/panel: no permanent compositor layer.
- [ ] Add green PCVR toolbar link only during active XR; replace complete menu
      content, rather than adding another ordinary settings tab.
- [ ] Matching Desktop link only with connected desktop stream. Switching menu
      type must not toggle desktop visibility.
- [ ] Wristwatch gear beside screen button opens PCVR settings independently of
      desktop visibility. Preserve calibrated anchor/orientation.
- [ ] Separate menu visibility/focus from desktop visibility in handover logic;
      closing settings restores previous view. Keep head tracking continuous.
- [ ] Suppress game actions while interacting, release held actions on focus
      changes, and require release before resuming game input.
- [ ] Explicit Exit PCVR restores desktop/welcome. Hide irrelevant app-exit,
      disconnect and desktop-settings actions in PCVR menu.
- [ ] Remove stale PCVR menu state automatically on stop/failure.

## Phase 2: actual configuration, not decorative controls

- [ ] Persistent bounded per-eye resolution, bitrate in Mbps, stream FPS settings.
- [ ] Extend authenticated negotiation, validation, runtime environment/bridge and
      actual encoder configuration together. Log requested and effective values.
- [ ] Preserve working defaults; clearly label next-session application. Do not
      unexpectedly restart games or silently promise dynamic resolution.
- [ ] Display effective FPS, bitrate, drops and measured latency where available;
      unavailable measurements must not be presented as zero latency.
- [ ] Validate higher resolution/rate profiles end to end before offering them.
- [ ] Keep codec, encoder, foveation, half-rate and sharpening out of user-facing
      controls until those features genuinely work.

WiVRn reference: local `.build-cache/meteor-xr/WiVRn/client/scenes/gui_settings.cpp`
and `dashboard/qml/SettingsPage.qml`. Useful concepts: per-eye render scale,
preferred refresh, bitrate, foveation, half-rate and OpenXR post-processing.
Reference designs are not a claim that our transport implements these features.

## Phase 3: desktop timing coordination

- [ ] PCVR owns the single physical headset refresh rate while active; negotiate
      supported hardware rates, rather than treating 60 video FPS as 60 Hz.
- [ ] Temporarily override Sunshine desktop stream FPS to match PCVR stream FPS.
- [ ] Disable desktop FPS/refresh controls with explanatory tooltip during XR.
- [ ] Leave desktop bitrate and resolution independently configurable.
- [ ] Preserve saved desktop preferences; restore effective settings on all exit,
      cancellation and failure paths. Never persist transient overrides.
- [ ] Coordinate any required Sunshine restart during entry, not mid-game;
      avoid restart loops, stale asynchronous callbacks and input leakage.

## Phase 4: usable session lifecycle and recovery

- [ ] Remove five-minute gameplay limit after explicit exit and cleanup tests;
      retain bounded startup, connection and failure watchdogs.
- [ ] Audit independent frame-count, lease and application-supervisor limits.
- [ ] Test game exit/crash, network loss, host shutdown, receiver failure,
      cancellation during startup, repeated entry and reconnect.
- [ ] Test headset standby/resume, controller loss, recenter, boundary changes,
      seated/standing/crouching height and wrist/menu alignment.
- [ ] Replace or clearly document DEV B/Y-hold exit so normal game input cannot
      unexpectedly terminate production sessions.

## Phase 5: audio, compatibility, performance and packaging

- [ ] XR game audio path, including desktop/XR routing and no duplicate playback.
- [ ] Headset microphone to host for VRChat; assess reuse of existing microphone
      transport without assuming the host audio-device path is already solved.
- [ ] More OpenXR/OpenVR-via-compat applications and controller binding coverage.
      Current projection/quad support is not general layer-type compatibility.
- [ ] Sustained FPS, latency, encode/decode, network, drops, GPU and thermal tests.
- [ ] Turn private DEV diagnostics off by default; retain opt-in useful failures.
- [ ] Meteor-managed runtime installation, application launch and user-friendly
      authentication: no manual collection of development scripts/services.
- [ ] Windows runtime/encoding/application-launch port after Linux baseline.
- [ ] License/dependency distribution review, documentation and release gates.

## Immediate implementation and verification

Start with the desktop-accessible PCVR page and explicit exit using existing UI.
Next decouple presentation/focus, add watch gear, then wire actual configuration
and desktop timing. Do not combine all stages into one untestable change.

Initial implementation: desktop-accessible replacement page, conditional green
PCVR/Desktop link, received-frame counter, explicit Exit PCVR and hiding unrelated
toolbar actions are implemented in `ui_controller.gd`. Existing viewport is reused.
Watch gear/independent menu presentation are now implemented too: the existing
watch face has separate monitor and gear hit regions; menu-only mode suppresses
desktop visual leaves/collisions, keeps video presentation suspended, and runs
only the pointer/panel update path. Closing or stopping restores temporary
visibility/collision changes. Hardware keyboard/gamepad events are not forwarded
to the hidden desktop. Head tracking stays continuous and game actions remain
neutral while settings have focus. Real settings/timing overrides remain next.
An optimized release-signed DEV build with native XR rebuilt is deployed for the
first physical UI check; physical confirmation is still outstanding.

### Resolution/bitrate increment (2026-10-21)

Implemented next-session video preferences in `user://pcvr_stream.cfg`, separate
from host identity/config and saved desktop settings. Resolution cycles 512/1024
pixels per eye; unset retains existing host profile. Bitrate cycles Auto,
16/32/48/64/80/100/120/160 Mbps. Auto preserves the historical formula (16 Mbps
at 512 per eye, 64 Mbps at 1024); it is not adaptive bitrate/network estimation.
The PCVR page labels these as next-session settings, not effective live values.

Non-Auto bitrate is sent through authenticated `configure_video` before the offer.
Host accepts 0 or 8..160 Mbps, rejects changes once a session exists, and snapshots
the selection into the accepted profile. Rust passes it into the scoped runtime;
Python validates/forwards it and NVENC receives explicit CBR average/max bitrate.
Encoder logs `METEOR_VIDEO_CONFIG eye_size=... bitrate_bps=...`. Older host builds
must be updated to understand non-Auto configuration. No active-session mutation.

Validation: all GDScript test scripts passed, including persistence, invalid
preferences and cycling. 54 Rust XR tests passed / 4 optional tests ignored;
73 XR Python tests passed; native bitrate parser bounds tests passed. Real GPU
quad/loading/encode/decode smoke `quad-smoke-l6adkj7u` confirmed explicit 32 Mbps
reached NVENC, with stereo/alpha/transition/drain checks passing.

Optimized release-signed DEV APK built and installed. Release host rebuilt and
only verified dedicated XR listener PID 604283 was terminated/replaced (tool
session 19612, same port/pin/allowlist). Normal Meteor services untouched.
Native capture service ABI unchanged; source-fingerprinted encoder helper rebuilt
and exercised in smoke. No commits made in this increment.

Still next: physical menu/settings check, supported-rate implementation and
desktop timing coordination, effective negotiated-profile/telemetry reporting,
then safe removal of the five-minute session cap. No new frame-rate control is
exposed yet: the long profile remains 60 FPS, distinct from headset display Hz.

### Desktop timing coordination increment (2026-10-21)

Implemented transient `PCVRTimingPolicy`, owned by SettingsController. The
authenticated offer's FPS is retained on the client and adopted when handover is
armed. Desktop launch options, decoder configuration and status use effective FPS
instead of overwriting `settings.host.stream_fps`. Desktop FPS cycling is blocked
and labelled `(PCVR)` with an explanation. Resolution/bitrate controls remain
independent; Auto desktop bitrate still uses the saved desktop preference.

For this bounded initial increment, PCVR pins the actual current runtime display
Hz (rather than requesting nonexistent 60 Hz), and app render cap follows that
Hz rather than the lower desktop video FPS. The PCVR page distinguishes both.
Selecting additional PCVR stream/display rates is still outstanding; current
managed transport supports only 20/60, long sessions 60.

If an existing desktop stream has different FPS, the existing ordered restart
path runs while the desktop is still shown; video-backed XR handover additionally
waits for the desktop restart to finish. No mid-game restart just for revealing
the desktop. On cancellation/failure/normal stop, timing is released only after
native standby has stopped; saved preferences were never changed. A needed
desktop FPS restoration uses the same restart path. If no desktop stream is
running, ordinary display policy is restored instead.

Tests cover effective FPS versus saved preference, UI lock/cycle rejection,
repeated cleanup, invalid profiles, distinct video/display rates, handover waiting
for desktop timing, and restoration after receiver shutdown. All GDScript test
scripts passed. Optimized release-signed DEV APK built and installed. Physical
entry/exit/reconnect with an active Sunshine stream remains to be confirmed.

At user request, restarted installed Meteor desktop AppImage 0.1.0 (tool session
59104), with successful proxy/depth/microphone listener startup. Dedicated XR
listener was already running (verified PID 1174620); left it untouched. Did not
restart Vibepollo. No commits made in this increment.

### Quest 3 default profile research (2026-10-21)

See `docs/development/meteor-quest3-defaults.md` for primary sources, rationale
and the distinction between transport limits and headset capability. Quest 3
family defaults are now explicitly 1024 per eye / 80 Mbps AVC; missing developer
rate defaults to 60 FPS. Explicit saved preferences (including Auto/profile)
are retained; other devices unchanged. These are conservative supported defaults,
not a full-quality Quest 3 optimum. Missing/invalid/default/override cases have
regression coverage. Higher-resolution and matched-rate profiles remain the
next quality milestone rather than silently enabling unsupported settings.

### HEVC / 2K-per-eye / matched 72 profile (2026-10-21)

Supersedes the provisional 1024/60/AVC default above, at user's request. Quest 3
family defaults now select 2048 square pixels per eye, HEVC Main SDR 8-bit,
72 video FPS / 72 display Hz and 80 Mbps. Explicit resolution/bitrate preferences
remain preserved. The previous developer `hz=60` does not override this Quest 3
profile; legacy non-Quest-3/diagnostic paths retain their profiles.

`configure_video` accepts optional bounded codec h264/h265 (omitted defaults AVC).
Session codec is immutable after offer. NFXR byte 48 is codec 1=AVC/2=HEVC;
byte 51 carries 20/60/72 FPS (zero preserves legacy 60); bytes 52..63 reserved.
All matching Rust/native readers validate codec-specific Annex-B config/IDR
(HEVC VPS/SPS/PPS), freeze codec/rate/dimensions and accept 2048-per-eye. Sender
signals the selected codec; NVENC sets matching codec GUID/VUI/GOP/rate and
headset selects video/hevc hardware decode. No silent AVC/software fallback.
Historical diagnostic `.h264` filenames can now contain HEVC: inspect bitstream
metadata, not filename. Legacy tests remain AVC by default.

72 Hz display preparation now precedes native XR standby/receiver startup.
With a desktop stream, use its ordered teardown/restart path and wait for timing
completion; without a stream, request/settle/read-back directly. Fail if 72 Hz
is unavailable. Timing ownership transfers to handover after arm; cancellation
before transfer drains any receiver before restoring. Long-session frame budget
is now rate×300 (21600 at 72), still below the 32768 wire cap.

GDScript suite, standalone native wire tests and 56 Rust XR tests passed (four
optional interop tests ignored); 73 Python XR tests passed. Full 4096×2048 HEVC
72-target GPU smoke `quad-smoke-x9zpk4vh` passed stereo/alpha/loading/projection
transitions and encode/decode at 32 Mbps. Exact 80 Mbps smoke is recorded below
when complete. CPU-rendered fixture frame times are not a sustained-game benchmark.
Native Monado capture service and release-signed optimized DEV APK rebuilt;
APK installed. Physical headset decode/72 Hz and entry/exit remain user gates.

Exact 80 Mbps smoke `quad-smoke-qdkz6y3c` also passed: ffprobe confirmed real
HEVC at 4096×2048, encoder log confirmed 72 FPS target / 80,000,000 bps, decoded
stereo visibility/alpha and projection↔quad/static-loading transitions passed.
Updated dedicated listener PID 1174620 was terminated/replaced (tool session
16260); normal Meteor desktop app untouched. Installed APK SHA256
`032b732fe7681a8d244962b0fae28d0a730552f60d128f6656dae59daa367f29`.
No external `pcvr_stream.cfg` found on the headset, so no file there overrides
the defaults; private user preferences, if any, are still intentionally respected.
All work remains uncommitted on `feat/meteor-xr-streaming`.

### Projection resolution, measured status and runtime filters (2026-10-21)

User confirmed HEVC/72 session, desktop switches and exit worked, but image
still looked low-resolution. Found a genuine remaining downscale: host/decoder
were 2048 per eye while `NightfallXrProjectionTest::EYE_SIZE` fixed the final
headset projection to 1024. The authenticated control client now passes the
negotiated eye size to the native provider before standby; swapchain extent,
viewport and submitted sub-images use that size. Decoder/projection mismatches
fail explicitly. This is independent of increasing host encoding resolution.

Added native actual decoder width/height, codec, target FPS and received video
byte counters. PCVR status bar reports Rx per-eye dimensions → XR projection
dimensions, codec, measured decoder output FPS versus target, actual display Hz,
payload receive Mbps and app FPS. Counter sampling is bounded to 0.5s intervals;
stale/reset counters show unknown instead of misleading zero/stale measurements.
Decoded FPS is not unique game-render FPS; receive bitrate excludes overhead.
Pending resolution preferences are never presented as actual received dimensions.
The status bar reuses the existing menu viewport, no extra composition layer.

Added optional 2560×2560 per eye (5120×2560 stereo), preserving 2048 default. All
profile/rectangle/tracking/transport/encoder guards updated. Full-resolution
HEVC/72-target/80Mbps GPU encode/decode plus projection/quad/loading smoke passed
in `quad-smoke-3jb8rei6`; this does not prove headset frame rate or network quality.

WiVRn review: `client/scenes/gui_settings.cpp` exposes Off/Normal/Quality OpenXR
sharpening and supersampling; `client/scenes/stream.cpp` attaches those flags to
the projection. Implemented equivalent PCVR-only flags through requested
`XR_FB_composition_layer_settings`. Two live controls, default Off, persist in
PCVR preferences; unsupported runtime disables them. No AI/FSR upscaler was added.
Sharpening may introduce halos; supersampling may reduce shimmer and is not a
replacement for sufficient input detail. Runtime cost still needs headset testing.

PCVR/Desktop toolbar link now square in normal/hover/pressed/disabled/focus styles.
GDScript suite (including telemetry, reset, persistence and square-style tests),
standalone native wire tests and 56 Rust XR tests passed; four optional Rust
interop tests ignored. Native XR rebuilt and optimized release-signed DEV APK
installed. Physical checks: actual Rx→XR size equality, sharpness at 2048, optional
2560 cost, filters/halos and menu readability.

Automatic XR launch is the next distinct phase, not implemented in this update:
`meteor-xr-automatic-launch.md`. Plan uses a cheap trusted control watch and
host-local pre-launch intent, avoiding persistent GPU standby. It must live in
the normal Meteor host process for the final install-host/run-client experience,
not require users to keep running a separate DEV listener. Steam wrapper first;
general runtime broker later. No global runtime or Steam launch options changed.

Updated dedicated XR listener PID 1465576 was replaced with release build (tool
session 50999); regular Meteor untouched. Installed APK SHA256
`ddf8ee06b0b3723f1da8ccf38e6f465d740a4a8bb3e82d327b956a72f46a3499`.
All changes remain uncommitted. Automatic launch is documented only, so testing
still uses the existing explicit XR preparation flow for this build.

### 2026-10-21: automatic Steam launch deployed for combined testing

Supersedes the preceding automatic-launch status: implemented the trusted idle
control watch, host-local expiring/PID-bound Steam launch intent, single-use
claim and runtime-ticket binding, and automatic offer/accept. No idle XR GPU
resources and no remote command arguments. Existing desktop-mode launch flags
bypass XR; existing first-frame handover and desktop restoration remain in use.
Only the configured application and matching connected desktop host qualify.
Dedicated DEV listener updated (tool session 39357); normal Meteor untouched.
No Steam options or global runtime registrations changed.

76 Python XR tests, 58 Rust XR tests (four optional tests ignored), full GDScript
suite and diff checks passed. Optimized release-signed DEV APK installed with
SHA256 `ddbdc3985d0649a33c9bd0e65e9cdd90578b9f3c5a0682372f7be2fcdba04f12`.
Physical automatic-launch/resolution/filter checks pending. Changes uncommitted.
Normal-host packaging, generic runtime broker, Windows and removing the five-minute
DEV gameplay bound remain outstanding. See `meteor-xr-automatic-launch.md`.

### 2026-10-21: automatic-entry physical pass and xrizer pose panic

User confirmed automatic entry and desktop restoration worked. The game exited
unexpectedly. Session `1792594475768072375-1952100/application-live.log` records
an xrizer panic at 16:55:13 in compositor.rs:1373: xrEndFrame returned
ERROR_POSE_INVALID for the left projection view's zero quaternion. This occurred
well before the five-minute bound. Later tracking disconnect/termination records
are cleanup evidence, not proof that transport caused the original failure.

Found an avoidable invalid-pose path: meteor_tracking_pose_v1 used try_lock and
reported no pose if the latest-sample writer briefly held its mutex. Changed it
to wait for the short memory-copy critical section (no network I/O inside it).
Genuinely stale (>250 ms), failed and invalid-time samples remain unavailable.
The Monado relation now contains identity orientation even when validity flags
are cleared, instead of an invalid zero quaternion. This is a candidate fix;
the originating call cannot be conclusively reconstructed from existing logs.

Regression tests exercise real bridge contention, stale/failed rejection, and
unavailable-to-valid-to-unavailable relation transitions. Both are included in
helper preflight builds. Rebuilt isolated Monado and validated the updated helper
cache. Host-only change: next XR launch picks up both without a new headset APK.

Removing the gameplay cap is still pending, deliberately not a timer-only edit:
the DEV encoder writes full encoded video and per-frame diagnostics to disk.
This short session recorded 204,518,153 bytes; unrestricted use could exhaust
storage (host currently has about 88 GB free). First add optional/bounded capture
and bounded diagnostics, then remove coordinated client/runtime/control/frame
bounds while preserving startup, idle-I/O, cancellation and shutdown watchdogs.

### 2026-10-22: reserve B/Y for streamed games

Disabled the hold-B/Y-to-exit gesture for Meteor PCVR sessions, where VRChat
uses those buttons for its menus. Removed its startup hint for Meteor too.
Standalone diagnostic projection tests retain the gesture. Explicit stop,
application-pause teardown, failure recovery and session timeout are unchanged.
Regression covers both controllers held beyond one second in Meteor mode and
the retained diagnostic gesture. Full GDScript suite passed.

Follow-up: physical testing exposed a second, independent B/Y hold handler in
PCVRWorkspaceHandover (the automatic standby/handover route). Removed that
handler and its accumulator entirely. Added an ACTIVE handover regression with
both buttons held for 1.5 seconds; no stop is requested. Full GDScript suite
passed again. The earlier exclusive-controller fix alone was incomplete.

### 2026-10-22: forward B/Y and verify stick-click input

Added B/Y click and touch to headset capture (bits 5/6), the extended NFXJ
packet validator (mask 127), and host left-Y/right-B Touch input declarations
and state updates. Menu/system remain local. Packet layout is unchanged; older
DEV readers with mask 31 reject the new bits, so headset and host must be updated
together. Legacy NFXI still strips the extended button/stick fields.

Latest session logs already showed stick-click bit 1 on both hands. VRChat's
installed bindings_oculus_touch.json maps joystick click to global/in/stick_click
and B/Y to global/in/menu. No missing stick-click binding was established.
Found and fixed a separate try-lock dropout in controller_v2: a simultaneous
sample update could previously report all controller input unavailable. It now
waits for the short sample-copy mutex, with stale/failed-sample guards unchanged.
This may help reliability but is not proof of the in-game menu root cause.

Regression covers both hands' click/touch mapping, release, wrong-hand exclusion,
inactive inputs, packet roundtrip/unknown-bit rejection and actual bridge
contention. Isolated Monado rebuilt and optimized DEV APK installed. Next test:
B/Y Quick Menu, each stick click (also try holding if a tap does not open the
Action Menu), press/release, and no accidental XR exit. Do not change VRChat's
installed bindings or Steam configuration without evidence and user agreement.

### 2026-10-22: prove OpenXR and xrizer per-hand action output

User reported prior WiVRn+xrizer bindings worked. Compared WiVRn's driver with
the partial Touch bridge; WiVRn exposes a fuller profile, but no missing
thumbstick-click declaration or swapped input bit was established. Do not infer
causation from xrizer's per-device action-set warning alone.

Added deterministic host-only controller fixture and two real-runtime probes:
`meteor_openxr_input_probe.h` through the OpenXR loader, and
`meteor_openvr_input_probe.cpp` through the installed xrizer v0.6 library using
VRChat's actual, unmodified actions.json and bindings. The latter submits a tiny
Vulkan texture to get genuine XR input focus (no focus means inactive actions).
The fixture-only compositor mode skips capture/encoder pixel-oracle validation;
normal sessions are unaffected. No Steam, game binding or global runtime changes.

GPU-backed run `controller-host-cmniz5er` passed both probes: left/right click
alone, release, Y alone, B alone, B+Y, both stick clicks and final release. Each
hand's `/actions/global/in/stick_click` and `/actions/global/in/menu` values
matched independently; B/Y did not become stick clicks. This proves transport's
host-side mapping through xrizer, not VRChat's internal choice of menu gesture.
No new gameplay fix or headset APK resulted from this investigation.

VRChat documentation conflicts: its Touch page lists stick clicks for Action
Menu, while https://docs.vrchat.com/docs/action-menu explicitly documents holding
the Quick Menu button by default, with joystick-click activation configurable
in its Bindings settings. Next physical check: hold B alone and Y alone, rather
than both together; inspect VRChat's Action Menu binding if joystick activation
is desired. If each button still opens both hands, collect that as a separate
in-game/per-hand-action-set case, not a proven bit-mapping defect.

Reproduce (build image and pinned runtime prerequisites as earlier):
`test/run_monado_controller_probe.sh` inside the isolated Monado build container
compiles the fixture and OpenXR probe. To build the optional OpenVR probe, mount
the cached OpenVR headers at /openvr and set METEOR_XRIZER_LIBRARY; xrizer needs
a GPU-supported Vulkan driver, not lavapipe. `test/run_xr_controller_probe.py`
runs the built probes with the host NVIDIA ICD, a private short IPC directory,
process-local runtime manifest and owned/reaped service. Paths currently target
this development machine. The real game's manifest is only read, never edited.

### 2026-10-22: PCVR compositor-filter capability ownership fix

User saw both filters as Unavailable. XR_FB_composition_layer_settings was
requested through the CORE-registered wrapper, but the enabled flag was an
instance member. The scene creates a separate projection provider, which kept
its own flag false. That disabled both the controls and projection next-chain
attachment even when Godot had enabled the extension.

Made the flag process-shared, matching the existing shared clock extension
capability. Only Godot's enabled-extension negotiation populates it; this does
not assume support from extension enumeration alone. Instance creation logs
clock/filter capability and destruction clears the shared flags. Rebuilt native
XR and optimized DEV APK; full GDScript suite passed. Physical filter quality,
latency and supersampling cost still need testing; unsupported runtimes must
continue to show Unavailable. No host or model changes required.

Installed and launched on Quest: 13:25:39 NightfallPCVR reports
`Instance capabilities: clock=1 pcvr_compositor_filters=1 (shared startup/provider state)`.
APK SHA256 `b702ec16488ae4c51635fad11f7400df868243bff213d0a00dbc9c563c7c07dc`.
This confirms enabled capability, not the visual quality/performance of each mode.

### 2026-10-22: pre-launch PCVR settings and clean welcome

Removed synthetic projection, decoded-USB, authentication/accept/cancel debug
buttons and their status label from the welcome screen. Automatic XR watching
is independent of those controls and remains enabled for provisioned hosts.
Manual diagnostic entry in Advanced is unchanged.

PCVR toolbar entry now appears while the matching desktop stream has an
authenticated XR watch/prepared connection, as well as during active XR. This
is stronger than detecting ordinary Meteor depth support, but currently still
depends on the provisioned dedicated DEV XR endpoint (not generic discovery).
No separate GPU/runtime standby is created just to edit preferences.

Idle link is neutral; active XR is green. Desktop return remains available from
the PCVR page even without a running XR game. Idle page says Ready for XR,
suppresses stale live stats and hides Exit PCVR. Video/filter preferences can be
edited before launch; existing session setup reads them. Open menus refresh on
capability/session changes, and the link fills the toolbar height instead of
inheriting the action-button vertical shrink flag. Other menu restoration issues
from user feedback have not been assumed fixed by these changes.

Regression covers authenticated watch vs depth-only/idle/failed/disconnected,
pre-launch page entry, idle status, active exit/link state, capability loss and
toolbar vertical fill. Full GDScript suite passed including the final toolbar
test update; optimized release-signed DEV APK built and installed successfully.

Latest user physical results before this UI update: automatic entry, stability,
game controls and menu gestures, watch placement and input focus pass. Basic
desktop overlay passes, not extensively stressed. Resolution visibly improved;
explicit Rx/projection sizes, optional 2560, stream settings/restart behavior,
newly-enabled filters and exit/relaunch cycle remain to test.

### 2026-10-22: controller-free headset startup fallback

Added session-only hand tracking rescue after a 1.5-second startup detection
grace period, once the runtime supplies live hands and no tracked physical
controller has been seen. Uses tracker profiles plus actual pose validity;
hand interaction/aim trackers and untracked controller placeholders are not
physical controllers. Existing Hands/UI Only preferences are unchanged.

The fallback reports Hands (Auto), does not write saved settings, and an explicit
tracking toggle cancels it for this session. A seen physical controller preserves
the saved Off preference; later controller loss does not repeatedly override it.
Late hand acquisition is permitted while startup is still undecided. Headset OS
hand tracking must already be available; this does not change Horizon settings.

New policy/tracker tests and the full GDScript suite passed. Optimized DEV build
targets the connected controller-free Quest 3S (3487C10H0400XS). Physical check:
launch using hands only, pinch through welcome/menu/keyboard; verify auto label,
explicit Off and ordinary controller startup behavior. No PCVR hand-controller
emulation or host inference changes are included.

Optimized DEV APK installed successfully on the Quest 3S and launch requested.
Hands-visible physical verification is pending; no fallback activation was yet
present in the available startup log.

### 2026-10-22: correct fresh-install AI 3D labels while disabled

User saw EdgePad-256-CPU on a fresh install. The persisted/default backend was
already GPU/OpenCL and Android platform normalization selected Auto. The UI
called get_depth_backend_index(), which returned CPU as an "irrelevant while
Off" sentinel, then resolved the displayed model to its CPU twin. Removed that
sentinel: configured backend/model labels remain accurate with AI 3D Off, while
get_depth_model_index() still returns zero and inference remains disabled.

Quest 3S log confirms actual enabled inference was EdgePad-512/OpenCL (model 25,
backend 2), not CPU fallback. Regression tests fresh platform normalization,
Auto/OpenCL labels while Off, disabled inference and explicit CPU preservation;
full GDScript suite passed. Source fix only: no rebuild/install during the user's
active demo. Next APK should include this change.

### 2026-10-22: single-controller primary selection and mirrored shortcuts

Physical controller availability now supplies a session-only primary-hand
override after 0.75 seconds of stable tracking. Left only chooses Left; right
only chooses Right; both restore the saved Right/Left/Auto preference. Temporary
loss of both holds the last selection rather than flipping, and active click/
grab interactions defer a change. Saved preferences are not rewritten; hand
tracking retains its independent preferred-hand behavior. UI indicates the
effective controller selection with (Auto).

Normal-mode shortcuts now follow the effective primary hand (or pointer owner
under Auto): Y/B menu, X/A keyboard, primary stick-click SBS. The existing
two-stick gamepad chord and trackpad-exit exclusion remain. Hand changes,
gamepad/hand-input ownership and PCVR return require button release before
shortcuts can fire, preventing a held game button from opening desktop UI.
PCVR game inputs remain untouched when the workspace is hidden.

Policy/edge tests and a main.gd integration test cover left-only routing,
secondary-hand exclusion, repeat suppression, hand switches, tracking loss,
two-controller restoration, trackpad/pad chords and XR-return release guarding.
Full GDScript suite passed; optimized DEV APK includes the prior off-state
Auto/OpenCL display correction and is targeted to Quest 3S 3487C10H0400XS.

### 2026-10-23: logical commit checkpoint

Branch remains `feat/meteor-xr-streaming`. Recorded the latest code in sections:

- `35dcf17`: controller-free startup, single-controller primary selection and
  primary-hand shortcuts, with handover release guards and regression tests.
- `a2c61f1`: preserve Auto/GPU/OpenCL labels while AI 3D is disabled.
- `11f4cfe`: native HEVC/72 Hz video, negotiated projection sizes, composition
  and filters, tracking/controller robustness, native diagnostic probes.
- `ca2249c`: authenticated launch intents, Steam launcher, video negotiation,
  managed runtime supervision and process diagnostics.
- `94132fc`: automatic client startup, PCVR preferences/telemetry, wristwatch
  menu focus, display timing and welcome debug-control removal.

Validation at checkpoint: full GDScript suite, 76 Python XR tests and 58 Rust XR
tests passed; four optional Rust interop tests ignored. Standalone native video
and tracking packet tests passed, as did the validated native helper preflight
(controller mapping/contention, image leases, timing, quad math and bounded
asynchronous transport). Earlier real OpenXR+xrizer probe and physical-test
results are recorded above; no new physical result is implied by committing.

Outstanding: deploy the latest presentation-era APK to the reconnected Quest 3;
exercise PCVR preferences/filters and repeat menu/overlay transitions; verify
actual receive/projection sizes, bitrate/session changes and exit/relaunch.
Remove the five-minute limit only after bounding/optionalizing recording and
diagnostics. Normal Meteor XR packaging/discovery, XR audio/microphone and Windows
remain later work. Historical "uncommitted" notes above describe earlier points
in time; this checkpoint supersedes them. No push/release/deployment performed
as part of this commit-only task.

Run GDScript regression tests after UI/state changes; add lifecycle/focus tests.
For protocol/encoder work run Rust, Python and native/GPU smoke tests. Full native
suite currently needs missing host FFmpeg development packages. For physical
tests use an optimized release-signed DEV APK, rebuild native XR after C++ edits,
and read BUILD.md before building. No debug APK for performance comparisons.

### 2026-10-23: wristwatch toggle and live bitrate

- Repeated wristwatch gear presses now close the PCVR menu, including when the
  desktop is visible. Opening settings retains the existing focus guards.
- Bitrate changes travel over the authenticated XR control connection and are
  bound to its accepted session. Latest-only requests are applied by the encoder
  thread between frames using NVENC reconfiguration. Acknowledgements report the
  applied rate or rejection without stopping the current stream. Auto restores
  the encoder's existing resolution-based bitrate default. Resolution continues
  to apply to the next session; sharpening and supersampling remain live.
- Validation: GDScript suite, 76 Python XR tests and 59 Rust XR tests passed
  (four optional Rust interop tests ignored). Native helper tests cover replay,
  coalescing, invalid requests, Auto and failed reconfiguration. A real HEVC
  72 Hz GPU composition/decoding smoke test applied 40 then 24 Mbps successfully,
  preserving all projection/overlay transitions and encoder drain.
- Optimized release-signed DEV APK installed on Quest 3; dedicated XR listener
  rebuilt/restarted. Normal Meteor remains running. Physical testing pending:
  gear open/close with and without desktop, live bitrate acknowledgement and
  continued XR/desktop input. Repeat game exit/relaunch and supersampling checks
  from the previous checklist. Five-minute diagnostic limit is unchanged.

### 2026-10-23: headset-relative resolution and filter review

Physical feedback confirms live bitrate updates and wristwatch gear toggling
work. VRChat launched again, although startup was slow. Supersampling remained
visually subtle even after increasing resolution.

Reviewed WiVRn `f0fa861` (`client/scenes/stream.cpp`, `gui_settings.cpp`) and ALVR
`a9f6542` (`alvr/client_openxr/src/graphics.rs`). Both attach the same
`XrCompositionLayerSettingsFB` supersampling/sharpening flags to their projection
layer as Nightfall. No mismatched flags or missing projection-chain attachment
found. Meta documents Normal as a temporal two-tap sampling filter and Quality
as a four-tap filter. These reduce downsampling shimmer, do not increase game
render resolution, and remain runtime hints rather than guaranteed effects.
Keep Off as default; clarified the tooltip rather than adding another shader.
Reference: https://developers.meta.com/vr/documentation/native/android/mobile-openxr-composition-layer-filtering/

Resolution now cycles 100%, 110%, 120%, 130%, 140%, 150%. The native client queries
OpenXR's recommended dimensions for both eyes. The current square-eye transport
uses the larger recommended axis as its 100% reference, applies the percentage
to each dimension and rounds up to 16 pixels. This is not the physical panel
resolution or SteamVR's pixel-area percentage convention: 150% means 2.25 times
the pixels. Resolution is capped at 4096 square per eye (8192×4096 stereo).
Runtime recommendations handle Quest 2/3/3S without conflating their optics or
hardcoding panel sizes. Actual performance/decoder support still needs device
testing, especially at higher percentages on Quest 2.

Existing fixed-size/host preferences appear as Custom and remain unchanged until
the user selects a percentage. New installs default to 100%. Pre-launch settings
show next-session dimensions; active status continues reporting actual received
and projection dimensions, never substituting pending preferences. Resolution
still requires a new XR session; bitrate and compositor filters remain live.

Updated all runtime/encoder/transport size guards to accept bounded 16-pixel
aligned eye sizes. Validation: GDScript suite, 59 Rust XR tests (four optional
interop tests ignored), 76 Python XR tests, native wire and helper tests passed.
Real HEVC/72 Hz GPU smoke passed at 2656 square per eye with two live bitrate
updates, decoded pixel checks, projection/overlay transitions and clean drain.
Optimized release-signed DEV APK installed on Quest 3 and XR listener rebuilt
and restarted. Physical percentage-resolution checks remain pending. No new
Quest 2 or 3S physical result is implied.

### 2026-10-23: fine and extended resolution ranges

Supersedes the initial 100–150% resolution choices above. Normal mode now offers
75–135% in 5% steps, default 100%. Advanced Settings → PCVR → Extended Resolution
switches the choices to 50–150% in 10% steps and persists independently of the
selected resolution. Changing range does not silently round or replace the
current value, including an off-grid value from the other range; the next
resolution click advances to the next available percentage and wraps normally.
The first click from a legacy Custom selection chooses 100%.

Aspect-ratio follow-up: current eyes are square using the larger recommended
axis. Their projection FOV prevents this alone stretching scene geometry, but
rectangular eyes preserving the recommended ratio could avoid unnecessary
pixels on the shorter axis at comparable sampling density. This requires an
end-to-end host/encoder/transport/client change, not a UI-only adjustment.
WiVRn's panel-width baseline override is a separate choice from preserving the
ratio; adopting the latter need not mean changing our 100% reference to panels.
Foveated encoding remains unimplemented and outside this UI change; any future
implementation should be an explicit option, default Off, as requested.

### 2026-10-23: rectangular eyes and optional centre-priority encoding

Implemented rectangular per-eye dimensions end to end: preference calculation,
authenticated offer, session-frozen runtime environment, Monado simulated-device
recommendation, projection/overlay capture, retained asynchronous jobs, Vulkan
packing/quad viewports, NVENC input, metadata/wire transport, Android decoder,
headset swapchain/viewports and actual-resolution status. Width/height are each
bounded to 256–4096 and aligned to 16 pixels. Packed stereo remains side by side.
Existing stream framing already carries both dimensions; no new packet layout.
Legacy square fixtures and explicit Custom preferences remain supported.

Percentage resolution now scales both OpenXR recommended axes uniformly, with a
common scale cap and independent encoder alignment. It no longer makes both
axes as large as the larger axis. The previous range choices and default 100%
remain unchanged. Resolution changes still require a new XR session.

PCVR Settings → Foveated Encode is optional and defaults Off. This initial mode
uses **fixed-centre NVENC QP-delta ROI encoding**, not WiVRn's spatial compression.
Each eye has its own centre; QP delta transitions smoothly from -2 in the central
half-width/height region to +6 at the periphery. Maps are generated once/session
and supplied per picture (16-pixel H.264 macroblocks; 32-pixel HEVC CTBs).
Spatial/temporal AQ is disabled only when this explicit mode is enabled, as
required for the QP map. Live bitrate reconfiguration retains this mode.
The setting is negotiated before offer and frozen for the session.

This mode redistributes compression quality within the target bitrate; it does
**not** reduce game rendering resolution, encoded/decoded pixel count or add
eye tracking. It adds no spatial warp/unwarp, headset pass or XR layer. No
measured performance/quality advantage is claimed yet. NVENC rejection remains
an explicit session failure, not a hidden fallback. A future geometric foveation
path would be a separate optimization with matching inverse sampling on client.

Validation: GDScript suite and rectangle-aware telemetry test passed; 59 Rust XR
regressions passed sequentially (four optional interop tests ignored), plus the
new rectangular/foveation negotiation/default/immutability test. 76 Python XR
tests passed, along with native transport and QP-map symmetry/bounds tests.
Actual Vulkan→NVENC→decode composition smoke passed for HEVC and H.264 with
512×768 eyes, centre-priority mode On and two live bitrate updates; default Off
also passed at 2064×2208/eye. Tests cover eight quads, static loading hold,
projection/overlay transitions, pixel sampling, timestamps and clean drain.
Optimized release-signed DEV APK rebuilt with native changes and installed on
Quest 3. Physical VRChat checks remain pending: select 100% (Custom preserves
old square preference), check rectangle dimensions, compare Off/On in separate
sessions, repeat menu/watch/input and exit/relaunch. Quest 2/3S physical tests
remain outstanding. No commits/push requested for this step.

### 2026-10-23: physical feedback — audio and pending resolution

User reported silent VRChat and termination while changing resolution. Recovered
the private rotated diagnostics via the existing external
`export_diagnostics_on_start` marker and normal MediaStore export. Latest session
started standby at 23:09:39, activated projection at 23:09:50, and ended at
23:14:39 with `[PCVR-STANDBY] Stop reason=DEV session timeout elapsed=300.0s
limit=300.0s`. This is the existing five-minute cap, not evidence that changing
resolution reconfigured or killed the stream. Host metadata retained 2560×2560
eyes through disconnection. The cap is unchanged by this fix.

Pending resolution now shows `(restart)` beside the selected percentage only
when its calculated dimensions differ from the running projection. The info
line shows next-session dimensions; the status bar continues to show actual
running dimensions. Selecting the active size again clears the indicator.
Cycling resolution only saves preferences: it makes no native reconfiguration,
control cancellation, host restart or bitrate update. Added a regression test
checking these invariants and a diagnostic log of saved/active dimensions.

XR has no dedicated host-to-headset audio transport yet. Handover had explicitly
paused the otherwise-live Sunshine audio player. It now retains the connected
desktop host's captured audio while hiding its video, preserves an existing
paused state and pauses stale playback after desktop disconnection. Exit still
restores the saved pause state. Tests cover those transitions. This supplies
game audio when the preserved Sunshine connection captures the game's output;
XR without a desktop stream still has no audio. Dedicated XR audio routing and
XR microphone work remain outstanding; no duplicate audio transport was added.

### 2026-10-23: make 100% match Quest panel dimensions

Physical feedback: pre-launch 100% did not match Quest 3's panel resolution.
The calculation was using OpenXR's standalone render recommendation, as
originally implemented/documented, which is distinct from the physical panel.
Meta documents Quest 3 panel dimensions as 2064×2208/eye, with a default render
scale size of 1680×1760. Reference:
https://developers.meta.com/vr/essentials/render-scale/

Changed the percentage baseline for known headsets to native panel dimensions,
identified through the existing Build.DEVICE bridge: eureka (Quest 3) →
2064×2208; hollywood/panther (Quest 2/3S) → 1832×1920. Connected headset confirmed
as eureka. Unknown headsets retain the OpenXR recommendation fallback. Both the
menu preview and authenticated XR offer use the same reference helper. The
tooltip states the new definition and encoder alignment; resolution still
applies on the next session, preserving the pending restart indicator.

100% on Quest 3 is exactly 2064×2208/eye. Quest 2/3S encode at 1840×1920 because
the shared encoder/profile guards require 16-pixel alignment. This is an
intentional up-rounding of eight pixels, not a different display model. Added
tests for all three headset mappings, unknown-device fallback, panel alignment
and a runtime recommendation deliberately different from the Quest 3 panel.
GDScript suite passed; optimized release-signed DEV APK rebuilt for deployment.
Prior real GPU smoke already covered 2064×2208/eye. No new physical visual
confirmation is implied, and no host protocol or encoder changes were needed.

### 2026-10-23: wristwatch-only menu pointer recovery

Physical feedback: PCVR settings opened from the watch had no usable laser,
while opening the desktop made menu pointing work. Found an input-path mismatch:
the settings-only early return processed controller fade and pointer clicks but
skipped `_process_hand_tracking`, which updates hand/controller ownership and
restores controller ray transforms after hand tracking. During an XR game the
ordinary desktop loop is suspended, so that ownership can be stale when the
watch opens settings. The full desktop path performed this update correctly.

The settings-only loop now updates hand/controller ownership/poses before fade
and pointer dispatch. Composition controller rays also accept `menu_only` as an
active presentation condition, matching the existing UI/cursor/panel gates;
their visibility no longer depends on the desktop composition flag in this mode.
Screen/video/ambient updates remain outside the settings-only path, and the
watch trigger release guard remains in force. No layers or native changes added.
Physical recheck pending: enter XR after using hands, pick up controllers, open
settings directly from watch without showing desktop, then hover/click/close and
repeat. Confirm desktop and hand pointer paths still work as before.

### 2026-10-23: automatic detection must re-arm after game exit

Physical report: enter VRChat, change pending resolution, exit, then two relaunch
attempts fail. Recovered diagnostics show a good 2064×2208 session starting
23:39:46, projection active 23:39:56, saved-only changes through 115% at
23:40:31–33, then ordinary session end at 23:41:49 and native/workspace drain
complete at 23:41:50. No automatic watching/offer followed; no new host runtime
session directory was created for the failed attempts. This was not the
five-minute timeout or evidence of an incompatible new resolution.

Root cause: PCVRTestController's normal native teardown called
WelcomeScreen.cancel_xr_control(false), which unconditionally set
`_auto_suppressed=true`. That same flag deliberately stops automatic detection
after user cancellation, and previously cleared only on resume/disconnection.

Separated those policies: cancellation now accepts `suppress_auto` (default
true for explicit cancellation/lifecycle callers). Internal native teardown
passes false, allowing automatic detection after native/handover drain and a
short retry delay. It does not clear a prior manual suppression. Advanced's
Cancel XR action now uses the deliberate-cancel wrapper. Existing busy/native
drain guards remain, and the next offer still reloads saved resolution choices.
Regression tests cover actual controller teardown preserving automatic launch
eligibility, manual suppression surviving later cleanup, and resume re-enabling
detection. Full GDScript suite passed. Optimized DEV APK rebuilt for deployment;
physical second-launch verification remains pending.

### 2026-10-24: accept decoder padding at percentage resolutions

After re-arming was fixed, both new launches reached the host/runtime and
negotiated the saved 115% (2384×2544/eye). Headset logs identify a separate
failure: `Unexpected Meteor decoded buffer size`. Qualcomm HEVC reports logical
video 4768×2544, allocation height 2560, and visible crop (0,0,4767,2543) in its
inclusive MediaCodec format. Our EGL-import path incorrectly required the
allocation dimensions to equal the logical dimensions. Old aligned profiles
hid the assumption; new percentage sizes exposed it. Native failure closed the
tracking connection and the host then tore down the owned game/runtime.

The AImageReader receiver now reads each acquired AImage's crop rectangle
(exclusive right/bottom per Android NDK), validates it against both the hardware
allocation and authenticated logical frame dimensions, and returns normalized
crop/texel coordinates with the held frame. The projection shader samples this
region within the imported allocation, clamping within each eye at half-texel
boundaries to avoid padding/other-eye bleed. No CPU frame readback, new layer or
extra rendering pass. Invalid/mismatched crops still fail explicitly and log
logical dimensions, allocation and crop bounds. First buffer dimensions/crop
are logged once per session for future diagnosis. Status stays at logical video
and projection sizes; it does not present padded allocation size as resolution.

New standalone native tests cover the exact 4768×2544-in-4768×2560 case, padding
on both axes, non-zero crop origins, stereo midpoint, unpadded identity mapping
and rejection of out-of-bounds/mismatched/empty regions. Rebuilt native XR in
the optimized release-signed DEV APK; GDScript regression suite also run.
Physical 115% launch/relaunch remains the next verification. No host restart or
preference downgrade is needed. Five-minute diagnostic limit remains unchanged.
NDK reference: https://developer.android.com/ndk/reference/struct/a-image-crop-rect

### 2026-10-24: successful relaunch, audio environment and startup hand policy

User confirmed entering VRChat, exiting and entering again now works. Still no
sound, and putting down controllers activated hands with saved tracking mode Off.
Recovered diagnostics show session-only startup hand fallback enabling at
00:05:57, then hands reappearing after controller use with `tracking_mode=0`.

The fallback previously required an actively tracked grip/aim/default pose to
recognize a physical controller, waited indefinitely for hands to appear, and
never withdrew an already-enabled fallback when controllers subsequently woke.
Physical interaction profiles now count without a pose. Hand-specific and Quest's
emulated `khr/simple_controller` profiles remain excluded. The decision window is
bounded to the first five seconds; an automatically enabled fallback continues
checking for physical controllers and retires permanently on detection. Thus
putting controllers down later cannot re-enable this rescue. Explicit Hands/UI
Only choices are unchanged; no saved preference is rewritten. Tests cover late
controller detection, controllers at rest, no mid-session fallback, emulated
hands and explicit choices. OpenXR exposes profiles/tracking, not a general OS
paired-controller inventory; this policy does not claim otherwise.

Audio diagnostics during VRChat show decoded and output PCM at -120 dBFS, zero
write failures, and normal AAudio output. Subsequent desktop content is audible
in signal diagnostics (~-25 dBFS). The silence is upstream of headset playback;
retaining the Godot audio-player pause state alone did not solve native audio.
Found the managed launcher replaces `XDG_RUNTIME_DIR` with a private Monado IPC
directory and passes it to the game, hiding default PulseAudio/PipeWire sockets.
VRChat's host log also contains ALSA fallback errors.

Reproduced with a real host connectivity probe: `pactl get-default-sink` fails
under a temporary private XDG directory, but succeeds after supplying the actual
host `PULSE_SERVER`, while leaving XR isolation untouched. Added a host-local
endpoint helper resolving the existing host Pulse socket and PipeWire runtime
directory before replacing XDG_RUNTIME_DIR. Explicit configured audio endpoints
win; absent sockets are not invented. No system default sink, global audio
configuration, Steam options, microphone route or XR runtime registration is
modified. The next managed XR session picks up this Python change automatically;
the native listener does not require a rebuild/restart for it.

Validation: GDScript suite plus final startup-policy test, 78 Python XR tests
and explicit-endpoint tests passed. Real sound-server connectivity succeeds
through the new helper while XDG_RUNTIME_DIR remains private. Optimized
release-signed DEV APK rebuilt with the fallback changes. Physical audible
VRChat and put-down/pick-up checks remain pending. This still uses the preserved
Sunshine audio stream; dedicated XR audio/microphone remain future work.
