# Reuse Polaris's Wayland multi-monitor work

Status: initial KDE region-capture implementation built, 2026-10-28.
Geometry tests and isolated KWin capture initialization pass. Real two-monitor
Nightfall streaming is not yet accepted or deployed.

Committed on 2026-10-29 in Meteor-Vibepollo as `f4b9191`
(`codex/meteor-vibepollo-baseline`). The previously staged development archive
predates this commit and records a dirty source tree; rebuild it from this
commit before deployment so the reported version identifies the tested source.

## Sources and findings

Source checkout: `/var/home/tyrone/Development/Personal/polaris`, branch
`feature/wayland-virtual-monitor-teardown-on-resume`, commit `7f6c2b6`.
Its three local modifications are preserved; the original checkout is not changed.

The historical `WAYLAND_MULTI_MONITOR_PLAN.md` is stale. The implementation
advanced beyond it: commit `da37cde` replaced sequential per-monitor portal
capture with a single KDE **Full workspace** stream, followed by cropping.
It also fixed reconnect waits and portal shutdown cancellation. The commit
records successful single/dual-monitor streaming and pointer tests.

Relevant reusable pieces:

- `kscreen_doctor_parser.*`: connected outputs, disabled outputs, physical
  mode sizes, scale and compositor-logical positions.
- `wayland_manifest.*`: selected outputs and pointer mapping in matching
  coordinate spaces, including fractional scaling and negative origins.
- `portal_grab.cpp`: workspace crop and matching frame rectangles.
- `portal_session.*` and `session_media_gate.h`: cancellation and bounded
  teardown/start waits, to adapt to Vibepollo's own lifecycle.

This path targets **KDE Plasma**, not every Wayland compositor. Other
desktops retain existing single-monitor portal capture until supported.
Creating additional virtual monitors through EVDI is separate work; it is
not required to capture existing monitors and is excluded from this port.

## Integration sequence

1. Port the pure KDE output parser and scale metadata, with fixture tests.
   Preserve X11 defaults. Include malformed fields, disabled displays,
   preferred modes, fractional scaling and negative coordinates.
2. Add a shared layout calculation for workspace crop, optional packing,
   manifest and pointer mapping. Validate against the actual negotiated
   PipeWire size; do not assume every portal buffer is logical resolution.
   Account for the whole workspace origin when converting desktop positions
   to buffer offsets. Reject unsupported selections instead of silently
   capturing the wrong display.
3. Adapt `portalgrab.cpp` / `pipewire.cpp` to the single-workspace source.
   Existing Vibepollo can obtain several portal sources but chooses only one.
   Adapt its existing SHM/DMA-BUF and encoder paths instead of replacing them
   with Polaris's unrelated capture backend. Keep the direct KWin
   single-output fast path; route multi-output requests to an implementation
   that actually captures all requested outputs.
4. Wire `/polaris/v1/display/manifest` only when capture and input agree.
   Keep `source: host_manifest` for Nightfall compatibility. Do not return
   XWayland geometry as the real Wayland monitor layout.
5. Adapt bounded startup and cancellable portal waits. Changing outputs on
   `/resume` must refresh capture, manifest and input calibration together.
6. Test real KDE Wayland capture before publishing a host update. Retain
   existing X11/NvFBC behavior and capture-aware encoder selection.

## Testing tools merged from PR #67

`origin/main` was merged into the bundled-host branch. See
[agent testing](../../guides/agent-testing.md).

- `tools/verify.py unit`: Nightfall/Meteor regression checks after merging.
- Host C++ parser/geometry tests: deterministic layouts without a display.
- `tools/verify.py ui`: monitor controls and menu behavior on the PC.
- `tools/nf.py`: inspect selected outputs, state and client controls.
- `tools/verify.py stream`: real stream statistics once paired.
- `tools/verify.py e2e`: frame pacing and delivery with the test pattern.

Headset and end-to-end checks require coordinating with the user. The e2e
check restarts Meteor and draws on the desktop. These tools supplement,
rather than replace, a real KDE Wayland capture test.

Acceptance: one/two monitors, mixed scale, negative origins, subset changes,
pointer clicks at every edge, repeated reconnects, portal refusal/cancel,
unchanged X11 single/multi-monitor capture, and no wrong-monitor fallback.

## Current boundary

The implementation uses a simpler path than the original integration sequence:
Vibepollo already supports the KWin screencast protocol's `stream_region`
request (version 3 onward). Rather than transplant Polaris's separate capture
engine, it now requests a region directly from KWin at scale 1.0 and passes
that single source through the existing PipeWire/encoder code. There are no
new CPU crop copies or sequential waits on individual monitor streams.

`wayland_workspace.h` is the pure shared geometry policy. Live geometry comes
from XDG output logical positions/sizes, including compositor rotation and
fractional scaling, rather than guessing logical size from physical pixels.
The imported KDE JSON parser remains available but is not required at runtime;
the path does not introduce a dependency on the `kscreen-doctor` executable.

Implemented in the separate Meteor-Vibepollo checkout:

- KDE automatic capture prefers native KWin before interactive portal probing.
- Explicit `outputs=` requests use native region capture for automatic/KWin
  selection. Explicit portal/wlr/KMS selections are not silently overridden.
- The manifest reports that same logical frame and preserves `host_manifest`.
- Input uses the full logical desktop extent and an origin-normalized capture
  offset; the compositor request retains its signed desktop coordinates.
- Invalid/unknown/incomplete selections, missing region-protocol support and
  layouts beyond decoder limits are rejected. Non-contiguous selections are
  rejected when a bounding crop would include an unselected monitor.
- Negotiated PipeWire dimensions must match the manifest exactly. The
  existing private-display physical capture path is retained.
- Monitor enumeration now sorts by a strict order/position/name tuple.

All 44 focused host tests pass (eight parser tests, nine workspace tests,
plus existing geometry and NVENC policy coverage). The Release host build
passes. After merging PR #67 and refreshing the local Godot class
cache, the unit runner passes: 175 Rust tests and the GDScript suite. The
first restricted run could not open test sockets; rerunning with local
socket access passed. Desktop tests still report missing native XR extension
binaries; this is not evidence of live capture or XR acceptance.

An isolated headless KWin smoke run used two 640×360 virtual outputs, temporary
XDG settings, a separate D-Bus session and software rendering. The actual host
enumerated both outputs, requested its default single-output workspace region
and negotiated 640×360 PipeWire memory buffers with no layout-size mismatch.
This verifies initialization, not two-monitor streaming, image quality, input
injection or sustained encoding. The compositor and test host both exited;
the real X11 desktop and running Meteor installation were not replaced.

Reports in the host checkout:
`.build-cache/meteor-host-release/wayland-workspace-{build,tests,package}.log`,
`test-build/wayland-workspace-results.json`, and `wayland-smoke/summary.json`.

Still outstanding: real KDE Wayland one/two-monitor client streaming, pointer
edges, reconnect/output-selection changes, hotplug behavior and hardware
performance. This initial native region path does not pack oversized layouts
into tiles, create virtual monitors or add generic non-KDE portal multi-output
capture. The existing X11 packing implementation remains available.

A local `0.1.0-preview.4-dev` host archive is staged for later testing. No new
public release, pin update or headset deployment has been performed.
