# Settings popups and controller drag scrolling

## Extended bitrate opt-in

Advanced/Settings → General → Extended Bitrate defaults to Off and is saved as
an app preference. It doubles codec-specific desktop and PCVR slider maxima:
H.264 150→300, H.264+ 500→1000, HEVC and AV1 200→400 Mbps. Existing codec
choices, separate desktop/PCVR profiles, minimum values and Auto behavior remain.
Turning it off clamps selected/saved profiles back to their normal limits;
desktop bitrate changes use the existing restart, PCVR changes use live control
when available. Raising the ceiling alone does not increase the selected bitrate.

Client XR validation, Meteor Linux/Windows session validation, live bitrate
commands and NVENC/VA-API encoder parsers now accept up to 1000 Mbps. The UI still
enforces the chosen codec's range. This is a policy limit, not a guarantee that
the network, encoder or headset sustains every offered value.

Verification: all 69 GDScript scripts passed, including defaults, persistence,
codec profile switching and clamp-on-disable; 27 targeted Rust tests passed;
C++ initial/live bitrate boundary tests and rebuilt XR helper preflight passed.
The optimized APK, Linux Meteor and updated versioned XR helpers were deployed
locally. Post-install bridge check did not reply, so live UI acceptance remains
pending. Actual high-bitrate quality/latency is not benchmarked by these checks.

Status: in progress, 2026-11-13.

## Implementation checkpoint

Implemented and awaiting combined user acceptance:

- One shared popup within the existing menu viewport; no additional XR layers.
- Desktop bitrate slider: Auto or a codec-specific range, with Apply. Legacy saved
  preset indexes retain their values; Auto retains its 120 Mbps ceiling.
- Ambient gain slider: 0–200%, with live preview and 100% preserving today's
  Static/Slow/Live baselines. Outside dismissal, menu closure and suspension roll back
  uncommitted preview values. Provisional location: Settings → Display.
- Explicit choices for main-menu display, picture, input, AI 3D, diagnostics,
  language and staged screen counts. Ordinary On/Off buttons remain direct.
- PCVR resolution and bitrate sliders, codec, sharpening and supersampling choices; existing
  next-session resolution and live bitrate/post-processing behavior retained.
- Long lists support mouse/XR drag scrolling without selecting while swiping.
- Grip Scroll under Settings → Input, Off by default. With Mapping off, hold
  the pointing controller's grip and move vertically over a desktop/browser.
  Replaces screen right-click while enabled. Captures host/screen/tab/hand;
  cancellation requires release. Tracking loss, standby, menus, active mappings,
  existing clicks and screen grabs cannot start or prolong a gesture.
- GameStream receives high-resolution wheel events; Android WebView receives
  fractional wheel events rather than the old Page Up/Page Down keys.

Verification: all 66 headless GDScript checks pass. The pointer-routing test
uses real physics/raycast hits and checks host/browser separation, cancellation,
closed screens, held-input rearming and release of captured browser references.
An isolated Android instrumentation test confirmed fractional wheel events reach
an actual WebView page in both directions (seven seconds, no user profile used).
Fifteen representative menu buttons were opened and cancelled through the Quest
bridge; screenshots confirmed language and PCVR list bounds. Optimized DEV APKs
are used for headset testing. Grip Scroll is left Off and normal sleep restored.

A bounded desktop-stream test also negotiated 200 and 400 Mbps H.264 with
Vibepollo. Host logs confirmed both requested targets without a 100/120 Mbps
clamp; the Quest reported about 72 fps at its configured 72 Hz. Both samples
and reconnects completed in 14.8 seconds. HEVC/120 Mbps was restored, the stream
disconnected, and normal headset sleep restored. This was a mostly static
desktop negotiation check, not a sustained throughput/quality benchmark.
Evidence: `build/verify/bitrate-negotiation/summary.json`.

Manual acceptance remains: gesture feel, live ambient appearance, model/stream
changes and sustained high bitrate throughput. Offering 500 Mbps does not prove
that every host, network or decoder sustains it. moonlight-common-c carries the
full requested bitrate in its Sunshine-specific configuredBitrateKbps attribute;
legacy GFE retains its cap. Vibepollo can impose its own max_bitrate. PCVR bitrate accepts 8–500 Mbps, constrained by the selected codec profile.
PyroWave's existing Auto multiplier is unchanged.

