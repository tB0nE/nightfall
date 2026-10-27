# Accepted-lease live encrypted relays (development)

This increment connects the authenticated control/data foundation to native
video/tracking workers and the existing fixed upstream demo launcher. It remains
Linux/NVIDIA, manually provisioned, bounded and development-only. It is not the
finished paired LAN XR product; no endpoint starts during normal Meteor use.

## Explicit host modes

```bash
# Authenticated control only; no data listeners or app launch:
meteor/target/release/nightfall-meteor --xr-control-dev \
  127.0.0.1:47905 <host-private-key-file> <allowed-device-public-key>

# Session-owned encrypted relays, but no app launch:
meteor/target/release/nightfall-meteor --xr-control-dev \
  <intended-bind-IP>:47905 <host-private-key-file> <allowed-device-public-key> --relay

# Also supervise the fixed pinned upstream demo after BOTH data lanes authenticate:
meteor/target/release/nightfall-meteor --xr-control-dev \
  <intended-bind-IP>:47905 <host-private-key-file> <allowed-device-public-key> --relay "$PWD"
```

No arbitrary executable/path is accepted from the network. The checkout is a
trusted local CLI argument; the only launch is the existing validated upstream
Godot demo adapter. Relay mode accepts only fixed 512-square-eye profiles at
20 or 60 Hz, with negotiation passed through to the launch configuration.
These are bounded 200/1,200-frame diagnostics, not continuous play. Windows runtime launch
is rejected; its process/service adapter remains future work.

## Ownership and startup

1. Existing pinned-host/device-allowlist handshake authenticates the control
   connection. Offer has no data listeners. User explicitly accepts its session.
2. Only then create two dynamically allocated data ports on the control bind IP.
   Reply includes `relay: {video, tracking, framing: 1}`. Normal capability stays
   `lan_video_available: false`: these are explicitly opted-in experimental
   relays, not a production capability advertised through discovery.
3. Every accepted data socket receives a fresh 32-byte random attachment
   challenge. Append this challenge to the existing data HKDF context, for both
   attachment proof and every traffic key on that lane. New attachment purposes
   5 (video) and 6 (tracking) have independent keys/counters. Proof is 32 bytes:
   `NFXB`, lane byte 1/2, three zero bytes, 16-byte session ID, eight zero bytes.
   It is encrypted with the corresponding attachment key at counter zero.
   A captured proof/record cannot be replayed on a different connection.
4. Prove possession before admitting a loopback producer. Both proofs must pass
   before the optional runtime starts. Public session IDs/ports alone grant no
   access. Invalid proof cancels both lanes. Authentication failure is fatal,
   never a plaintext fallback.
5. On Nightfall, explicit relay configuration enables `MeteorXrRelay` workers.
   The client enters the existing exclusive projection preparation and waits
   for both native loopback listeners to report ready before attaching.
6. The native workers connect to those **local** consumers only when their first
   authenticated traffic is ready. Otherwise the consumers' short read deadlines
   would incorrectly include host build/import time. This was found and fixed by
   the combined GPU test; it is not papered over by disabling their deadlines.

## Workers and shutdown

Host video worker validates raw NFXR packets, encrypts them, authenticates decoder
feedback and requires the exact sequence/frame ID or END acknowledgment before
forwarding it to the producer. Tracking has an independent socket/task/key/counter,
so video cannot block clock/pose/controller/optics/haptic requests. It checks
response kind/size; existing native semantic/clock/haptic checks remain active.

Native workers use bounded socket operations outside the Godot/render threads.
The receiver/MediaCodec and tracking endpoint are unchanged except an atomic
listener-readiness report; the existing render-thread image/fence drain still
owns their teardown. B/Y exit stops the control connection and native relays;
lease expiry, control disconnect or lane failure cancels host workers and requests
bounded graceful runtime exit, with an exact owned-process-group kill fallback.
Cancellation invalidates GDScript generations and clears credential copies.

