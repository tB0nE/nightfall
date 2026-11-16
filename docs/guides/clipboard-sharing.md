# Clipboard sharing between browsers and desktop tabs

Use **Copy**, **Cut** and **Paste** on Nightfall's virtual keyboard, or
Ctrl+C/X/V on a connected keyboard. Browser right-click opens **Select All**,
**Copy**, **Cut** and **Paste** inside the browser surface. With controllers,
use the grip right-click shortcut; turn Grip Scroll off to use that gesture. Focus the source tab and select text,
copy it, then focus an input in the destination tab and paste. Physical and
virtual monitor tabs share the host OS clipboard. Browser tabs share Android's
clipboard. Browser addresses and URLs are plain text too.

This first implementation shares plain text up to **64 KiB of UTF-8**. It does
not transfer images, files or rich formatting. Browser and desktop keyboard shortcuts use the same shared-clipboard path.
Select text or focus an editable field before opening the edit menu.

## Host compatibility

Cross-device sharing needs an active desktop connection and the host's paired,
authenticated `/actions/clipboard?type=text` API, with read/write clipboard
permissions. It does not require a separate Meteor clipboard service. Hosts
without that API retain normal local copy/paste; cross-device transfers are
unavailable. The development bundled Vibepollo host includes the Linux support;
the public host download pin must be updated before distributing this feature.

Linux uses packaged `wl-copy`/`wl-paste` on Wayland and `xclip` on X11, in the
logged-in desktop session. No root access or shell interpolation is used.
Vibepollo already implements the Windows clipboard API, but Windows acceptance
of this new client path remains outstanding. macOS is not validated here.

## Behavior and privacy

Sharing is user-triggered; there is no continuous clipboard polling or watcher.
Browser-to-desktop Paste writes the host clipboard before sending Ctrl+V. Failed
writes do not paste unrelated previous host contents. Desktop Copy/Cut obtains
the resulting host text and makes it available to browser Paste. Browser Paste
can refresh host text lazily if no newer local copy needs preserving.

Android clipboard access requires Nightfall in the foreground. Host responses
cannot overwrite a newer headset copy, and pending paste actions are cancelled
if the target tab/host changes or the app pauses. Clipboard contents are never
included in diagnostics or saved to Nightfall settings. The OS clipboard itself
retains copied text according to normal platform behavior.
