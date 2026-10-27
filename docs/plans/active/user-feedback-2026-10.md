# User feedback, October 2026

> Status: Active (2026-10-23). Feedback after v0.8.1 and the v0.8.2 browser
> preview: GitHub issues, Reddit and chat. Branch placement follows
> [v0.9-integration.md](v0.9-integration.md).

## Summary

| Item | Size | Branch |
| --- | --- | --- |
| #60 Gamepad right stick scrolls the mouse wheel | Small | `fix/user-feedback` |
| #61 Pointer moves the mouse without clicking | Small | `fix/user-feedback` |
| Reddit thread (Rush_iam): 12 items | Mostly small | `fix/user-feedback` |
| Environments (cinema, living room) | Medium–large | new `feat/environments` off `main` |
| Web Apps on the welcome screen | Medium | `feat/unified-content-tabs` |
| Netflix, Disney+, Prime Video in 3D | Not feasible in-app | docs only |
| VR app menu | | `feat/meteor-xr-streaming` (later) |

## #60: gamepad right stick scrolls

`XRInteraction.handle_scroll()` (`src/xr_interaction.gd`) reads the Quest
right stick and, when that's idle, every connected joypad's right stick.
A DS4 or Xbox pad's right stick is already forwarded to the PC as a
gamepad, so it also sends mouse-wheel events: in shooters, weapons change.

Fix: scroll from the Quest controller only; drop the joypad loop. Add a
test that a joypad right-stick value sends no scroll.

## #61: pointer moves the mouse without clicking

The PC cursor moves only on trigger or grip (`_position_stream_pointer()`
and the click paths in `src/xr_interaction.gd`). RTS games need the cursor
to follow the pointer, to preview placement before clicking.

Fix: a setting "Pointer moves mouse" (off by default; Moonlight XR does
this by default). While on and the ray is on the stream screen, send
`send_mouse_position_event` when the host point moves by at least one
pixel, at most once per frame. It must not send when the ray leaves the
screen, over the menu, or while the trackpad or keyboard is in use.
Reuse the parallax-shift correction the click path uses. Applies to
desktop and KBM mode; not gamepad mode.

## Reddit (Rush_iam)

Quest 3, Windows host, Sunshine and Vibepollo. Already done on
`fix/user-feedback`:

- **Custom host port (50000) never pairs.** Cherry-picked `db94d36`:
  pair on the port mDNS advertises.
- **"EdgePad-256 CPU" shown on a fresh install.** Cherry-picked
  `a2c61f1` from the XR branch, with a test for `main`.

To fix on `fix/user-feedback`:

| Report | Cause / fix | Size |
| --- | --- | --- |
| Connect loops back to Select Server; the log says the device lacks "Launch applications" | Vibepollo gives full access only to the first client ever paired; later ones get view-only (`src/nvhttp.cpp`, `PERM::_default`). Not a pairing bug. Show the host's refusal on the welcome screen with what to change, instead of returning to the server list. In our fork, grant launch to clients paired through the PIN prompt. | Small |
| Cursor doesn't follow the pointer, so no hover feedback in desktop mode | #61 | Small |
| Menu buttons and the pointer ring vanish against a white wall in passthrough | A darker, adjustable menu background (opacity slider), and an outline on the pointer ring | Small |
| Passthrough fade level | A passthrough opacity slider next to the background setting | Small |
| 207 Hz glitches the headset, and cycling from 90 to 72 Hz passes through it | Cycling applies each step. Apply the refresh rate only once cycling stops (short delay), and hide rates above 165 Hz behind an Advanced toggle | Small |
| AI 3D on/off is hard to find (looked in the 3D tab) | Add the on/off switch to the AI 3D tab too | Small |
| Stats say EdgePad-384 while 512 runs (the log says 512) | The stats overlay reads the wrong label | Small |
| 2–3 s freeze switching model (384 → Auto) | Model load; known. Show "Loading model…" instead of a silent freeze | Small |
| USB Link: pairing to `fe80::…%usb0` never reaches the host; "USB Link: Up" still used Wi-Fi | Investigate. The scoped IPv6 link-local address may be malformed in the pair URL (`%` must be `%25` inside `[...]`) or not routed; prefer the USB interface's IPv4 when there is one | Medium |

Not ours, or no change now:

- **UFO-test stutter at 90 Hz**, also in Moonlight XR. Rush_iam fixed it
  with RTSS's frame limiter on the host, so it's host frame pacing. Add
  a note to the troubleshooting docs; revisit if others report it.

### Status (2026-10-23)

Done on `fix/user-feedback`, not yet tested on a headset:

- #60, #61 (Mouse Follows Pointer), the shortcut-bar backdrop, refresh
  rates (debounced; 200/207 Hz behind Settings > High Refresh Rates), the
  AI 3D switch on the AI 3D tab, the stats model name, "Loading depth
  model…".
- Permissions: the client can't ask for more when pairing; the host
  decides. Nightfall now reads the `Permission` the host reports and
  explains what to allow. Launch failures show on the welcome screen.
  Needs the native library rebuilt.
- USB Link: a Wi-Fi-paired PC's USB address is learned when the link
  comes up; failed pairing over the cable names `address_family = both`
  and the Windows Public-network firewall.

- Passthrough fade (Settings > Display > Passthrough Fade: Off, 25, 50,
  75%): Godot's passthrough has no opacity control, so a compositor
  equirect sphere of translucent black sits behind every other layer;
  without equirect support it falls back to the projection layer's
  clear colour. Check on the headset that it darkens the room in both
  rendering modes and that the screen and menus stay in front of it.
