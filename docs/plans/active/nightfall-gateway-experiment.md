# Nightfall Gateway experiment

> Status: Active proposal
>
> Date: 2026-09-30
>
> Initial platform: Nightfall Quest client, a Linux gateway on the same LAN,
> and an existing Sunshine-compatible host
>
> Product decision under test: preserve Sunshine, Apollo, Polaris, and
> Vibepollo as independent hosts while an optional Nightfall Gateway adds
> frame-synchronized depth and future Nightfall-specific services.

## Decision summary

Build an optional gateway that connects upstream as a Moonlight client and
accepts a separate, versioned Nightfall protocol downstream from the headset.
It terminates both authenticated sessions, relays the original compressed
video without decoding and re-encoding it for delivery, and separately decodes
the same encoded frames on the gateway GPU for depth inference.

```text
Other Moonlight clients ───────────────► Sunshine/Apollo/Polaris directly
                                                │
                                      upstream GameStream session
                                                ▼
Nightfall headset ◄── Nightfall protocol ── Nightfall Gateway
                                                ├─ compressed video relay
                                                ├─ audio/input/rumble bridge
                                                ├─ duplicate GPU decode tap
                                                ├─ synchronized depth stream
                                                ├─ microphone service later
                                                └─ XR orchestration later
```

This is a terminating gateway, not a transparent packet proxy. GameStream
pairing, encryption, session negotiation, and transport state belong to the
upstream connection; the headset has an independent authenticated session with
the gateway. The encoded video access units may remain byte-identical, but
their transport framing and encryption cannot simply be forwarded unchanged.

The existing direct Nightfall-to-host connection remains the default and
fallback. Installing the gateway must not modify the existing host or prevent
other Moonlight clients from connecting to it directly.

## Why test a gateway

- One independently maintained component can add Nightfall features in front
  of Sunshine, Apollo, Polaris, or Vibepollo without requiring every upstream
  project to accept and maintain those features.
- The gateway sees the exact encoded frame sent to the headset. It can assign
  one frame identity to both video and its derived depth map, which a separate
  capture-side companion cannot guarantee.
- Server-side EdgePad inference can use a desktop GPU, where inference is much
  faster and does not compete with headset decoding or rendering.
- The original encoded stream can still reach the headset without another
  lossy generation or the latency of a second encode.
- It creates a controlled place for Nightfall-specific capabilities such as
  synchronized depth, diagnostics, microphone devices, and XR mode
  orchestration while retaining upstream compatibility.

The gateway is not automatically the final architecture. The experiment must
prove that protocol ownership, latency, reliability, and maintenance cost are
better than a small upstream plugin or a complete Nightfall host.

## Goals

1. Connect to an unmodified Sunshine-compatible host using the existing
   GameStream/Moonlight protocols.
2. Relay H.264, HEVC, or AV1 access units to Nightfall without video
   transcoding.
3. Preserve codec configuration, HDR metadata, timestamps, keyframes, and
   recovery behavior.
4. Decode a non-blocking copy of each assembled access unit on the gateway GPU
   for EdgePad depth inference.
5. Give every video frame and depth result an unambiguous shared identity.
6. Let the headset use bounded depth synchronization without creating
   unbounded video latency or audio drift.
7. Keep direct mode available when the gateway is absent, unsupported, or
   unhealthy.
8. Establish secure discovery, pairing, upgrades, diagnostics, and failure
   behavior suitable for a later product.
9. Measure the real cost before adding microphone, XR, or host-like features.

## Non-goals for the first experiment

- Replacing Sunshine, Apollo, Polaris, or Vibepollo.
- Supporting ordinary Moonlight clients downstream of the gateway.
- Re-encoding or visually modifying the video stream.
- Multiple monitors, virtual displays, or application launching.
- XR-environment streaming.
- Microphone passthrough.
- Internet exposure or operation outside a trusted LAN.
- Supporting every codec, operating system, and GPU in the first prototype.
- Combining several upstream streams into one canvas.
- Shipping a background service or polished settings application before the
  relay and depth paths are proven.