There is no additional unbounded relay queue: the existing encoder latest-frame
queue and decoder acknowledgments provide backpressure. This is still a bounded
correctness profile, not a low-latency/throughput claim. Local plaintext TCP
adapter endpoints assume trusted development machines/app sandbox; replace that
ambient local access with capability-bound IPC before production distribution.

## Developer client provisioning

Use the control configuration described in meteor-xr-control-protocol.md, adding
`relay=true` in `[host]`. It contains only host address/port/public pin. On Android
an alternative to the private `user://` path is the app's external-files
`meteor_xr_control.cfg`, queried from `Context.getExternalFilesDir` by the native
bridge. This makes public development configuration ADB-provisionable without
making a release-signed app debuggable. A private internal config takes precedence.

The device private identity **never** goes to external storage. The configured
DEV welcome probe logs its public identity for host allowlisting. Verify the host
pin independently; no network discovery key is accepted automatically. No marker
means no developer probe, and non-DEV builds do not expose it.

The application package remains the release-signed optimized DEV package, not a
debug APK. Build outputs are Nightfall-Android-arm64-v8a-dev.apk and
meteor/target/release/nightfall-meteor. The 20-Hz path has since been deployed and
physically tested on LAN; the sustained 60-Hz profile still needs headset testing.

## Evidence

- Native worker fixture exchanges video, exact decoder ACKs, END, pose requests/
  responses and quit through the actual Rust relays and production C++ workers.
- Invalid proofs and lease drop close connections; control tests require explicit
  acceptance, reject a non-launchable profile and verify Stop removes relays.
- Combined Linux/NVIDIA test: both authenticated workers attach, Meteor launches
  the upstream engine app, synthetic tracking traverses the native endpoint and
  encrypted return path, and 201 actual NVENC frames pass wire/decode/ownership/
  encoder-drain validation with no engine shutdown errors. The consumer is a
  native wire fixture plus host FFmpeg validation, **not Quest MediaCodec**.
- Android release shared libraries (streaming and XR) compile/link; 36 GDScript
  scripts pass. Meteor suite: 88 passed, 9 ignored. Opt-in native-worker and
  combined GPU tests were explicitly run and passed.

Logs: /tmp/nightfall-xr-relay-live-test.log, /tmp/nightfall-xr-relay-gpu.log,
/tmp/nightfall-xr-relay-regressions.log, /tmp/nightfall-xr-relay-gdscript.log,
/tmp/nightfall-xr-relay-android.log, /tmp/nightfall-xr-relay-apk-build.log.
Runtime adapter logs now use a fresh private directory per attempt:
`.build-cache/meteor-xr/lan-sessions/<timestamp>-<pid>/runtime.log`.
The same directory retains service/import/probe logs, outcome JSON and validation
artifacts, even after a failed attempt or retry. Meteor prints the exact directory
at launch and includes the log path and process status in runtime failures.
This development cache is not automatically pruned; encoded/decoded diagnostic
artifacts can consume disk space over repeated tests.
Engine-import stdout/stderr now survives failures in monado-nvenc-spike/godot-import.log.

Next physical gate: provision the public pin/device allowlist, start only the
intended development listener, install the optimized APK, then one complete
authenticate → explicit accept → scene/control → B/Y exit → relaunch test over
the actual LAN. Quest decoder/display recovery and real-network behavior remain
unverified. Do not infer them from the loopback/synthetic run above.

First physical LAN attempt (2026-10-19): control reached exclusive preparation,
but the client mistook native `idle` during the asynchronous layer drain for a
startup failure and cancelled before listeners started. The readiness wait now
allows idle while the projection session is exclusive, retaining its five-second
deadline and immediate failed/stopping checks. Added regression coverage and
control-state diagnostics. Physical video validation remains pending the retry.

Physical retry: user confirmed entry into the world and movement on the second
authenticate/accept attempt. Quest logs show first frame at 22:46:25, 200 frames
received, then native drain to idle at 22:46:35. Host validation reports 201
decoded frames and balanced leases/encoder drain. This confirms actual LAN
encrypted transport through Quest decode/projection, not just the host fixture.
The first attempt failed before any frame with `Authenticated XR relay
disconnected` and a host runtime-adapter failure; its runtime log was overwritten
by the successful retry. First-attempt startup reliability remains outstanding;
do not label the path reliable or infer its cause from the successful run.

