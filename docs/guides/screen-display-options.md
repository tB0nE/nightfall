# Screen crop, colour key and placement

Current controls after PR #81 (2026-11-12). These features change presentation;
they do not change the host's requested stream resolution.

## Crop

Stream → Crop offers Off, 21:9, 4:3, 16:9, 16:10, 32:9 and Auto. Manual and Auto
crop affect **only the primary screen**. Other monitors and browsers stay
uncropped. Pointer coordinates are mapped back into the cropped source region.
Manual modes use exact ratios: real films may be 2.39:1 rather than literal 21:9.

Auto checks a 128×72 uncropped colour sample every 300 ms, only while Auto and
media are active. Persistent near-black symmetric borders must match a plausible
preset, but the applied crop uses the **measured edges**, without an intentional
retained border. Five consistent samples confirm a change, about 1.5 seconds.
Changed boundaries reconfirm even within the same aspect preset. Dark frames
retain the last confirmed crop; full-frame content clears it. Subtitles or HUD
in a bar can cause a conservative return to the full picture. Tiny content below
the sample resolution may be missed; use Off/manual for ambiguous material.

Native Quest sampling happens before AI warp, picture controls, keying, bezel
and stats. Two fenced PBOs avoid waiting for GPU completion on the draw thread.
Legacy/Linux uses a small offscreen viewport and reads it after drawing. No new
XR layer is created. At the requested cadence sample traffic is about 123 KB/s;
that is not a measured GPU latency. `AutoScreenCrop.last_analysis_usec` records
CPU analysis only. Edge precision is limited by the small sample grid.

## Colour-key passthrough

Picture → Colour Key selects Off, Green, Blue or Magenta. Key Tolerance offers
Low/Medium/High to handle similar colours, shading and compression fringes.
Passthrough makes matching background regions transparent; colour spill is
reduced at the edges. This applies to desktop/browser screens, not PCVR games.
A key can remove real content that uses the same colour.

Picture → Set Host Background is opt-in. With a desktop stream, a non-Off key
and Meteor support, it temporarily sets a matching host wallpaper. Disabling
it, disconnecting or ending the owning session restores the prior wallpaper.
Recovery journals and ownership checks protect against stale cleanup or a user
changing the wallpaper manually. GNOME/Windows/macOS still need real platform
acceptance; the macOS implementation affects the visible Spaces only.

Advanced → Display → Host Cursor controls whether a compatible host includes
its operating-system cursor in captured video. It does not resize that cursor
or change Nightfall's aiming pointer. Meteor-Vibepollo Linux preview.6 adds the
paired API. See [host releases](meteor-host-releases.md).

## Placement

Remembered screen arrangements and tracking-origin correction solve different
problems. Arrangement restores each screen's placement across reconnects. Origin
correction compensates a valid runtime-reported origin transform after recenter
or standby, moving the workspace rather than the user's tracking origin.
Invalid/unavailable origin transforms are not guessed. Longer-term physical
headset relocalisation still needs monitoring.

## Further reference

- [Current work and acceptance queue](../plans/active/current-work.md)
- [Auto crop implementation record](../archive/plans/automatic-primary-screen-crop.md)
- [Original crop/key/origin work](../archive/plans/screen-crop-key-and-placement.md)
- [Host wallpaper lifecycle](../archive/plans/host-colour-key-background.md)
- [Menu and hover implementation record](../archive/plans/menu-screen-pcvr-cleanup.md)
