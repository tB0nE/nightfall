# User feedback, October 2026

> Status: Active (2026-10-23). Feedback after v0.8.1 and the v0.8.2 browser
> preview: GitHub issues, Reddit and chat. Branch placement follows
> [v0.9-integration.md](v0.9-integration.md).

## Summary

| Item | Size | Branch |
| --- | --- | --- |
| #60 Gamepad right stick scrolls the mouse wheel | Small | `fix/user-feedback` |
| #61 Pointer moves the mouse without clicking | Small | `fix/user-feedback` |
| Reddit thread (Rush_iam) | Not read yet | `fix/user-feedback`, cherry-picks |
| Environments (cinema, living room) | Medium | new `feat/environments` off `main` |
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

Reddit blocks automated reading, so the thread hasn't been read. Paste
it in, and each item gets a row here: already fixed (cherry-pick the
commit onto `fix/user-feedback`), fix now, or later.

## Environments

The request: a cinema or a living room around the screen, instead of
black or passthrough.

What exists: `src/composition_environment_layer.gd` (on `main`) already
draws an OpenXR equirect composition layer behind the screen, and the
Display tab has the background setting. `3d-environments` (214 commits
behind `main`) has an older 3D-room experiment; don't revive it.

Plan:

1. **360° image environments.** A picture on the existing equirect layer.
   The compositor draws it, so it costs almost nothing on the GPU, which
   the depth model needs. Ship three or four (dark cinema, living room,
   night sky) from CC0 sources such as Poly Haven, plus "your own image"
   from the headset's storage.
2. **Dimming.** Lower the environment's brightness while video plays, like
   a cinema; a slider in the Display tab.
3. **Later, maybe:** real 3D rooms, with the screen set into a wall.
   They cost GPU every frame and conflict with projectionless composition
   mode; only if users ask after 1–2.

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
3. Environments, phases 1–2, on `feat/environments`.