## Required operating modes

Nightfall should expose the topology rather than silently choosing one:

```text
Direct mode       Nightfall headset ──► Sunshine-compatible host
Gateway mode      Nightfall headset ──► Nightfall Gateway ──► host
XR overlay mode   Nightfall overlay ──► WiVRn/Monado composition path
```

Gateway discovery may offer a convenient default, but a saved host entry must
record whether it targets a direct host or a gateway. Failure to discover or
connect to a gateway must never redirect credentials to another service.

## Component ownership

| Responsibility | Initial owner |
| --- | --- |
| Desktop capture and application launch | Upstream host |
| Video encoding and HDR production | Upstream host |
| Virtual display and host controller emulation | Upstream host |
| Upstream pairing and GameStream session | Gateway |
| Encoded access-unit assembly | Gateway |
| Downstream transport and congestion handling | Gateway and Nightfall |
| Duplicate hardware decode for inference | Gateway |
| EdgePad inference and depth normalization | Gateway |
| Video decode and OpenXR presentation | Nightfall headset |
| Depth/video synchronization and stereo warp | Nightfall headset |
| Headset input and upstream input conversion | Gateway |
| Upstream rumble and downstream haptics | Gateway and Nightfall |
| Audio playback clock | Nightfall headset |
| Direct connection fallback | Existing Nightfall client |
| Future virtual microphone | Gateway |
| Future PCVR transport | WiVRn, not GameStream |

## Protocol boundary

### Upstream

The gateway acts as a normal Moonlight client. Reuse a maintained protocol
implementation such as `moonlight-common-c` wherever possible rather than
reimplementing pairing, RTSP negotiation, input packets, and stream recovery.
The first investigation must identify the callback where a complete encoded
access unit is available before it enters a decoder.

### Downstream

Use a small Nightfall-specific protocol instead of pretending to be a complete
Sunshine server. Recreating the whole GameStream server interface would inherit
application discovery, launch semantics, pairing compatibility, and legacy
behavior that the gateway does not need.

The downstream protocol must be independently versioned and capability based.
The first negotiated session description should include:

- protocol version and optional capabilities;
- codec, profile, level, resolution, and nominal frame rate;
- color primaries, transfer function, matrix, range, and HDR metadata support;
- audio codec, sample rate, channels, and channel layout;
- depth availability, dimensions, format, cadence, and normalization version;
- maximum datagram and fragmentation behavior;
- selected synchronization policy and maximum depth wait;
- session epoch and clock synchronization data.

Use separate logical channels for control, video, audio, input, haptics, depth,
and telemetry. Control messages require reliable ordered delivery. Video and
depth should use sequenced low-latency delivery with explicit recovery rather
than head-of-line blocking old frames. The transport choice is an experiment
deliverable; QUIC is a strong candidate but must be measured against the
existing RTP-based path before it becomes a commitment.

### Frame identity

Every assembled video access unit receives a gateway frame ID within a session
epoch. Its envelope should include:

- session epoch;
- monotonically increasing gateway frame ID;
- upstream frame index when the host exposes one;
- gateway receive and assembly timestamps;
- presentation timestamp or derived stream clock timestamp;
- keyframe, codec-configuration, discontinuity, and HDR flags;
- fragment index/count and payload integrity data.

The corresponding depth result carries the same epoch and frame ID. A session
restart changes the epoch so delayed packets can never match a new stream.

### Codec fidelity

The relay must preserve parameter sets, codec configuration records, HDR
metadata, reference-frame ordering, and access-unit boundaries. IDR requests,
packet loss, congestion feedback, stream reconfiguration, and resolution
changes must cross the gateway deliberately. Success is not merely displaying
a picture; the downstream decoder must recover as reliably as it does in
direct mode.

## Media and input paths

### Video

```text
upstream packets
      │
      ▼
access-unit assembler ──► downstream packetizer ──► headset decoder
      │
      └─► bounded inference tap queue ──► gateway decoder ──► EdgePad
```