- Our Vibepollo fork (`nightfall` branch, `0f78785`) gives every paired
  device full permissions; entering the PIN already needs the host's
  admin login.

Dropped: the lag after opening the Meta menu was most likely the depth
model loading at start-up; revisit separately.

## Environments

The request: a cinema or a living room around the screen. 360° pictures
look flat, so the direction is real 3D rooms.

**Start from `3d-environments`, but port it rather than merge it.** Its
environment work sits in one commit (`6358933`) together with
performance tools, and the branch is 214 commits behind `main`, whose
`main.gd` and menus have since been refactored. What to carry over:

- `src/environment_manager.gd`: loads a `.glb` room, turns on Godot's
  projection layer at 50% render scale for the room only (the stream
  stays a composition layer, so it stays sharp), turns off subsampled
  foveation, and places the screen in the room.
- `src/assets/environments/psx_cinema.glb` with its CC BY 4.0
  attribution ("VR Cinema Environment" by fangzhangmnm, Sketchfab), and
  the "Off / Minimal Room / PSX Cinema" setting.

The rest of that branch (native renderer, LiteRT baseline, GPU priority,
stats overlay) is unrelated; leave it.

**Cost:** a room means rendering a projection layer every frame, on the
GPU the depth model uses. Measure depth latency with a room on, and keep
rooms low-poly with baked lighting.

**Where rooms come from:**

1. **Bundled:** one or two in the APK (the PSX cinema).
2. **Your own catalogue:** rooms you make or buy, listed in a JSON index
   and downloaded on demand from GitHub releases, so the APK stays
   small. Each entry carries its screen anchor (position and size),
   scale, licence and attribution.
3. **The user's own file:** a `.glb` from the headset's Downloads. Godot
   loads glTF at runtime (`GLTFDocument`).
4. **From a website such as Sketchfab:** feasible, but the most work.
   Sketchfab's download API needs the user's Sketchfab login (OAuth) and
   only works for models whose authors allow downloads; licences vary
   (CC BY needs the attribution shown). Arbitrary models also don't know
   where the screen goes, may be the wrong scale, and can be far too
   heavy for the Quest.

Options 3 and 4 need the same safeguards: a file-size and triangle
budget (refuse or warn), texture downscaling, and a "place screen" step
that saves the anchor per room. Do 1 and 2 first, then 3; 4 only if
users ask after that.

## Web Apps

The idea: on the welcome screen, next to "PC (GameStream)", tiles for
YouTube, Plex, Xbox Cloud Gaming and similar.

**No custom frontends.** Building a client per service means following
each service's API and login changes forever, and most (YouTube, Xbox)
don't allow third-party clients. A Web App is the service's own website
with a profile Nightfall applies:

- start address, and an icon and name;
- user agent, where the site has a better mode for it, e.g. YouTube's TV
  interface (`youtube.com/tv`) is built for a gamepad and a big screen
  (check it works in our WebView before shipping it);
- display defaults: screen size, curve, AI 3D on or off;
- input: gamepad passthrough for cloud gaming (the browser's existing
  gamepad bridge), pointer otherwise;
- logins kept (cookies allowed for that site only);
- small page tweaks where needed: hide a banner, enter fullscreen.

Good first set, all without DRM so AI 3D works:

| Web App | Address | Notes |
| --- | --- | --- |
| YouTube | `youtube.com/tv` or `youtube.com` | Some videos are DRM-protected (films) |
| Plex / Jellyfin | `app.plex.tv`, the user's server | Personal media, no DRM |
| Xbox Cloud Gaming | `xbox.com/play` | WebRTC video and the Gamepad API |
| GeForce NOW | `play.geforcenow.com` | Same |
| webrcade | `play.webrcade.com` | Retro games in the browser; the chat request |

Free browsing is already in the v0.8.2 preview; Web Apps are shortcuts
into it, kept as data (a JSON list), so adding one isn't a code change.

## Netflix, Disney+, Prime Video

Not feasible inside Nightfall, and not something to work around.

- These services use Widevine DRM. On the Quest, protected video is
  decrypted and decoded into protected memory, shown through a secure
  surface. Nightfall's browser draws the WebView into a texture, so
  protected video would come out black, and the depth model can't read
  the pixels either. That is the point of the protection.
- Reading the frames anyway would mean defeating the DRM. That breaks
  the services' terms and anti-circumvention law (DMCA §1201, EU
  Copyright Directive art. 6), and would put the project at risk.
- Netflix itself dropped its Quest app for the Quest Browser (1080p).
  Prime Video has a native Quest app; Disney+ has none.

What users can do: play these in their own apps or in the Quest
Browser, in 2D. Nightfall doesn't advertise a PC-capture route.

A quick check worth doing once: whether Netflix even loads in our
WebView (`BrowserCapabilities` reports `drm_validated: false`). If it
shows an error page, show a clear "This service needs its own app"
message instead.

## VR app menu

Belongs with XR streaming (`feat/meteor-xr-streaming`): a menu listing
the PC's SteamVR and OpenXR apps to launch. Not part of this round.

## Order

1. #60 and #61, plus the Reddit fixes, on `fix/user-feedback`; release
   as the next 0.8.x (0.8.2 is taken by the browser preview).
2. Web Apps on the browser branch, for the next browser preview.
3. Environments on `feat/environments`: port the room, then the
   catalogue, then user files.
