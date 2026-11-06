# Stream-only cursor enlargement on KDE Wayland

Date: 2026-10-30. Branch: `codex/bundled-host-testing`; host checkout:
`../meteor-vibepollo`, `codex/meteor-vibepollo-baseline`.

## Why

The existing Meteor 1×/2×/3×/4× cursor setting only affected X11 capture.
KWin embedded the cursor in its frames before the host received them.
Changing KDE's cursor theme would affect the desktop and application behavior,
which is outside the intended stream-only setting.

## Implementation

- For Meteor-managed KWin capture, request PipeWire cursor metadata rather than
  an embedded cursor. Other capture backends retain their previous cursor mode.
- Negotiate `SPA_META_Cursor`, validate bitmap offsets/strides/dimensions and
  retain an owned bitmap between position-only updates. Handle KWin's id=0
  cursor-outside-region signal and invisible/unknown bitmaps.
- Read cursor metadata even from queued frames discarded for latency and from
  cursor-only buffers. KWin can mark the absent video content as corrupted on
  those buffers; retain the last valid video image and present the new cursor.
- DMA-BUF capture keeps desktop pixels on the GPU and uses the existing GL
  cursor overlay before video conversion. KWin supplies premultiplied RGBA;
  normalize its cursor channels and use premultiplied-alpha blending.
- The shared-memory BGRA/BGRx path blends into the consumer-owned frame, retaining
  an untouched source for cursor-only updates. Non-cursor shared-memory capture
  keeps its previous swap path. Other CPU pixel formats are not extended here.
- Scale the hotspot along with the bitmap so the pointer's click point remains
  fixed. Coordinates are local to the capture, including KWin workspace capture.
- Reuse Meteor's existing control file. A separate Wayland capability marker
  makes its menu status accurate. No desktop/theme configuration is changed.

GPU overlay adds a private composition pass when a cursor is visible; it does
not read the full desktop back to the CPU. Live streaming and cursor behavior were subsequently confirmed working by the
user; wider hardware coverage remains separate.

## Checks and deployment

Seven C++ tests passed with AddressSanitizer and UndefinedBehaviorSanitizer,
including 5,000 malformed metadata cases, padded RGBA rows, bitmap ownership,
position-only updates, clipping and hotspot geometry. Optimized host compilation
passed. The development host is packaged separately as `0.1.0-preview.9-dev`;
public release pins are unchanged. Meteor's optimized XR-enabled AppImage is
rebuilt for the capability/status update.

Acceptance checklist (user confirmed working): compare 1×/2×/4×, move the mouse over an otherwise static desktop,
check arrow/text/link cursor changes, both monitors and screen edges. Confirm
that the physical desktop cursor remains unchanged and reconnect still works.

## Separate finding: low idle depth rate

Wayland capture is variable-rate. In the live desktop trace, about 20 encoded
frames/s corresponded to 20 depth updates/s, with VDA around 3.4 ms and no skipped
inference frames. The user confirmed the rate rose during gameplay. We are not
forcing redundant inference to make idle statistics look higher.

References: [PipeWire cursor metadata](https://pipewire.pages.freedesktop.org/pipewire/structspa__meta__cursor.html),
[KWin's cursor producer](https://github.com/KDE/kwin/blob/master/src/plugins/screencast/screencaststream.cpp).

Live smoke check: rebuilt Meteor and the preview.9 host were started, the paired
headset reconnected successfully, and its state reported HEVC hardware playback
at 120 Hz with App:120fps and Meteor depth active. The host capability marker
reported `wayland-cursor-scale-v1`, with the selected stream scale still 3×.
The user subsequently confirmed the change works on the headset.

Host implementation commit: `b6efac1` in `tB0nE/Vibepollo`.
