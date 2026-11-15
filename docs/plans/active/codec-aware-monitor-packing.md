# Codec-aware monitor packing and admission

Status: implemented on `codex/virtual-monitor-transition-speed`, 2026-11-15.
Host and client changes remain uncommitted alongside the existing branch work.

## Reference behavior

Virtual Desktop's developer announcement documents up to three monitors on
Quest 3, two on Quest 2/Pro, and one on Quest 1, with resolution dependent on
headset and monitor count. The developer attributes Quest 2's count to XR2
processing capacity. Recent official macOS release notes also specify three
monitors on Quest 3/3S. Public material reviewed does not establish whether VD
packs one video canvas or uses independent streams, or disclose its packing
algorithm. Do not claim its architecture matches Nightfall.

Sources:
- https://www.reddit.com/r/OculusQuest/comments/1d9malz/virtual_desktop_update_multimonitor_tracked/
- https://github.com/guygodin/VirtualDesktop/releases (v1.34.0 macOS notes)

## Intended behavior

Preserve requested per-monitor resolution when adding physical or virtual
outputs. Preview the proposed complete capture before changing host displays,
counts, codec, tab ownership or the running session. Browser tabs/screens do not
consume desktop video-canvas capacity; their separate rendering/memory and
visible-screen limits remain. Inactive monitor tabs currently DO consume capture
capacity, so admission must count them too.

Limits derive from actual selected resolutions, codec, headset decoder, host
encoder, and known sustained decode budget at the requested refresh rate; do not
hardcode a monitor count such as 'H.264 supports two'. H.264+ changes bitrate,
not its spatial codec budget. Current Quest guards are 4032 per axis for H.264;
HEVC uses 8192 per axis, 35,389,440 declared total pixels and a separately tested
21,233,664 sustained-pixel ceiling. These are existing policy limits, not a
universal codec specification or proof of throughput at every frame rate/GPU.

For example, two 2560x1440 outputs fit geometrically in an H.264 canvas of
2560x2880. Two side-by-side outputs would exceed the width guard. Four
1920x1080 outputs fit geometrically as 3840x2160. These examples alone do not
establish sustained frame-rate support.

## Host/client work

1. Add a versioned client decode budget to the launch-plan preview AND actual
   launch/resume requests. Use request-local limits; do not mutate the global
   encoder limit for one client's codec. Legacy clients retain legacy behavior.
2. Build the same deterministic packing plan for preview, capture, manifest,
   input mapping and depth-region selection. Preserve desktop_rect; optimize
   frame_rect independently of where monitors are physically arranged.
3. Start with the existing row/grid packer, evaluate compact arrangements and
   minimize padding subject to the combined encoder/decoder budget. Prefer
   preserving every requested tile over scaling. Mixed portrait/landscape and
   unequal sizes need explicit tests; do not rotate content implicitly.
4. Honor Default Res/per-tab sizing before judging whether tiles fit. A physical
   4K source requested at 1440p must not be admitted as though 4K was requested.
   Report requested and effective per-monitor sizes in the preview response.
5. Return lossless-fit/reason metadata, the selected canvas, normalized regions
   and whether a proposed HEVC alternative fits. Keep old downscaling behavior
   only where compatibility requires it; do not silently use it for new additions.
6. Gate every add path (physical/virtual, tabs/screens and main settings counts)
   on this preview. Recheck after asynchronous replies and before committing.
   No fit must leave the workspace and host outputs untouched.
7. Only offer HEVC when both ends support it AND the same outputs fit that
   host's HEVC encoder/decoder/performance budget. An old AMD encoder may have
   its own lower axis ceiling, so HEVC is not automatically a solution.
8. Show the confirmation in the screen toolbar when initiated there:
   'Adding this monitor exceeds H.264's full-resolution limit. Switch to HEVC?'
   Actions: 'Switch to HEVC and add' / 'Keep current setup'. On confirmation,
   apply one coordinated codec/layout restart, preserving H.264 bitrate/profile.
   If no codec fits, offer a lower resolution instead of creating/scaling first.

## Verification

Pure host tests: 2x1440 H.264 vertical packing, 4x1080 grid, mixed sizes,
portrait, padding minimization, encoder smaller than decoder, total-pixel cap,
no-fit metadata, stable IDs and identical preview/launch plans. Add explicit
rollback/admission tests, browser exclusion and inactive monitor-tab inclusion.

