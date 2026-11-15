# Automatic XR launch on Linux (development preview)

This opt-in path lets a connected Nightfall headset enter PCVR when a game opens
Meteor's OpenXR runtime. Steam launches the game itself. Meteor-specific
per-game options are not required; game-specific mods and VR flags still are.
Native OpenXR discovery and Steam sandbox visibility have automated coverage.
Real Steam/Proton game and headset acceptance is still pending.

## Set up once

Use a Meteor build containing the namespaced activation runtime and open Setup.
Setup has a **Steam XR method** choice:

- **Steam launch options (Default)** uses the existing per-game method.
- **Automatic XR (Experimental)** is an explicit opt-in.

Fresh installations and Install All use the original method. Browsing the
selector changes nothing until you apply the chosen method. An already enabled
experimental choice is remembered. The experimental option requires the updated
runtime; it is disabled otherwise.

1. Select **Automatic XR (Experimental)** and click **Enable experimental method**.
   Close Setup to restart Meteor. This does not close Steam or
   change any game's launch options.
2. Exit Steam normally after closing any running games, then start it from its
   usual applications-menu shortcut. Existing desktop commands, including distro
   wrappers, are retained. Existing autostart entries are updated too; no new
   autostart entry is created.
3. Setup shows **Restart Steam to apply** while an old Steam process is still
   running without the environment. A fresh Steam launch receives OpenXR import
   and narrowly scoped runtime/socket filesystem access.
4. Connect Nightfall to the desktop stream as usual. The authenticated headset
   watcher temporarily selects Meteor's OpenXR runtime and bundled xrizer.
5. For the first game test, remove only the Meteor wrapper from that game's
   Steam launch options. Preserve its other variables, flags and mods.
6. Start the game normally. Check entry into XR, the wristwatch, desktop return,
   and launching the same game a second time.

For example, keep `WINEDLLOVERRIDES="winhttp=n,b"` and `-vrmode openvr` when
removing a `meteor_xr.py steam-run ... --` prefix. See the
[game compatibility guide](game-compatibility.md) for required game-specific setup.
If there are no other options, the field can be empty. Games retaining the old
Meteor wrapper can still use that fallback.

The VR app list accepts the automatic path once setup is enabled and Steam's
running environment is current. If Steam is closed, launching from that list
supplies the environment when starting it. **Install All** does not re-add
per-game wrappers once automatic setup is configured.

## Scope and coexistence

The persistent setup changes only per-user Steam desktop/autostart overrides.
It does not change GPU selection, library paths, game configurations or the
system-wide OpenXR runtime. Steam launched directly from a terminal bypasses
these desktop overrides; use the configured desktop shortcut for this preview.

OpenXR selection changes only for an authenticated headset connection or a live
XR runtime. On disconnect/shutdown, the previous OpenXR/OpenVR files or symlinks
are restored. Later edits by another VR tool or the user are preserved, with
backup/journal files retained for recovery. A runtime upgrade waits until the
registration/session is no longer using its files.

To return to the original method, select **Steam launch options (Default)** and
click **Update launch options**. This restores owned Steam launcher entries,
disables automatic mode and updates the per-game wrappers. Steam is closed and
reopened; close any running game before switching. Close Setup afterward to
restart Meteor.
An externally edited launcher is preserved rather than overwritten. The small
standalone helper also falls back to the original Steam command if the XR
installation has been removed.

Flatpak Steam needs separate permissions and is not configured by this preview.
Windows uses the existing SteamVR driver route, not Linux runtime registration.

## Automated checks

Run with the host Python:

```bash
PYTHONPATH=test /usr/bin/python3 -m unittest test_steam_environment
/usr/bin/python3 test/check_steam_xr_environment.py \
  --bundle /absolute/path/to/xr-bundle \
  --steam-runtime /absolute/path/to/SteamLinuxRuntime_4 \
  --output build/verify/steam-xr-environment
```

The second command uses isolated configuration, a temporary installed runtime
and a temporary socket. Its container command checks the socket, private
libraries and pressure-vessel's translated OpenXR selector. It does not launch
a game, render GPU frames, restart Steam or change real runtime selection.
Read its `summary.json`; this check does not establish tracking or game quality.
