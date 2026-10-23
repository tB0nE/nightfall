# Standalone Nightfall browser

Date: 2026-10-15
Branch: `feat/unified-content-tabs`
Baseline: `0db1d66` — standalone browser, on-headset AI 3D and fullscreen video.
Status: implementation plan; features below are not implemented unless explicitly noted.

## Goal and scope

Make one browser on the primary screen useful without a PC before attempting
concurrent PC streaming, multiple physical screens or multiple browser tabs.
Users should be able to browse, watch video, save favourite sites and optionally
block ads, with the existing on-headset AI 3D and screen controls.

This phase takes priority over the next multi-screen steps in
[Unified screens and content tabs](unified-content-tabs.md). Retain that
architecture, but do not use this work to expand screen creation or concurrency.
Keep the old monitor counts, presets and layout controls in Screens intact.

Quest 3 is the first validation target. Quest 2 compatibility is a later test
gate, not an excuse to introduce Quest-3-only assumptions into ordinary UI code.
Linux browser support is outside this phase.

## What already works

- Android system WebView in an app-owned VirtualDisplay/Presentation, captured
  through SurfaceTexture/OES rather than per-frame screenshots.
- User-driven opening without a PC, pointer input, virtual keyboard, basic
  navigation and closing back to the welcome screen.
- Browser inference uses its own capture uploader and the existing on-device
  depth engine. Native XR presentation supplies the production 3D warp and
  Final Depth Map view. Meteor does not generate browser depth.
- YouTube video playback and browser AI 3D were confirmed by the user.
- Fullscreen custom-video-view handling, inactive-depth corrections and a
  three-process-frame close handoff have been added. The user subsequently
  reported that the build was working pretty well and approved the commit.
  Explicit repeated-close, fullscreen and standby stress testing is still needed.
- The browser remains a prototype: it opens a local test page, has minimal
  controls, and does not yet offer a complete browser settings/privacy surface.

## Architecture and non-negotiable constraints

- Keep the current WebView engine for this phase. It is not Horizon Browser
  embedded in Nightfall, and does not provide Chrome's extension installer.
- Keep navigation, video and browser-owned UI inside the existing captured
  surface. Do not launch an external browser or Android Activity for ordinary
  navigation/fullscreen: that would escape Nightfall's AI and input path.
- Retain the provider/source boundary. Do not pretend a PC session is active
  to unlock browser features. Browser input must never reach a host.
- One physical primary screen, one live browser page and one AI owner.
  Existing `ScreenContentTabs` registration remains a foundation, not a promise
  of functional browser tabs in this milestone.
- Android view work stays on the UI thread; GL work stays on its owning render
  thread. Generation-check callbacks, cancel held input and discard stale work
  during close/reopen, renderer loss and source changes.
- Preserve native/GLES teardown safeguards. Do not shorten the model-switch
  cooldown or replace the current close handoff merely to make navigation faster.
- Use existing surfaces for controls; do not spend additional XR layers on
  individual browser buttons or prompts.
- Protected video is a separate capability. Do not bypass DRM or promise AI 3D
  when a service prevents readable frame capture.

## Stage 1 — establish a reliable browser lifecycle

1. Exercise opening/closing from both the in-browser control and Screens.
   Check repeated close, rapid clicks, close during page load/fullscreen/model
   initialization, and starting a PC connection during the delayed close.
2. Verify standby/resume with video and AI on/off. Default to pausing/muting
   when the app is suspended; explicitly validate WebView/video audio behavior
   rather than assuming `onPause()` stops every form of playback.
3. Recover from renderer death, missing WebView provider and first-frame timeout
   with an understandable error and a usable welcome screen. Offer explicit Retry.
4. Keep lifecycle diagnostics: provider version, source generation, open/close,
   fullscreen transitions, capture/inference status and renderer failures.
   Exclude URLs, query strings, page contents, cookies and typed credentials.
