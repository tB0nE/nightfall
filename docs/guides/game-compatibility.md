# PCVR game compatibility

Setup notes and test results for PC VR games streamed through Nightfall Meteor.
This is separate from playing a flat game on a streamed desktop with AI 3D.

Last updated: **2026-11-12**. Some results below come from development builds;
an unreleased fix is identified explicitly rather than attributed to a public
release.

## Before launching a game

1. Install Nightfall and Meteor from the same release and finish Meteor's PCVR
   setup. Connect Nightfall to the PC's desktop stream.
2. Configure the game's Steam launch options using Meteor's Setup window or
   its **Custom Steam Launch Options required: Copy** tray-menu entry. Copy
   the command generated on that PC: its paths depend on the installation.
   Keep any game-specific environment settings and arguments described below.
3. Launch the game from Steam or Nightfall's **VR Apps** list. The desktop stays
   available while the game starts; the XR view takes over when it is ready.
4. Use the wristwatch to show the desktop or PCVR settings during the game.
   Quitting the game should return to the desktop stream.

Linux uses Meteor's managed Monado/xrizer runtime; Windows has its own XR
backends. Do not copy Linux launch commands onto Windows. For Windows setup
and recorded backend limitations, see the [Windows XR guide](meteor-windows-xr.md).

## Recorded game tests

“Previously tested” records a working development test, not a retest against
every later release. “Not recorded” means there is no test result here.

| Game | Linux | Windows | Input / setup notes |
|---|---|---|---|
| VRChat | Previously tested: movement, buttons, stick clicks, audio and desktop/wristwatch access. Also affected by the intermittent native XR failures noted below. | Tested through SteamVR; see the [Windows checkpoint](../plans/active/meteor-windows-vrchat-compat.md) for the tested configuration and limits. | Quest motion controllers. Record the Proton version when reporting Linux problems. |
| Half-Life: Alyx | Previously tested in game with working XR streaming. Not rechecked in the latest session. | Not recorded. | Motion controllers. Use Meteor's Steam launch setup. |
| Moss | Previously tested in game; recent attempts also encountered intermittent native XR failure. | An xrizer-backed test is recorded in the [Windows XR guide](meteor-windows-xr.md). | Controller poses and buttons are required; generic gamepad support is not equivalent to the tested XR input path. |
| Subnautica | VR startup and rendering confirmed on 2026-11-12; user quit normally. A subsequent quick gameplay test confirmed Quest Touch controls after the launcher fix below. Earlier attempts also encountered native XR failure. | Not recorded. | Original VR mode uses a gamepad or keyboard/mouse. Motion controls require a mod such as SubmersedVR. |

## Subnautica: motion controls with SubmersedVR

Subnautica's original VR mode does not provide tracked motion controls.
[SubmersedVR](https://github.com/Okabintaro/SubmersedVR) adds them; its author
also documents Linux testing with WiVRn/xrizer. Use the mod's current
[installation instructions](https://github.com/Okabintaro/SubmersedVR#installationsetup)
for game-version requirements, BepInEx and incompatible mods.

For Linux/Proton with Meteor:

1. Install BepInEx and SubmersedVR in the game's installation directory as
   described by the mod author. Meteor does not install game mods.
2. Start with the Steam launch command copied from Meteor on this PC.
3. Prefix that command with `WINEDLLOVERRIDES="winhttp=n,b"` and a space. This
   lets Wine load BepInEx's `winhttp.dll`.
4. Append `-vrmode openvr` after the game's `%command%` placeholder. Keep the
   Meteor wrapper around the game command.
5. Launch the game and check that `BepInEx/LogOutput.log` in the game directory
   has a fresh modification time and reports loading SubmersedVR. An old log
   or the presence of `SubmersedVR.dll` alone does not show that the mod loaded.
6. Test menu selection, both sticks, triggers and grips, then enter gameplay.

These environment/argument requirements come from the mod's
[Linux setup notes](https://github.com/Okabintaro/SubmersedVR#linux-setup).
Use Meteor's generated command rather than another streamer's runtime paths.

### Meteor DLL-override fix — development change

On 2026-11-12, the Steam handoff was found to omit `WINEDLLOVERRIDES` from its
allowed environment variables. Steam could receive the correct launch option,
but the game launched by Meteor did not inherit it. In the local reproduction,
SubmersedVR was installed but its log had not updated since April.

The launcher now preserves this specific variable, with a regression test for
the handoff. The updated runtime was installed on the development PC; **it has
not yet been identified with a public release**. A subsequent quick gameplay test confirmed that Quest Touch controls work
with the fix. Longer gameplay and broader host testing remain outstanding. Once shipped,
the fix travels with Meteor's bundled runtime; it is not a per-PC exception.

## Current investigation: games ending shortly after startup

On 2026-11-12, attempts with Subnautica, VRChat and Moss recorded a native XR
failure on the client, followed by connection teardown and Meteor stopping its
owned game process. Some host logs then show xrizer reporting
`ERROR_INSTANCE_LOST`. That error can be a consequence of teardown rather than
the original failure.

A later Subnautica attempt after reopening Nightfall delivered roughly 2,300
decoded frames and ended normally when the user quit. The intermittent failure
is **not confirmed fixed**. Whether tracking or network conditions contributed
is unresolved; lying down or testing in another room has not been established
as the cause.

When reporting this symptom, export the headset log before repeatedly restarting
the app, and include Meteor's log. See [saving diagnostic logs](../../README.md#support-logs).
Report whether only the game ended, Nightfall closed, or the headset rebooted.

## Adding a compatibility result

Open a [GitHub issue](https://github.com/tB0nE/nightfall/issues) or a pull request
updating this guide. Include:

- Game name, store/app ID, game version and any mods with their versions.
- Nightfall and Meteor versions, including whether they are development builds.
- Host OS; on Linux, desktop environment, X11/Wayland and Proton version.
- GPU(s), driver, selected XR backend, headset and controller type.
- Relevant Steam launch options; replace personal installation paths if desired.
- What worked: startup, image, audio, controls, gameplay, quit and a second launch.
- What failed, how long it took, and whether a fresh Nightfall launch changed it.
- Headset and Meteor logs from the same attempt.

Keep results scoped to the tested configuration. A successful startup is not
confirmation of motion controls, sustained performance or reliable reconnects.
