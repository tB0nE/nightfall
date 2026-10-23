# Meteor PCVR: outstanding work and implementation order

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