Per-attempt diagnostics change: two successive automated combined GPU/native
relay sessions passed with isolated artifacts. The first-attempt physical failure
was not reproduced by those synthetic-tracking runs; it still needs real-device
evidence rather than a speculative timeout increase. Session-directory regression
checks verify private permissions and preservation of the preceding attempt.

## Sustained-rate profile (next checkpoint)

The public developer `[host]` configuration may set `hz=60`. The accepted
512-square-eye profile then launches a 1,200-frame target (approximately 20
seconds at target rate); omitted `hz` retains the 200-frame/20-Hz baseline.
Negotiation retains the offered rate and passes it to the fixed runtime adapter.
No network-supplied executable, arbitrary dimensions or indefinite run is added.
The 60-Hz offer gets a bounded 60-second accepted lease (the 20-Hz baseline keeps
30 seconds), so host startup plus sustained video does not race the old lease.
The 45-second projection deadman and B/Y exit remain active. Target cadence is
not a measured throughput or latency claim.

Both wire validators and the rebuilt isolated Monado direct transport now allow
up to 2,048 frames; boundary regressions still reject excess frames. The larger
Python diagnostic allowance is restricted to the upstream-demo path. Engine
validation decodes every frame to small frame hashes and only retains one RGB
frame, avoiding multi-gigabyte raw RGB output for sustained sessions.

Saved logs exposed a headless-import abort before any stream: a late editor
callback called `EditorNode::is_cmdline_mode()` with no remaining editor instance.
The separate `godot-4.7-headless-import-cleanup.patch` treats that state as
command-line mode, skipping editor-only work. It is applied only to the isolated
host engine by `build_xr_engine_fixture.sh`, not the Android toolchain. Verify
repeated imports and the complete sustained run before treating this guard as a
confirmed fix; the original unrecorded physical failure is not proven identical.

Automated sustained-profile evidence: 1,201 frames delivered/decoded, balanced
leases, encoder/raw/delivery drains and clean host-engine shutdown. Encoded display
timestamp cadence measured **54.38 Hz**, below the requested 60-Hz target; this is
not Quest display rate or motion-to-photon latency. The fixture's synthetic
tracking/native wire consumer is still not a physical sustained-session test.
Regression results: 91 active Rust tests, 25 focused Python tests and all 36
GDScript test scripts pass. Log: `/tmp/nightfall-xr-sustained-guarded.log`.

Physical sustained test (2026-10-19 23:28): first frame approximately 7.4 seconds
after acceptance; 22.6 seconds of received video followed by native drain to idle.
Host validated 1,201 encoded/decoded frames, balanced leases, encoder drain and
clean engine shutdown, at 53.06-Hz encoded display-timestamp cadence. Quest's
final projection counter was 1,199; do not equate that counter with host encoded
or decoded counts, or claim every encoded frame was displayed. No client relay
failure was reported. Right-stick input and host locomotion changes were logged;
both controllers were not simultaneously active in the sampled input evidence.
Session artifacts: `lan-sessions/1792445316628755536-2886807/`.
The user reported completion, not a detailed visual-quality rating. Next useful
work is cadence/latency instrumentation and profiling before raising resolution.

## Host pipeline timing

Every completed engine validation now also writes `pipeline-timing.json`.
For an existing session, regenerate/read the report with:

```bash
.build-cache/model-tester-venv/bin/python test/report_xr_pipeline.py \
  .build-cache/meteor-xr/lan-sessions/<attempt> --target-hz 60
```

The report separates raw-job queue wait, encode-worker wall time, GPU-pack wall
time, NVENC submit-to-lock, delivery queue/service, local socket send and ACK
roundtrip. All durations use the host monotonic clock; no cross-machine clock
subtraction is used. ACK means codec input admission on Quest, **not** completed
decode/presentation (the local native fixture merely acknowledges wire consumption).
Stages overlap/nest, so adding their percentiles does not produce end-to-end
latency. Missing instrumentation in older sessions is null, never a zero-time stage.

