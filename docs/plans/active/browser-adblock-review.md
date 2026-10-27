# Browser ad-blocking integration review

Date: 2026-10-15. Scope: one standalone Android WebView on the primary screen.

## Engine decision

- Use upstream [Brave adblock-rust](https://github.com/brave/adblock-rust), pinned
  at crate 0.13.3 with Cargo.lock. It supplies established filter syntax and
  matching, rather than a Nightfall-specific substring/domain denylist.
- Upstream identifies the engine as MPL-2.0 and supports network/cosmetic rules.
  Preserve notices and source references, including pinned Rust dependencies,
  under Settings > About > Licences. No upstream engine modifications are made.
- The [Adblock Plus Android SDK](https://github.com/adblockplus/libadblockplus-android)
  documents a separate V8 build, an NDK r16b baseline and an AdblockWebView
  wrapper. Those integration requirements are a less attractive fit for this
  existing NDK 29 GPU-surface browser. This is not a claim that its licence or
  filtering quality is inadequate.
- An [eyeo Chromium fork](https://gitlab.com/eyeo/adblockplus/chromium-sdk) would
  expand engine packaging/security maintenance far beyond this standalone slice.
  Chrome extension installation is not added to system WebView.

## Implementation boundaries

- A small Rust JNI adapter compiles to an arm64 library. The initial stripped
  build measured about 3.1 MB uncompressed; APK size rose from about 104 to
  105 MB at the existing build script's rounded precision. These are not Quest
  memory or frame-time measurements.
- Compile lists on one low-priority background worker. Publish a replacement
  under a native mutex only after compilation succeeds. Never fetch, compile
  or read list files in the WebView request callback or GL/render path.
- Disable adblock-rust's single-thread optimization so the shared engine supports
  concurrent callers; JNI adapter serializes engine access. Fail open on missing
  engine/input failures. A poisoned native mutex cannot crash browsing through
  an uncaught Rust panic crossing JNI.
- Blocking is off by default. Turning it on loads app-private cached rules or
  fetches the fixed official HTTPS EasyList and EasyPrivacy subscriptions.
  Update is manual in this slice; no periodic scheduler or silent first-launch
  download. Status includes cache date and an aggregate process-lifetime counter.
- Downloads have response-code, byte, line-length, header/title and time bounds;
  redirects are rejected. Never forward browsing cookies or Referer. Both lists
  must arrive/validate before replacement. AtomicFile retains the old cache if
  writing fails; existing active rules remain on a failed refresh.
- No Acceptable Ads subscription, paid whitelist, remote scriptlets, CSP changes,
  resource replacements or parameter-rewrite behavior. EasyList's ordinary allow
  rules are still evaluated by the engine.
- Exceptions are exact lowercase hostnames, not registrable-domain or suffix
  matches, stored privately and separate from host settings. Requests never log
  browsing URLs, filter matches, query strings or page contents.
- WebView request type is inferred from fetch destination headers where available,
  then common file extensions, otherwise `other`. Never block top-level navigation.
  These are integration limitations, not full browser-extension parity.
- Service-worker interception is installed, but only attributed requests matching
  the current page's referrer hostname are considered. Unknown/older workers fail
  open. WebView does not expose all redirect/request paths; no complete-coverage
  claim is made. See [Android's request callback](https://developer.android.com/reference/android/webkit/WebViewClient)
  and [service-worker callback](https://developer.android.com/reference/android/webkit/ServiceWorkerClient).
- Apply the engine's URL-specific cosmetic selectors after page completion, using
  fixed local JavaScript to install a style element with JSON-quoted CSS. Filter
  content is never executed as JavaScript. CSS is bounded; generic DOM class/id
  discovery and SPA-specific reapplication are deferred. CSS selectors already
  installed still match later DOM elements normally.
- Turn Off/site exclusion removes the injected stylesheet and bypasses future
  matching. Reload restores resources previously blocked. UI explains this and
  provides Reload page, manual Update, global toggle and exception reset.

## Licensing/data provenance

- Engine: https://github.com/brave/adblock-rust, MPL-2.0. The locked crate and JNI
  sources are available through Cargo and the Nightfall repository respectively.
- Rules: The EasyList authors, https://easylist.to/. Lists are downloaded directly
  on opt-in rather than bundled in the APK. Their published licensing information
  is at https://easylist.to/pages/licence.html; the GPL-3.0-or-later option and
  attribution are exposed in Nightfall's licence page.
- `licences/browser-adblock-dependencies.txt` is generated from locked Cargo
  metadata and upstream archive licence/notice files, deduplicated by content.
  It also identifies archives that only declare SPDX terms. Regenerate/review
  when Cargo.lock changes; include relevant upstream notices when adding crates.
- Regeneration: run Cargo metadata with `--locked --filter-platform
  aarch64-linux-android --format-version 1`, then feed that JSON to
  `tools/build_support/browser_adblock_notices.py`. Its output replaces the
  generated notice file. Licence texts remain English.

## Verification and remaining gates

- Rust unit test: upstream network rules, allow exceptions, third-party rules,
  resource types and cosmetic selectors.
- Host Java tests: global Off, engine-not-ready, exact-host exceptions, local
  Home bypass, request-type fallback, source-origin stripping and list validation.
- Actual desktop JNI test: installation, matching, exceptions, selectors,
  release and rejecting an oversized replacement without losing the old engine.
  Run `bash test/run_browser_adblock_native_tests.sh`; optional arguments are
  locally downloaded EasyList and EasyPrivacy text files.
- Real official-list host test measured 86 ms compilation and about 3 microseconds
  per repeated JNI+reflection request. This is a narrow desktop measurement, NOT
  a Quest performance estimate, broad workload benchmark or guarantee.
- Cross-compiled Android library and optimized APK build succeeded. Re-run full
  project/packaging checks after final documentation/notices changes.
- Still needed: headset settings interaction, actual filter downloads, cached
  offline operation, failed-refresh fallback, exceptions on real sites, smaller
  ad-heavy sites, login/video/fullscreen, AI on/off, close/reopen and standby.
  Device CPU/frame-time and long-session memory measurements remain outstanding.
