# Multi-monitor encode/decode budget and layout theory

Working theory from live testing + on-device `MediaCodecInfo.CodecCapabilities.VideoCapabilities`
queries on a Quest 3 (Snapdragon XR2 Gen 2, Adreno 740). Captures why naive horizontal-strip
multi-monitor composition breaks down past 2 monitors, and what layout strategy replaces it.

## The core constraint

Multi-monitor streaming currently works by capturing the whole combined desktop as **one**
X11 region, encoding it as **one** H.264/HEVC bitstream, and decoding it with **one** decoder
session. Per-monitor screens are produced client-side by sampling different UV regions of the
single decoded frame (`ScreenLayout.uv_region_for()`), not by decoding separately per monitor.

That means the single decoder's real limits bound the whole composite desktop. On this device,
those limits are **not** a simple fixed max width (an earlier theory, since disproven):

- Per-axis ceiling: width and height can each go up to **8192px independently**.
- But they're not simultaneously available at their individual maximums - there's a combined
  budget underneath. Measured via `VideoCapabilities.getSupportedHeightsFor(width)`:

  | width | max height | width × height |
  |---|---|---|
  | 1920 | 8192 | (under budget, axis-limited) |
  | 3840 | 8192 | (under budget, axis-limited) |
  | 4096 | 8192 | (under budget, axis-limited) |
  | 4480 | 7888 | 35,338,240 |
  | 5760 | 6144 | 35,389,440 |
  | 7680 | 4608 | 35,389,440 |
  | 8192 | 4320 | 35,389,440 |

  Below ~4480px width, height is limited only by the flat 8192 ceiling. Past that, the product
  locks to a constant **~35.4 million pixels (~138,240 macroblocks)** - a classic total-budget
  constraint, same shape as the H.264/HEVC "Level" system. **This is the number to plan around:
  total canvas pixels ≤ ~35.4M, each individual axis ≤ 8192px.**

- This was confirmed identical for both H.264 (`c2.qti.avc.decoder`) and HEVC
  (`c2.qti.hevc.decoder`) on this device - same declared budget for both codecs.
- Caveat: `isSizeSupported()`/`getSupportedHeightsFor()` are **static declared capabilities**
  from the codec's platform descriptor, not a guarantee of real-time sustained decode
  throughput at a given framerate. Treat sizes near the ~35.4M ceiling as "technically
  accepted," not "confirmed smooth" until actually tested live.

## Why horizontal strips break down

A naive "N monitors side by side" strip only spends the *width* axis and wastes the *height*
axis entirely, so it hits the 8192 width ceiling almost immediately - 3 monitors at native
4K width alone (3×3840 = 11,520) already exceeds it, regardless of the pixel budget. This is
a hard geometric wall, separate from and in addition to the pixel budget.

## Layout strategy: packed grid, not a strip

Pack monitors into a grid that uses both axes instead of concatenating along one. Key
relaxation: **rows don't need to share a single crosshair center point.** Each row gets its
own height (set by its tallest monitor), each column within a row gets its own width - so
differently-sized monitors don't force wasted padding, as long as each row is internally
left/right-aligned.

### 4 monitors: 2×2 grid

Fixed slot order (deterministic, no bin-packing needed for this case):
primary = top-left, secondary = top-right, third = bottom-left, fourth = bottom-right.

Example, 4× real 2160p (3840×2160) monitors:
- Canvas: 7680 × 4320 (2×3840 wide, 2×2160 tall)
- Width 7680 is under the 8192 ceiling; confirmed height ceiling at that width is 4608, and
  we only need 4320
- Total: 33,177,600 pixels - under the ~35.4M budget, but only by ~6% margin (tight)

### 5 monitors: asymmetric rows (2 top, 3 bottom)

3 monitors can never share a row at full native 4K width (3×3840 = 11,520 > 8192 axis
ceiling) - independent of pixel budget. So the "3-per-row" set must run below 4K. Worked
example: primary+secondary full 4K on top, third/fourth/fifth at 1440p on bottom:

