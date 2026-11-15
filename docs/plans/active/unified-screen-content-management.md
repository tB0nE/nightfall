# Unified screen and tab management

Status: implementation started, 2026-11-14.

## Updated tab creation requirements

Accepted direction: Add tab offers Browser / Physical screen / Virtual screen
while a desktop stream exists, and Browser / Start stream otherwise. Physical
availability counts monitors already assigned anywhere in the workspace,
including inactive tabs, rather than only currently visible monitors. Grey the
physical choice when every capturable physical monitor is already represented.

The four-visible-screen limit must not constrain tabs. Keep the existing eight
browser pages per screen. Virtual tabs have no product/UI count limit tied to
screens; retain their individual host desktop/window state while inactive.
Creation remains subject to actual host capabilities/resources and must report
host rejection rather than pretend unlimited live displays are guaranteed.

Implementation checkpoint: basic create/select/close is implemented, with
regression tests for physical reservations, more than four monitor tabs on one
visible screen, manifest mapping, and sibling preservation. The existing eight
browser-page quota remains separate. Linux host validation permits up to 64
virtual displays as a resource safety bound; other platforms retain their
existing host limits. This is not a promise that hardware can sustain 64 outputs.

Inactive monitor tabs currently remain captured in the shared packed stream.
They retain desktop/window state and consume no additional XR layers, but still
cost capture/encoding bandwidth. Active-only capture selection below remains
future optimization.

Verification (2026-11-14): all 70 GDScript scripts passed, followed by the
updated toolbar regression; all nine Meteor discovery tests passed with host
socket access. A standalone C++ check confirmed six virtual entries survive
mode parsing and display planning. Optimized DEV APK installed in place; matching
Meteor and portable bundled host deployed. Quest verification passed. A bounded
live stream created a virtual tab alongside the physical tab on exactly one
VRScreen, selected the virtual source, and switched back to the physical source
successfully. The test disconnected and restored normal headset sleep. User
acceptance of mixed browser/monitor switching and closing is still needed.

Follow-up: parking the last visible stream for a browser now bypasses Welcome's
single-screen reset. The live Quest regression created physical + virtual tabs,
opened a browser (all three tabs remained), closed that browser, and confirmed
both monitor tabs returned on exactly one VRScreen. All 70 GDScript scripts
passed with coverage of the workspace-preservation flag. Optimized APK deployed.

Toolbar follow-up: monitor IDs are strings and browser page IDs are integers.
Direct equality between those Variant types raises a GDScript runtime error,
aborting mixed-tab drawing. Normalize IDs for selection comparisons in the row
and overflow list. Regression coverage now renders two monitor tabs plus two
browser tabs with a browser selected and exercises mixed-ID overflow selection.

Updated behavior: monitor-to-browser tab switches now retain the host stream,
decoder and virtual desktops, including when every monitor tab is hidden.
Explicit disconnect/closing the final monitor source retains its normal meaning.
The native browser path uses the entire browser texture rather than the retained
monitor's packed-stream rectangle. Primary browser binding resets UVs/aspect,
and background stream texture updates skip browser-owned surfaces. Mixed visible
browser-primary/desktop-secondary rendering uses independent legacy surfaces
because the native renderer samples one color producer. All 70 GDScript scripts
pass, including no-reconnect switching and browser/stream texture isolation.

Resume follow-up: monitor switches now hide/pause the live Android WebView
instead of destroying it. Hidden media is paused explicitly. Retain the last
browser texture across suspension and rebind it on resume; static pages must
not wait for a fresh SurfaceTexture frame to replace the desktop. The native
renderer also refuses to adopt the desktop producer while a browser is active
but still awaiting its first texture. Android integration assertions cover
retained page identity and visibility across monitor switches.
Live Quest check passed with two browser pages: physical → page 1 → physical →
page 2 → physical → page 1. Each return restored browser content and selected
the requested page while keeping the desktop connected. Test content was stopped
afterwards. All 70 GDScript scripts passed; optimized APK installed in place.

Design requirements and remaining optimization:

1. Render the toolbar from ScreenContentTabs, including multiple monitor tabs,
   rather than browser pages plus one synthetic Desktop item. Separate stable
   tab identity from the host connector currently captured on its screen.
2. Reserve physical outputs across tabs; add physical/virtual source choices and
   a disconnected Start stream action without consuming another VRScreen slot.
