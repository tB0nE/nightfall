# Quest 3 PCVR defaults: research and current implementation

Reviewed 2026-10-21. Current requested baseline: HEVC, 2048×2048 per eye,
72 video FPS at 72 Hz and 80 Mbps. This is a starting point for physical testing,
not a measured optimum across all games, GPUs and access points.

## Findings

- Meta specifies 2064×2208 display pixels per eye. Render-target resolution is
  not identical to panel resolution because optics/distortion also matter.
  Source: https://about.fb.com/news/2023/09/meet-meta-quest-3-mixed-reality-headset/
- ALVR's own settings guide treats resolution, codec, bitrate and sustainable
  refresh as a combined tuning problem, and recommends measuring network and
  decoder behaviour rather than simply maximizing bitrate. Its high-quality
  wireless examples use substantially higher AVC bandwidth than HEVC. Those
  example bitrates are not directly transferable to our lower-resolution stream.
  Source: https://github.com/alvr-org/ALVR/wiki/Settings-tutorial
- WiVRn's configuration supports encoder/codec choices. Our pinned reference
  client defaults to 50 Mbps, resolution scale 1.2 and automatic preferred refresh
  (`client/configuration.h`). Those are WiVRn defaults, not a measured Quest 3
  optimum, and its foveated/codec pipeline differs from ours.
  Source: https://github.com/WiVRn/WiVRn/blob/master/docs/configuration.md

There is no universal optimal bitrate/rate: PC GPU, game workload, codec, access
point and decoder headroom affect it. Network/decoder timing must eventually
drive presets or adaptation. Avoid interpreting router link speed as usable
low-latency video bandwidth.

## Defaults implemented now

For devices identified by the existing Quest 3-family check:

- 2048×2048 per eye, packed to a 4096×2048 stereo video frame. This is a square
  render view, not a claim that the physical panel is square.
- HEVC/H.265 Main, SDR 8-bit, hardware NVENC encode and Qualcomm MediaCodec decode.
- 80 Mbps: a conservative initial target, still requiring network measurement.
- 72 video FPS matched to 72 Hz, explicitly prepared and read back before XR
  receiver allocation. Desktop stream restart, if needed, happens before this.
  An unavailable 72 Hz target fails clearly rather than pretending it matched.

The previous 1024/60/AVC-only implementation limits have been extended through
authenticated negotiation, Monado capture/tracking/sub-rectangle guards, encoder,
wire metadata and headset decoding. Legacy AVC 20/60 profiles remain supported.
Unknown codecs/rates and mid-session codec/rate/dimension changes are rejected.
72 Hz is the default app display rate per Meta:
https://developers.meta.com/vr/documentation/native/android/mobile-display-refresh-rate/

Preferences live in `user://pcvr_stream.cfg`. Missing keys use device defaults;
explicit saved resolution, bitrate, Auto (0) and host-profile (0) choices survive.
Invalid values fall back to the device default. Other devices retain the existing
host-profile/Auto behaviour. UI and authenticated offer resolve the same defaults.

## Next quality milestone

Physically validate the new matched 72 profile, then explore 90/120-capable
stream/display pacing as optional choices. Use runtime-recommended dimensions and actual supported
rates; audit all size/rate guards, frame/lease budgets, projection targets,
encoder limits, decoder configuration and desktop override/restoration together.
Rate selection must occur safely before relevant GPU resources are allocated.
Measure host frame time, encode/decode latency, drops and network behaviour.
Compare AVC and HEVC on actual content and tune bitrate for each.

The end-to-end GPU smoke checks configuration and decoded pixels, not sustained
game FPS, headset decoder latency, thermals or wireless performance. Physical
validation is still required before calling this a release-ready default.