5. Record an optimized-build baseline: app FPS, depth updates/inference time,
   capture/warp cost, CPU/GPU load where available and memory during a long video.
   Test with AI off/on and representative models. Establish regression limits
   from measurements rather than inventing a target before the baseline exists.

Gate: repeated close and standby recover without a crash, stuck sound, black
screen or stranded input. Preserve ordinary PC streaming after browser closure.

## Stage 2 — navigation and a real start page

- Replace the GPU test page with a local Nightfall start page. No automatic
  external requests until the user navigates; opening the app still does not
  automatically open the browser.
- Provide Back, Forward, Reload/Stop, Home, address/search entry and a compact
  overflow/settings menu. Reflect navigation/loading state and page title.
- Show the current origin/address honestly; do not imply that an HTTPS icon
  certifies a trustworthy site. Never bypass certificate errors.
- Treat entered HTTP(S) URLs as navigation and other text as a search using a
  documented/configurable search provider. URL-encode queries and reject
  unsupported schemes. Treat external-app links separately and require consent.
- Keep controls comfortable for XR pointers, hands and the virtual keyboard.
  Improve smooth scrolling, text selection, Enter/submit, focus transfer and
  cancellation of held keys; preserve clipboard support only through explicit
  user actions, with no automatic clipboard inspection.
- Add desktop/mobile site mode and bounded zoom/text scaling. Reload only when
  needed, make mode visible, and do not advertise user-agent changes as guaranteed
  service compatibility. Allow per-site preferences if persistence is ready.
- Keep the existing fullscreen-video capture path. Provide a discoverable way
  to exit even if a site's controls fail: retain Escape and add a Nightfall-owned
  exit action in existing UI, without permanently covering the video.
- Handle target-blank links/popups deliberately. For now use the same page for
  approved user-initiated links; reject unsolicited popups. Sites that require
  separate login windows need a scoped, tested flow—not a hidden second browser.

Gate: navigate, search, scroll, type, reload, enter/exit fullscreen and recover
from failed navigation entirely within Nightfall.

## Stage 3 — bookmarks, shortcuts and history

- Add/remove/edit bookmarks with a user-chosen label and URL. Show saved shortcuts
  on Home, with optional starter suggestions such as YouTube and Xbox Cloud Gaming.
- Support reorder and confirmation/undo for destructive actions; avoid duplicate
  entries and validate stored URLs on load.
- Add bounded local history, a clear-history action and a save-history preference.
  No telemetry upload or diagnostic export of browsing history.
- Use versioned app-private storage, atomic writes and graceful corrupt-file
  recovery. Keep browser preferences separate from per-host stream settings.
- Do not persist credentials, authorization headers or tokens in bookmarks/history.
  Strip sensitive transient data where possible; warn against saving token-bearing
  links. Let WebView manage cookies rather than copying them into workspace files.
- Default to Home on browser open. Last-page restoration, if offered, is opt-in
  and does not silently restart video or a cloud-gaming session.

Gate: bookmarks/settings survive restart and can be edited/cleared without
affecting host pairings or existing monitor presets.

## Stage 4 — optional ad and tracker blocking

Implement the requested install/remove-like experience as an optional blocker
module with Enable/Disable, rather than pretending to install Chrome extensions.