3. Maintain an explicit active-tab-to-screen mapping when applying manifests.
   Inventory and inactive tab entries must not create extra visible VR screens.
   Bind each active captured tab's UV/input mapping from its own manifest entry.
4. Separate host display existence from capture selection. Retain inactive
   virtual desktops/windows, but request capture for active monitor tabs only.
   Packed-stream reconfiguration must preserve other screens' providers.
5. Remove the four-display assumption from host count validation, virtual-size
   parsing, display plans and KWin creation/placement. Keep advertised backend
   limitations honest; never claim another platform supports this untested path.
6. Close the selected source tab, preserving sibling tabs. Stop the desktop
   session only after its final monitor tab closes. Show Welcome only after all
   physical, virtual and browser content is gone.

Acceptance: two physical outputs produce exactly two assignable physical tabs
and then a disabled Physical choice; multiple virtual tabs can occupy one screen
without increasing VRScreen count; inactive virtual tabs retain windows; eight
browser tabs fill only their own screen's browser quota; closing/reopening host
sources leaves browser content intact. Test switching and closing each source
with other screens still active, as well as zero-content and reconnect behavior.

## Agreed behavior

- Physical monitors, virtual monitors and browsers use the same screen/tab model.
- Each screen has tabs above its surface. Browser navigation occupies a second
  row only when the selected tab is a browser. Reuse the existing controls layer.
- The bottom grab bar remains; shortcut buttons belong only to the primary.
- Resolution and crop belong to each **tab**, not each screen. Existing crop
  processing handles aspect-ratio changes without requiring a host mode change.
- Inactive stream tabs stop video reception. Browser tabs retain the existing
  browser background-audio policy; do not promise concurrent live WebViews.
- Basic add/select/close only. Moving tabs between screens is deferred.
- Start with a clean workspace each launch. Do not automatically restore tabs,
  URLs, monitor assignments or layouts. Existing global preferences/bookmarks
  remain; explicit saved layouts can be added later.
- Local depth belongs to the screen and follows its selected tab. Initially one
  local inference screen; Meteor may supply stream depth alongside one browser
  using local inference. Do not run inference for inactive tabs.

## Milestones

1. Shared model and lifecycle groundwork: per-tab resolution/crop; one stable
   mixed source list; browser metadata refreshes must preserve stream selection,
   monitor identity and existing per-tab settings. Tests require no headset.
2. One primary screen switching browser/monitor tabs. Retain browser navigation
   in RAM during suspension, stop inactive stream traffic, serialize disconnect
   and reconnect, cancel captured input, drain native texture consumers before
   producer changes, and rebind depth only after current-generation frames.
   Never silently keep decoding a hidden stream to simulate completion.
3. Unified toolbar: Add tab/Add screen -> type. Browser controls only for browser
   content; expose a per-tab resolution/aspect selector. Keep the existing
   multi-screen path operational during migration.
4. Extend to multiple mixed screens. Default practical visible-screen cap four;
   grid layouts through eight and beyond-grid policy remain to be resolved.
   Reconcile inactive packed monitor tabs with host capture/encoding requests:
   hiding a region of a combined video frame does not stop its reception.
5. Custom virtual monitor creation: resolution/aspect popup, host-capability
   validation, up to 8K where capture/encoder/decoder budgets permit. Surface
   actual host limits rather than presenting unsupported sizes as guaranteed.
6. Persistence and tab movement are explicitly later work.

## Current architectural constraints

`BrowserPrototype` owns a browser surface per screen and Android currently
retires/restores a single WebView when switching browser pages. Closing the
browser clears page state; closing is therefore not a suspension primitive.
`StreamManager` owns a primary host session; connection currently closes the
primary browser. A real browser/stream switch requires a retained browser
suspension path and explicit stream-session ownership, not just changing labels.
`ScreenSources.sync_browser_pages` currently mirrors metadata and unconditionally
selects the browser page. This must not steal selection from a monitor tab.

## Verification and acceptance

- Unit/model tests: mixed tab identity, stale page removal, preserved selection,
  independent display settings, stream suspension and transactional restore.
- Headset: repeated browser -> stream -> browser; correct pointer coordinates,
  clicks/keyboard, audio ownership, retained browser state, resolution/crop,
  active-tab-only depth, close races, standby and return from PCVR.
