# Polaris → Nightfall multi-monitor integration handoff

Server-side work for multi-monitor VR streaming is done on **two** independent capture
backends in `~/Development/Personal/polaris` (fresh clone of
https://github.com/papi-ux/polaris, uncommitted working-tree changes, branch `master`):

1. **X11** (`desktop_display`/"Mirror Desktop" path) — captures the real host desktop's
   RandR outputs. Built first; see section 1a.
2. **Wayland/labwc headless** (`headless_stream`/"Private Stream" path, the one actually used
   for VR/game sessions) — creates N *virtual* monitors inside the private labwc compositor
   and tiles them. Built second, after discovering that dynamically creating extra displays
   on X11 (Xvfb/dummy-driver multi-head, EDID emulation, etc.) is fragile; wlroots' headless
   backend can create virtual outputs on demand far more reliably. See section 1b.

This doc has everything needed to build/run the server and wire the client against either
path.

## 1. What changed, and why

**Goal:** capture N monitors (real, for X11; virtual, for Wayland/labwc), composite them into
one tiled frame, feed that through the existing single-stream encoder unchanged, and tell the
client how the frame is laid out so it can crop per-screen instead of cloning.

### 1a. X11 (`desktop_display` path) — real monitors

**Backend targeted: X11, not the XDG portal.** Polaris models Linux streaming as a "stream
path" (`docs/stream-paths.md`): Runtime × Capture × Topology. `desktop_display` ("Mirror
Desktop") is Runtime: none, Capture: portal, Topology: leave_alone — that's the path that
matches "stream the real desktop." But this codebase also has a separate, un-registered X11
capture backend (`src/platform/linux/x11grab.cpp`, inherited from the Sunshine fork, not in
the stream_path registry) that the docs don't mention.

I checked both before building anything:
- **Portal/PipeWire path** (`portal_session.cpp`, `portal_grab.cpp`, `pipewire_capture.cpp`)
  is architected for **exactly one** video stream end-to-end: `portal_session_t` has scalar
  `pw_node_id`/`pw_node_serial` fields (not a vector), the D-Bus `SelectSources` call never
  sets the `multiple` boolean, and the response-parsing loop literally `break`s after the
  first stream tuple. No position/size metadata is even read from the portal today. Making
  this support multiple monitors is a from-scratch feature (new protocol flag, a
  vector-of-streams data model, N `pipewire_capture::capture_t` instances, a new GPU/CPU
  compositor stage) — **not done**, and not safely buildable/testable in this environment
  (no way to drive an interactive multi-monitor portal picker headlessly).
- **X11 path** (`x11grab.cpp`) captures via `XGetImage`/SHM off the X11 root window. X11's
  root window already spans every RandR output in one shared coordinate space — so instead
  of building a tiling/compositing routine, multi-monitor capture is just "capture the whole
  root window instead of one monitor's CRTC crop." Real per-monitor positions are preserved
  for free, no blit/tiling code needed. **This is the path that got the real implementation.**

This machine is an X11 session (`XDG_SESSION_TYPE=x11`), so X11 is also what's actually
testable here end-to-end.

**Follow-up needed:** if Nightfall's multi-monitor testing needs to run on a Wayland/GNOME/KDE
**portal**-only host (i.e. someone else's desktop being mirrored, not Polaris's own private VR
compositor), that path still needs the work described above. Flag this to whoever owns that
environment. This is a *different* gap from section 1b below — don't confuse them.

### 1b. Wayland/labwc headless (`headless_stream` path) — virtual monitors

This is the path actually used for VR game-streaming sessions: Polaris spawns a private
`labwc` compositor (`cage_display_router.cpp`) running wlroots' **headless** backend (no
visible window, no real GPU output — pure off-screen rendering), the game/app renders into
it, and Polaris captures via `wlr-screencopy` (`wlgrab.cpp`/`wayland.cpp`). Previously this
always created exactly **one** virtual output (`HEADLESS-1`) sized to whatever resolution the
client negotiated.