- Top row: 2× 3840×2160 = 7680 × 2160
- Bottom row: 3× 2560×1440 = 7680 × 1440 (width matches the top row exactly - zero wasted
  canvas padding)
- Canvas: 7680 × 3600 = 27,648,000 pixels - comfortably under budget, ~7.7M pixels headroom
- Dropping the bottom row to 1080p instead (3× 1920×1080 = 5760×1080) frees even more budget
  (~24.9M total) at the cost of a width mismatch with the top row (padding waste)

General approach for other monitor counts: decide row groupings so no row's monitors sum past
8192px wide, prefer per-row widths that line up with each other to avoid padding waste, and
check total canvas pixels against the ~35.4M budget before committing to a layout.

## What needs to change to build this

**Server (Polaris):** currently captures a single contiguous rectangle of the real X11 virtual
desktop (wherever monitors physically/virtually sit per xrandr) - this only works for the
strip case. A packed grid requires actual recompositing: capture each monitor separately and
blit it into its assigned slot of a new composite canvas, then report the real per-monitor
`frame_rect` placement in the manifest. This is the significant chunk of new work.

**Client (Nightfall):** likely needs little to no change for this. `ScreenLayout`/`MonitorSpec`
and `uv_region_for()` were already built generically around arbitrary axis-aligned
`frame_rect`s, with no baked-in assumption that monitors sit in a horizontal strip. Once the
server sends grid-shaped `frame_rect` values instead of strip ones, the client should be able
to pick them up largely as-is.

## Known open bug: H.264 fails at exactly 4480×1440 (100% of a real 2-monitor desktop)

Live-tested, reproducible: H.264 decode produces **zero** frames (not "a few then stalls" -
literally never a single `AndroidMediaCodec: Frame ready` log line) at 4480×1440, while
4032×1296 (90% of the same desktop) decodes continuously and works fine, and HEVC works fine
at the full 4480×1440 with no issue. No error, exception, or async error callback fires -
totally silent.

Investigated and ruled out:
- **Not a declared decoder capability limit** - the device's own `isSizeSupported()` reports
  `true` for 4480×1440 on both H.264 and HEVC, and it's well inside the ~35.4M pixel budget
  (6.45M pixels).
- **Not the separate FFmpeg "software decode then upgrade to MediaCodec" path**
  (`StreamConnection::_try_h264_hw_upgrade()`) - confirmed via live logs that H.264 goes
  through the exact same primary path as HEVC (`AndroidMediaCodec`/async NDK MediaCodec,
  `Native MediaCodec created: ... mime=video/avc`), not the FFmpeg fallback. Earlier theory
  that this asymmetry was the cause was wrong.
- **Not the "max input size" override quirk** - `CCodec` logs a warning at configure time
  that our client-requested max input size (`width * height`, no encoding-overhead margin)
  is smaller than the component's recommendation and gets silently overridden. Confirmed this
  identical warning fires on the *working* 4032×1296 case too (with its own smaller numbers) -
  it's a universal, benign quirk of this behavior, not correlated with the failure.

Both the working and failing case run through **identical client code**, on the **same
vendor decoder** (`c2.qti.avc.decoder`), with the same quirks along the way - the only
difference is the requested dimensions. That points to something inside Qualcomm's
closed-source Codec2 HAL specific to this exact configuration, not anything in Nightfall's
own code, and not anything the platform's declared capabilities predict. Very likely an
undocumented vendor decoder limitation/bug, plausibly never validated against an unusual
~3:1 combined-desktop aspect ratio like this (far outside normal single-screen use cases).
Not considered practically fixable from the client side without vendor-level access or
extensive further probing across many other width/height combinations for diminishing
returns - especially since a working avoidance strategy already exists.

**Workaround in place (client-side, `main.gd::compute_requested_resolution()`):** H.264
requests are capped to 4096px per dimension, scaling both dimensions down together to
preserve aspect ratio if exceeded. Empirically avoids the bug. Treat as permanent unless
a real root cause and fix surfaces later - this isn't expected to be worth revisiting
without new information (e.g. a Qualcomm/AOSP bug report matching this exact symptom).