1. Evaluate maintained WebView-compatible blocking engines, including
   [Adblock Plus's Android integration](https://github.com/adblockplus/libadblockplus-android).
   Review actual maintenance, license compatibility, transitive dependencies,
   native ABI support, APK size, CPU/memory cost and our GPU/fullscreen integration
   before choosing a library. Do not replace WebView blindly with a wrapper.
2. Prefer a reusable engine and established filter syntax/lists over a homemade
   URL-substring blocker. Support request filtering and cosmetic page rules where
   the chosen engine permits them. Check service-worker requests, redirects and
   streaming-media behavior explicitly; interception alone is not complete coverage.
3. Provide global On/Off, a per-site exception, filter-update status and reset.
   Disable means no filtering, not just hiding an indicator. If a native engine
   ships in the APK, explain that disabling does not uninstall its binary.
4. Cache compiled rules off the rendering/UI hot path. Use bounded HTTPS updates,
   validate downloaded data, retain last-known-good rules and avoid arbitrary
   remote executable scripts. Browsing should remain usable if updates fail.
5. Clearly document any acceptable-ads policy, list sources and defaults. No paid
   whitelisting or silent exceptions. Start with a small, documented list set.
6. Test smaller ad-heavy sites, redirects, video playback and login with blocking
   on/off. Provide an obvious “disable for this site” escape hatch for broken pages.
   Never log a user's browsing destinations to count blocked requests.

Gate: measurable blocking on representative third-party sites, working exceptions,
no material video/AI regression and a reviewed dependency/license choice.
YouTube video-ad removal and arbitrary browser-extension support are not goals.

## Stage 5 — privacy, site permissions and session controls

- Expose clear cookies/site storage/cache/history with accurate descriptions and
  confirmation. Explain when clearing is global rather than truly per-site.
- Keep login persistence as an explicit user-visible behavior. Test first-party
  cookies and only enable third-party cookies when a justified compatibility need
  is understood; do not weaken the global default to fix one site silently.
- Request microphone/camera/geolocation only from a user-initiated, trusted origin
  flow, with visible origin and specific resource. Default-deny unsupported
  requests. Android permission consent and WebView origin consent are separate.
- Microphone support includes capture, mute indication and lifecycle testing;
  never grant every resource in a WebView permission callback automatically.
- Treat JavaScript dialogs, file pickers and browser permission prompts as XR UI
  work: system dialogs on the private virtual display may not be usable directly.
- Investigate private sessions separately. A new WebView alone is not cookie/storage
  isolation. Do not label a mode “private” until the chosen provider supports tested
  isolation, or a documented safe process/profile design has been implemented.
  Do not clear ordinary-session cookies behind the user's back to simulate it.
- Retain HTTP(S)-only navigation, disabled unrestricted file/content access, no
  general-purpose JavaScript-to-native bridge and no automatic external intents.
- Display WebView version/provider information for support and establish a Quest
  engine-update/security policy. WebView follows its provider, not Chrome's UI.

Gate: prompts are usable in XR, denial is safe, stored data can be cleared, and
privacy claims match actual storage behavior.

## Stage 6 — downloads and uploads

- Offer explicit download confirmation, progress, cancellation and completion/
  failure status. Prefer Android's supported Downloads/MediaStore or download
  manager APIs rather than broad filesystem permissions.
- Handle filenames, MIME types, redirects, size limits, collisions and authenticated
  downloads carefully. Do not log cookies or signed download URLs. Reject unsafe
  schemes and never auto-open/install downloaded executables or APKs.
- Add a constrained, user-driven upload/file chooser only after checking how it
  appears in XR. Restrict URI grants to selected files and their required lifetime.
- Clarify initial limitations for blob/data URLs, protected downloads and services
  that require unsupported browser functionality. Do not promise a universal downloader.

Gate: a normal file downloads to an accessible location and one selected file
can be uploaded without granting a site arbitrary filesystem access.

## Stage 7 — free Xbox Cloud Gaming compatibility spike

No subscription purchase is required for the initial test:
[Fortnite's official Xbox Cloud Gaming instructions](https://www.fortnite.com/mobile/xbox-cloud-gaming)
describe free play using a Microsoft account at [xbox.com/play](https://www.xbox.com/play).
Region, service availability and queues still apply; embedded WebView support
is not guaranteed by support for ordinary Chrome/Edge.

1. Start with a Bluetooth/USB gamepad paired to the headset. Confirm login,
   navigation and session launch before changing AI or inference settings.
2. Check whether the installed WebView exposes a functioning web Gamepad API.
   Route required Android key and generic-motion events to the focused browser
   presentation without also sending them to Nightfall's host input path.
   Event injection alone does not prove that web Gamepad API support exists.
3. Define ownership of system/menu buttons and release held buttons/axes when
   focus changes, the page closes or a controller disconnects. Keep web gamepad
   delivery separate from controller-as-pointer input to prevent double actions.
4. Test Fortnite video, audio, fullscreen, buttons/triggers/sticks, latency and
   resume with AI off first; then enable AI and Final Depth Map to check capture,
   responsiveness and model cost. Watch audio/video sync and thermal behavior.
5. Classify failures: unsupported-browser checks, login/cookie flow, missing
   Gamepad API, codecs/WebRTC, secure video capture or input routing. Keep useful
   sanitized diagnostics rather than treating all failures as an inference bug.
6. Touch controls can help check streaming if offered, but do not establish gamepad
   compatibility. Quest motion-controller emulation and microphone/game chat are
   separate follow-ups, not prerequisites for this first test.

Gate: either demonstrate a playable free session with a real controller and AI,
or document the concrete blocker and a bounded next experiment. Do not recommend
buying a subscription to investigate an unproven compatibility path.

## Validation and handoff

- Automated: URL/search handling, settings/bookmark storage, blocker exceptions,
  provider generations, close/reopen, input release and navigation state. Retain
  current native GLES dispatch and primary-source regression tests.
- Android integration: fullscreen enter/exit, file/permission callbacks, renderer
  failure and gamepad event ownership. Use controlled pages where possible.
- Headset: ordinary pages, a third-party ad-heavy site, YouTube, unprotected video,
  Microsoft login and Fortnite; repeat with AI off/on and across standby.
- Exercise controller and hand pointer input, virtual keyboard, menus and screen
  grab/resize. Confirm the old monitor menu and normal PC streaming still work
  after the browser is closed, not concurrently.
- Use optimized release-signed DEV builds for all performance conclusions. Record
  device/provider versions, workload and AI model/cap instead of anecdotal FPS alone.
- Ship small testable commits. Do not call protected-service, private-session or
  cloud-game compatibility complete based only on a page loading.

## Recommended delivery order

1. Lifecycle stress gate, then navigation/fullscreen polish.
2. Home, bookmarks/shortcuts, settings and history.
3. Free Fortnite compatibility probe; identify engine/input blockers early.
4. Ad-blocking dependency decision and optional blocker UI.
5. Privacy/site permissions, then downloads/uploads; private mode only after isolation proof.
6. Long-session performance/security review and a standalone-browser release gate.

After this gate, return to the unified-content plan for actual tabs, hidden-page
pause/audio policy, extra screens and concurrent browser/PC presentation. None
of those should hold up a useful single-browser experience.

## Implementation checkpoint — navigation slice, 2026-10-15

- Replaced the GPU test page with local Home content and YouTube/Xbox links.
  No external page is automatically fetched merely by showing Home.
- Added Back/Forward enabled state, Reload/Stop, Home, Go/Enter navigation,
  current address, page title and loading progress. Address editing is not
  overwritten while it has focus. Search is explicitly labelled DuckDuckGo.
- Extracted pure Java URL/search policy: HTTP(S) URLs and bare hostnames,
  localhost/ports, encoded search queries, rejection of unsupported schemes,
  credential-bearing URLs and malformed explicit addresses. No destination
  or search text is written to diagnostics.
- Added a fading fullscreen Exit button inside the existing surface. It appears
  initially for four seconds and is revealed again by pointing at the top edge;
  Escape and site video controls still work. No extra XR layer is allocated.
- Added host-JDK policy tests, runnable with
  `bash test/run_browser_navigation_tests.sh` (JDK 17); full Android UI behavior
  still requires headset testing. Retained the existing close/source/GLES tests.
- Next headset gate: address/search and virtual-keyboard Enter, Back/Forward,
  Home, Reload/Stop, fullscreen exit, repeated close/reopen and AI/Depth Map.
  Bookmarks, blocker, desktop mode/zoom, history, gamepad delivery, permissions
  and downloads are not implemented by this slice.

## Implementation checkpoint — bookmarks slice, 2026-10-15

- Added a Bookmarks button and native manager inside the existing captured
  browser surface, not a JavaScript bridge or additional XR layer.
- Save the current page with an editable name/address, open and edit entries,
  reorder with Up/Down, and remove with explicit confirmation. Duplicate exact
  URLs update an existing entry; editing into another entry's URL is rejected.
- Home shows escaped bookmark links below the built-in YouTube/Xbox suggestions.
  Closing the manager refreshes Home when appropriate without navigating away
  from an ordinary page. Home itself cannot be saved as a remote bookmark.
- Up to 100 entries, 120-character labels and 4096-character HTTP(S) URLs.
  Credentials in URL authority and unsupported schemes are rejected; the UI
  warns that query strings can contain private tokens before explicit saving.
- Stored as one versioned snapshot in Android app-private SharedPreferences,
  separate from host/workspace settings. Storage is not an encryption or private-
  browsing feature. Android handles asynchronous preference persistence.
- Invalid saved data is not silently overwritten on opening. The UI reports
  the issue; an explicit later save preserves a private recovery copy first.
- Navigation/bookmark host-JDK tests, project parse, full GDScript suite and
  optimized Android build pass. Headset gate: save/edit/reorder/remove, verify
  Home shortcuts and persistence after browser/app restart, then confirm AI,
  fullscreen and close/reopen remain operational.
- History, private sessions and ad blocking remain unimplemented. Next work is
  the free cloud-gaming compatibility probe and ad-blocking dependency review;
  neither is implied by the Bookmarks UI.

## Implementation checkpoint — ad blocking slice, 2026-10-15

- Added optional Brave adblock-rust 0.13.3 through a small pinned Rust JNI bridge;
  system WebView, video capture and AI rendering are unchanged.
- Added Blocking controls inside the browser: global On/Off, exact-hostname
  exclusion, reset exceptions, manual filter update, cache date/status and Reload.
  Off is the default, with no native engine loading or filter downloads until
  opt-in. The small native library is bundled regardless of the toggle.
- Fixed official EasyList/EasyPrivacy HTTPS downloads are bounded and processed
  on a background worker. Rules/cache replacement retains the last known good
  version on refresh failure; cached rules can be loaded offline.
- Network filtering plus bounded URL-specific cosmetic CSS; no downloaded
  scriptlets, resource replacement, Acceptable Ads subscription or telemetry.
  Service-worker attribution, resource-type inference, redirects and generic
  cosmetic discovery impose documented coverage limitations.
- Added native Rust, Java policy and actual host-JNI tests, including real
  official-list compilation/matching. Added licence entries, locked dependency
  notices and a build guard against stale notices after lockfile changes.
- Full evaluation, commands, measurements and remaining hardware checks:
  [Browser ad-blocking integration review](browser-adblock-review.md).
- Headset/UI, filter-download/cache failure scenarios and AI/video performance
  still require validation. This does not implement the cloud-game controller
  route, history, private mode, microphone, downloads or multiple screens.

## Implementation checkpoint — privacy/history slice, 2026-10-15

- Added Privacy UI within the existing captured browser surface. It shows the
  actual system WebView package/version and explains that this is not Horizon
  Browser or private browsing.
- History is off by default and requires explicit opt-in. The app-private,
  versioned list retains at most 200 unique page paths, most recent first, with
  title/time. URLs omit query strings and fragments, preserve encoded paths,
  reject credentials/unsupported schemes, and skip Home/error pages. Titles and
  paths can still be sensitive; this is not encrypted/private storage. Open path
  cannot restore query-dependent pages exactly, which the UI explicitly notes.
- Turning history off retains existing entries; confirmed Clear history removes
  the saved list and runtime Back/Forward history without clearing bookmarks or
  logins. The current navigation is suppressed from immediate re-recording.
- Separate two-step confirmations for cookies/DOM storage and HTTP cache.
  Cleanup first retires the current document to about:blank, then returns to
  local Home and resets Back/Forward history. Browser navigation is held while
  clearing; pending global cookie deletion blocks a new browser from opening
  over that operation. Late callbacks cannot restore a newer browser view.
- Cookie removal has an asynchronous completion callback. Cache/WebStorage API
  operations without a completion callback are described as requests, not proof
  of a complete wipe. No deletion of WebView's internal profile directories.
  Bookmarks, saved visits (unless explicitly cleared), host pairings, blocker
  rules and site exceptions are kept by cookie/cache actions.
- The framework WebStorage API is deliberately labelled DOM-storage cleanup,
  not complete site/profile removal. IndexedDB, service-worker storage and other
  artifacts are not guaranteed erased. Future full clearing should evaluate
  feature-gated [WebStorageCompat.deleteBrowsingData](https://developer.android.com/reference/androidx/webkit/WebStorageCompat).
  See [framework WebStorage](https://developer.android.com/reference/android/webkit/WebStorage)
  and Chromium's [legacy cleanup implementation](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/android_webview/browser/aw_quota_manager_bridge.cc).
- Explicitly deny unsupported protected site permissions, geolocation and file
  uploads. Block external-app schemes/download launch with visible status;
  certificate errors are cancelled without a bypass. Permission/error notices
  survive ordinary title/progress updates until the next navigation.
- Added host-JDK history tests: serialization, privacy stripping, ordering,
  deduplication, bounds, invalid data and clearing. Android permission and
  cleanup callbacks still need integration/device validation. Automated tests
  use isolated in-memory data; no existing headset cookies/history were cleared.
- Private sessions, full profile erasure, microphone, downloads/uploads and
  wider cloud-game controller compatibility remain deferred. Next headset gate includes
  persistence/toggle, explicit clear confirmations, login effects, cancelled
  permissions, close during cleanup, fullscreen, AI and normal stream recovery.

### Browser/gamepad checkpoint — 2026-10-15

User testing confirms the navigation/bookmark/blocking features and Fortnite
streaming with both Quest PAD mode and a connected Xbox controller. Quest input
uses a document-start, read-only software Gamepad API adapter; physical Android
events retain the native WebView route with a browser-local snapshot compatibility
path when the native pad is not exposed. This is not a system virtual HID device,
and general cloud-service/controller compatibility is not claimed. Browser input
is gated while Nightfall's menu/keyboard is open and released across lifecycle
changes. HTTP sites such as local Plex servers are permitted without disabling
HTTPS certificate validation. Closing an AI-3D browser no longer disables the
welcome viewport in the mono-capture policy; headset confirmation is pending.

See [browser testing](browser-testing.md) for confirmed checks, remaining tests,
the isolated Android instrumentation suite, diagnostic page and limitations.

## Web Apps — 2026-10-23

From user feedback (docs/plans/active/user-feedback-2026-10.md on
`fix/user-feedback`): a "Web Apps" column on the welcome screen, bottom
right, opposite the browser picker. Each opens its service's own website
in the browser; no custom frontends.

- The list is data: `src/web_apps.json` (id, name, https address,
  optional user agent), loaded and validated by `WebApps`. It is in the
  export `include_filter`.
- `BrowserPrototype.setStartPage()` hands the session its first page and
  user agent before `open()`; every page WebView in that session uses the
  user agent. A plain browser opened afterwards gets the home page and the
  default user agent again.
- First set: YouTube (`youtube.com/tv` with a TV user agent), Plex, Xbox
  Cloud Gaming, GeForce NOW, webrcade. None needs DRM, so AI 3D works.

To check on the headset: that YouTube's TV interface loads with that user
agent and takes the gamepad (fall back to `youtube.com` if not), that
GeForce NOW accepts the WebView, and that logins persist across sessions.