**Why this got built as a second, separate implementation instead of extending X11:**
dynamically creating extra *displays* for the "multiple real monitors" idea turned out to be
a bad fit for X11 — Xvfb/dummy-driver multi-head setups and EDID-emulator tricks needed to
fake a second monitor at runtime are fragile and awkward to automate. wlroots' headless
backend, by contrast, already supports creating an arbitrary number of virtual outputs on
demand via a single environment variable (`WLR_HEADLESS_OUTPUTS=N`) — precisely the
capability the multi-monitor VR use case needs (N virtual "panels", not N real monitors).

**How it works:**
- `cage_display_router::start()` now computes a monitor layout: when
  `linux_multi_monitor_capture` is enabled and the labwc runtime is headless, it sets
  `WLR_HEADLESS_OUTPUTS` to `linux_wayland_monitor_count` and splits the **client-negotiated**
  stream resolution into that many equal-width, full-height, contiguously-positioned columns
  (`compute_wayland_monitor_layout()`). Each column becomes one `HEADLESS-i` output, positioned
  via `wlr-randr --output HEADLESS-i --custom-mode WxH --pos X,0`.
- Splitting the *already-negotiated* resolution (rather than picking arbitrary per-monitor
  sizes) means the tiled composite is **always** exactly what Moonlight/Nightfall already
  agreed to stream — no changes needed anywhere in the resolution-negotiation or encoder
  pipeline.
- `wl::wlr_t::init()` (in `wlgrab.cpp`) enumerates all `HEADLESS-i` outputs via the existing
  Wayland registry/xdg-output machinery, builds the same shared bounding-box/tiling geometry
  used by the X11 path (`platf::compute_capture_region_from_outputs()`, now in a shared
  backend-neutral header — see section 2), and stores one "capture slot" (wl_output + tile
  rect) per enabled monitor.
- `wl::wlr_ram_t::snapshot_multi_monitor()` (new) captures each virtual output's
  `wlr-screencopy` frame **sequentially** (one shared capture session, reused per monitor —
  mirrors the existing single-monitor one-shot-per-tick model) and blits each into its tile of
  one shared frame buffer: a direct offset `memcpy` for the SHM path, or an offset
  `glGetTextureSubImage` (with `GL_PACK_ROW_LENGTH` set to the full composite width) for the
  DMA-BUF/EGL path. Same "composite before the encoder" contract as X11 — the encoder never
  knows multiple outputs exist.
- Because outputs are virtual and created purpose-built for this, they always tile with zero
  gaps starting at origin `(0,0)` — there's no X11-style "bounding box might include an
  unwanted third monitor" gap here.

**Scoped to the RAM/SHM capture path only.** The GPU-native paths (`wlr_vram_t` —
direct-to-encoder DMA-BUF for windowed/GPU-native labwc, and `wlr_extcopy_vram_t` — true
headless GPU-native DMA-BUF for CUDA) still only support a single output. Multi-monitor
Wayland capture forces the RAM/SHM path regardless of what would otherwise be selected. This
mirrors the same X11-vs-portal scoping decision from section 1a: extending the GPU-native
paths to composite N separate DMA-BUFs would need an actual GPU compositing/blit pass (a
render target + shader), not just geometry math — flagged as follow-up work, not silently
dropped.

**A real, measurable cost worth knowing about:** because the single capture session is reused
sequentially across N outputs, screencopy round-trips serialize — capture latency scales
roughly linearly with monitor count. Fine for the VR multi-panel use case (small N, this isn't
a real-time-critical extra hop compared to the encode itself), but a follow-up could
parallelize N independent capture sessions if this becomes a bottleneck at higher N.

## 2. Files changed

