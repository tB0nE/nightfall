# TakeyaSaito PR integration review — 2026-11-15

Integration branch: `codex/takeya-hardware-pr-review`, based on the current
`codex/virtual-monitor-transition-speed` checkout (including its newer unified
screen/tab work), rather than dropping that work by branching from main.
Main is unchanged. No PR has been merged on GitHub or pushed by this review.

## Imported PR heads

| PR | Head | Scope |
| --- | --- | --- |
| [83](https://github.com/tB0nE/nightfall/pull/83) | d21b267bf9a22395e052cb43352ccfd071e51f0f | Linux ARM64 builds, V4L2 decoding, pairing/app-list fixes, composition geometry, SteamVR hand ownership |
| [84](https://github.com/tB0nE/nightfall/pull/84) | 0edbd3c9402759ba8f7cba945e779867a4d7a279 | Experimental duplicate-path video/audio reception and Meteor fan-out |
| [85](https://github.com/tB0nE/nightfall/pull/85) | 5019e999707f160abccc77cb41f7a4ef69cbe74f | Frame controller bindings/motion, gamepad-mode pointer behavior, toast overlay |
| [86](https://github.com/tB0nE/nightfall/pull/86) | 18637c97abeb91f6a408694786994c416b20113b | App cover picker and remembered app per host |

These PRs do not change Meteor's AMD inference models or GPU-selection logic.
Steam Frame support primarily targets its Linux/Qualcomm client. General Linux
build/decoding and networking changes still warrant desktop regression tests.

## Findings identified in review (both subsequently fixed)

1. **P2 — Secondary paths are not revalidated against their session token.**
   `meteor/src/proxy.rs:252–259`: an address already in `owner_of_extra` is
   refreshed and swallowed before checking the new packet's payload. If that
   address/port is reused for a new session while the old upstream flow remains
   alive (up to its 30-second idle timeout), new-session pings stay attached to
   the old flow. Even a non-ping refreshes this association. Require a valid
   ping matching the owner's current token; detach/reclassify on a changed
   token. Add reconnect/token-change tests. The existing tests cover successful
   duplication and quiet paths, not this case.

2. **P2 — Audio/video multipath receivers share an unsynchronized C variable.**
   `addons/nightfall-stream/vcpkg-overlay/moonlight-common-c/0004-multipath-second-path.patch:92,111`:
   `recvUdpSocketMultipath()` has a function-static `first` and modifies it from
   both receive threads. This is a C data race when both secondary sockets are
   active. Move fairness state into each stream or use thread-local/atomic
   state. With the environment variable unset the function returns before
   touching it, so ordinary single-path clients do not trigger this race.

Additional multipath hardening is already acknowledged upstream: client opt-in
is an environment variable, but the server accepts matching-payload secondary
addresses automatically, without a subnet restriction or explicit server opt-in.
Keep this experimental; the client variable does not gate Meteor's relay logic.
The added `MSG_DONTWAIT` call also deserves a Windows-native-client compile
check if that C overlay is ever built there; Windows Meteor itself does not use
this client receiver and was not tested in this review.

## Shared behavior requiring headset acceptance

- **Gamepad mode now disables screen pointing, hover and grabbing** while a
  desktop stream is active, unless Nightfall settings or keyboard are open.
  This intentionally affects Quest too. Both-stick toggling must still work;
  a welcome screen must retain its cursor after disconnecting.
- **Toast uses another composition layer while visible.** Test it with four
  screens and with AI 3D/passthrough. No budget-aware suppression was added;
  do not infer layer-budget safety from GDScript unit tests. The toast renders
  continuously for its short visible lifetime and disables its viewport after.
- **Cylinder padding changes are shared**, not Frame-only. Verify pointer
  alignment at both edges of a curved screen with bezel on/off, including crop,
  multiple screens, AI 3D and after changing primary screen.
- **App picker changes the welcome layout for everyone.** Verify covers,
  selection, host switching, remembered apps and server disappearance. New
  toast text is hardcoded English; the app picker adds locale entries.
- V4L2 is tried first only on Linux; Android MediaCodec candidate selection is
  unchanged. The FFmpeg overlay is a new native dependency build input, so
  existing native binaries alone do not validate it.

## Integration resolutions

- Kept our per-tab region and selected-at depth freshness checks, combining
  them with multipath's same-client check rather than replacing them.
- Kept grip-scroll cancellation in the controller-mode pointer guard.
- Rebuilt all four CJK subsets from the combined locale dictionaries; choosing
  either side's binary fonts would lose characters from the other branch.
- Restored the earlier uncommitted clipboard/browser-editing work. Retained
  browser-only right-click support and the relocated once-per-frame controller
  toggle. Clipboard changes remain uncommitted, with the original named stash
  retained as a backup.

## Verification

- All **76 GDScript test scripts passed**, including the restored clipboard
  tests: `/tmp/nf-pr-review-gdtests.log`.
- Meteor `cargo test --no-default-features`: **211 passed, 19 ignored**, no
  failures: `/tmp/nf-pr-review-rust-tests.log`.
- Generated Godot 4.7's actual default OpenXR action map and compared bindings
  semantically: generic, Quest Touch, Pico 4 and EXT hand interaction are
  identical. The only extra profile is Valve Frame. This validates binding
  definitions, not actual tracking or input feel.
- Isolated headless app-picker check passed: 25 apps, three pages, selection,
  remembered ID restoration after reordering, and navigation within 1920×1080.
  `/tmp/nf-pr-picker-test.log`.
- `git diff --check` passed.
- No gamescope/Vulkan UI test was run, to avoid the known desktop-reset issue.
- Steam Frame, AMD hardware decoding and real two-network-path streaming
  still need contributor hardware acceptance. See subsequent build below.

## Short manual checklist after a fresh optimized build

1. Connect/disconnect/reconnect; pick a host app and verify it is remembered.
2. Curve the stream, check pointer/host cursor alignment at both edges, toggle
   bezel/crop and test two monitors plus a browser.
3. Toggle Quest controller mode on/off with both sticks; test triggers, settings,
   keyboard, then disconnect and confirm the welcome pointer works.
4. With four screens, show the controller-mode toast and check for blackouts.
5. Contributor hardware: Frame buttons/gyro, V4L2 decode, dual-link reconnect and
   loss of either network path. Modern AMD hardware needs its own acceptance.

## Subsequent development deployment

On request, built the optimized DEV APK and Linux Meteor AppImage with all four
PRs. Refreshed vcpkg dependencies (the old Android cache had manifest installs
disabled), linked/stripped the Release native addon and confirmed the multipath
string in the packaged native-library input. Normal native-XR build checks ran.
Installed the APK in place and restarted Meteor from the new extracted AppImage,
preserving its environment, saved ports, configuration and pairings. Bundled
host `/serverinfo` responds HTTP 200 on port 49989. Meteor loaded EdgePad Vulkan
and cached TensorRT VDA on the RTX 3090.

Artifacts:
- `Nightfall-Android-arm64-v8a-dev.apk`
- `meteor/target/appimage/Nightfall-Meteor-0.9.1-preview.1-takeya-review-x86_64.AppImage`
- Running extraction after fixes: `.build-cache/takeya-pr-review-multipath-fixed/squashfs-root`
- Build logs: `/tmp/nf-takeya-native-configure.log`,
  `/tmp/nf-takeya-android-native.log`, `/tmp/nf-takeya-apk-build.log`,
  `/tmp/nf-takeya-meteor-build.log`
- Runtime log: `/tmp/nf-takeya-meteor-runtime.log`

Multipath remains opt-in on the client. The initial build preserved the review findings; the follow-up below fixes
them. Branch and clipboard changes remain local.

## Multipath fixes

Both findings were reproduced by failing regression tests before changing the
implementation:

- A known secondary path now refreshes only on a valid ping matching its
  owner's current session token. A changed token detaches and reclassifies the
  address immediately. A primary-token change also removes its old token
  mappings, revokes old secondary paths and clears their depth/mic association.
  Non-ping datagrams cannot keep a secondary path alive.
- Receive-order fairness state uses C11 thread-local storage, so audio and video
  receive threads never read/write the same variable. The dependency revision
  is bumped to `moonlight-common-c` port-version 2 to invalidate old binaries.

Validation: Meteor suite **214 passed, 19 ignored**, including three new UDP
regressions (secondary reconnect, owner-token rotation/authorization, malformed
keepalive expiry). `/usr/bin/python3 test/test_multipath_receiver.py` compiles
and exercises the actual patched C receiver with two interleaved threads and a
single-path fallback. It fails against the old function-static implementation
and passes with the fix. No GPU or headset is needed for that test.

Logs: `/tmp/nf-multipath-before.log`, `/tmp/nf-multipath-after.log`,
`/tmp/nf-multipath-c-before.log`. Fresh optimized builds are generated using the
same artifact names as the initial integration deployment.

Corrected optimized APK installed; corrected Meteor AppImage built and restarted.
Bundled host health check remains HTTP 200 on port 49989. Fix deployment evidence:
`build/verify/takeya-pr-review/multipath-fixes.json`.

## PR #87 — optional AMD MIGraphX VDA (2026-11-16)

Merged head `40848353b6e3345ed8db5a5f397d1b027adf31f1` locally in merge commit
`6af15be`, retaining all uncommitted clipboard changes and multipath fixes.
Unlike PRs #83–86, this one directly adds AMD inference support.

- Optional Linux-only HIP/MIGraphX native runtime, with dynamic ROCm loading,
  device-name selection, first-use compilation/cache and GPU graph replay.
- Shared Vulkan VDA wrapper now supports both backends; preprocessing overlap
  changes only for MIGraphX. Existing Vulkan serialization is retained.
- The backend needs folded ONNX graphs, not the existing Vulkan ncnn graphs.
- Local tests: **216 passed, 19 ignored** with `cargo test --no-default-features`;
  native multipath receiver regression still passes. Log `/tmp/nf-pr87-tests.log`.
- ROCm headers are absent here, so the optional C++ backend was not compiled or
  executed. Tests do not establish AMD performance or compatibility.

Distribution remains incomplete: the existing AppImage builder only builds and
copies `libmeteor_vda_vulkan.so`, not `libmeteor_vda_migraphx.so`, and its build
container does not provide the required ROCm headers. The PR's new model catalog
entries also require six matching assets on the model release. Validate the
folded outputs/checksums before publishing; no model release assets were uploaded
as part of this integration. Building on a ROCm-equipped development machine is
not sufficient to make our current AppImage expose this backend.

PR #87 changes Meteor only; a new APK is unnecessary for this PR.

Fresh optimized Meteor AppImage built and restarted on 2026-11-16 from
`.build-cache/takeya-pr87-review/squashfs-root`. Bundled host HTTP 200 on the
saved port 49989; EdgePad Vulkan and TensorRT VDA initialized on RTX 3090.
ROCm/MIGraphX runtime is absent in this non-ROCm build, as expected.
Build log `/tmp/nf-pr87-meteor-build.log`; runtime log
`/tmp/nf-pr87-meteor-runtime.log`. Installed APK is unchanged.

## Controller notification layer removed — 2026-11-16

Replaced CompositionToast's quad/viewport with a timed message in the primary
screen's existing stats-overlay texture. Native and legacy mono/stereo paths
share the same pixels; stats remain available above the notification. The
shared texture is now 768x640 (the original stats area remains 768x512), and the
native renderer draws it into its existing eye swapchain. No notification XR
layer or swapchain is allocated. Overlay targets follow primary-screen changes.

All 77 GDScript scripts passed, including notification expiry, no extra layer,
primary transfer, stats coexistence and native visibility when stats are off.
Native XR and streaming libraries rebuilt, optimized DEV APK built and installed
in place. Logs: `/tmp/nf-screen-toast-tests.log`,
`/tmp/nf-screen-toast-apk.log`, `/tmp/nf-screen-toast-quest.log`.
The earlier warning about the toast consuming another layer is now resolved;
the existing persistent/shrunk pointer-layer accounting still deserves separate
attention. This change does not claim to solve that wider layer-budget issue.

### Notification appearance correction

Restored the original 1100x140 rounded notification design: 28px corners, purple
3px border, 40px light text and translucent dark background. The atlas is now
1100x656: stats occupy 768x512 at the top, message occupies 1100x140 at y=516.
Legacy screen viewports sample separate AtlasTexture regions. Native rendering
samples the same two regions into the existing eye swapchain: stats top-left,
notification centred. Notification width is 55% of the primary screen width;
mono/stereo eye placement agrees. No additional XR layer or viewport.

An actual OpenGL screenshot exposed initial PanelContainer autowrap growing the
panel to 2863 pixels tall and placing its text outside the captured strip. After
text layout settles, explicitly restore the panel's intended size and refresh
its texture; stale revisions are ignored. Verified a centred, bordered message
with visible wrapped text in `build/verify/screen-toast-centred/notification.png`.
All 77 GDScript tests pass, including actual label containment after layout.
Optimized build passed after clearing two obsolete test AppImage extractions
following a temporary disk-space failure. Screenshot check used direct OpenGL,
not gamescope/Vulkan; no XR session was started on this PC.

Follow-up: controller-enable hint now lasts 2.5 seconds. Enlarged the message
strip to 1100x184 with a 4px transparent inset around its panel and extra atlas
padding below (1100x704 total). Native sampling and legacy AtlasTexture regions
match, leaving the complete bottom rounded border inside the sampled area.
Targeted timeout/layout assertions pass; rendered screenshot inspected with the
complete border visible. No additional layer or viewport.

## SBS notification and server picker — 2026-11-16

SBS grab-bar/controller shortcut remains a quick Off/On toggle, restoring the
menu-selected Stretch or Crop mode. Replaced session-global last-mode state with
per-host `sbs_last_mode`, persisted even when SBS is Off; legacy configs default
to their active SBS mode or Stretch. The shortcut now displays SBS: Off/Stretch/
Crop using the existing centred 2.5-second notification. Menu selection still
chooses the mode without cycling it through the quick shortcut.

Server selection now uses four-column, eight-card pages, with PC icons, names,
addresses/custom HTTPS ports, selected-server border and USB indicator. Network
discovery feeds the same paged grid, deduplicated by address and service port.
Saved-host selection, identity-aware discovered pairing, scan, manual add, clear
saved servers and Back retain their established actions. All controls render
inside the welcome viewport; no additional XR layers.

Validation: all 79 GDScript scripts passed, including SBS mode round-trip/host
isolation/notification and server paging, custom ports, selection, discovery and
bounds. Direct OpenGL render inspected at 1920x1080 (no gamescope/Vulkan).
Artifacts: `build/verify/server-picker-sbs/server-picker.png`;
logs `/tmp/nf-server-sbs-suite.log`, `/tmp/nf-server-sbs-apk.log`.

## Right system button / Start investigation

User reports Horizon opens instead of sending gamepad Start. Verified current
and pre-PR Touch profiles both map right `/input/system/click` to `menu_button`,
and the mapper still maps it to 0x0010. No mapping change or confirmed OS
regression is inferred from this alone. Meta documents this system input as
potentially unavailable to applications.

Optimized DEV diagnostics added (mapping unchanged): XRController button signal
edges for menu/select plus A and stick click as positive controls, OpenXR session
focus/visibility transitions, Android application pause/focus transitions, and
Start/Back routing into desktop/browser gamepads. All entries use `[PAD-SYSTEM]`
and monotonic timestamps. Logs contain input names/states only, no content.
All 79 GDScript tests pass. Installed diagnostic build; awaiting one physical
sequence: stream + gamepad mode, A, Meta, return to Nightfall, A, Download Log.
This distinguishes a delivered edge lost before polling from a system-reserved
input never delivered by OpenXR. No replacement Start gesture selected yet.

### Physical button test result

Export `Nightfall-diagnostics-20261116-131915.txt`, current diagnostic session:
- 13:18:57, t=17629/18004: right A pressed/released while PAD-HAND is active.
- 13:18:59, t=20010: OpenXR falls to session_visible; right menu/select are
  both false and no Start bit was forwarded. No right menu/select press edge
  appears in the action-signal log.
- 13:19:03, t=23714: session_focussed resumes; both actions remain false.
- 13:19:12: both stick-click edges arrive and deactivate controller mode,
  confirming action delivery after returning to Nightfall.

Conclusion: in this test the system press was not delivered to Nightfall's
OpenXR actions; it was not a delivered Start dropped by the mapper. Horizon
opened its system UI. We cannot infer which OS update changed the behavior or
claim it never worked before. No mapping change can forward an undelivered
button; a usable alternative Start binding requires a separate UI/design choice.
The full private export was read from /tmp, not added to tracked documentation.

### Alternate left Menu and controller-mode guide

Quest left Menu now sends Start normally and Select/Back while the left
controller's configured Tilt or Head alternate mapping is active, in both
PAD-HAND and PAD-ABXY. With alternates disabled it remains Start.
Steam Frame keeps its dedicated left View/Back and right Menu/Start bindings;
both grips toggle controller mode, rather than the Quest's two stick clicks.

The enable notification now explains the configured gesture, normal/alternate
face-button mappings, left Menu mapping, and exit gesture. It retains the
requested 2.5-second duration and uses the existing primary-screen overlay,
without adding an XR layer. The shared atlas is now 1100x960; native rendering
selects only the visible compact or expanded message region and skips it
entirely when no message is shown.

Validation: all 80 GDScript test scripts passed, including the new alternate
Menu and mode-specific guide tests. A bounded OpenGL visual check confirmed
the expanded Head/PAD-HAND guide fits within its styled panel. The optimized
Android DEV export succeeded; git diff --check passed. Steam Frame behavior
was checked in code, not on physical Frame hardware.

### Persistent gamepad guide trial

The enable guide now stays visible until a fresh controller button/trigger/grip
press. Opening controls must first be released; the dismissal input is consumed
until release so it does not also operate the streamed game. Other notifications
remain timed. Quest left Menu now sends Select/Back normally and Start with the
alternate mapping. Tilt activation retains its original direction on both
controllers; Head activation distance remains unchanged. The initial reversal
of Tilt was a misunderstanding and has been reverted at the user's request.
Steam Frame retains its dedicated View/Menu bindings.

Validation: all 80 GDScript scripts passed, including opening-button hold,
release-to-arm, dismiss, and held-dismissal consumption checks. The seven-line
mapping guide was visually checked in a bounded OpenGL run; its 34 px text fits
the existing expanded panel without allocating another XR layer.


## Checkpoint — 2026-11-16

User accepted the corrected controller mappings and requested committing all
pending work. Current behavior: original Tilt/Head activation, left Menu Select
normally / Start with alternate mapping, persistent press-to-continue guide,
shared notification overlay (no extra XR layer), SBS remembered mode, paged
server picker, and transparent local Desktop artwork. Latest optimized APK is
installed. The controller guide and Desktop cover checks passed; the full
80-script suite passed before the final isolated tilt-direction correction,
and its targeted controller regression passed after that correction.

Outstanding:
- Clipboard foreground end-to-end acceptance (browser/desktop, physical and
  virtual keyboards, Unicode/multiline), X11 and Wayland; Windows/macOS separate.
  Publish the companion host build and update its download pin before release.
- Contributor acceptance: Steam Frame bindings/motion/V4L2, real multipath with
  link loss/reconnect, modern AMD MIGraphX inference. These cannot be established
  from Quest/NVIDIA tests.
- MIGraphX distribution: native library/ROCm packaging and six verified folded
  model release assets. Current AppImage lacks this optional runtime.
- General regression checks: curved-screen edge alignment with crop/bezel/AI3D,
  multiple screens, primary changes; server discovery/remembered apps across
  hosts. Four-screen overlay budget acceptance remains useful, although this
  notification itself no longer allocates a layer.
- Push the checkpoint and prepare the integration PR when requested. No release
  assets or download pins were changed in this checkpoint.
