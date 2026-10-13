# Unified screens and content tabs

## Agreed product scope

- Quest 3 first; keep platform-specific providers separate for later Quest 2/Linux support.
- Four physical screens total, shared by PC monitors, browsers and local media.
- Add Screen creates an empty screen with a source picker. Add Tab uses that same picker.
- A tab can be a streamed PC monitor, webpage, headset file, SMB item, Plex item or Jellyfin item.
- Screen position, curvature, size, bezel and controls belong to the physical screen.
- Navigation/playback state, audio policy and AI settings belong to each tab.
- Hidden tabs pause and mute by default. Keep Audio Playing is opt-in and retains the
  necessary playback/decoding resources, but never runs hidden-tab inference.
- Restore Workspace is optional. Restoring content is separate from automatically
  reconnecting or resuming playback. Start with explicit user activation after restore.
- Only ONE screen can use AI 3D at a time, regardless of headset/Meteor backend.
  Ownership switching needs an explicit UI decision; do not silently transfer it yet.
- Meteor is only available to sources that actually supply external depth. Local
  browser/video frames are not automatically sent to a host.

## Architecture

Physical VRScreen -> ScreenContentTabs -> ScreenContentTab -> ContentProvider

1. VRScreen retains geometry, OpenXR presentation and grab/resize targets.
2. ScreenContentTabs owns ordered tabs and selection independently of MonitorSpec.
3. ScreenContentTab owns a stable identity, source locator and per-tab preferences.
4. Providers own content production, input routing, audio and lifecycle. The common
   interface does NOT require every source to use the same decoding/rendering code.
5. A workspace service owns physical screen IDs, restoration and the single AI owner.
6. Stream providers reference a shared stream session plus monitor identity. Hiding
   or closing a monitor tab must not terminate the shared session. Another visible
   monitor can still consume it.

## Implementation stages and gates

### 1. Foundation (current work)

- Add tested source/tab/selection data structures and the provider lifecycle contract.
- Give existing monitor screens a matching stream tab without changing presentation.
- Preserve the current four-screen cap; do not resurrect the eleven-screen layout.
- Probe the installed Android WebView provider; report unavailable providers clearly.
- Keep hand-tracking changes separate until their device validation is complete.

### 2. Browser-to-GPU feasibility prototype

- Verify WebView package availability on Quest 3. A package probe is NOT proof that
  rendering, codecs, cloud gaming, login or DRM work.
- Evaluate a hardware-accelerated WebView attached to an app-owned virtual display
  and Presentation, rendered into a Surface consumed by GLES. Compare alternatives
  if this fails. Validate pointer/keyboard coordinates and surface lifecycle.
- Do not use per-frame software screenshots as the production video pipeline.
- Test ordinary pages, unprotected HTML5 video, YouTube, full-screen transitions,
  cookies/login, audio, controller input, standby and browser renderer-process death.
- Measure CPU/GPU frame cost, latency, memory and decoder contention WITH a PC stream.
- Test Quest WebView version/update availability and browser-engine security upkeep.
- If the system provider is unavailable or insufficient, evaluate a packaged engine
  (e.g. GeckoView) explicitly for GPU-surface integration, size and update ownership.
- Treat Netflix and other protected services as independent feasibility gates.
  Protected frames may not enter our ordinary GPU/inference path; do not promise
  AI 3D or work around content protection. Explain unavailable capabilities in UI.
- The competing Depthray thread confirms service-specific features, not a universal
  browser or a general DRM-to-inference solution.

### 3. UI and provider integration

- Add Screen shortcut opens the shared source picker; enforce the four-screen limit.
- Tab strip and source-picker visuals share existing control layers where possible.
  No extra OpenXR layer per tab. Only the selected tab is visually submitted.
- Implement empty-screen state, close tab/screen, rename, selection and navigation.
- Reuse monitor placement/curvature, but do NOT fabricate PC monitors for local tabs.
- Route all pointer, scroll, keyboard, trackpad and gamepad input to the focused
  provider. Release held inputs before focus/tab changes. Never forward browser
  passwords or local interactions to the PC stream.
- Audit global stream resize, YUV binding, ambient, welcome screen and disconnect
  loops: none may overwrite a non-stream tab's texture, dimensions or lifetime.
- Implement existing monitor presentation as the first real provider, then browser,
  then native headset-file playback. Hardware decoding feeds the shared frame API.

### 4. Media sources and persistence

- SMB: file picker, authentication, streaming/seeking and reconnect/error states.
- Plex/Jellyfin: account/server setup, browsing, playback URLs, direct-play versus
  transcoding, subtitles and expiry/re-authentication. These are separate integrations,
  not free functionality inherited from local playback.
- Persist tab locators/preferences and screen transforms through a versioned schema.
  Do not store passwords/tokens in ordinary workspace JSON or diagnostic logs.
- Browser cookies persist in the browser engine's storage; expose clear-site-data.
- Restore Workspace toggle initially restores placeholders, not auto-playing media.

### 5. AI, audio and performance

- Admit at most one AI screen and process only its selected visible tab.
- Both inference input and rendered depth must identify source/frame/generation;
  discard stale completions across switches and clear temporal history.
- Browser/decoded video must offer actual GPU-readable pixels before AI is enabled.
- Preserve ordinary flat UI when suitable; investigate video-only AI versus whole
  page AI rather than assuming text/toolbars should always be warped.
- Background-audio policy controls providers, not just presentation visibility.
- Audit audio focus/mixing, per-tab mute/volume, A/V sync and PC audio limitations:
  a shared PC stream's audio cannot reliably be separated by monitor.
- Count layers at runtime with four screens, stereo, controls, menu, keyboard,
  pointers, ambient and passthrough. Reserve headroom for system constraints.
- Suspend inactive browser/video work by default; release resources on close and
  preserve asynchronous GPU destruction/model-switch safety.

## Acceptance tests

- Existing monitor streaming is unchanged before enabling new providers.
- Four-screen cap, mixed tab ordering, source validation and selection are tested.
- Switching/closing tabs releases input; a stale frame cannot replace current content.
- PC disconnect leaves browser/local media operational; standalone startup needs no PC.
- Hidden tabs are silent/paused unless background audio was explicitly selected.
- One AI screen only; headset and Meteor modes cannot bypass the ownership rule.
- Login/URLs and credentials stay out of exported diagnostics where sensitive.
- Standby/resume, browser-process crash, media failure and rapid tab switching recover.
- Profile a PC game plus browser video plus AI on Quest 3 before calling it usable.

## Next milestone

One hardware-accelerated browser screen playing unprotected video without a PC.
Only after that works, integrate the shared source picker and real tab switching.

## Resume checkpoint — 2026-10-13

- `feat/unified-content-tabs` fast-forwarded to `80bb643`, retaining all
  depth-model, controller, hand-tracking, Meteor and audio-comparison fixes.
- Restored the foundation/probe WIP from its stash. Kept the stash as a backup.
  Resolved test-list and Android packaging conflicts by retaining both additions.
- Godot's editor scan recognizes the restored global classes; scripts parse.
- Quest `dumpsys webviewupdate` reports an enabled `com.android.webview`
  provider, version `149.1.0.10.52.1018773402`, target SDK 36.
- This is an OS provider check only. Browser-to-GPU rendering, video, input,
  lifecycle and DRM remain unvalidated; no browser screen is implemented yet.
- Next implementation gate remains the isolated GPU-surface browser prototype
  in stage 2, before new source-picker/tab UI or changes to stream presentation.