- Keep tests bounded and restore normal sleep. Use optimized DEV APKs, preserve
  pairings, do not run gamescope/Vulkan desktop UI tests on this machine.

## Implementation checkpoint

Shared tabs now carry validated resolution/crop preferences, with explicit
default inheritance and backward-compatible optional serialization fields. This
does not enable automatic workspace saving/loading. The crop renderer and menu
read the selected primary tab; Auto crop resets its sampling history on a tab
change. Resolution values are model groundwork, not yet provider resize calls.
Browser metadata reconciliation now updates the shared list while preserving
monitor selection, tab objects and their settings. Same-monitor refreshes retain
their tab object. Inactive stream policy explicitly suspends the provider even
if browser audio flags were copied to it.

All 66 GDScript scripts pass after these changes, including new mixed-source,
per-tab settings, JSON round-trip, invalid profile and metadata reconciliation
checks. Full source switching/retained browser suspension and the unified toolbar
remain to implement; no APK is advertised as the completed redesign.

## Source-switching checkpoint

- Android browser suspension now retires the live WebView while retaining tab
  identities and navigation bundles in RAM. Resume reconstructs the selected
  page; close still clears the session. A generation guard rejects late resume
  after close. Existing browser audio behavior is unchanged (inactive WebViews
  are retired; there is no new background-audio implementation).
- Primary toolbar combines the PC/welcome tab with browser pages. Add tab opens
  a source-type submenu. PC selection reuses the existing monitor source.
- Switching the sole visible monitor to a browser disconnects video, records
  the host/app session in RAM and reconnects it when selected again. Other
  packed monitor screens block this operation until per-monitor ownership is
  implemented. Secondary browser screens keep their existing behavior.
- Source changes cancel transient input and local inference; native consumers
  drain before browser suspension. Stream startup preserves a suspended browser.
- All 67 GDScript checks pass, including the new disconnect/reconnect round-trip
  test. Real Android WebView suspension/resume/late-close instrumentation passed
  in 6.36 seconds against the isolated test package.
- Optimized DEV APK built and installed. Full unattended in-app validation is
  **not confirmed**: browser pages opened, but the bridge stopped responding
  during the round trip; subsequent ADB shell operations also timed out. Test
  cleanup was attempted with strict time limits. Do not report full live source
  switching, pointer correctness or AI handover as tested until reproduced.
- Still outstanding: reliable in-app acceptance, provider resize per tab,
  custom virtual sources, mixed multi-screen organization and full type menus.

## Follow-up checkpoint: bounded drain and tab resolution

The source-switch drain waited for `RenderingServer.frame_post_draw`, which is
not guaranteed after disabling the last native source in projectionless XR. It
now observes that signal opportunistically while retaining a three-to-six-frame
drain, then disconnects its temporary callback. The round-trip regression now
uses this production drain rather than a stub.

The desktop tab exposes `+ Add → Tab resolution`. Its override participates in
actual stream negotiation, preserves Default Res, keeps packed-stream aspect
and passes through the existing codec/Quest hardware ceilings. Changing it on
a live stream uses the normal debounced restart. Browser resolution resizing is
not exposed yet: the current native browser surface supports only 1080p/1440p
and requires coordinated producer/consumer resizing.

All 68 GDScript scripts pass, including production resolution negotiation for
per-tab/default restoration, H.264 bounds and browser/stream preference isolation.
An optimized DEV APK is built. ADB shell/forwarding has been intermittent; user
confirmed the headset itself is responsive. PC-side ADB restart restored access,
and testing switched from SideQuest's 35.0.1 ADB to SDK 37.0.1. Do not interpret
transport timeouts alone as an app or headset freeze. Live round-trip acceptance
remains pending after the bounded-drain fix.

The native renderer's per-frame `refresh()` now explicitly suppresses both
reactivation and legacy fallback while `switching_tab` or `switching_primary`
is true. The old browser texture can remain valid across drain frames, so source
eligibility alone was insufficient. A policy regression verifies no eligibility
probe or legacy restore during the transition, followed by normal eligibility
afterward. Source-switch phase logs are flushed at the async boundaries for
future headset diagnostics.

Latest optimized APK, including the native refresh guard and flushed phase
diagnostics, was installed successfully. The final scripted acceptance attempt
stopped before opening a browser because the bridge was unavailable after launch;
it therefore does not validate or invalidate the corrected handoff. Sleep/Guardian
automation was restored by cleanup. No desktop stream or game was started.

