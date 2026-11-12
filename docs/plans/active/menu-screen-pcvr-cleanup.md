# Menu / Screens / PCVR cleanup — 2026-11-12

Branch: `feat/remember-screen-arrangement`, based on main `190493c`.

## Controls

- Stream row 1: Resolution, FPS, Bitrate, Crop.
- Stream row 2: Codec, HDR, Volume, USB Link (platform visibility unchanged).
- Picture row 1: Brightness, Contrast, Gamma, Bezel.
- Picture row 2: Sharpen, Colour Key, Key Tolerance, Set Host Background.
- Advanced Settings / Display: High Refresh Rates, Host Cursor.
- Screens row 1: Monitors, Virtual, Browsers (disabled live count), Grid Mode.
- Screens row 2: Layout, Apply, Save, Remove.

Screens now uses standard 250×132 options, standard row separation, and the same
status/grab positions as Display/Stream/Picture. Layout opens the existing preset
diagrams in a same-viewport overlay, retaining selection, apply/save/remove and
browser-inclusive layout counts. Browser content remains controlled above its
own screen. No added XR composition layers.

PCVR has Stream and VR Apps tabs styled like the desktop tabs. Stream's rows are
centered, with Exit PCVR beside resolution/bitrate. Gear and Exit remain visible;
Disconnect remains present on PCVR, disabled when no desktop stream exists.
The app library loads the host's existing four-item pages into one scrollable
four-column grid. It reuses the Advanced Settings drag, clipping metadata,
scrollbar and culling behavior. Art requests stay queued between pages. The
fixed PCVR tab bar and toolbar sit above the scrolling library for hit testing.

## Host cursor support

Nightfall already calls the paired HTTPS endpoints
`/polaris/v1/session/status` (GET) and `/polaris/v1/session/cursor` (POST).
Meteor-Vibepollo previously implemented the monitor manifest but not these.
The fork now implements them with paired-certificate/view permission checks and
strict boolean request validation. The keyboard shortcut and API share one
atomic visibility value; capture threads refresh their local bool pointer each
frame, so the API never writes through a capture backend's pointer.
This controls cursor inclusion in captured video, not the local OS cursor or
Nightfall's superimposed pointer.

Host source: `../meteor-vibepollo`, branch `merge/upstream-2026-11`.
Changed files: `src/globals.{h,cpp}`, `src/video.cpp`, `src/nvhttp.cpp`,
`src/host_cursor_visibility.h`, `tests/test_host_cursor_visibility.cpp`.
These changes are separate from this repository and not yet committed.

Release host built in the documented Ubuntu container, then packaged as
`0.1.0-preview.6-cursor-dev`. Meteor's development `host_binary` setting now points
to this package. Original settings backed up under
`build/verify/menu-pages/meteor-config-before-cursor.toml`; settings and pairings
retained. This does **not** change the pinned public host release/download.
A later host release and Meteor pin update are needed to distribute support.

## Verification

- Full unit summary: `build/verify/unit-20261112-100332/summary.json`:
  198 Rust tests, GDScript suite passed.
- Updated library unit test covers accumulated pages and runtime installation flow.
- `test/check_menu_pages.py`: bounded isolated headless layout test, no gamescope
  or GPU. Compares toolbar/status/grab geometry; standard Screens button sizes;
  read-only browser count; all 12 fake apps reachable; gear hit-tested after
  scrolling. Summary in `build/verify/menu-pages/summary.json`.
- Vibepollo optimized build and standalone atomic cursor/shortcut test passed.
- Remaining headset acceptance: actual cursor inclusion on/off; visual menu
  styling; VR Apps scrolling/launching in a real PCVR session.

## Independent screen-chrome hover (2026-11-12)

The shared screen atlas now has independent visibility state for its top browser
menu and bottom grab/shortcut strip. Continuous hover reveals the grab bar after
100 ms, shortcut buttons after 200 ms, and the top browser menu after 100 ms.
Moving across a region briefly does not accumulate dwell across separate visits.
The existing 500 ms hide grace remains. Address editing pins only the top menu;
active grab/resize operations retain their controls. Invisible controls cannot
activate while waiting for reveal. Top hover geometry is seeded without needing
to show the bottom bar first.

Both regions still render into the same viewport and composition layer for each
screen. No new OpenXR layers are allocated; the layer is submitted when either
region needs it. Pure timing tests cover thresholds, independence and interrupted
hover, and the shared-controls test checks top-only visibility and layer count.
The full GDScript suite passed after these changes.
