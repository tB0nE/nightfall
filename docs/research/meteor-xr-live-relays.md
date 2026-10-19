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