## Agreed scope

- Use the Screens Layout selector's popup interaction for settings choices.
- Bitrate and ambient intensity get sliders; enumerated settings get explicit
  choices rather than repeatedly cycling their buttons.
- Preserve existing defaults, saved choices, hardware restrictions and model
  switching safeguards.
- Investigate thumbstick-free scrolling for desktop and browser screens.
- Defer widescreen resolutions and screen organization to the wider redesign.
- Final placement of the intensity button and other controls remains flexible.

## Baseline before implementation

`src/ui_controller.gd` builds `ScreenLayoutPopup` as a PanelContainer inside
the existing menu viewport. Reuse this approach: native popup windows cannot
reliably receive our projected XR input. No additional OpenXR layers are needed.
`src/menu_schema.gd` describes most ordinary controls, but AI 3D, Screens and
PCVR also have separately constructed controls which need auditing.

Desktop bitrate originally stored an index, with -1 meaning Auto. Manual values
are 5–120 Mbps; Auto uses its existing resolution-dependent calculation. PCVR
has a separate bitrate implementation and host validation, currently 8–160 Mbps.
Do not conflate these ranges or change Auto as part of a presentation change.

Ambient intensity currently uses 0.20 for Static and 0.35 for Slow/Live.
The native input bridge already exposes vertical/horizontal high-resolution
scroll events; the GDScript stream backend currently forwards discrete scrolls.

## Shared popup component

Introduce a reusable `src/settings_option_popup.gd`, owned by the menu UI.
Extend schema descriptors with interaction type, current-value getter, explicit
setter, available choices or numeric range, default, and application policy.
Use stable setting/option identifiers rather than translated labels or indexes.

Application policies distinguish cheap live previews, immediate choices and
debounced expensive changes. A setter must select a value directly: never call
a cycling handler repeatedly to reach the requested option. Keep validation,
persistence and side effects in the existing authoritative controllers.

- One popup at a time, styled like the current menus and keyboard.
- Highlight the current selection and show units, defaults and unavailable
  choice explanations. Preserve translated labels and tooltips.
- Place within viewport bounds; long lists scroll without covering the toolbar.
- Close on selection, explicit close, menu/tab changes or outside press.
- Consume the dismissing press so it cannot click the screen behind the menu.
- Capture slider input until release, even when the pointer leaves its bounds.
- Dismiss tooltips on opening; route input ahead of underlying screens, grab
  bars and menu content. Clear capture on tracking loss, standby or disconnect.
- Revalidate dynamic capabilities when opening and applying; refresh an open
  list if the host or inference source changes.
- Avoid per-frame list rebuilding and any rendering work while closed.

Binary On/Off buttons remain direct toggles. Two named alternatives such as
GPU/CPU are choices, not binary toggles, and should use the selector.

## Pilot: bitrate

The popup contains Auto, a manual slider and an exact Mbps readout. Existing
saved preset values continue to load without changing their effective bitrate. Preserve existing saved index
values and Auto behavior. Add a validated explicit custom Mbps representation
with backward migration, rather than inserting arbitrary values into indexes.

Dragging updates the displayed pending value. Apply once when confirmed and reuse
restart coalescing; never restart the stream on every slider tick. Keep the
current desktop restart behavior until live bitrate control is supported end
to end. PCVR's existing live bitrate path remains separate.

Higher bitrate is a separate capability task. Audit client request bounds,
host clamps, encoder settings, transport buffering and decoder limits before
choosing a new maximum. Do not silently change defaults or promise a universal
500 Mbps limit. Validate representative 150/200/300/400 Mbps requests where
supported, including requested versus applied values and frame delivery.