Client tests: codec-specific offer, unsupported HEVC, HEVC still too small,
dismissal leaves state unchanged, repeated requests/stale previews, one restart
on acceptance, main settings and screen-toolbar paths, bitrate profile retention.

Bounded headset check: add the second 1440p output under H.264 without reducing
per-monitor pixels; confirm frame_rect/input/depth alignment for vertical packing;
at a real limit confirm the HEVC prompt precedes creation and acceptance uses
one restart. Repeat under HEVC and test an AMD host separately. Leave headset
comfort/sustained throughput as hardware acceptance, not claims from geometry.

## Implementation checkpoint — 2026-11-15

- Companion source: `/home/tyrone/Development/Personal/meteor-vibepollo`.
  `client_packing_budget.h` keeps the decode budget request-local; launch, resume
  and manifest planning enter a scoped budget without changing encoder globals.
- `display_plan.h` evaluates every grid column count, minimizes padding among
  fitting grids, then prefers the smallest maximum dimension for equal areas.
  Physical desktop coordinates remain independent from encoded tile coordinates.
- Physical Default Res / percentage and per-tab physical overrides are applied
  before admission. Explicit virtual dimensions stay exact; inherited virtual
  modes follow the default profile. Requested sizes are reported separately.
- Version-1 metadata reports support, full-resolution fit, effective canvas,
  requested tile sizes and the encoder-limited budget. A scaled preview is not
  accepted as a full-resolution fit. Strict launch requests reject a plan that
  no longer fits; existing oversized configurations retain compatibility scaling.
- Client monitor-tab and monitor-screen additions preview before modifying
  content, counts or outputs. The main settings apply path also checks newly
  enabled outputs, including replacements that keep the same total count.
- HEVC is offered only when available at both ends and its preview actually
  fits. The toolbar confirmation shares the existing controls atlas; it creates
  no new XR layer. Dismissal, timeout and stale requests reject the addition.
- Acceptance preserves codec bitrate profiles and defers the codec restart to
  the monitor transaction. A one-use request signature prevents a second prompt
  when the staged controller consumes the source's approval.
- The native launch URL forwards the same profile and limits used by preview.
  Profiled canvases bypass the former second global Default Res scale.

### Scope and remaining hardware acceptance

The extension is advertised only by tiled plan-based capture. Legacy/non-tiled
hosts retain their previous behavior; this does not implement a new X11 packing
backend. Current supported tiled paths use the shared host plan (KWin/GNOME,
Windows and macOS when their existing multi-monitor paths are enabled).
Windows/macOS builds and AMD hardware have not been verified in this checkpoint.
Limits reuse existing Quest codec policies, including the existing Quest 2 total
pixel guard. Geometry does not prove sustained throughput at every refresh rate.

Automated evidence:
- Pure C++ budget harness passed: 2x1440 H.264 vertical, 4x1080 grid,
  H.264 rejection versus HEVC fit, physical sizing, smaller host encoder and
  scoped-budget restoration. Durable companion gtest cases added; the portable
  production host build does not build that gtest target.
- All 72 GDScript scripts passed. New tests cover fit policy, version/size validation, scope metadata,
  confirmation cancellation, alternate codec support/fit, one-use approval and
  stale replies, together with the existing suite.
- Host portable build/package and native Android library compiled successfully.
- Release-optimized DEV APK built and installed in place, preserving pairings.
- Bounded headset connection succeeded with version-1 profiled metadata and
  matching encoded canvas/monitor rectangles. Evidence:
  `build/verify/codec-packing/smoke.json`.
- A second confirmation smoke attempt never reached a ready streaming session
  while the unattended headset was asleep. Its unchanged counts are not proof
  of real confirmation interaction. No display was added by that attempt.

Next manual check: start with one 1440p monitor on H.264, add a second and confirm
both retain 2560x1440. At a real limit, cancel the HEVC offer and check counts are
unchanged; then accept it and check the new output, cursor and depth alignment.
The app is stopped after automated checks to avoid draining the headset.

Development host restart preserves `METEOR_RESTARTED=1` and base port 49989.
An unrelated Brave UDP socket can occupy a reserved-but-unused host port, so a
cold reservation scan may choose another base. Do not clear pairings or kill
Brave to work around this. Current host log: `/tmp/nf-codec-packing-meteor.log`.