| File | What |
|---|---|
| `src/config.h` / `src/config.cpp` | Config keys: `linux_multi_monitor_capture` (bool, shared by both backends), `linux_capture_outputs` (comma-separated output-name filter, shared), `linux_wayland_monitor_count` (int, new, Wayland-only — how many virtual outputs to create). Also fixes a real pre-existing bug — see section 9 |
| `src/platform/linux/display_manifest.h` (new) | Backend-neutral home for `monitor_manifest_entry_t`, `desktop_manifest_t`, `output_descriptor_t`, `capture_region_t`, the header-only pure function `compute_capture_region_from_outputs()`, and `split_csv()`. Extracted out of `x11grab.h` so Wayland reuses the identical, already-unit-tested tiling geometry instead of a parallel implementation |
| `src/platform/linux/x11grab.h` / `.cpp` | Unchanged behavior from the X11 pass; now includes `display_manifest.h` instead of defining those types itself. `x11_attr_t::init()`'s multi-monitor branch and `x11_query_desktop_manifest()` are as before |
| `src/platform/linux/cage_display_router.h` / `.cpp` | New `compute_wayland_monitor_layout()` (splits negotiated WxH into N contiguous columns) and `build_mode_retry_cmd()` (generates the `wlr-randr` mode+position commands for all columns); `start()` sets `WLR_HEADLESS_OUTPUTS=N` and gates readiness-waits on the first column's actual size (not the full negotiated size) |
| `src/platform/linux/wlgrab.cpp` | `wl::wlr_t::init()` gets a multi-monitor branch (enumerate all outputs, build tile rects via the shared geometry function, store `capture_slots`); new `wl::wlr_ram_t::snapshot_multi_monitor()` (sequential per-output capture + blit-into-shared-buffer); new `platf::wl_query_desktop_manifest()` |
| `src/platform/linux/wayland.h` | Declares `platf::wl_query_desktop_manifest()` (with a `std::nullopt`-returning stub when built without Wayland support) |
| `src/input.cpp` | Fixed a real, pre-existing bug (from the X11 pass, generalizes automatically to Wayland — see section 5): incoming absolute mouse coordinates were rescaled into display-local space but the captured display's `offset_x`/`offset_y` was never added back before injection |
| `src/nvhttp.cpp` | `GET /polaris/v1/display/manifest` and `GET /polaris/v1/session/status` now try `x11_query_desktop_manifest()` first, then fall back to `wl_query_desktop_manifest()` |
| `src/platform/linux/pipewire_capture.h` / `.cpp` | Incidental fix, unrelated to multi-monitor — see section 9 |
| `tests/unit/test_x11grab_monitor_layout.cpp` + `tests/unit/platform/test_cage_display_router.cpp` + `tests/CMakeLists.txt` | X11: 6 gtest cases for the shared geometry math (unchanged). Wayland: 4 new gtest cases for `compute_wayland_monitor_layout()` (single-output legacy shape, windowed-mode fallback, equal-column split, remainder-column exact-tiling) |

No new stream_path id was added for either backend — per `docs/stream-paths.md`'s "what not to
do" list, this is a capture-detail enhancement to the existing `desktop_display`/X11 and
`headless_stream`/labwc capture, config-driven, same pattern as existing
`linux_streaming_output`/`linux_primary_output`.

## 3. Config keys (in `polaris.conf`)

### 3a. X11 (`desktop_display`)

```ini
linux_stream_mode = desktop_display
capture = x11
linux_multi_monitor_capture = enabled
# optional: restrict to specific outputs (RandR names, e.g. from `xrandr --query`).
# Empty (default) = every connected output.
linux_capture_outputs = DP-0,HDMI-1
```

