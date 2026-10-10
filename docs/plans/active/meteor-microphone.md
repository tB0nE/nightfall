# Nightfall Meteor: microphone passthrough

> Status: Host side done (Phases 0 and 1). Quest side (Phase 2) built
> 2026-10-08 and installed, not yet tested on the headset (see "Progress").
>
> Date: 2026-10-03
>
> Replaces: [microphone-passthrough.md](microphone-passthrough.md), the
> in-protocol approach on branch `apollo-microphone-passthrough`.
>
> Initial platform: Quest 3 client, Linux host with PipeWire (1.6.9 here,
> through its PulseAudio compatibility layer).

## Why Meteor

The earlier attempt sent microphone audio inside the Moonlight protocol.
That needed a forked moonlight-common-c (logabell's `codex/mic-common-c`),
and only a fork of Apollo accepts that stream; stock Apollo, Sunshine,
Vibepollo and Polaris don't.
The branch also never captured real audio; `_capture_audio` was a silence
stub.

Meteor already runs on the host and already knows which client is streaming,
so it can receive the audio itself and present it to the PC as a normal
microphone. That works with every host (Sunshine, Apollo, Vibepollo,
Polaris), needs no common-c fork, and works whether or not AI 3D is on.

```text
Quest mic ─► AAudio capture ─► UDP :47902 ─► Meteor ─► jitter buffer
             (voice preset,                             │
              echo cancelling)                          ▼
                                    PipeWire source "Nightfall Microphone"
                                      (Discord, games, OBS pick it up)
```

## Progress (2026-10-03)

**Phase 0 (host side)**
- `module-pipe-source` works as a device and produces silence when idle. But
  its built-in rate control holds about **260 ms** of audio, and
  `node.latency` doesn't change that. Too slow.
- A null sink with `media.class=Audio/Source/Virtual`, fed by a `pw-cat`
  process linked with `pw-link` (`node.autoconnect=false`,
  `node.dont-fallback=true`), measures about **8 ms**. Meteor now uses this.
  The pipe source is the fallback when `pw-cat` is missing.
- The device reads a whole graph quantum at a time (1024 samples, 21 ms) and
  pads any shortfall with silence. Each stream therefore starts with 30 ms of
  silence as a cushion:
  - without it: 115 gaps in 3 s;
  - with it: none.
- `pw-cat` reads its input ahead into its own buffer, so its fill level can't
  be used as a clock. Playout runs on Meteor's 10 ms clock instead. Long-term
  drift between that clock and the sound card's is the known limit to check
  in the 30-minute test.
- Still to do: check the device in Discord, KDE's settings and a game. That
  needs a person.

**Phase 1 (done)**
- The pieces (`meteor/src/mic.rs`):
  - the device's lifecycle, including stale-device cleanup and removal on
    exit or SIGTERM;
  - the UDP receiver, accepting only loopback or a client with an active
    video flow;
  - the jitter buffer;
  - tray status, mute, and "Set as default input";
  - the discovery `"mic"` field.
- Test sender: `meteor/tools/send_mic.py`.
- Measured: a tone comes out of the device 80-105 ms after the first packet
  is sent, including the 40 ms jitter buffer and the 30 ms cushion. There
  are no gaps on a clean stream. With 2% loss and 30 ms jitter, the only gaps
  are the lost packets themselves.
- The 30-minute run is still to do.

**Phase 2 (built 2026-10-08, not yet tested on the Quest)**
- Capture: `addons/nightfall-stream/src/audio/meteor_mic.cpp`, native
  AAudio as designed (48 kHz, mono, 16-bit, `VOICE_COMMUNICATION`, low
  latency, shared). A thread reads 480-sample frames and sends each as one
  UDP datagram in the `meteor/src/mic.rs` format to Meteor's port, over a
  connected non-blocking socket (a full buffer or an unreachable port drops
  the frame). It fails to start, with the reason, if the stream doesn't
  open at exactly 48 kHz mono 16-bit.
- Control: `src/meteor_microphone.gd` runs capture while the setting is on,
  the stream goes through a Meteor that offers `pcm_s16le_48k_mono`, the app
  has `RECORD_AUDIO`, and it isn't paused. It retries every 5 s and logs
  `[METEOR-MIC]` packets per second and peak level every 10 s.
- UI: Settings > Microphone (On/Off, off by default). Turning it on asks
  for `RECORD_AUDIO` the first time. One setting for every host, not per
  host as planned above.
- Export: `permissions/record_audio=true`.
- Encrypted (2026-10-08, packet version 2, details in `meteor/src/mic.rs`):
  Meteor makes an X25519 key pair per run and publishes the public key in
  discovery; the headset makes one per session and sends its public key in
  every packet, so there's no handshake. HKDF-SHA256 gives an AES-256-GCM
  key; the sequence number is the nonce and the header is authenticated.
  Cost: 48 bytes a packet and microseconds of CPU. Plain version 1 packets
  are accepted only from loopback (`tools/send_mic.py`). Checked: the C++
  cipher (`mic_cipher.cpp`, OpenSSL) matches a fixed vector from Meteor's
  tests, and a 3 s tone sent encrypted through Meteor recorded from the
  device at the exact level and frequency.
- Opus (2026-10-08): the headset encodes 10 ms frames at 32 kbit/s
  (complexity 5, voice, in-band FEC for 5% loss) when Meteor lists
  `opus_48k_mono`, else sends PCM. Meteor decodes with libopus (built from
  `audiopus_sys`'s bundled source, statically linked) at playout; a lost
  frame comes from the next packet's FEC, else loss concealment. Measured
  on the PC: 83 kbit/s on the wire with headers and encryption (PCM: about
  820); with every 25th packet dropped, each loss showed as a 12-18 ms dip
  to 7-19% of a 440 Hz tone's level rather than silence (FEC is a lower
  quality voice coding, better on speech than on a sine).
- Meteor's key is permanent since 2026-10-08 (`meteor.key`) and the headset
  remembers it per host (trust on first use), so a different Meteor
  answering for that PC is refused. Settings > Forget Meteor Keys trusts a
  reinstalled one.
- Grab bar (2026-10-08): a microphone button left of the controller button
  turns the microphone on and off, lit while on, with a blue dot while
  audio is reaching Meteor. An AI 3D on/off button joins the right side, so
  there are three each side.
- Not done: echo checks with game audio on the speakers, and the exit gate
  below.

## Design

### Client (Quest)

- **Capture: native AAudio** in nightfall-stream.
  - 48 kHz, mono, 16-bit, in 10 ms frames.
  - Input preset `VOICE_COMMUNICATION`, so Android applies its echo
    cancellation and noise suppression where the Quest offers them. Without
    echo cancellation, game audio from the Quest's speakers comes back into
    the mic.
  - Godot's own microphone input (`AudioStreamMicrophone`) is simpler, but it
    has more latency and no way to choose the voice preset, so it's the
    fallback rather than the plan.
- **Permission.**
  - Set `permissions/record_audio=true` in the export presets. It's `false`
    today.
  - Request `RECORD_AUDIO` at runtime the first time the user turns the
    microphone on, not at startup.
- **Sending.**
  - One UDP datagram per 10 ms frame goes to Meteor's microphone port.
  - Header: magic, version, sequence number, sample timestamp, and a mute
    flag. Payload: the PCM frame.
  - v1 sends raw PCM, which is 768 kbit/s. That's negligible next to the
    video, and it means there's no codec on either side, so the first test
    is about capture, transport and the virtual device only.
  - Opus is the planned v2 (about 32 kbit/s, better on poor Wi-Fi). The
    client already links libopus for audio decoding, and the encoder wrapper
    on the old branch (`MicrophoneManager`) can be reused for it.
- **When it runs.** Only while a stream is active, Meteor is present, and the
  user has the microphone on. Capture stops on disconnect, pause or sleep.
  The Quest's own "microphone in use" indicator shows whenever capture is
  running.
- **UI.**
  - A "Microphone" option on the Settings page, shown only when Meteor offers
    a microphone. It's off by default and saved per host.
  - The status line shows when the mic is live.
  - A mute shortcut on the controllers comes later, after v1 is proven.

### Meteor (host)

- **Virtual microphone on Linux.** Implemented as a `pw-cat`-fed virtual
  source (see Progress). The original pipe-source design below is the
  fallback.
  - At startup Meteor loads PipeWire's PulseAudio `module-pipe-source`:
    `pactl load-module module-pipe-source source_name=nightfall_mic`, with
    `file=$XDG_RUNTIME_DIR/nightfall-mic`, `format=s16le rate=48000
    channels=1`, and a description of "Nightfall Microphone".
  - It writes PCM into that FIFO. Applications see an ordinary input device.
  - This needs no build-time PipeWire libraries (none are installed here).
    Meteor unloads the module on exit.
  - At startup Meteor removes a leftover `nightfall_mic` from a crash, so
    there's never a duplicate device.
  - If the pipe source turns out unsuitable (see Phase 0), the fallback is a
    native PipeWire stream with `media.class = Audio/Source/Virtual` through
    the `pipewire` crate, which does need the dev headers.
- **Receiving.**
  - Meteor accepts microphone packets on UDP port 47902, only from a client
    address that currently has an active video flow through Meteor. That's
    the same pairing rule as the depth channel.
- **Jitter buffer.**
  - Target 40 ms.
  - Drop audio once it's more than 120 ms behind, so delay never builds up.
  - Fill gaps with silence.
  - When the stream stops, the source falls silent rather than repeating the
    last frame.
- **Discovery.** The reply gains
  `"mic": {"port": 47902, "formats": ["pcm_s16le_48k_mono"]}`. Opus is added
  to `formats` when v2 lands, and the client picks the best format both
  sides support.
- **Tray.**
  - Shows "Microphone: idle / live (client IP)".
  - Has a "Mute microphone" checkbox that silences the virtual device from
    the PC side.
  - Has "Set as default input", which runs `pactl set-default-source`, for
    users who want every app to use it.

### Security and privacy

- Audio is encrypted since 2026-10-08 (see Progress, Phase 2). The depth
  channel still isn't.
- Encryption belongs to the shared Meteor session work: one session key for
  the depth and microphone channels, agreed during the stream. It isn't
  blocking for a LAN test, but it must be done before this is presented as a
  finished feature.
- Never log audio contents, only levels and counts.

## Phases

### Phase 0: prove the virtual device

1. Load `module-pipe-source` by hand and feed it a test tone with a small
   script.
2. Confirm that it appears as "Nightfall Microphone" in KDE's audio settings,
   Discord, and a game.
3. Confirm what it outputs when nothing writes to it (silence, or a stall).

Exit gate: it works as a normal input device, and an idle pipe doesn't break
apps.

### Phase 1: Meteor side

- The virtual device's lifecycle: load, clean up, unload.
- The UDP receiver and jitter buffer.
- The tray status and mute.
- The discovery field.
- Testing with a desktop sender (a small Rust or Python tool that streams a
  WAV file to port 47902).

Exit gate: the WAV comes out of the virtual mic cleanly, with no added delay
after 30 minutes.

### Phase 2: Quest capture

- AAudio capture, the permission flow, the UDP sender, and the Settings
  toggle.

Exit gate:
- Voice chat in Discord through the Quest mic works for 30 minutes.
- Measured latency is below about 80 ms from mouth to PC.
- With game audio playing on the Quest speakers, echo is acceptable.

### Phase 3: Opus and polish

- Opus encoding on the Quest and decoding in Meteor.
- A controller mute shortcut.
- Encryption, shared with the depth channel.
- Windows research: Windows can't create a microphone without a driver, so it
  needs a virtual audio driver (for example VB-CABLE) or a signed driver of
  our own. That's a separate decision; Meteor is NVIDIA and Linux first
  anyway.

## Risks

| Risk | Mitigation |
| --- | --- |
| Echo from game audio on the Quest speakers | `VOICE_COMMUNICATION` preset (Android echo cancellation); recommend headphones if the Quest's cancellation is weak; measured in Phase 2 |
| Quest doesn't honour the voice preset | Test it in Phase 2; fall back to a software noise gate |
| `module-pipe-source` stalls apps when idle | Phase 0 checks this; Meteor writes silence while a stream is active but the mic is muted or idle; native PipeWire stream as the fallback |
| Delay builds up over long sessions | Bounded jitter buffer that drops audio, with a delay readout in the tray |
| A stray device is left after a crash | Startup cleanup by source name |