The forwarding path must not wait for duplicate decode or inference. The tap
queue is bounded and drops inference work when overloaded; it never drops or
delays video merely to preserve every depth update. Depth cadence may be lower
than stream cadence.

No decoded RGB frame should pass through the relay path. No full-frame CPU
copy should exist in the target inference path. Any temporary copy in the
prototype must be measured and logged.

### Audio

Relay the negotiated compressed audio format when practical. Audio remains on
the video presentation clock and must not wait on depth independently. If the
client deliberately delays video for depth synchronization, it must apply the
same presentation offset to audio or cap the video wait below a tested
perceptual threshold. The design must report measured audio/video skew.

### Input and haptics

Nightfall sends normalized controller, hand-derived pointer, keyboard, mouse,
and gamepad events to the gateway. The gateway converts them to the upstream
protocol. Upstream rumble packets are validated and translated back to the
appropriate Nightfall controller without allowing malformed host values to
reach the OpenXR haptic API.

Input must have its own low-latency path and must never queue behind depth or
diagnostic traffic.

## Server-side depth architecture

For each selected access unit `N`:

```text
encoded access unit N
  ├─ unchanged compressed payload ──────────────► Nightfall video N
  └─ hardware decode ─► GPU texture ─► EdgePad ─► Nightfall depth N
```

The initial model should be the current highest-quality EdgePad-384 pipeline.
The gateway has a different performance budget from Quest, so model choice
must remain negotiated rather than hard-coded permanently.

The first depth payload should be deliberately simple: an 8-bit normalized
480x270 map at 20 Hz. That is approximately 2.59 MB/s, or 20.7 Mbit/s before
transport overhead, and is acceptable as a LAN feasibility baseline. Add
lightweight lossless, delta, or video-style depth compression only after the
uncompressed path proves timing and quality; compression must not obscure
whether synchronization works.

Each depth packet/result must describe:

- epoch and source video frame ID;
- width, height, stride, and format;
- depth normalization and inversion convention;
- model and post-processing revision;
- decode, inference, and packaging timestamps;
- valid-region or confidence metadata if later models expose it.

### Client synchronization policy

The headset keeps a small frame-indexed depth cache. It should support:

1. **No wait:** present video immediately and use the newest eligible depth.
2. **Bounded sync:** wait up to a configured small budget for exact-frame
   depth, then present using the newest safe depth or flat fallback.
3. **Diagnostic exact match:** development-only mode that exposes misses and
   latency; it must not become a normal unbounded queue.

The existing Depth Sync work is the starting point, but matching must use the
gateway frame identity rather than arrival order. A late depth map must never
be applied to an unrelated newer frame. Stream discontinuities flush both
caches.

## Security and privacy

- The gateway owns its upstream Moonlight certificate, keys, PIN pairing, and
  saved host credentials. They are never sent to the headset.
- The headset and gateway use a separate pairing identity with mutual
  authentication, fresh session nonces, encryption, and replay protection.
- Discovery advertises a distinct Nightfall Gateway service and must not
  create discovery loops with the upstream host.
- Bind to the local network by default. Internet listening requires a future
  explicit threat model and configuration.
- Protect saved credentials with operating-system facilities and restrictive
  file permissions.
- Diagnostics must never include private keys, passwords, pairing PINs,
  keyboard text, decoded screen pixels, or microphone samples.
- Protocol parsers must validate lengths, frame dimensions, packet counts,
  enum values, and allocation limits before use.
- The gateway must publish its exact build and protocol revisions in exported
  diagnostics without exposing secrets.

## Phase 0: feasibility and baseline

### Work

1. Create a separate experimental repository or isolated prototype for the
   gateway; do not embed a long-running host daemon inside the Android project.
2. Choose one known host and record its version, codec, HDR setting, stream
   resolution, frame rate, network, and GPU/driver details.
3. Capture direct Nightfall baseline metrics for latency, frame pacing, loss,
   bitrate, reconnect behavior, and visual quality.
