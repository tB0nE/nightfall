# Request: per-session output selection for X11 multi-monitor capture

From the Nightfall/client-testing session. Filed against `~/Development/Personal/polaris`
(same directory as `multi-monitor-server.md` and
`wayland-portal-multi-monitor-request.md`, which this extends - read those first for
the existing multi-monitor architecture).

## Why this is needed

Nightfall's client now lets the user enable/disable individual monitors in its monitor tab
(each screen's real `frame_rect`/`desktop_rect` from the host's manifest is preserved when
doing this - see the "Monitor remove/add" fix in the client repo). Disabling a monitor
correctly stops *displaying* it client-side.

**It does nothing server-side.** Polaris has no way to know the client only wants a subset of
outputs - `linux_multi_monitor_capture` + `linux_capture_outputs` (`src/config.h:177`) are a
single **static, global config value**, read once at startup from `polaris.conf` and applied
to every session identically, forever, regardless of what any given client actually asked
for. So disabling a monitor client-side today just crops what's *displayed* out of a frame
the host is still fully capturing and encoding - no bandwidth or encode-cost savings, and if
the user re-enables that monitor later, nothing needs to change server-side at all since it
was never told to stop.

This is a real product gap: the intended user story is "I only want to see my primary
monitor right now" actually reducing what the host captures/encodes, not just what the
client crops.

## What's actually needed

A per-session output filter: the client should be able to tell Polaris, at launch/resume
time, which specific outputs (by RandR name) to include - and the host should honor that in
its capture path for that session, going back to the current static-config behavior on the
next.

## Exact seams in the current code

All in `src/nvhttp.cpp` and `src/platform/linux/x11grab.cpp`, current as of this session's
read of the tree.

1. **`src/config.h:177`** (`linux_display.capture_outputs`) and its consumer,
   **`src/platform/linux/x11grab.cpp:471-472`**:
   ```cpp
   if (config::video.linux_display.multi_monitor_capture) {
     const auto only = platf::split_csv(config::video.linux_display.capture_outputs);
     const auto region = compute_capture_region(xdisplay.get(), xwindow, xattr.width, xattr.height, only);
     ...
   ```
   `x11_attr_t::init()` **already receives per-session parameters** (`display_name`, `config`)
   - it just doesn't use them for output selection, going straight to the static global
   instead. This is the actual capture-region computation; `only` is the output-name filter
   list that needs to become session-aware.

2. **The same static `capture_outputs` value is also read by the manifest endpoint's backing
   function**, `x11_query_desktop_manifest()` (same file, used by `GET
   /polaris/v1/display/manifest` via `src/nvhttp.cpp`). For consistency, once a session has a
   real output filter, the manifest response during that session should reflect the same
   filtered set - not the static default - so the client's own layout/manifest reconciliation
   (see `multi-monitor-server.md` section 4) doesn't fight what it just asked
   for.

3. **`/launch` and `/resume` query-arg parsing**, `src/nvhttp.cpp` (`launch()` around line
   4893, `resume()` around line 5230, both funnel through `make_launch_session()` around line
   3830). This is the standard Moonlight/GameStream launch handshake - `appid`, `mode`
   (WxH@FPS), `sops`, `rikey`, etc. are all parsed here into a `launch_session_t`. There's no
   existing param for output selection at all (the legacy single-monitor `output_name` used
   by the non-multi-monitor X11 path, `src/config.h`, is *also* static config only - same
   gap, smaller scope).

   Needs: a new query param (e.g. `outputs=DP-0,DP-2`, comma-separated RandR names, empty/
   absent = every connected output, same semantics as the existing static config value) parsed
   alongside the others, stored somewhere reachable from the X11 capture init call (either on
   `launch_session_t` if that's threaded through to display init already, or a new
   `proc::proc`-level per-session field mirroring how `proc::proc.display_name` already works
   for the legacy single-monitor case - see `src/video.cpp:2136-2137` for that existing
   pattern to follow).

4. **Client side already has what it needs to send this** - not a gap, just context for
   sizing the client-side half of the wire-up once the server accepts it. Each
   `MonitorSpec.label` in Nightfall's `ScreenLayout` (`src/screen_layout.gd`) is populated
   directly from the manifest's own `label` field (the real RandR output name, e.g. `"DP-0"`)
   when the layout was built from a host manifest - so
   `main.layout.enabled_monitors().map(func(m): return String(m.id ... )` - actually via
   `.label` - already has the exact comma-list value to send, no new client-side discovery
   needed once the server accepts the param.

## Testing

Same note as the Wayland portal request: this is a live X11 session with a real physical
monitor plus a working virtual second monitor (NVIDIA `ConnectedMonitor`/`CustomEDID`
override) already set up for multi-monitor testing, and the Nightfall client this would pair
with is already built and can toggle monitors on/off today (just without effect
server-side). No synthetic/headless test environment needed - hand it back for live
end-to-end testing once landed.

## Scope note

Suggest incremental delivery:
1. Land the query param + parsing + threading into `x11_attr_t::init()`'s call site, with
   logging of what was requested vs. what the static config says - verify the right value
   arrives server-side without changing actual capture behavior yet.
2. Wire it into the actual `only` filter list used by `compute_capture_region()`, falling
   back to the static `linux_capture_outputs` config when the param is absent (preserves
   today's behavior for any client that doesn't send it, e.g. stock Moonlight).
3. Apply the same filter to `x11_query_desktop_manifest()` for the active session so the
   manifest and the actual encoded frame stay consistent.

Not in scope here (per the client-side conversation this was filed from): richer
screen-management UX like reordering, per-slot output assignment, or non-X11 (Wayland
portal) output selection - that's the follow-up already tracked in
`per-session-output-selection-request.md`'s sibling doc for the portal path once this
lands for X11.
