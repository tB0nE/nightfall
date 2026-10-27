# Meteor VR app library

## Implemented preview

The first library is Steam-only, including VR-enabled non-Steam shortcuts.
Lutris integration is deferred. Adding a shortcut to Steam does not establish
its XR launch setup; it still needs the Meteor wrapper.

Nightfall exposes VR Apps from PCVR settings. Meteor also has a VR Apps tray
entry, which asks the connected client to open the same panel. The panel reuses
the settings viewport and adds no OpenXR composition layer.

The host discovers installed games registered in Steam's VR manifest, cross-checks
installed app manifests, also reads binary shortcut metadata, and returns four cards per page. Cached artwork becomes
small rounded thumbnails; missing art has a named placeholder. This discovery can
miss games not yet registered with SteamVR.

Catalog, artwork and launch requests use the existing authenticated encrypted XR
control connection. Requests and responses are bounded; only numeric Steam IDs
can be launched. Launches use Steam without a shell. The helper never returns
private configuration paths or launch options to the client.

Shortcuts launch through Steam's 64-bit rungameid URI; their 32-bit shortcut ID
still binds the Meteor launch intent to its runtime session. Steam's zero AppId
shortcut environment is accepted only with the matching 64-bit SteamGameId.

Games need existing Meteor steam-run launch options. The panel marks other games
as needing setup rather than modifying Steam configuration automatically. Alyx
and VRChat are configured on this development host, along with the remaining
installed store VR apps and BraindanceVR's non-Steam shortcut. Launching a second game while
an XR session is active is blocked in this first version.

## Validation and deployment

- Python catalog, privacy, thumbnail and launch-guard tests passed.
- Rust XR tests: 62 passed, four ignored.
- Full GDScript suite passed, including library navigation and request queuing.
- Optimized release-signed DEV APK built with `./build.sh --dev` and installed
  on Quest 3 on 2026-10-24.
- Release Meteor binary built and both local services restarted. Normal Meteor
  uses `.build-cache/meteor-library-preview/` with the AppImage's bundled models
  and libraries preserved; the installed AppImage itself was not replaced.

## Headset acceptance checks

1. Open PCVR settings, then VR Apps; check artwork, pagination and Back.
2. Choose VR Apps in Meteor's desktop tray; confirm the same panel opens.
3. Launch configured Alyx or VRChat and verify normal automatic XR handover.
4. Confirm an unconfigured game reports that launch setup is required.

## Follow-up

Package helper discovery and the tray notification mechanism for distribution;
the preview currently uses the development checkout. Consider setup assistance,
installed-game discovery beyond Steam's VR manifest and
launch-state feedback after headset validation. Existing XR audio behavior is
unchanged.

## Headset handoff and duration (2026-10-24)

Moss's first session ended after about 43 seconds: the headset closed its control
connection, then runtime teardown caused xrizer to lose its instance. The user
confirmed this happened while handing the headset to their son.

Application pause no longer cancels Meteor standby or an active Meteor game.
Microphone/input pause handling remains, and standalone diagnostic projection
tests still stop on pause. Meteor's client duration checks, external application
timeout and Steam wrapper outcome timeout have been removed. Active authenticated
relay requests renew a six-minute host idle lease rather than expiring gameplay
after a fixed duration. Actual disconnects and explicit stops still clean up the
owned game. Long headset suspension can still exceed transport/idle timeouts;
this change addresses ordinary headset handoffs, not disconnected session recovery.

GDScript regression coverage now checks pause/resume and over-ten-minute simulated
Meteor playback, with explicit stop afterward. Python lifecycle tests cover
unlimited execution retaining owner-exit cleanup. Real headset validation remains.

A follow-up Moss test exposed one additional supervisor cutoff at 315 seconds.
The host logged `XR runtime exceeded session deadline`; the thumbstick press
coincided with the cutoff. The Rust adapter now also leaves external game duration
unbounded, retaining fixed durations only for diagnostic fixtures. A Rust regression
test covers both external-game profiles and bounded fixture profiles.