Next manual acceptance: browser with two tabs -> Desktop/welcome -> either
browser tab; then repeat while a desktop stream is available and confirm video
disconnect/reconnect. Test the desktop tab's `+ Add → Tab resolution` override
separately from Default Res. Browser render-surface resizing remains next work.

## Browser per-tab resolution checkpoint

Implemented `+ Add → Tab resolution` for the primary browser tab: Default,
1920×1080 or 2560×1440. Each tab retains its own override in memory, and selecting
a tab reapplies its desired size. Default inherits the existing browser preference.
No automatic workspace save/restore was introduced. Secondary-screen resolution
controls remain outside the first primary-screen switching milestone.

The Android virtual display and SurfaceTexture buffer size now resize without
recreating the WebView. The GLES uploader resizes its existing RGBA output texture
on the render thread, preserves its texture name/RID, updates ImageTexture size
metadata and reports the allocated dimensions. Input and local inference pause
during the guarded drain/resize. Both native and Android dimensions must match
before pointer coordinates change. A partial acknowledgement attempts rollback;
if rollback cannot be confirmed, close the provider rather than leave mismatched
input coordinates. Failed requests do not retry every frame.

Validation: Release streaming extension rebuilt with CMake/Ninja and stripped
per BUILD.md. All 68 GDScript scripts passed, including resolution profiles,
Default restoration, rejected sizes, allocation rejection and picker bounds.
The real Android isolated test switched 1080p/1440p three times, checked actual
VirtualDisplay dimensions and retained WebView/tab identity, and verified invalid
size/late-close rejection: PASS in 6.008 seconds. This verifies the Android
producer; final native VR image quality and AI-resize behavior still need headset
acceptance. Optimized DEV APK rebuilt with the matching native library.

## Add screen source types checkpoint

The toolbar's Add screen action now opens Browser, Physical monitor and Virtual
monitor choices. Unsupported choices are disabled; Desktop connection is offered
only when the workspace needs one. Existing Screens controls remain available.
Monitor creation uses the existing host configuration/restart lifecycle, preserves
enabled physical outputs and the primary output, and prevents duplicate creation
or browser additions while a monitor change is pending. The shared four-screen
limit applies across browsers and monitors. Custom virtual sizes remain later work.

Validation: all 69 GDScript test scripts passed, including source-menu bounds,
capability checks, pending-request exclusion and preservation of a non-leftmost
primary monitor. Release-optimized DEV APK built and installed in place, retaining
settings and pairings. Live host creation, mixed-source switching and browser
resolution acceptance still need headset testing; unit coverage is not a substitute
for those checks.

Latest bounded headset check: bridge confirmed idle desktop/welcome and accepted
`select_browser_tab(primary_screen)` with a true result. The next state query
timed out; Android reported `com.oculus.os.clearactivity/.ClearActivity` as the
foreground activity. Therefore suspension/resume and the full round trip are
still unverified, not a confirmed application hang. Normal sleep/Guardian
automation was restored. Evidence: `build/verify/screen-source-roundtrip/summary.json`.

Follow-up with Nightfall foregrounded found a real suspension rejection:
JavaClassWrapper's dynamic Java static methods report false through `has_method`,
including the already-working `browserTabsFor`. The new visibility API had used
that check and therefore returned before suspension. Removed that invalid
introspection guard, retaining null-bridge checks, consistent with the other Java
calls. All 69 GDScript scripts pass; optimized APK rebuilt and installed in place.
Post-install automatic launch did not yield a bridge reply, so the corrected
full live round trip remains pending. No unattended media or sleep override left
running. Evidence: `build/verify/screen-source-roundtrip/java-bridge-fix-summary.json`.

## First user acceptance findings

- Choice popup panels grew, but GLES ScrollContainer clipping still cut their
  contents. Disabled that clip path, as already done for Advanced settings;
  complete rows are explicitly culled for rendering and pointer input. Regression
  checks include reaching the last row and preventing offscreen clicks.
- Secondary captured monitors had no toolbar because `menu_for_screen` returned
  null without a browser provider. They now get an inactive, menu-only provider
  and use the existing controls atlas. This does not allocate an Android browser
  or add a composition layer. Regression checks verify reuse and no registration.
- **Not implemented yet:** per-tab editing/switching for secondary packed-stream
  monitors. Showing their toolbar is not completion of milestone 4.