The completed physical session's existing data shows median pack 242 us and
NVENC submit-to-lock 951 us, no recorded delivery backpressure, and 145 encoded
display intervals longer than 1.5 target periods. This alone does not identify
whether those gaps originated in app rendering, pacing or host scheduling.

Instrumented synthetic/native-worker run: 1,201 frames, clean shutdown/drains,
59.23-Hz encoded cadence, five intervals longer than 1.5 target periods; median
raw wait 6 us, encode-worker wall 1,159 us, delivery wait 7 us, delivery service
429 us, pack 179 us and NVENC submit-to-lock 842 us. These are **not** physical
Quest/LAN latency numbers or proof of an optimization: only timing instrumentation
changed. The variation from the prior run requires matched device evidence before
changing queue, pacing or resolution policy. Artifacts:
`lan-sessions/1792445543709424848-2904895/pipeline-timing.json`.
Host instrumentation is rebuilt and ready; the installed APK is unchanged.

Physical instrumented run (`lan-sessions/1792445631473380157-2886807/`): 1,200
host frames validated, clean host shutdown/drains and Quest return to idle;
encoded cadence 56.69 Hz. Median encode-worker wall was 1,686 us (p95 2,165),
raw wait 18 us (p95 30), delivery wait 21 us (p95 34), delivery service 4,607 us
(p95 6,904), ACK roundtrip 4,408.5 us (p95 6,590), and no delivery backpressure.
There were 64 encoded timestamp gaps over 1.5 target periods. Neither stage
medians nor these queues demonstrate a sustained encode/network bottleneck.
Quest's projection counter was 1,108, below host encoded count. The receiver uses
`AImageReader_acquireLatestImageAsync`, so superseded images can intentionally be
skipped; this run does not quantify how much of the difference is latest-image
replacement, fence/swapchain waits or final teardown. Add device-side stage/skip
counters before treating all encoded frames as displayed or changing buffering.

### Device counters (next physical run)

The optimized DEV APK now exposes `meteor_device_counts` in native test status.
The controller logs a JSON `[XR-DEVICE]` snapshot at stopping and again at idle,
so normal app diagnostics retain it without per-frame log scraping. Use the
idle snapshot after the decoder and render resources drain for final accounting.

- `received` / `queued`: valid packets reaching codec setup / successful codec
  input submissions; neither implies decode or presentation.
- `codec_outputs`: matching decoder outputs released to the image reader.
- `selected`: image-reader images borrowed for copying to the projection.
- `superseded_before_selection`: wire sequence numbers skipped before a later
  image is selected, including initial skips. This is not proof that the reader
  alone caused the skip, and does not include an unselected tail at shutdown.
- `projection_copies`: successful projection copies, not compositor display ACKs.
- Metadata-lock, no-image, acquire-fence, copy-fence and swapchain wait counters
  count polls, **not unique dropped frames**. Reuse counts report callbacks that
  keep the preceding projection when a new decoded image cannot yet be used.

For a completed, ordered session, `queued - selected - superseded` describes the
unselected tail; `selected - projection_copies` can expose a selected but never
copied image. Compare counts only after idle, not across concurrent live reads.
No queue policy, image ownership, GPU wait deadline or frame selection changed.
Portable accounting tests cover initial/interior skips, tail and session reset;
the native unit runner includes them.

Physical counter run (`lan-sessions/1792445899428588576-2886807/`, 23:38):
host encoded/validated 1,201 frames at 56.25-Hz encoded timestamp cadence; Quest
received and queued 1,201, released 1,201 codec outputs, selected/copied 1,199,
and accounted for exactly two sequence supersessions. Final unselected tail and
selected-but-not-copied counts were zero. Idle matched stopping counters; clean
native/host shutdown and balanced leases/drain. This run's entire count difference
is accounted for, but does not retroactively explain the previous 92-frame gap.
There were zero metadata-lock, acquire-fence or swapchain wait polls, 1,156
nonblocking copy-fence wait polls, and 1,373 preceding-projection reuse polls.
Wait/reuse polls overlap and are not dropped-frame counts; do not remove fences
or infer a GPU bottleneck from their magnitude. Host medians: encode-worker
1,705 us, ACK 4,290 us, raw/delivery waits 19/21 us, one delivery backpressure
event. Remaining cadence loss is already present in host encoded timestamps;
next investigate application/compositor pacing and diagnostic file/log overhead.

