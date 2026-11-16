# Explicit browser / desktop clipboard sharing

Implemented on `codex/virtual-monitor-transition-speed`, 2026-11-15, and included
in `codex/takeya-hardware-pr-review`. Awaiting end-to-end user acceptance.

- Virtual keyboard Copy/Cut/Paste and its latched Ctrl+C/X/V use ClipboardSharing.
- Explicit, serialized text operations only; no periodic clipboard reads.
- Native authenticated GET/POST uses the paired host's existing clipboard API.
- BrowserClipboard reads/writes Android text only while the Activity is focused.
  Host-origin markers avoid overwriting a later host copy with stale headset
  text. Timestamp checks preserve newer local copies. No URI coercion.
- Focus/tab/host changes prevent delayed paste injection; pause invalidates queued
  actions. UTF-8 payload limit is 64 KiB. Never log text payloads.
- Companion Linux host replaces clipboard stubs with bounded helper execution.
  Fixed argv, no shell; two-second helper deadline and bounded pipes. Existing
  streaming-certificate and clipboard-permission checks remain. Failed writes
  now return once instead of sending both a 500 and success response.
- Portable host includes clipboard binaries, dependencies and license metadata,
  with the same glibc 2.35 baseline audit. Public release pin remains a separate
  release task.

Verification:
- All 75 GDScript scripts pass, including direction/order, errors, UTF-8 size,
  newer-copy protection, target changes and application-pause cancellation.
- Native Android library and portable host build/package pass.
- C++ subprocess harness passes Unicode round-trip, oversized output, timeout
  and missing-command cases without touching the user's desktop clipboard.
- Isolated Quest test passes rejection of background clipboard access. Its
  positive WebView clipboard test is skipped when the test Activity lacks focus;
  do not interpret the aggregate 'OK (2 tests)' as two positive clipboard tests.
- Release-optimized DEV APK and matching host prepared for in-place deployment.
  Meteor restart retains base 49989 and existing credentials/pairings.

Remaining: test on-screen Copy/Paste in both directions in foreground Nightfall,
  including Unicode/multiline text and a virtual monitor tab. Verify Wayland and
  X11 on actual desktop sessions; Windows/macOS need separate acceptance.

## Browser editing and connected keyboards

- Added an in-surface right-click menu: Select All, Copy, Cut and Paste. It uses
  the existing browser texture, preserves editor focus and closes on focus/tab
  changes. Actions are tagged with the selected page and a sequence number;
  stale actions cannot paste into a different tab.
- Browser edit actions and physical Ctrl+C/X/V use the same sharing queue as
  the virtual keyboard. Ordinary physical keys go to the focused browser, even
  without a desktop stream; settings text fields retain priority.
- Delayed host shortcuts reconstruct Ctrl only if it is no longer held, and
  consume the original shortcut-key release to avoid unbalanced key events.
- Explicit desktop focus no longer falls back to an unrelated active browser.
- Added a physical-keyboard routing regression and an isolated Android test for
  menu actions, surface bounds and focus-loss cleanup. Grip Scroll owns grip
  gestures when enabled; disable it to use controller grip for right-click.