Virtual Desktop's H.264+ denotes its higher-bitrate H.264 option, not a separate
standard codec requiring another decoder. Nightfall already supports H.264;
equivalent high-bitrate functionality needs the above end-to-end validation,
not merely another codec label. Its proprietary encoder tuning is not implied.
Reference: [developer release announcement](https://www.reddit.com/r/OculusQuest/comments/14jik0r/).

## Pilot: ambient intensity

Add a persisted ambient gain, initially 1.0. Present 100% (Default) as the
current mode's existing intensity: Static 0.20, Slow/Live 0.35. This preserves
today's appearance and mode differences. Use one gain across modes initially;
per-mode memories can be considered later without changing the first design.

Preview gain live through the existing lighting parameter update and persist
when confirmed. Determine a useful bounded slider range during visual acceptance.
Allow configuration while Ambient is Off without turning it on. Do not restore
old blur/neon choices or couple intensity to bezel state. Static colour remains
specific to Static mode.

## Migrate the other choices

Audit every multi-value action, including controls outside MenuSchema. Migrate
in small groups, retaining each platform's existing option list and defaults:

1. Resolution, FPS/Hz, codec, volume and existing Crop choices. No new aspect
   ratios or widescreen behavior in this work.
2. Curve, background, ambient mode/colour, passthrough fade, picture adjustments,
   sharpening, colour key and tolerance.
3. AI 3D source, model, backend, priority, Hz cap, separation, convergence and
   diagnostic choices where present. Preserve Auto and all model teardown,
   load debounce and safe-switch sequencing.
4. Cursor type/smoothing/position, mapping type, alternate mapping, primary
   hand, double click, connection policies, language and audio output.
5. Screens layout/count choices and PCVR Stream settings, including dynamic
   resolution/refresh options and restart-required indications.

Preserve existing slider-like settings as defined choices first unless their
runtime/persistence supports continuous values. This prevents a UI migration
from silently changing image processing behavior or supported ranges.

## Thumbstick-free scrolling

Start client-side: holding a configurable input while moving the pointer
vertically produces scroll-wheel deltas. This needs no Meteor-specific host
extension and retains Sunshine-compatible host support.

Expose the native bridge's high-resolution scrolling in `src/stream_backend.gd`.
Use fractional accumulation, a small dead zone and bounded event delivery.
Route the same gesture to local browser scrolling rather than GameStream when
a browser screen is targeted. Menus consume their own scroll input.

Choose and capture the target at gesture start; do not move the gesture to a
different screen mid-drag. Stop and release on tracking loss, standby, screen
closure or disconnect. Coordinate with existing click/drag handling so a scroll
does not also activate a button or drag the screen.

Do not hard-code grip or Y until mapping conflicts are checked. Use an opt-in
mapping and respect primary-hand and single-controller setups. Do not steal
gamepad or PCVR game actions. Direct middle-click forwarding is a separate
mapping: browser middle-click autoscroll varies by application and OS, so it
must not be the foundation of this feature. Anchor-based continuous scrolling
could follow after the simpler drag gesture is accepted.

## Delivery and verification

1. Shared popup and bitrate pilot, with direct setters and persistence migration.
2. Ambient intensity pilot and live preview.
3. Enumerated-choice migration, grouped as above; retain restart/load safeguards.
4. Scroll gesture and input routing, independently testable from the UI changes.
5. Higher bitrate validation and any required host changes.

Automate descriptor validation, saved-value migration, explicit selection,
one-commit-per-drag, cancellation and changing-capability cases. Exercise popup
hit priority, outside dismissal, clipping and toolbar access with bridge-driven
checks. Run relevant unit checks; documentation alone needs no app build.

On this machine do not run the gamescope/Vulkan desktop UI tests which have
previously reset the desktop. Use isolated headless checks and the Quest bridge
for UI geometry/input. Build release-optimized DEV APKs for performance checks.

Headset acceptance: left/right controllers and hands, slider drag beyond bounds,
long lists, open/close from every tab, underlying-screen click protection,
model/reconnect coalescing, standby recovery and unchanged defaults. Compare
layer counts before/after. Verify ambient appearance and scrolling feel with
short user tests. Test high bitrate separately on supported codecs, Quest 2/3/3S,
Wi-Fi/USB and both ordinary compatible hosts and bundled Vibepollo.

## Combined user test when time permits

1. Open sliders and choice popups from ordinary Settings and PCVR. Check
   selecting a value, Cancel, outside dismissal and dragging long lists.
2. Confirm ambient preview/Cancel and the 100% default. Check one model change
   and one stream-setting change; no repeated intermediate reloads should occur.
3. Under Settings → Input enable Grip Scroll, with Mapping off. Point at a
   desktop/browser and hold the pointing controller's grip while moving up/down.
   Check both primary hands, a curved screen and a secondary screen. Release
   before clicking. Turning Grip Scroll off restores screen right-click.
4. During a gesture leave the screen, open a menu, change tabs, disconnect or
   remove/re-wear the headset. No scroll/click should remain stuck; the grip
   must be released before another gesture starts.
5. Try higher manual desktop bitrates incrementally on the chosen codec and
   connection. Compare actual received rate, latency and dropped frames; a
   host-side max_bitrate or network/decoder limit may prevent the requested rate.
   Auto should look and behave as before. PCVR bitrate is a separate setting.

Desk checks do not establish controller feel or sustained 300–500 Mbps
streaming. Grip Scroll remains Off for the later manual test; no stream was
started during its UI verification.

## Slider and codec feedback checkpoint (2026-11-13)

- Desktop and XR codec/bitrate profiles are independent and remember manual
  bitrate per codec. H.264: 5–150 Mbps; H.264+: 5–500; HEVC/AV1: 5–200.
  XR has an 8 Mbps minimum. These are selectable ranges, not throughput promises.
- H.264+ maps to ordinary H.264 on the wire. Desktop AV1 is capability-filtered;
  XR currently offers H.264, H.264+ and HEVC only because its projection pipeline
  does not implement AV1. Changing the XR wire codec applies next session.
- XR bitrate remains live when the selected codec matches the running session;
  pending codec changes mark bitrate as requiring restart too. Portable runtime
  helpers and host validation were rebuilt for the new 500 Mbps ceiling.
- All popups omit Cancel and size to their content. Click outside to dismiss;
  sliders retain Apply and Auto/Default where appropriate.
- Sliders: passthrough fade 0–100%; volume 0–24 dB; separation 50–100%
  (default 75%); convergence 30–70% (default 50%); brightness −20–20%;
  contrast/gamma 50–150%. Existing defaults are preserved.
- Default Res lists actual dimensions. User confirmed it applies per monitor,
  preserving packed multi-monitor layout; old percentage saves remain readable.
- XR resolution is continuous within the current standard/extended bounds.
- Hiding the desktop in XR suspends presentation, not its connection/decoder.
  Concurrent streams still share headset decode, memory and network resources.
- Validation: 206 Rust tests passed (19 ignored), all 66 GDScript scripts passed,
  and the rebuilt portable XR bundle/AppImage passed their static ELF audits.
  Headset slider comfort and sustained high-bitrate playback remain user tests.

## XR launch investigation (2026-11-13)

User reported Moss, Alyx and VRChat failing to enter VR under both launch modes.
Recorded Moss/VRChat per-game sessions show xrizer failing to find the runtime
socket. The host received tracking, but no application began a session.
A real Steam-container CPU probe reproduced `XDG_RUNTIME_DIR` being rewritten
from the private supervisor directory to `/run/user/1000`.

Fixed the owned Steam launch path to expose the private IPC directory and
restore runtime/socket selection after Steam's `_v2-entry-point` container
setup. Native app argv and game arguments remain unchanged. Added launcher
regression tests and an optional real Steam sandbox path to the existing sample.
Validation: native installed runtime 66 encoded frames; repaired Steam sandbox
63 encoded frames; 12 launcher unit tests passed. No headset worn or real game
required. Evidence: `build/verify/xr-startup-investigation/findings.json`.

Real-game acceptance and full experimental automatic handoff remain pending.
The desk-driven automatic headset test lost bridge responsiveness after desktop
connection; Nightfall was stopped and normal sleep restored. No unattended
stream or game was left running, and Steam launch settings were not changed.

## Popup height feedback (2026-11-14)

Increased choice targets from 64 to 96 pixels and size the scroll area from the
actual themed grid, capped to the available menu height. Short lists show all
options; long lists keep usable rows and scroll without extending off-panel.
Slider popups have a 320-pixel minimum height and an 80-pixel slider target.
Regression checks cover 3, 7 and 24 choices within a 1200×580 menu.

Grip scrolling was saved Off on the test headset; Mapping was also Off. No
input-policy change was needed. Enable Gear → Input → Grip Scroll, close the
settings menu, point at a scrollable page, hold the side grip and translate the
pointing hand vertically without the trigger. It is controller-only and replaces
right-click while enabled; a held grip cannot rearm after cancellation until
released. The real raycast-routing regression still passes.