## Diagnostic monitor overhead reduction

The host demo formerly re-read and split its entire growing JSONL ledger every
application frame. The default monitor now reads only appended bytes, in at most
128-KiB chunks, at most 10 polls/s. It counts newline-terminated records correctly
even if a writer/chunk ends mid-record; truncation fails explicitly. Disconnect
and 35-second watchdog checks still run each application frame. Completion may
overshoot the frame target by a few frames before the next poll; wire/session
limits and ordered final drain remain enforced.

For controlled developer comparisons only, launch the host/test with
`NIGHTFALL_XR_MONITOR_LEGACY=1` to retain the old monitor. This is local CLI
environment, not a network-selectable app or unlimited profile. The monitor emits
one aggregate `ENGINE_MONITOR_TIMING` at shutdown; the pipeline report includes
bytes, poll counts, total/max callback cost and draw-callback spans. Those are CPU
application callback timings, not GPU or physical presentation measurements.

Measured synthetic-worker baseline: 1,201 frames at 58.12 Hz, 1,222 ledger polls,
252,508,055 bytes read, 1,572,725 us cumulative monitor work and 3,996 us maximum
poll. Verified incremental repeat: 1,205 frames at 58.81 Hz, 175 polls, 411,307
bytes read, 48,428 us cumulative work and 463 us maximum poll. Clear diagnostic
I/O/CPU savings; the modest cadence change and run-to-run variability do not
establish that this resolves all frame gaps. GPU fences/queues are unchanged.

First incremental comparison drained host video but failed the synthetic tracking
publisher's clean-exit assertion; do not call that whole run a PASS. The repeat
passed the complete native-worker/runtime gate. Preserve the earlier failure at
`lan-sessions/1792446105883521218-2936163/` for lifecycle follow-up. The Rust
integration gate now also waits for `pipeline-timing.json` and the final validator
PASS, preventing test teardown from racing report generation after the earlier
engine-outcome file appears.

Baseline: `lan-sessions/1792446068775390257-2934049/`; verified repeat:
`lan-sessions/1792446194838645886-2941967/`. New GDScript regression covers partial
records, repeated polls, capped chunks and truncation. The next physical run uses
the updated host monitor with the already-installed APK; no headset rebuild is
required. Physical cadence improvement remains unverified.

Physical incremental-monitor follow-up (`lan-sessions/1792446282704191621-2886807/`,
23:44): 1,203 encoded/received/queued/codec-output frames, 1,200 projection copies,
three accounted supersessions, zero unselected tail; clean host validation/drains
and native return to idle. Encoded cadence 59.26 Hz, p95 interval 16.67 ms, ten
intervals over 1.5 target periods, versus 56.25 Hz / 70 long intervals in the prior
physical monitor run. This is encouraging single-run evidence, not locked 60 Hz
or a controlled multi-run performance guarantee. Monitor read 581,760 bytes in
174 polls, total 54,819 us, max 653 us. Median encode-worker time 1,684 us and ACK
roundtrip 4,269 us remained close to prior values. Copy-fence wait polls 1,197;
zero metadata-lock, acquire-fence and swapchain waits. Keep fence ownership intact.

## 1024-square-eye profile (next physical gate)

The public developer config accepts `eye_size=1024` alongside `hz=60`; omission
still selects the proven 512-square baseline. Host negotiation stores the offered
size and passes it through the managed runtime, simulated HMD recommendation,
GPU packing and encoder. Both wire validators/rectangle guards explicitly allow
the new bounded shape. Unsupported sizes still fail instead of being silently
scaled. The higher profile is restricted to the upstream demo diagnostic.