- **Priority next:** virtual creation must first present preset/custom width and
  height (aspect presets reuse crop). No monitor should be created until confirmed.
  The current `/meteor/virtual` and GameStream launch paths carry a count only;
  host display plans derive virtual sizes from the primary monitor. Implement
  advertised per-output size support across plan preview, actual creation and
  manifest/encoding, validate host and aggregate codec limits, then expose it in
  the creation picker. Do not fake custom creation by changing only client UVs or
  the global packed-video resolution. Existing hosts must retain count-only
  compatibility and unsupported custom-size choices must be clearly unavailable.

## Secondary tabs and custom virtual creation implementation

This checkpoint supersedes the two outstanding items immediately above.

- Secondary physical/virtual monitor toolbars can add a browser tab and return
  to their retained Desktop tab. They reuse browser surface slots, preserve the
  shared desktop connection for other screens, and restore the monitor's UV
  region and aspect on return. Closing the last browser tab on such a screen
  restores its monitor instead of deleting the screen. Browser tabs on these
  screens also expose the existing 1080p/1440p per-tab surface resize path.
- The primary can switch content while other monitors remain visible, keeping
  their shared packed session connected. This is not independent per-monitor
  decoding: the packed transport remains shared while other monitors use it.
- Add screen → Virtual monitor opens a creation picker. Match host monitor is
  backward compatible. Presets and Custom resolution are enabled only when the
  host manifest advertises `virtual_modes_supported`. Custom creation collects
  width, height and explicit Create confirmation. Dismissing a picker does not
  create a monitor. Dimensions must be even, within 320×240 to 8192 per axis and
  within the host's 35,389,440-pixel picture budget; the packed encoder plan can
  scale the resulting stream to its aggregate hardware ceiling.
- Session-local sizes are scoped to the selected host. Virtual tab resolution
  edits relaunch the host capture plan; they do not resize the whole packed
  stream as if the virtual monitor were the only screen.
- GameStream launch and prelaunch manifest queries carry `virtual_modes`, a
  count-matched comma-separated list such as `0x0,2560x1440`; `0x0` inherits the
  physical primary's size. The native library URL-encodes the parameter.
- The companion checkout `/home/tyrone/Development/Personal/meteor-vibepollo`
  now validates these requests, computes per-monitor packing/desktop positions
  and creates the actual KWin outputs at their requested sizes. Request state is
  passed explicitly, never stored in a global override. Size changes recreate
  virtual outputs because KWin cannot resize them in place. Custom sizing is
  currently **KDE Wayland only**. Other backends keep default-size creation and
  reject unsupported explicit size requests instead of silently ignoring them.

Validation: 69 GDScript scripts passed, with new secondary-tab handoff, toolbar
allocation and custom-size validation regressions. Release Android extension and
containerized host built successfully. Standalone C++ parser/packing and KWin
heterogeneous-placement tests passed; persistent gtest cases were added in the
host checkout (the complete host gtest suite has not been run). The host was
packaged with its portable-library RUNPATH and activated under the existing
Meteor configuration. APK is release-optimized DEV, installed in place.

Live paired-host check connected successfully, reported custom-size support and
showed all creation-picker buttons, including the last Custom resolution row.
The subsequent create/switch test timed out before making a monitor change;
actual custom output creation and secondary browser/monitor visual/input
acceptance remain pending. Evidence lives in
`build/verify/custom-virtual-screens/`. No test media was played.

Next user checks: add a custom virtual monitor (e.g. 1280×720), verify its host
desktop size, add a Browser tab on that screen, switch to Desktop and back, change
the tab's resolution, and close the browser tab. Other screens should remain
usable. Both repositories contain uncommitted source changes and must be included
when this work is committed/released; shipping only the APK does not add custom
size support to older bundled hosts.

## Closing monitor screens

Each screen toolbar now has one red circular × at the top left. It closes the
active browser tab or physical/virtual monitor source. Per-tab close targets have
been removed; hovering another tab does not change the close target.
The close action reduces the selected physical/virtual count through the existing
host transition lifecycle. Physical output selection is explicit, so closing a
leftmost monitor does not accidentally reselect it. Closing the last monitor disconnects its stream. Browser tabs/screens remain
available; Welcome is displayed only when no content remains. This supersedes
the earlier physical-monitor fallback.

