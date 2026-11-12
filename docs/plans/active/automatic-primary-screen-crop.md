# Automatic primary-screen crop

Implemented on `feat/remember-screen-arrangement`, November 2026.

## Behaviour

The Stream tab's Crop control now cycles through the existing presets and Auto.
Both manual and Auto crop affect **only the primary screen**. Other monitors and
browsers remain uncropped, including when primary ownership changes. Crop remains
a display/input transform; it does not change the negotiated stream resolution.

Auto samples every 300 ms while media is active and Auto is selected. It checks
for near-black, edge-connected strips spanning complete rows/columns, symmetric
opposite borders, and sufficiently bright content in the centre. It matches the
existing aspect presets within a small sampling tolerance. Five consecutive
matching samples are needed before applying or clearing a crop (about 1.5 s).
The preset match validates plausibility; the applied crop uses the measured edges,
without an intentional retained border. Edge precision is limited by the sample grid.

Black frames and uncertain boundaries cancel a pending decision and retain the
last confirmed crop. Sustained full-frame content clears it. Asymmetric bars,
including visible subtitles in one bar, request the full picture after the same
confirmation period. Tiny text below sample resolution can still be missed.
This is a conservative heuristic, not semantic recognition: a static scene with
perfectly uniform black edges can resemble letterboxing. Manual presets and Off
remain available. Auto resets when the primary source, dimensions or SBS changes,
when media stops, and when leaving Auto. Detected crop is not saved as a preset.

## Sampling and cost

Android's native renderer draws a separate **128×72 uncropped colour sample**,
before AI warp, picture adjustments, bezel, stats overlay or colour keying. It
uses the existing neutral OES/2D shader variant and primary source transform,
including the selected left SBS image. Two fenced pixel-pack buffers allow
readback only after GPU completion; no blocking fence wait or full-resolution
CPU image copy is introduced. It does not consume the ambient sampler's results.

At the requested cadence this transfers at most roughly 123 KB/s of RGBA sample
data. The sample texture plus two PBOs occupy about 108 KiB. The draw/readback is
requested only in Auto; resources are allocated with the renderer and cleaned up
with its EGL context. No XR composition layers are added.

Legacy/Linux uses an UPDATE_ONCE 128×72 offscreen viewport, cloning the source
YUV material with neutral display settings, or sampling the browser RGB texture.
It reads only that small viewport after frame_post_draw. This path may incur a
small readback synchronization cost; it does not read the full video texture.

These are workload bounds, **not measured GPU latency**. Actual performance and
visual classification on Quest still need normal-use testing.

## Validation

The GDScript suite covers manual secondary-screen exclusion, crop coordinate
mapping, five-sample confirmation, black-frame hold, subtitle detection,
full-frame crop removal, Auto persistence, and existing workspace-origin math.
The release-optimized DEV build rebuilds the changed native XR extension.

For headset acceptance:

- Select Auto on Stream, show a bright letterboxed/pillarboxed image, and wait
  about 1.5 seconds. Check pointer alignment after cropping.
- Switch to full-frame content and check the crop clears; dark fades should hold.
- Check a second monitor/browser stays uncropped in manual and Auto modes.
- Repeat on a primary browser and with AI 3D enabled. Watch for unexpected crops
  in dark games; use Off/manual if content is inherently ambiguous.

## Border correction

Initial Auto snapped to a nominal preset and retained one sample-pixel border.
User testing showed that margin clearly at screen scale across films and games.
Auto now applies the detected boundaries directly and reconfirms changed edges
even when they match the same preset. Manual preset values remain exact ratios.
`AutoScreenCrop.last_analysis_usec` reports the most recent CPU detector time;
this excludes the GPU sample draw/readback and is not an end-to-end cost metric.