This is 2048x1024 packed video versus 1024x512 previously: four times the pixels,
not an FOV or stereo-pose change. The current encoder's existing area-based CBR
policy raises its nominal target from 16 to 64 Mbps. The Quest projection texture
was already 1024 square per eye, so its size, fences and ownership are unchanged.
The session still targets 1,200 encoded frames at 60 Hz with the same exit/deadman
controls; neither resolution nor rate is advertised as a production capability.

Offline engine validation uses lightweight per-frame CRC output rather than MD5;
both force full decoding and validate frame count/byte size, with one RGB frame
retained for the existing nonblank/stereo smoke check. Neither is a pixel oracle
or a cryptographic integrity check (transport authentication remains unchanged).
No full raw-video dump is created.

The first local attempt hit an overlooked fixed-size guard in the outer capture
hook and rejected before encoding; that guard is now updated and the isolated
runtime rebuilt. Do not infer stability from that rejected attempt. Physical
testing remains pending successful combined validation and optimized deployment.

Combined 1024 profile passed locally with 1,202 frames, 2048x1024 packed output,
59.30-Hz encoded cadence, four long timestamp intervals, balanced image leases
and clean encoder/delivery/engine drain. Artifacts:
`lan-sessions/1792446584080393610-2975607/`. Regression checks: 92 active Rust
tests, all 37 GDScript scripts, 27 focused Python tests and standalone native wire
and rectangle tests pass. Optimized DEV APK and host release binary rebuilt for
this profile. Physical 1024-square decode/display performance remains unverified.

Physical 1024-square run (`lan-sessions/1792446677322487546-2979148/`, 23:51):
confirmed 2048x1024 packed output, 1,207 encoded/received/queued/codec outputs;
1,192 selected/copied and 15 supersessions, zero unselected tail. Encoded cadence
59.15 Hz, p95 interval 16.67 ms, seven long timestamp intervals. Median encode
worker 3,533 us (p95 4,216), NVENC 2,849 us, ACK 5,793 us (p95 7,759). One
delivery backpressure event. Zero acquire-fence/swapchain waits, one metadata-lock
poll; 1,176 copy-fence wait polls. Clean host validation, ownership/drains and
native return to idle. Fourfold pixel increase retained similar encoded cadence
in this run, with higher encode/ACK costs and more accounted supersessions than
512-square. User reported completion only; visual sharpness/smoothness has not
been explicitly rated. This is not a full-rate/latency guarantee.

The user subsequently explicitly confirmed that 1024 per eye looked sharper and
remained smooth. Treat it as the current visually tested baseline.

## Repeat-start helper cache

`probe_monado_nvenc.sh` now delegates helper preparation to
`test/xr_preflight_cache.py`. Cold preparation compiles and runs the same rectangle,
format, image-lease, queue and transport regressions, then builds both native
bridge libraries. Only successful preparation writes the validated manifest.
The key covers C/C++ helper sources/headers, external NVENC headers, build script,
cache implementation and compiler identity. Cache hits re-hash every artifact and
check executable permissions; missing/tampered artifacts or corrupt manifests
rebuild, never silently bypass validation. A file lock serializes preparation,
private cache directories isolate it, and independent copies go into each session.
This remains a trusted local development cache, not signed production packaging.

Measured preparation: 3,411.2 ms cold, 8.5 ms cached. The complete cached 1024/60
native-worker/runtime test passed with 1,203 frames and clean drain/shutdown;
its preflight was 10.0 ms and Godot import remained 1,817.0 ms. Artifacts:
`lan-sessions/1792446945452606114-2993878/`. Source still undergoes headless import
on every run; no import failure is ignored or converted into success. The final
cache revision is primed for the next headset run. No APK/native queue change.
32 focused Python tests cover cache invalidation, tamper/missing artifacts,
malformed manifests, inputs changing during a build and failed-build rejection
alongside prior pipeline tests.
Actual acceptance-to-first-frame improvement still needs headset confirmation.