Virtual IDs are compacted with the count-based host protocol: surviving views,
their monitor-tab identities and custom-size profiles move together. The closing
view receives a retirement ID so it cannot be reused for a different survivor.
Primary replacement adopts the surviving screen's provider/toolbar. Browser tabs
retained on the closing monitor remain open: the monitor tab is removed and its
view becomes a browser screen. Browser screens keep their position when capture
primary changes. Browsers on other screens remain untouched. New monitor close requests are blocked during an active
monitor transition. No host protocol change is required for this increment.

Validation: all 69 GDScript scripts passed, including monitor-removal plans,
exact physical-output selection, last-virtual physical fallback, size/profile
compaction and pending-request exclusion. The toolbar regression also verifies a
visible/clickable X on a monitor without browser pages and dispatch to the close
action. Release-optimized DEV APK built; live headset close/reconnect acceptance
remains to test.

### Last browser tab returns to retained desktop

The browser's producer-close path previously drained and restored the welcome
surface without consulting the desktop session parked by a tab switch. Browser
producer closure now asks ScreenSources to restore the retained monitor after
the existing three-frame drain: rebind the monitor if the shared stream is still
running, or reconnect the parked host/app if it was stopped for a sole browser.
A standalone welcome/browser workspace still returns to welcome. Explicit
takeover/stop calls do not request automatic reconnection, and callbacks cannot
override a connection already starting. Consuming the parked session when it is
restored prevents a later welcome-only browser from reconnecting an old host.

Regressions cover close/drain ordering, reconnecting the original host/app,
selecting the retained monitor, consumed-session behavior and late callbacks
during another connection. Existing secondary-browser close behavior remains.

### Closing Desktop leaves Browser open

The last physical Desktop tab with retained browser pages now has a dedicated
close path rather than calling the ordinary Browser tab switch. It marks the
browser view for preservation during full disconnect cleanup, stops the decoder,
waits for consumer retirement, resumes the same browser session, removes the
Desktop tab and clears the parked reconnect request. The disconnect still clears
video resources/audio/input, but does not replace this retained screen's layout
or texture with Welcome. Closing Browser afterwards cannot reconnect a Desktop
tab the user explicitly closed. Normal tab switching continues to retain Desktop
and supports the opposite close-and-return path above.

The regression verifies the preservation flag is visible during disconnect,
browser page/tab identity survives, Desktop is removed, reconnect state is
consumed and no extra stream starts.

### Empty-workspace rule (supersedes physical fallback)

The last physical or virtual monitor can now close to zero. No physical monitor
is reopened automatically. With no remaining browser, use full disconnect cleanup
to show Welcome. With a surviving browser on the closing screen, retain it; with
a surviving browser on another screen, preserve and promote that browser and
remove the closed monitor view. Already-active browsers rebind their colour
texture after decoder cleanup. Closed/closing browsers do not count as survivors.
Saved virtual count and pending reconnect state are cleared on final-monitor
closure. A normal single-screen GameStream host can also close to Welcome without
needing multi-monitor capability.

Regressions cover zero-monitor removal plans for physical and virtual sources,
no automatic physical reconnect, preservation on the same screen and browser
promotion from another screen. The full 69-script suite passes.

## Recently used browser pages and selected-monitor depth (2026-11-15)

Browser page switches detach and pause the previous WebView, retaining it for
10 minutes since last use. Returning before expiry reattaches the same document,
without a reload. Eviction destroys the cached view but keeps RAM-only navigation
state for reconstruction. Closing a tab/session or clearing browser data releases
cached views immediately. Media is paused while hidden. Existing limits remain
8 browser pages per screen; retention does not add VirtualDisplays or XR layers.

Meteor advertises `depth.region_hello`. Supporting clients send an `NFDC` hello
(the normal X25519 public key followed by four little-endian float32 normalized
bounds: left, top, right, bottom). Legacy `NFDK` connections still use the host's
primary-monitor region. Client selection is scoped to its canonical source IP
and connection lease; a closing old connection cannot erase a replacement's
selection. Region changes clear receiver maps, reset temporal stream identity,
and exclude maps whose input predates the new hello.

NVDEC updates its display area between packets with cuvidReconfigureDecoder;
there is no desktop-stream restart. FFmpeg decoders crop downloaded NV12 before
existing CPU/Vulkan model preparation. This adds a bounded copy for a non-full
region on FFmpeg paths; full-frame input avoids that copy. Rendering crop and
inference source selection are separate: user cropping still applies afterward.