4. Prove that the chosen upstream client library exposes complete encoded
   access units before decode.
5. Record whether access-unit data can be retained/referenced safely without a
   full CPU copy.
6. Trace keyframe requests, resolution changes, and codec configuration from
   host to client.
7. Decide the smallest downstream transport prototype after comparing QUIC
   datagrams/streams with a narrow RTP-derived implementation.

### Exit gate

- Complete access units and their stream metadata are observable without an
  upstream-host fork.
- A credible no-transcode relay path exists.
- No protocol or license constraint makes distribution impractical.

## Phase 1: relay-only prototype

### Work

1. Pair and connect the gateway to one upstream host.
2. Add a minimal authenticated downstream Nightfall session.
3. Support one codec first, matching the current normal release configuration.
4. Forward codec configuration and encoded access units to Nightfall.
5. Decode and present them with the existing Android hardware decoder and
   native XR renderer.
6. Relay audio and basic gamepad input.
7. Implement IDR requests, clean disconnect, reconnect, and stream restart.
8. Add packet/frame tracing that correlates both sides without logging media.

### Exit gate

- A 30-minute stream runs without video transcoding or unexplained corruption.
- Relay-only visual output is indistinguishable from direct mode.
- Added gateway processing latency is below 1 ms at p95, excluding network
  transit and the existing host/headset codecs.
- Depth-disabled forwarding never waits for a full decoded frame.
- Input and audio remain usable through reconnect and one resolution change.

## Phase 2: non-blocking duplicate GPU decode

### Work

1. Feed references to the same access units into a bounded inference queue.
2. Add hardware decode on the gateway's initial GPU platform.
3. Keep decode output GPU-resident through resize and model input.
4. Drop old inference work when the queue is full while preserving the relay.
5. Log every GPU/CPU boundary and measure decode, resize, inference, and queue
   time independently.
6. Verify that enabling the tap does not alter packet forwarding or keyframe
   behavior.

### Exit gate

- Duplicate decode cannot block video, audio, or input forwarding.
- Sustained overload reduces depth cadence rather than stream cadence.
- The target path performs no full-frame GPU readback.
- Relay latency and frame pacing remain inside the Phase 1 budget.

## Phase 3: synchronized depth side channel

### Work

1. Run EdgePad-384 against selected decoded frames at an initial 20 Hz cap.
2. Send R8 480x270 depth with exact source frame IDs.
3. Add Nightfall diagnostics for gateway decode, inference, depth age, exact
   matches, reused maps, dropped maps, and queue depth.
4. Add the Nightfall Depth debug view for received gateway maps and final warp.
5. Test scene cuts, rapid camera motion, animation, text, reconnects, and
   stream reconfiguration.

### Exit gate

- Every displayed depth map can be traced to its source video frame.
- The client rejects stale epochs and impossible frame IDs.
- Depth overload cannot destabilize the stream.
- Quality is at least equivalent to local EdgePad at the same model settings.

## Phase 4: bounded presentation synchronization

### Work

1. Add the no-wait and bounded-sync policies.
2. Measure motion coherence against the current local-inference path using the
   same clips and interaction tests.
3. Measure motion-to-photon latency and audio/video skew with depth off,
   no-wait depth, and bounded depth.
4. Tune only after collecting distributions for depth arrival time; do not
   derive the wait from a single average.
5. Flush queues on seek-like discontinuities, reconnect, model change, and
   resolution change.

### Exit gate

- Bounded sync materially improves frame/depth coherence.
- It never adds more than its configured maximum delay.
- Audio remains synchronized within the selected acceptance threshold.
- Users can disable the feature without restarting the session.

## Phase 5: hardening and compatibility matrix

Test at least:

- Sunshine, Apollo, Vibepollo, and Polaris where available;
- H.264, HEVC SDR, HEVC HDR, and AV1 where supported;
- 1080p, 1440p, and 4K at 60, 72, 90, and 120 FPS where hardware permits;
- normal loss, deliberate packet loss, Wi-Fi roaming, host sleep, headset
  standby, gateway restart, host restart, and application relaunch;