Setting `capture = x11` is important — without it, `desktop_display` may resolve to portal
capture instead (Polaris auto-picks portal over X11 when both are available; see
`src/platform/linux/misc.cpp`'s `display()`/`init()` dispatch).

Behavior:
- `linux_multi_monitor_capture = enabled` + `linux_capture_outputs` empty → captures the
  entire X11 virtual desktop (all connected monitors) as one frame, at their true relative
  positions.
- `linux_capture_outputs = "A,B"` → captures the bounding box of just outputs A and B (by
  RandR output name, e.g. `DP-0`). If A and B aren't adjacent, the frame may include pixels
  from whatever's spatially between them (a third monitor not requested) — a known,
  documented limitation of the bounding-box-crop approach for non-contiguous subsets.

### 3b. Wayland/labwc headless (`headless_stream`)

```ini
linux_stream_mode = headless_stream
headless_mode = enabled
linux_use_cage_compositor = enabled
linux_multi_monitor_capture = enabled
# How many virtual monitors to create and tile. Each gets an equal horizontal slice
# of the client-negotiated stream resolution (same height as the full frame).
linux_wayland_monitor_count = 2
# optional: same filter semantics as X11, but names here are the compositor-reported
# output names ("HEADLESS-1", "HEADLESS-2", ...). Empty (default) = every created output.
linux_capture_outputs =
```

This is the path VR game-streaming sessions already use (`headless_stream` = Runtime: labwc,
Capture: wlroots, Topology: leave_alone) — multi-monitor here doesn't require switching stream
modes, just turning on `linux_multi_monitor_capture` and setting a monitor count on top of
however the session already launches.

Behavior: with `linux_wayland_monitor_count = N`, Polaris creates N virtual `HEADLESS-i`
outputs sized as equal columns of whatever resolution the client negotiated, tiles them with
zero gaps starting at `(0,0)`, and the manifest's `frame_size`/`desktop_bounds` will both equal
that negotiated resolution. There's no non-contiguous-subset gap here (unlike X11's
`linux_capture_outputs` case) since the virtual outputs are always created contiguous.

## 4. The manifest endpoint (this is what Nightfall's client should fetch)

```
GET /polaris/v1/display/manifest
```

Same auth as every other `/polaris/v1/*` route: requires a paired client cert (mTLS), same
pairing flow as any Moonlight/Nova client. Returns 401 if unpaired.

Response JSON — matches the client's `ScreenLayout`/`MonitorSpec` schema exactly:

```json
{
  "version": 1,
  "source": "host_manifest",
  "frame_size": [3840, 1080],
  "desktop_bounds": [0, 0, 3840, 1080],
  "monitors": [
    {
      "id": "m0",
      "label": "DP-0",
      "enabled": true,
      "is_primary": true,
      "frame_rect": [0, 0, 1920, 1080],
      "desktop_rect": [0, 0, 1920, 1080],
      "hint": {}
    },
    {
      "id": "m1",
      "label": "DP-1",
      "enabled": true,
      "is_primary": false,
      "frame_rect": [1920, 0, 1920, 1080],
      "desktop_rect": [1920, 0, 1920, 1080],
      "hint": {}
    }
  ]
}
```

Notes:
- The handler tries the X11 query first, then falls back to the Wayland/labwc query — you get
  whichever backend is actually active, same JSON shape either way. `source` is always
  `"host_manifest"` regardless of backend; there's no field telling you which backend answered
  (if Nightfall needs that, `capture.backend` on `/polaris/v1/session/status` has it).
- `frame_rect` = crop rectangle within the decoded video frame (what to render on that VR
  screen). `desktop_rect` = real position within the full virtual desktop (what to use for
  mouse-position mapping). For X11 whole-desktop capture and for **all** Wayland/labwc capture
  these are numerically identical (frame == desktop, 1:1) — for X11 they only diverge when
  `linux_capture_outputs` restricts capture to a subset whose bounding box doesn't start at the
  desktop origin; Wayland's virtual outputs are always created contiguous from `(0,0)`, so this
  divergence never happens there.
- Disabled monitors (connected but not part of the current capture) still appear in the list
  with `enabled: false`, `frame_rect: [0,0,0,0]`, and their real `desktop_rect` — useful if
  Nightfall wants to show "this screen isn't currently streamed."
- `id` is a stable `"m<n>"` generated in enumeration order at manifest-build time — it is
  **not** guaranteed identical across reboots/reconfigures (X11: monitor connect order;
  Wayland: output creation order, which is deterministic per session but not guaranteed
  cross-session). Match on `label` (X11: RandR output name e.g. `DP-0`; Wayland: compositor
  output name e.g. `HEADLESS-1`) if you need stability, or just re-fetch the manifest at
  connect time and rebuild your screen list from scratch each session.