Verified: all 70 GDScript scripts passed; region validation/parsing, NV12 cropping
and NVIDIA ABI tests passed. Two isolated Android WebView tests passed on Quest,
including reuse of the same document across browser-page switches. Optimized
client installed in place and matching Meteor restarted. Live virtual → physical
selection changed the request from [0.5,0,1,1] to [0,0,0.5,1], with fresh maps
received for both, no NVDEC fallback, and automatic stream cleanup afterward.
The 10-minute wall-clock expiry and browsing comfort remain user acceptance.

## Browser-to-virtual-tab headset reboot investigation (2026-11-15)

Export preserved at build/verify/virtual-tab-reboot/diagnostics.txt. The previous
session ends abruptly, without a native exception/backtrace or the final virtual
creation event. Depth diagnostics show repeated 384/512 OpenCL model transitions,
several-second delegate loads and periods of zero completed updates. These are
concerning context, not proof of the reboot's exact GPU-driver cause. Horizon
reports only `reboot`; unprivileged ADB cannot read pstore.

Confirmed code defect: add_monitor_tab from an active browser drained the native
renderer without disabling local depth or waiting for its executor/model work.
The corrected path disables depth, blocks new Java submissions, cancels pending
GPU input, places an executor barrier, and waits up to eight seconds for inference
and model reconfiguration to finish before suspending the browser. Timeout aborts
creation with a status message, preserving the browser and tab list. Depth does
not submit while source/monitor transitions are pending. Native presentation also
waits for monitor_id to match its captured MonitorSpec, rather than presenting a
new tab using its previous monitor's region.

All 70 GDScript scripts passed. The monitor regression additionally tests a
busy-worker cancellation and successful drain ordering. Optimized APK installed
in place. A bounded Quest check created two browser pages, selected a retained
page with AI 3D enabled, then added a virtual tab. Log confirmed inference/render
consumers drained before the handoff; v1 became selected and the stream remained
connected, without a reboot. Test content was stopped. This is one successful
check, not proof the original system-level failure cannot recur. Repeated model
reloads on general source switches remain a separate optimization candidate.

## Monitor-switch latency, source reset and local picker (2026-11-15)

Existing monitor → monitor tab changes now bind geometry/UVs directly and force
native redraw, without apply_stereo(), Java model configuration or stream restart.
Browser producer changes and new-output creation retain their safety drains.
Meteor tags each decoded frame/map with the client region-selection lease. A new
lease changes temporal stream identity even for identical crop coordinates,
forcing VDA cold-start and post-processing reset. Depth delivery rejects old
selection IDs as well as old input timestamps. The headset replaces stale depth
with a neutral map while waiting and respects the initial Meteor grace period
instead of immediately starting local inference during each reconnect.

The screen toolbar now owns virtual-monitor creation and resolution editing:
Match host, presets, or an in-atlas width/height numeric keypad. Custom values
retain the existing validation. No main-menu toggle, extra keyboard surface or
additional composition layer is needed. Main settings retain their own controls.

Resolution finding: the saved report shows native 5120x1440 requested at
4032x1134 under H.264, so each 2560x1440 tile has only 2016x1134 encoded pixels.
Three native 2560-wide monitors were requested at 4032x756. Inactive monitor tabs
still participate in the packed capture. This is spatial downscaling at the
client's H.264 safety cap, not a bandwidth shortage. Closing outputs or choosing
HEVC avoids that particular limit where the larger frame is supported; no codec
preference was silently changed.

All 70 GDScript scripts passed, including the no-reconfiguration fast path,
preset picker and custom 1280x1024 keypad path; depth-server tests passed. Optimized
APK installed, matching optimized Meteor running. Live end-to-end verification
could not complete because the Quest was asleep and the app paused. No test
stream remained running; the paused test app was stopped.

During activation, a connected Brave IPv6 UDP socket on port 50002 made the
wildcard bundled-host reservation probe reject the saved base 49989 and choose
47989. Browser sockets were not interrupted. Intentional-restart reuse of the
saved base (previously Windows/macOS only) now applies on Linux as well; actual
listener binds still enforce conflicts. The original 49989 endpoint was restored
with all credentials/pairings preserved. Cold-start port selection is unchanged.
