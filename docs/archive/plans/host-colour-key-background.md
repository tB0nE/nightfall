# Temporary host wallpaper for colour-key passthrough

> Archived checkpoint — 2026-11-12. Implementation history and measurements
> are retained below. Dates, branch names, unchecked steps and older status
> statements describe that checkpoint, not the current backlog. See the
> [current work queue](../../plans/active/current-work.md) for outstanding work.

## Behavior

Settings → Host Background → **Set Host Background** is opt-in and off by
default. During a desktop stream, a non-Off Colour Key requests matching green,
blue or magenta on the Meteor host. Disable either option or disconnect to
restore the previous wallpaper. Browsers without a desktop stream do not change
any host. Icons, panels, application backgrounds and black window shadows are
not modified.

The existing authenticated, encrypted Meteor control connection owns the
change. No unauthenticated discovery command can modify the desktop. Discovery
advertises support so new clients do not send unknown commands to older hosts.
This currently requires that control service/connection (the same one used for
managed XR); discovery-only Meteor configurations cannot apply the setting.

Only one existing control connection owns a lease. Requests serialize with its
other commands; rapid changes coalesce to the latest colour. Disconnect drops
the lease and restores; a dead network connection can take the existing control
idle timeout (30 seconds) to be noticed. A durable journal is saved **before**
changing anything. Meteor recovers it on startup and restores before normal
shutdown. SIGKILL/power loss recovery occurs on the next Meteor start, not while
Meteor is absent. Old disconnect cleanup cannot restore a newer lease.

Recovery compares the installed values against current desktop settings before
restoring, preserving later user changes. Desktop APIs require a logged-in user
session; no root permissions or system configuration are changed.

## Platform adapters

- **KDE Plasma, X11 and Wayland:** Plasma D-Bus scripting; saves wallpaper plugin,
  image and colour per desktop/monitor. Other plugin settings remain untouched.
  Applies `org.kde.color`, then restores previous plugin/configuration. Verified
  on the development KDE session with a bounded apply/restore test.
- **GNOME, X11 and Wayland:** GSettings background schema, including light/dark
  picture URIs, picture options, both colours and shading. Journal/recovery tested
  with mocked settings; still needs a real GNOME host test. Requires `gsettings`.
- **Windows 11:** built-in PowerShell plus `IDesktopWallpaper`. Saves colour,
  enabled state and per-monitor wallpaper paths. Temporarily disables wallpaper
  display without deleting per-monitor/slideshow settings. Needs Windows testing.
- **macOS:** built-in JXA/AppKit `NSWorkspace`, generated 1-pixel solid PNG and
  saved image URL/options per attached screen. Only currently visible Spaces;
  inactive Spaces are not exposed by the public screen API. Needs macOS testing,
  including dynamic wallpapers and changing Spaces during a stream.
- Other Linux desktop environments return an explicit unsupported message.

Helpers are embedded into the Meteor binary, not downloaded. Linux requires
`/usr/bin/python3`, plus `gdbus` on KDE or `gsettings` on GNOME. Windows/macOS do
not require Python. Operations have a 15-second deadline (the client allows 20 seconds for this
command, leaving other command timeouts unchanged); individual Linux calls
have a 3-second deadline. Failures are logged and shown in Nightfall's status.

## Verification

- `test/test_host_background.py`: six isolated journal/lifecycle tests, including
  partial failure, colour changes, crash recovery, manual wallpaper changes and
  old-lease/new-lease races. Never changes the actual desktop.
- Rust rejects invalid colour commands before spawning platform helpers.
- GDScript persistence/reset tests cover the opt-in field.
- Final full Rust/GDScript suite: 198 Rust tests and GDScript passed
  (`build/verify/unit-20261112-072353/summary.json`).
- KDE real apply/restore passed for all five saved desktop configurations.
- No gamescope/Vulkan desktop tests used.

## User acceptance

1. Start Meteor and a desktop stream; select Colour Key Green and Set Host
   Background On. Desktop wallpaper becomes green; passthrough shows through.
2. Switch to Blue/Magenta. Disable Colour Key: original wallpaper returns.
3. Re-enable, disconnect: original wallpaper returns. Reconnect: colour reapplies.
4. While enabled, choose another wallpaper manually: disconnect must preserve it.
5. Repeat on GNOME/Windows/macOS before treating those adapters as verified.

## Development deployment (2026-11-12)

Optimized DEV APK installed in place, settings/pairings retained. Optimized
Meteor runs from `.build-cache/host-background-dev/usr/bin/nightfall-meteor`,
with libraries/models/XR bundle copied from the previously running AppImage.
Existing user configuration is retained; no release/autostart package replaced.
Discovery advertises `host_background: {supported:true, protocol:1}`. The new
setting was verified through the headset bridge, off by default. End-to-end
stream-driven switching still needs acceptance with the headset worn; it went
to sleep before that check. No playback or wake-lock test left running.