Physical cache test (`lan-sessions/1792447085344046505-2979148/`, 23:58):
acceptance at 23:58:06.225, first projection at 23:58:09.676, **3.451 seconds**,
versus 6.735 seconds in the preceding 1024-square run. Cached preflight 8.3 ms;
headless import 1,792.2 ms remains. Host cadence 59.12 Hz, clean validation/drains
and native idle. Device queued/output 1,206, selected/copied 1,150 with 56
supersessions and zero tail. Counts reconcile, but skips increased from 15 in
the preceding run; faster startup is confirmed, not improved presentation
consistency. Zero acquire-fence/swapchain/metadata-lock wait polls. Longer-session
validation should retain these counters and track their run-to-run variation.

Longer sessions remain the next separate increment. Do not simply raise the
frame target: the 2,048-frame wire bound, 45-second headset/host deadlines,
60-second control lease, engine watchdog, fixture timeout and validation budget
must agree on an explicit bounded longer profile first. Current test duration
and all exit controls remain unchanged in this cache-only increment.

## Explicit one-minute profile (next physical gate)

Public developer config: `long_run=true`, `hz=60`, `eye_size=1024`. This sends
the separate strict-schema `offer_long` request; normal `offer` still uses the
short profile. Long offers at 20 Hz or with arbitrary duration fields are rejected.
Acceptance keeps the size/rate/long flag bound to that connection-owned session.

Coordinated bounds:

- Target: 3,600 encoded frames, approximately one minute at target cadence.
- Wire hard cap: 4,096 frames on host, headset and direct transport.
- Accepted control lease: 120 seconds for long offers (short leases unchanged).
- Headset deadman: 90 seconds only for explicit long Meteor sessions, 45 for
  ordinary tests. Hold B/Y one second or suspend the app to exit as before.
- Engine watchdog: 80 seconds for this frame target; host app harness: 90;
  managed host task: 100. Synthetic test endpoint/client budgets are 100/110.
- Normal cancellation still gives the app/service four seconds to exit. Only
  after Python has reaped both can its `postrun-validation` marker permit up to
  20 seconds of additional validation-only grace. No XR app is kept alive by it.

The output still includes frame-accounting and timing reports. At nominal
64 Mbps a one-minute diagnostic can retain roughly 480 MB of encoded video,
plus logs; caches are development artifacts, not automatically pruned here.
Short profile remains selectable with `long_run=false`. No change to bitrate,
resolution, GPU-fence ownership, latest-image policy or ordinary Meteor startup.
Physical long-session reliability remains pending validation/deployment/test.

Full local long-profile validation passed with 3,606 encoded/delivered/decoded
frames, 2048x1024 packed output, 59.53-Hz encoded cadence, ten long timestamp
intervals and clean engine/encoder/transport drain. Application draw span was
60.59 seconds; the whole harness including preparation and post-run validation
took 73.41 seconds. Artifacts:
`lan-sessions/1792447330668272667-3020893/`. The larger validation-only budget
is exercised without changing image ownership or holding an XR app alive.
Optimized APK/host builds and local wire hard-cap tests pass; physical one-minute
headset testing remains pending. The development cache is warm for that test.

Physical one-minute run (`lan-sessions/1792447481844626946-3028687/`, 2026-10-20
00:05): 60.65-second application draw span, 3,601 encoded/received/queued/codec
outputs, 3,548 selected/copied and 53 supersessions (1.47%), zero tail. Host
encoded cadence 59.39 Hz; median/p95 interval 16.67 ms, 25 long intervals, zero
delivery backpressure. Median encode-worker 3,468 us (p95 4,009), ACK roundtrip
5,804 us (p95 7,907). Cached preflight 10.2 ms; import 1,834.5 ms. Zero image
acquire-fence, swapchain and metadata-lock waits; 3,525 nonblocking copy-fence
wait polls (not dropped-frame counts). Balanced leases/encoder/transport drain,
clean engine shutdown and native idle. Counts fully reconcile. User reported
completion; no additional subjective rating was requested for this run.
This validates one bounded minute, not hours of operation or full game support.