- depth disabled, depth capped, and depth overloaded;
- Quest 2, Quest 3, and Quest 3S behavior;
- NVIDIA, AMD, and Intel gateway GPUs before claiming broad compatibility.

Only after this matrix should the gateway gain service packaging, automatic
startup, UI polish, or remote-network support.

## Phase 6: microphone service

Microphone passthrough is a useful gateway feature but is not coupled to the
video proof:

1. Capture the headset microphone with explicit permission and indication.
2. Send it over an independent low-latency encrypted channel.
3. Expose it as a virtual microphone on the gateway/host machine using
   PipeWire on Linux and a separately evaluated virtual device on Windows.
4. Add mute, gain, device health, and round-trip diagnostics.
5. Determine whether the upstream host can consume the local virtual device or
   requires a host-specific bridge when the gateway is on another machine.

Do not tunnel microphone audio through the game audio clock without proving
that echo cancellation and latency remain correct.

## Phase 7: XR orchestration

XR streaming should reuse WiVRn rather than forcing stereo XR frames through
GameStream. The gateway may later act as the control plane that:

- detects an active OpenXR application;
- starts or monitors WiVRn/Monado;
- asks the Nightfall UI to enter an XR-oriented mode;
- launches the Nightfall desktop overlay described in the
  [WiVRn Nightfall overlay experiment](wivrn-nightfall-overlay-experiment.md);
- preserves a shortcut or wrist control to reveal and hide desktop screens.

This is orchestration between two transports, not an attempt to place WiVRn
frames inside the gateway media protocol.

## Multiple monitors

The gateway does **not** solve multiple monitors by itself. A normal upstream
GameStream session supplies one encoded desktop surface. Future choices are:

1. **Several upstream sessions:** preserves independent monitor quality but
   multiplies capture, encode, bandwidth, and host-session complexity.
2. **One stitched desktop canvas:** uses one stream but spends resolution on
   unused space and limits independent monitor quality and refresh rates.
3. **Direct secondary capture in the gateway:** efficient on a same-machine
   gateway, but starts turning the gateway into a host and requires platform
   capture, permissions, HDR, and virtual-display work.
4. **Host-specific extension/API:** potentially the cleanest data path, but no
   longer universal without adapters for each host.

Defer this decision until the single-stream relay and depth paths are proven.
Keep the downstream protocol capable of identifying multiple future surfaces,
but do not implement or advertise them in the initial experiment.

## Performance budgets and instrumentation

| Area | Initial success target |
| --- | --- |
| Video transcoding | None |
| Relay processing | Under 1 ms p95 per frame |
| Extra depth-off presentation latency | Less than one frame |
| Full-frame CPU copies in depth path | Zero in target implementation |
| Inference overload behavior | Drop depth work, never stream frames |
| Depth cadence | Stable 20 Hz baseline before uncapped tests |
| Video/depth matching | Exact frame IDs, measured miss/reuse rate |
| Audio/video skew | Measured and bounded under sync modes |
| Reconnect | No stale epoch media or credentials leak |

Exported diagnostics should contain distributions, not only averages:

- upstream packet arrival and access-unit assembly;
- packetization and downstream send time;
- downstream RTT, jitter, loss, and congestion state;
- gateway duplicate-decode queue depth and dropped jobs;
- hardware decode, resize, inference, normalization, and packaging time;
- headset receive, video decode, depth receive, presentation, and warp time;
- depth age, exact matches, reuse count, and bounded-sync timeout count;
- audio presentation offset and input round-trip estimates;
- negotiated versions, codecs, formats, and device capabilities.

## Failure behavior

- If depth initialization fails, continue the relay with depth disabled and a
  clear status; never interrupt an otherwise healthy stream.
- If the duplicate decoder falls behind, discard its oldest queued work.
- If downstream congestion occurs, prioritize control, input, audio, and
  decodable current video over depth and telemetry.
