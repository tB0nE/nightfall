# Request: multi-monitor support for the real-desktop Wayland portal path

From the Nightfall/client-testing session, after live end-to-end testing on a Quest against
`headless_stream` multi-monitor tonight. Filed against `~/Development/Personal/polaris`
(same directory as `multi-monitor-server.md`, which this extends — read that first).

## Why this is needed

Tonight's testing revealed a real product gap: **the two multi-monitor paths built so far
don't cover "stream my actual desktop, with multiple monitors."**

- `desktop_display` (portal/PipeWire) mirrors the real, already-running session — but per
  section 1a of the handoff doc, that path is architected for exactly **one** stream and
  multi-monitor was explicitly called out as "not done."
- `headless_stream` (labwc) supports multi-monitor, but only inside a brand-new, empty,
  throwaway private compositor — it was never meant to show the real desktop, and doesn't.
- The X11 multi-monitor path (`x11grab.cpp`) does mirror the real desktop with real
  monitors, but only applies to X11 sessions. The test machine (and apparently the user's
  daily driver going forward) is Wayland/KDE now.

So there's currently no path that does what a normal user expects "stream my desktop, I have
two monitors" to mean, on Wayland. This request scopes closing that gap.

## What's actually needed

Extend the portal/PipeWire `desktop_display` capture path to select and composite multiple
screens, mirroring the same "composite before the encoder" contract already used in section
1b (`wl::wlr_ram_t::snapshot_multi_monitor()`) — the encoder should stay unaware multiple
monitors exist.

## Exact seams in the current code

All in `src/platform/linux/portal_session.{h,cpp}` and `portal_grab.cpp`, current as of
tonight's read of the tree:

1. **`portal_session.h:42-43`** — `pw_node_id`/`pw_node_serial` are scalar fields on
   `portal_session_t`. Need to become a `std::vector` of a new per-stream struct: node id,
   serial, capture render node, and (new) position/size.

2. **`portal_session.cpp`, the `SelectSources` params builder (~line 596-610)** — builds an
   `a{sv}` dict with `types`, `cursor_mode`, `persist_mode`, `handle_token`. **Never adds a
   `"multiple"` boolean key.** Per the XDG ScreenCast portal spec, this key must be set `true`
   to let the user pick more than one source in the picker; without it the portal silently
   limits selection to one.

3. **`portal_session.cpp:712-735`** — the stream-parsing loop:
   ```cpp
   GVariant *streams_v = g_variant_lookup_value(resp, "streams", nullptr);
   if (streams_v) {
     GVariantIter iter;
     g_variant_iter_init(&iter, streams_v);
     GVariant *stream_entry = nullptr;
     while ((stream_entry = g_variant_iter_next_value(&iter)) != nullptr) {
       uint32_t node_id = 0;
       GVariant *props = nullptr;
       g_variant_get(stream_entry, "(u@a{sv})", &node_id, &props);
       session->pw_node_id = node_id;
       session->pw_node_serial = lookup_uint64_property(props, "pipewire-serial");
       ...
       break;   // <-- only ever consumes the first stream tuple
     }
   }
   ```
   This already iterates every stream the portal returned — it just discards all but the
   first. Drop the `break`, push each stream's data into the new vector instead of
   overwriting scalars, and also read the portal-provided **`position (ii)`** and
   **`size (ii)`** per-stream properties (present on every stream tuple whenever `multiple`
   was requested — see the spec) via a new `lookup_ii_property()` helper alongside the
   existing `lookup_uint64_property()`/`lookup_capture_render_node()`.

   Nice property of this path vs. the labwc one: **the portal gives you real per-monitor
   position/size directly** — no need to compute a synthetic layout like
   `compute_wayland_monitor_layout()` does for headless virtual outputs. Real monitor
   geometry (including gaps/non-contiguous layouts) comes for free.

4. **`portal_grab.cpp`** — currently assumes one stream throughout (e.g. lines 258-288,
   517-525 reference `g_media.portal->pw_node_id`/`pw_node_serial` as scalars). Needs:
   - one `pipewire_capture::capture_t` instance per stream (vector, analogous to how the
     labwc path holds one "capture slot" per `HEADLESS-i` output),
   - a compositing/blit stage that tiles each monitor's captured frame into one shared frame
     buffer using the portal-provided position/size (SHM: offset `memcpy`; DMA-BUF/EGL: the
     same `glGetTextureSubImage` + `GL_PACK_ROW_LENGTH` approach used in
     `wl::wlr_ram_t::snapshot_multi_monitor()`),
   - the same backend-neutral `platf::compute_capture_region_from_outputs()` header already
     shared between the X11 and labwc paths should apply here too, if the per-stream
     position/size is fed into it the same way.

## Testing — this is no longer untestable

The handoff doc flagged this as "not safely buildable/testable in this environment (no way
to drive an interactive multi-monitor portal picker headlessly)." That's true for a
throwaway dev box, but **the Nightfall/Quest test machine is a live, real KDE Plasma Wayland
desktop with a real xdg-desktop-portal-kde** — a human (the user) can click through the
interactive multi-select picker there. Once this lands, hand it back for live end-to-end
testing against the actual Quest client rather than log-only verification.

## Scope note

This is real feature work, not a bug fix — new data model (scalar → vector), new D-Bus
param, a new compositing stage for the portal/PipeWire path specifically. Please flag if
partial/incremental delivery makes sense (e.g. land the vector + `multiple` flag + logging
first, verify the portal actually returns N streams with position/size on this desktop,
*then* build the compositing stage) rather than attempting it as one large change.
