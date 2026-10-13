# Quest audio output comparison — issue #36

The reporter compares Nightfall with Abyss-c0re/moonlight-android's
`quest_fix` tag (`41e40dcd26e7944b54b5ba96a22ee1c5174fd74a`). That
client has no built-in amplifier in its audio renderer. It uses Opus
integer PCM decoding and Android AudioTrack PCM16 with `USAGE_GAME`.
Audio effects are optional and disabled by default. Nightfall uses Opus
float PCM and miniaudio (AAudio preferred, OpenSL fallback), without an
explicit game usage. Both request stereo by default. This difference
suggests a playback-policy comparison, but does not establish a cause.

## Test build

Settings → Audio Output selects Native (unchanged default) or AudioTrack.
Selection is saved and reconnects an active stream after the normal
restart debounce. It never replaces the output under a live audio
callback. If AudioTrack cannot initialize, connection initialization
fails explicitly rather than silently using Native and invalidating the
comparison. Linux continues using Native.

AudioTrack uses game usage, stereo PCM16, unity track volume, no effects
session or extra amplifier. It tries small/large buffers in low-latency
and normal modes like the referenced renderer. Conversion clamps float
samples to signed PCM16. It limits its queued playback to approximately
40 ms; initialization and write failures are logged. Decoder and boost
logic are shared between outputs.

`[AUDIO-LEVEL]` summaries are emitted every five seconds of decoded audio:
actual backend, negotiated channel count, gain, left/right decoded and
output RMS/peaks in dBFS, failed writes and estimated queue latency.
Output levels are measured before backend conversion and OS playback;
they cannot measure the physical speaker volume or Android attenuation.
Decoded levels are the front left/right channels when surround is
negotiated. No audio recording is created.

## Instructions for the tester

1. Use the same host, game/video passage and Quest volume throughout.
   Set Nightfall's Stream → Volume to Normal.
2. Play at least 15 seconds with Settings → Audio Output: Native.
3. Select AudioTrack, wait for reconnection, and replay the same passage
   for at least 15 seconds. Note loudness, distortion and audio dropouts.
4. Compare with the referenced Moonlight client, using stereo and audio
   effects disabled. Do not change the host volume between tests.
5. Download Nightfall's diagnostic log and report the output that sounds
   louder, if either. Test return to Native and reconnect/relaunch too.

Equivalent PCM levels but different audible loudness points downstream
of the decoder (output API, Android routing/policy, per-app volume or
effects). Different decoded levels requires investigating the host stream
and negotiated configuration first. Boost adds a soft limiter and should
not be used to diagnose unity-gain playback.

This is a diagnostic option, not a confirmed fix. New diagnostic menu
strings currently use explicit English fallback entries in translations.