- If the gateway dies, Nightfall returns to server selection and offers the
  saved direct host; it does not silently reuse gateway credentials upstream.
- If protocol versions are incompatible, report both versions and supported
  ranges without attempting a partially understood session.
- If HDR or a codec cannot be relayed faithfully, reject that configuration
  rather than silently converting it.

## Stop conditions and alternatives

Stop or redesign the gateway if any of these remains true after the prototype:

- complete encoded access units are inaccessible without maintaining a large
  invasive upstream fork;
- downstream delivery requires decoding and re-encoding video;
- the gateway adds more than one frame of latency when depth is disabled;
- reliable recovery and HDR metadata cannot be preserved;
- frame/depth synchronization requires unbounded buffering;
- the new security surface cannot be made substantially narrower than a full
  host;
- maintaining two protocol stacks costs more than integrating a small module
  into supported hosts.

Fallbacks, in preferred order, are:

1. a Nightfall side-channel companion paired with a normal direct stream,
   accepting weaker frame correspondence;
2. a small host plugin/API for exact encoded frames and depth metadata;
3. selected upstream forks for features requiring deep host integration;
4. a full Nightfall host only after capture, encoding, display, and maintenance
   requirements justify owning the complete stack.

## Repository and implementation boundaries

- The production gateway should live in its own repository and process, such
  as `nightfall-gateway`, with its own release and security lifecycle.
- Keep the downstream protocol schema and compatibility fixtures in a shared,
  versioned package consumable by the gateway and Nightfall client.
- C or C++ is the practical first implementation choice because the existing
  Moonlight protocol and GPU inference components are native, but Phase 0 must
  record the decision rather than treating it as irreversible.
- Isolate upstream-host integration behind an adapter. Gateway core code must
  not contain scattered Sunshine/Apollo/Polaris conditionals.
- Isolate GPU decode/inference behind a backend interface so NVIDIA, AMD, and
  Intel support can be added and tested independently.
- Review all reused code and linked libraries for license and attribution
  obligations before distributing a binary.
- Keep experimental gateway code out of the released APK until the protocol
  has compatibility tests and direct mode remains independently buildable.

## First implementation slice

The first useful test should do exactly this and no more:

1. Run the gateway on the same Linux PC as a known Sunshine host.
2. Connect upstream at 1080p60 HEVC SDR.
3. Expose one explicitly configured downstream endpoint on the LAN.
4. Connect a development Nightfall build to it.
5. Relay encoded video, audio, gamepad input, and haptics without depth.
6. Run for 30 minutes and compare latency, image hashes where meaningful,
   bitrate, frame pacing, and reconnect behavior against direct mode.
7. Add a non-blocking duplicate GPU decoder.
8. Send frame-ID-only diagnostic messages before sending actual depth data.
9. Confirm IDs and epochs remain correct through an IDR, reconnect, and
   resolution change.
10. Add uncompressed R8 EdgePad depth at 20 Hz and test no-wait mode.

Do not begin microphone, multi-monitor, XR, automatic discovery, or polished UI
work until this slice passes its exit gates.

## Deliverables

- A gateway architecture and threat-model note.
- A versioned downstream protocol specification.
- A relay-only prototype with no-transcode evidence.
- A repeatable direct-versus-gateway benchmark report.
- A frame-ID and session-epoch synchronization test suite.
- A duplicate-decode/depth prototype with copy and latency profiling.
- Nightfall debug views and exported gateway diagnostics.
- A host/GPU/codec compatibility matrix.
- A written proceed, redesign, or stop decision after Phase 4.

## Success definition

The experiment succeeds when an unmodified supported host can stream through
the gateway with no additional video encode, less than one frame of depth-off
latency, direct-mode-equivalent reliability, and correctly frame-matched
server-generated depth that improves motion coherence without destabilizing
audio, input, or video.

Only then should Nightfall treat the gateway as the foundation for microphone,
XR orchestration, multiple surfaces, or progressively more host-like features.