- The endpoint is queryable **any time** for X11 (opens its own short-lived X11 connection
  independent of whatever the encoder is doing). For Wayland it's only meaningful **while a
  labwc/cage session is actually running** — `wl_query_desktop_manifest()` needs a live socket
  to connect to; outside an active session it returns nothing and the endpoint falls through
  to the `manifest_unavailable` error (or to X11 if that's available instead).
- Also worth checking: `GET /polaris/v1/session/status` → `capture.multi_monitor_capture`
  (bool) and `capture.monitor_count` (int, count of *enabled* monitors) for a lighter-weight
  "is multi-monitor even on" check without parsing the full manifest.

**Not implemented:** any query-string opt-in flag on `/launch` (e.g. `?multiMonitor=1`) to
let the client request multi-monitor mode per-session, overriding the host config. Today
it's purely config-driven on the host side (per the task's "config-driven arrangement is
fine" allowance). If Nightfall wants per-session client control, the insertion point is
`make_launch_session()` in `src/nvhttp.cpp` (~line 3827) — there's already an identical
precedent for a `mirrorDesktop` query flag (`explicit_mirror_desktop_requested()`,
`src/nvhttp.cpp:164`) to copy.

## 5. Mouse input

Moonlight's `LiSendMousePositionEvent(x, y, referenceWidth, referenceHeight)` — the client
computes `(x, y)` within `desktop_bounds` and sends `desktop_bounds`'s size as the reference.
Polaris rescales this in `src/input.cpp`'s `passthrough(PNV_ABS_MOUSE_MOVE_PACKET)` →
`map_client_to_touchport()`. This now correctly operates in full virtual-desktop space:
- For whole-desktop capture (`linux_capture_outputs` empty), `desktop_bounds` from the
  manifest and Polaris's internal `env_width`/`env_height` are the same size, offset (0,0) —
  no adjustment needed, and none is applied.
- For a filtered/subset capture with a non-zero frame origin, the fixed offset math in
  `passthrough()` now correctly re-adds that origin before injecting, so client coordinates
  computed against the full `desktop_bounds` still land in the right place physically.

Nightfall's client-side math should be: compute `(x, y)` in `desktop_bounds` space (the
manifest's `desktop_bounds`, i.e. the full virtual desktop, **not** the video frame size),
and send `desktop_bounds[2], desktop_bounds[3]` as `referenceWidth`/`referenceHeight`. This
matches what the task description said the client already does.

This fix required **no additional changes** for the Wayland path — `video.cpp`'s `make_port()`
(which builds the `touch_port_t` consumed by `passthrough()`) reads `offset_x`/`offset_y`/
`env_width`/`env_height` generically off the active `platf::display_t`, and the Wayland
multi-monitor `init()` branch sets those same four fields the same way the X11 branch does.
Verified by reading through the call chain, not by a live multi-monitor Wayland session (see
section 8's caveats).

## 6. How to build Polaris

The host machine (Bazzite/Fedora immutable OS) is missing build headers
(`boost-devel`, `libevdev-devel`, etc.) and rpm-ostree makes installing them clumsy. Build
inside a disposable Fedora 43 distrobox container instead — this is what I used:

```bash
# one-time setup
distrobox create --name polaris-build --image registry.fedoraproject.org/fedora:43 -Y
distrobox enter polaris-build -- bash -c '
  sudo dnf install -y dnf-plugins-core git nodejs npm gcc-c++ pipewire-devel
  cd ~/Development/Personal/polaris
  sudo dnf builddep -y packaging/linux/fedora/Polaris.spec
  sudo dnf install -y grim labwc wlr-randr xorg-x11-server-Xwayland xdpyinfo
'

# submodules (only needed once)
cd ~/Development/Personal/polaris
git submodule update --init --recursive

# configure + build (CUDA off — this box has no matching toolkit; not needed to validate this feature)
distrobox enter polaris-build -- bash -c '
  cd ~/Development/Personal/polaris
  cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTS=ON \
    -DPOLARIS_ENABLE_CUDA=OFF -DCUDA_FAIL_ON_MISSING=OFF
  cmake --build build -j$(nproc)
'
```

Binary lands at `~/Development/Personal/polaris/build/polaris` (symlink to
`polaris-1.3.2.dirty`). Test binary at `build/tests/test_polaris`.

Note: don't use the `fedora` distrobox that may already exist on this machine for other
work — installing build deps there pulled in a full `systemd` package that conflicted with
its existing minimal `systemd-standalone-tmpfiles` and would have required `--allowerasing`
against a container the user actively uses. The disposable `polaris-build` container sidesteps
that entirely.

## 7. How to run it

**Don't point it at the real config** — Polaris defaults to `~/.config/polaris/polaris.conf`,
the same file the machine's existing native `/usr/bin/polaris` install uses. A bare
positional CLI argument overrides which config file loads:

```bash
distrobox enter polaris-build
cd ~/Development/Personal/polaris
mkdir -p ~/polaris-dev-config
./build/polaris --creds testuser testpass ~/polaris-dev-config/polaris.conf   # first time only
./build/polaris ~/polaris-dev-config/polaris.conf
```

Web UI: `https://localhost:47990` (self-signed cert). Add the config block from section 3
to `~/polaris-dev-config/polaris.conf` (or set it via the web UI's Linux display mode
settings) before launching a session.

The container shares the host's X11 display, network, and home directory transparently, so
this is effectively "run natively" from Nightfall's perspective — same X server, same
monitors, same network for pairing over the LAN.

## 8. Verifying it's working (no VR headset needed)

### X11

- **Logs**: when a stream session starts with multi-monitor enabled, `x11_attr_t::init()`
  logs (info level):
  ```
  Multi-monitor X11 capture: 2 output(s) composited into 3840x1080 frame (origin 0,0)
    [in]  DP-0 desktop=1920x1080+0+0 (primary)
    [in]  DP-1 desktop=1920x1080+1920+0
  ```
  Disabled/excluded outputs show as `[out]`.
- **Unit tests**: `./build/tests/test_polaris --gtest_filter='X11MonitorLayout.*'` — 6 tests
  covering single monitor, side-by-side, vertically-stacked, and the filtered-subset case
  that shifts the frame origin (the exact scenario the mouse-offset fix addresses). All pass.
- Not validated against real multi-monitor hardware — this dev machine has one physical
  display (`2560x1440` DP-0). The single-monitor manifest path was confirmed against the real
  live X11 session (correct `frame_rect`/`desktop_rect`, correct `is_primary`); the 2/3-monitor
  geometry is validated by unit tests against synthetic RandR layouts only. **If Nightfall's
  dev setup has an actual second monitor (or a dummy-plug/EDID emulator), that's the
  highest-value remaining X11 verification step.**

### Wayland/labwc headless

- **Logs**: `cage_display_router::start()` logs the computed layout before spawning labwc
  (info level):
  ```
  labwc: Tiling 2 virtual output(s) into 3840x1080 frame
    HEADLESS-1 1920x1080+0+0
    HEADLESS-2 1920x1080+1920+0
  ```
  and `wl::wlr_t::init()` logs after connecting to the compositor:
  ```
  wlr: Multi-monitor capture: 2 output(s) tiled into 3840x1080 frame
    [in]  HEADLESS-1 frame_rect=1920x1080+0+0
    [in]  HEADLESS-2 frame_rect=1920x1080+1920+0
  ```
- **Unit tests**: `./build/tests/test_polaris_platform --gtest_filter='*CageDisplayRouter*Monitor*'`
  — 4 new tests covering the single-output legacy shape (byte-identical to the pre-existing
  command when `linux_wayland_monitor_count = 1`), the windowed-mode fallback, an even
  2-way split, and a 3-way split with a non-divisible width (confirms the remainder column
  makes the tiled columns sum to *exactly* the negotiated width, not off-by-one short/over).
  All pass — see full run below.
- **Not validated against a real running multi-monitor headless session or the actual VR
  client.** This dev machine's X11-only session means the labwc headless runtime was
  exercised for build/link correctness and the geometry math was unit-tested against
  synthetic layouts, but I did not start an actual multi-output headless labwc session and
  confirm real screencopy frames land in the right tile. **This is the highest-value
  remaining verification step for Wayland** — start a session with
  `linux_multi_monitor_capture` + `linux_wayland_monitor_count >= 2`, confirm the log lines
  above appear with the expected layout, and ideally dump/inspect a captured frame to confirm
  each column shows the right virtual output's content at the right offset (e.g. render a
  distinct solid color or test pattern per virtual monitor and check the encoded frame).

### Build/test verification (this session)

Full `polaris` binary and both test suites below build clean with `-DBUILD_FULL_TESTS=ON` in
the `polaris-build` distrobox container (see section 6):

- `test_polaris_platform`: **110/111 pass** (1 skip = `CudaGlEncodeDeviceTests.LinuxCudaOnly`,
  expected — no CUDA GPU in this container). Includes all Wayland/cage-router tests above.
- `test_polaris_config`: **242/247 pass**; the 5 failures (`ProcessRuntimeConfigTests.*`,
  `ProcessMigrationTests.ParseUnwrapsPolarisHdrSessionLibraryHardwire`) are about Steam
  process-migration/`setsid`-wrapping behavior — unrelated to display/config/capture code,
  confirmed by inspecting the failure output and diffing against what this session's changes
  actually touch.
- `test_polaris` (fast suite): **42 failures**, all `PrivateStateFileTest`/`WebSessionStoreTest`
  — the exact same pre-existing, container-environment `/tmp`-permission quirk documented in
  section 8 of the previous (X11) pass of this doc, same count (42) as before.

None of the above failures are new or related to multi-monitor capture on either backend.

## 9. Known gaps / explicitly out of scope this pass

1. **Portal/PipeWire capture path has no multi-monitor support.** Neither X11 nor Wayland's
   fix touches this — it's the "mirror someone else's real Wayland desktop via XDG portal"
   case (`desktop_display` with `capture = portal`), architecturally a from-scratch feature
   (see section 1a). Not the same thing as the Wayland/labwc headless work in section 1b.
2. **Wayland's GPU-native capture paths (`wlr_vram_t`, `wlr_extcopy_vram_t`) are single-output
   only.** Multi-monitor Wayland capture forces the RAM/SHM path. Extending the GPU-native
   paths needs an actual GPU compositing pass (render target + shader blit), not just the
   geometry math this pass added. See section 1b.
3. **No per-session client opt-in** via launch query string, on either backend — purely
   host-config-driven. The insertion point (`make_launch_session()`, `src/nvhttp.cpp` ~3827)
   and precedent (`explicit_mirror_desktop_requested()`, `src/nvhttp.cpp:164`) are unchanged
   from before.
4. **X11's `linux_capture_outputs` bounding-box crop for non-contiguous subsets** can include
   pixels from an unrequested monitor spatially between the selected ones. Documented, not
   fixed. Wayland doesn't have this problem (virtual outputs are always contiguous).
5. **Wayland screencopy round-trips serialize per monitor** (one shared capture session reused
   sequentially) — capture latency scales with monitor count. See section 1b.
6. Real multi-monitor validation on **both** backends is still outstanding (see section 8) —
   X11 needs real second-monitor hardware; Wayland needs an actual multi-output headless
   session run end-to-end (this pass only verified the geometry math and that everything
   builds/links/passes unit tests).

**Two incidental bugs found and fixed this pass, unrelated to multi-monitor capture itself:**
- `src/config.cpp`'s `linux_display_t` aggregate initializer wasn't updated when the previous
  (X11) pass inserted `multi_monitor_capture`/`capture_outputs` mid-struct — every field after
  them (`private_runtime`, `headless_swap_mode`) was silently getting the wrong default value
  from that point on. Fixed; new fields now get added at the end of the struct specifically to
  avoid repeating this mistake.
- `src/platform/linux/pipewire_capture.h` declared `cpu_frame_metadata()`/
  `dmabuf_frame_metadata()` with stale signatures (missing a `spa_format` parameter that had
  been added to the `.cpp` definitions at some point without updating the header) — this broke
  linking for the entire `test_polaris_platform` suite (nothing to do with multi-monitor
  capture). Fixed the header to match the actual definitions.
