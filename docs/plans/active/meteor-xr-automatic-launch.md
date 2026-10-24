# Automatic XR launch from the Nightfall desktop

## 2026-10-24: multiple Steam games

The original spike pinned `application.json` to VRChat (438100). Host-local
Steam templates now also accept `"steam_app_id": "*"`. The wrapper publishes
the actual numeric application ID; Meteor validates and claims the live local
intent and resolves that ID into a private, session-specific application spec.
The runtime ticket and command validation still require that exact selected ID.
A later launch cannot retarget a running session. Numeric configuration remains
available when a host intentionally wants to restrict launches to one game.

Wildcard selection requires an automatic launch intent; it is not a wildcard
permission on runtime tickets or remote executable selection. The headset never
supplies the game command. Steam launch options are still needed per game:

```sh
.build-cache/model-tester-venv/bin/python tools/meteor_xr.py steam-options --app-id 546560
```

Copy the printed absolute command into Half-Life: Alyx's launch options. Use
438100 for VRChat. The current test host uses the wildcard template, with a
neutral checkout working directory; Steam supplies the game's actual command,
environment and working directory. No APK changes are necessary. Native Linux
Alyx compatibility remains a physical test, not guaranteed by launcher tests.

Updated 2026-10-21; `feat/meteor-xr-streaming`. Initial Linux DEV implementation deployed; physical testing pending.

## Current implementation and test handoff

The connected desktop now maintains an authenticated idle launch watch against
its matching trusted XR host. It allocates no XR receiver, projection or Monado
runtime while idle. The existing configured Steam wrapper publishes a private,
expiring, PID-birth-bound intent for its allowlisted application. The host claims
that generation once and binds it to the runtime ticket. Commands remain local.
Nightfall automatically negotiates and accepts, retaining the existing
first-decoded-frame handover and desktop restoration. Explicit non-VR launch
flags bypass the XR path. Cancelling suppresses automatic entry until desktop
reconnection or app resume.

This still uses the dedicated DEV listener and the already-configured per-game
Steam wrapper, not generic process detection or normal Meteor packaging.
No Steam launch options or global runtime registrations were changed.
The five-minute DEV session cap remains.

Validation: 76 Python XR tests, 58 Rust XR tests (four optional interop tests
ignored), and the full GDScript suite passed. Optimized release-signed DEV APK
installed; dedicated release-built host listener restarted, regular Meteor left
untouched. APK SHA256:
`ddbdc3985d0649a33c9bd0e65e9cdd90578b9f3c5a0682372f7be2fcdba04f12`.

Physical test: start a Sunshine desktop stream, launch VRChat in VR mode from
Steam without pressing the DEV preparation/authentication/accept buttons, check
automatic entry, wristwatch/menu access and return to desktop after game exit.
Also test the new resolution/status/filter controls in the same session.

## Desired user experience

Connect the desktop stream normally, launch VRChat from that desktop, and enter
XR automatically once the game and first decoded XR frame are ready. No manual
standby button or per-launch headset acceptance. Wristwatch and desktop overlay
behave as now; exiting the game restores the desktop. Pairing/trust remains
explicit once. A connected desktop must not imply permission to run arbitrary
remote commands or silently replace the user's global OpenXR runtime.

## Why waiting for an already-running XR game is insufficient

The current managed runtime starts only after an authenticated offer/acceptance.
Steam's existing per-game wrapper waits for an armed ticket, then hands the real
game command to our owned runtime supervisor. A game needs the correct runtime
manifest, IPC directory and OpenVR compatibility environment at launch; detecting
its process afterwards cannot safely move that process to Meteor's runtime.
Process names alone cannot distinguish desktop mode from VR mode.

## First implementation: launch intent before process startup

1. Add a persistent, low-cost authenticated control watch while Nightfall is
   connected to the trusted host's desktop. Keep existing desktop stream alive.
   Idle must not initialize Monado, decoder/swapchain or XR tracking transport.
2. Extend the host-local Steam wrapper to publish a bounded launch-intent ticket
   when no armed session exists. Include allowlisted application ID, generation,
   owning PID/birth identity, expiry and expected runtime mode. Keep command argv
   host-local under the existing validation/ownership model; never send to headset.
3. Meteor reports the pending intent over authenticated status/events. The client
   validates identity, generation, trust/auto-enter preference and workspace
   eligibility, prepares negotiated timing, and automatically offers/accepts the
   XR session. No repeated trust prompt after initial opt-in to this paired host.
4. Host binds exactly that pending intent to exactly one accepted session and
   launches through the existing supervisor once tracking/receiver lanes are
   ready. Preserve the user's current Proton selection and wrapper options.
5. Keep desktop visible until session activity plus decoded frame, using existing
   handover. Launch failure or timeout leaves desktop usable with a clear message.
6. On game exit, drain receiver/compositor, restore desktop timing/focus and
   return to low-cost watch state. Release input and handle network/standby loss.

## Safety and protocol work

- Separate long-lived authenticated idle watch from bounded launch/start watchdogs;
  don't just increase the current 30-second arm window or create phantom sessions.
- Single active headset/session ownership, explicit conflict response, single-use
  tickets and replay/stale-generation rejection. Reconnect must not relaunch games.
- Cancellation before game process creation; cleanup/reaping after creation. PID
  reuse, wrapper exit, host shutdown and headset disconnect must invalidate intent.
- Bound/rate-limit pending intents, authentication attempts, payloads and polling.
- Honor desktop/non-VR launch: bypass the XR wrapper when desktop mode is selected.
  Never auto-enter based solely on a game name or intercept every Steam launch.
- Do not have both the existing status loop and watch loop read the same cipher
  socket concurrently. Keep a single owner of requests/counters per connection.
- Preserve screen layout limitations until multi-screen coexistence is supported.
- Existing five-minute DEV gameplay limit remains a separate outstanding item.

## Later: general runtime broker

To remove per-game wrappers, Meteor needs a deliberately installed runtime broker
or supported launcher integration. Apps select it before initialization; it can
report launch intent, start the managed runtime and gate presentation. OpenVR
applications still require a compatible OpenVR→OpenXR layer. Never hijack another
runtime's active session. Linux first; Windows needs equivalent install/runtime
registration and application-launch integration rather than copying shell flags.

## Test gates

- Start desktop → launch VRChat → automatic first-frame-backed handover, no priming.
- Repeated launch/exit and return to desktop at original resolution/bitrate/FPS.
- Desktop-mode VRChat launch does not arm XR.
- Slow startup, cancellation, no headset, disconnected host, expired/duplicate
  ticket, wrong app ID, second headset and declined automatic-entry preference.
- Re-wear/reconnect does not duplicate game process or steal another runtime.
- UI-only/idle host has no XR GPU allocation or unnecessary persistent tracking.

Do not modify Steam launch options or global runtime registrations as part of
implementing this phase. Normal-host packaging and a generic broker remain later phases.
