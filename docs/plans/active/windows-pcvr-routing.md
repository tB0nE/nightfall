# Windows PCVR: game routing and the desktop stream

Proposed 2026-11-22. Settle this design before merging fork work that touches
the same code (`xr_session*.rs`, the tray, the catalog, the PCVR handover).
In particular, Jonathan-Eid/nightfall's desktop shutdown, independent audio
and USB lanes become inputs to it. See "Fork inputs" below.

## Goal

Every PC VR game starts the same way from the headset or the PC, keeps its
controllers, and doesn't compete with the desktop stream for Wi-Fi.

- **OpenVR games and anti-cheat games:** SteamVR, with Meteor's driver as the
  only headset driver.
- **Plain native OpenXR games:** Meteor's Monado runtime, skipping SteamVR.
  This is what Virtual Desktop does with VDXR.
- **The desktop stream** steps aside while a game is in front, and comes
  back when the desktop or the wrist menu is shown.

VDXR itself is not bundled. Its Oculus SDK licence conflicts with GPL
distribution (see the licensing decision of 2026-11-22).

## Where we are

| Path | Today |
|---|---|
| Headset library → Steam game | `steam://launch/ID/VR` into a Meteor-owned SteamVR with a private config: `forcedDriver: meteor`, `activateMultipleDrivers: false`, and lighthouse, oculus and null disabled (`xr_session_windows.rs`). Works: VRChat, Moss, VaM as a non-Steam shortcut. |
| Game started on the PC, SteamVR not running | The game starts SteamVR with **the user's own** settings. The driver's `MDS2` bootstrap calls `queue_steamvr()` (attach mode, `external_steamvr`). Other drivers (vrlink, lighthouse) load too. VaM from its .exe lost its controllers this way. |
| Native OpenXR games | Monado profiles exist, but only for games registered by hand. Monado is never the system's active OpenXR runtime. Only D3D11 has been tested on Windows. |
| Desktop stream during PCVR | It stays connected while hidden. It carries the game audio, and the client restarts it at a lower rate (`pcvr_desktop_timing_ready()`). In the VaM session it fell from 58 to 30 fps, and host depth writes blocked for up to 750 ms. |
| Microphone during PCVR | `_enforce_hidden()` pauses the Meteor microphone for the whole session (`pcvr_workspace_handover.gd`). A bug: the microphone must keep working in VR (decided 2026-11-22). |

## A. Which runtime runs a game

### Deciding per game

The catalog records one per game, in order of precedence:

1. **The user's choice**, from the PCVR menu or the tray. It always wins.
2. **Anti-cheat → SteamVR.** Detected from the install folder
   (`EasyAntiCheat/`, `BattlEye/`, `start_protected_game.exe`), plus a short
   known list. Monado's client DLL is unsigned and loads into the game's
   process. SteamVR's is accepted everywhere.
3. **OpenVR → SteamVR.** The executable imports `openvr_api.dll`, or ships it.
4. **Native OpenXR → Monado.** The executable or its bundled DLLs import
   `openxr_loader.dll`, or a Unity or Unreal OpenXR plugin is present, and
   there is no OpenVR. If both are present, use SteamVR until the game has
   been tested on Monado.
5. **Unknown → SteamVR.** This is the safe default.

It's a static scan of local files at Setup and when the library refreshes. It
never runs the game. Results are cached in the catalog with the reason, so
the tray can show "Monado: native OpenXR" or "SteamVR: anti-cheat".

### Status (2026-11-22): detection done, routing unchanged

- `meteor/src/xr_detect.rs` scans an install folder: OpenVR from
  `openvr_api.dll`, OpenXR from `openxr_loader.dll` (Unreal, Unity's OpenXR
  package and native games ship it), and anti-cheat from EasyAntiCheat or
  BattlEye folders and files and `start_protected_game.exe`. The scan goes 8
  folders deep, looks at up to 60,000 entries, and doesn't follow links.
  Unreal keeps its loaders about five levels down.
- Setup passes `--install-dir` when it registers each game. The catalog keeps
  `install_dir`, `detected` and `chosen` (the user picked the runtime). The
  tray and the headset listing show the reason, e.g. "VRChat: SteamVR
  (anti-cheat: EasyAntiCheat)". `select()` sets `chosen`.
- Routing is unchanged: every game still uses SteamVR unless the user picks
  Monado. `Game::may_use_monado()` is what a later Monado offer will check.
- On the user's PC: VRChat is anti-cheat. Subnautica, Neverout and
  Half-Life: Alyx are OpenVR. Moss ships both loaders, as Unreal games do, so
  it stays on SteamVR. **None is native OpenXR only**, so Monado has no
  candidates there yet.

**Finding that changes route (a):** for a Steam game, Meteor doesn't know the
real executable or its arguments. The VR manifest only has
`steam://launch/ID/VR`, and the removed Moss profile hard-coded both.
Options, still to choose between:
- **Find the executable from the install layout:** Unity has `<name>.exe`
  beside `<name>_Data`; Unreal has `*/Binaries/Win64/*-Win64-Shipping.exe`.
  Launch it with `SteamAppId` and `XR_RUNTIME_JSON`, as the Moss profile did.
  Arguments can't be known in general, so a profile is offered as "try
  Monado" and kept only once it works.
- **The existing Steam handoff** (`--xr-steam-run ... %command%`), which
  gives Steam's exact command. It needs a per-game Steam launch option, and
  the standing rules forbid changing Steam options without the user's
  explicit consent, so it would be opt-in per game.
- Steam's binary `appinfo.vdf` lists launch configurations, including VR
  ones, but the format changes between Steam versions.

### Moss on Monado (2026-11-22): crashed in the game

A hand-made Monado profile launched `Moss-Win64-Shipping.exe -vr -dx11
-hmd=OpenXRHMD` with `XR_RUNTIME_JSON` from the headset library.
- What worked: Monado started; Moss connected (D3D11, asking for hand
  tracking and eye gaze); 1,037 frames were encoded and delivered with none
  failed; tracking reached Monado.
- What failed: about 16 s in, Moss crashed with
  `EXCEPTION_ACCESS_VIOLATION reading 0x0` (Unreal 4.27.2, no symbols).
  Monado logged no error before the disconnect.
- Moss also tried its Oculus plugin ("Unable to load LibOVRRT DLL"). It
  ships SteamVR, Oculus and OpenXR paths, and the Steam build is played on
  SteamVR, so its OpenXR path is likely untested.
- Not yet run: Moss's OpenXR path through SteamVR's own runtime (`-hmd=OpenXRHMD`
  as a Steam launch option), which would say whether the crash is Moss's or
  Monado's.

The profile was removed and Moss is back on SteamVR only. The next
candidate is DCS World (free, native OpenXR, D3D11).

### Making Monado the active runtime for its games

The Windows OpenXR loader reads the active runtime from `HKLM`, which needs
admin rights. It also honours `XR_RUNTIME_JSON` in the game's environment.
There are two options:

- **(a) Environment variable only.** Meteor launches the game's executable
  itself with `XR_RUNTIME_JSON` pointing at Monado, as the old Moss/xrizer
  profile did. No registry change and no elevation. It doesn't work through
  `steam://launch`, because Steam starts the process, and games that relaunch
  themselves through Steam lose the variable.
- **(b) Swap the system runtime while a session runs.** A small elevated
  helper, installed by Setup within the one UAC prompt Setup already uses,
  sets `ActiveRuntime` to Monado when a Monado session starts and restores
  the previous value afterwards. The helper keeps a crash-safe record of the
  original value and restores it at Meteor startup if a session didn't end
  cleanly. This works for Steam-launched games and games started on the PC.

**Decided (2026-11-22):** start with (a) for games Meteor launches, which
covers the headset library. Add (b) once (a) has proven which games run well
on Monado. (b) touches a system-wide setting, so it needs the restore path tested
first. Either way, a game only goes to Monado once it's marked native OpenXR
and has passed a check on our hardware.

### Monado coverage before routing games to it

- Test D3D12, Vulkan and OpenGL client sessions on Windows. D3D11 is the only
  one verified so far. Any API that fails stays on SteamVR.
- Choose a set of native OpenXR games to accept (start with ones the user
  owns). Record each in `docs/guides/game-compatibility.md`.

## B. The desktop stream during PCVR

The aim is that no desktop video crosses the network while a game is in
front.

1. **Separate game audio.** Capture the PC's default playback device with
   WASAPI loopback. No virtual audio driver and no change to the default
   device. Send it over an authenticated, encrypted Meteor channel and play it
   on the headset with a small bounded buffer. This is the piece in
   Jonathan-Eid's fork (`meteor/src/xr_audio.rs`, `test/meteor_windows_audio.h`,
   `pcvr_meteor_audio.cpp`): review it against this design and take it,
   rather than writing a second one.
   **Review of the fork's audio (2026-11-23).** About 920 lines across:
   - `xr_audio.rs`: the `NFAP` PCM header, plus a reader that enforces
     sequence, rate and length;
   - `xr_relay.rs`/`xr_control.rs`: an authenticated, encrypted audio lane on
     the existing video port, with its own channel keys and a fresh
     challenge; losing audio doesn't end the game;
   - `test/meteor_windows_audio{,_transport}.h`: WASAPI shared-mode loopback
     of the default playback device, converted to stereo PCM16 in packets of
     at most 10 ms;
   - `pcvr_meteor_audio.cpp`: an AAudio player with a bounded queue, which
     trims beyond 40 ms and plays silence on underflow;
   - `pcvr_desktop_stream.gd`: the desktop stop and reconnect.

   The relay and headset halves fit our design as they are. **The capture
   end doesn't:** it's only wired into the fork's VDXR bridge
   (`test/ovr-bridge/bridge.cpp`), which runs inside the game's process.
   The relay takes PCM from a local TCP port (`127.0.0.1:<random>`). On our
   SteamVR path, something has to feed that port. Options:
   - **Meteor-steamvr-mirror** (preferred): it already runs once per SteamVR
     session, outside the game and vrserver. It would include the fork's
     `meteor_windows_audio.h` unchanged and write packets to the relay's
     local audio port.
   - Or capture in Meteor itself (Rust, WASAPI through the `windows` crate),
     which would also cover Monado sessions without a helper.
   Bring in the fork's relay, wire and headset code with its tests, plus the
   capture header. Then add the mirror as producer.
2. **Stop the desktop stream once the game's audio is flowing.** Keep the XR
   session, the lease and the selected app. Reconnect when the wrist menu or
   the desktop is shown, and when VR ends. If the separate audio fails, fall
   back to today's behaviour.
3. **Host depth.** Pause it while the desktop stream is stopped, which
   happens naturally since nothing is being streamed.
4. **Microphone.** It must keep working during PCVR, because VRChat and other
   social games need voice. Pausing it in `_enforce_hidden()` was a mistake
   (confirmed 2026-11-22), so fix it first, independently of B.1–B.3.
   The microphone also only runs while the desktop stream is connected
   (`main.is_streaming` in `meteor_microphone.gd`). B.2 must keep it running
   once the desktop stream stops, because it uses Meteor's own channel, not
   the desktop stream.

Acceptance: VaM through SteamVR on Wi-Fi with no AcquireSync timeouts, the
desktop stream disconnected while the game is in front, the wrist menu
bringing the desktop back within a second or two, and audio continuous
throughout.

## C. Games that start SteamVR themselves

**Resolved 2026-11-22: not a Meteor or SteamVR problem.** Retested VaM from
its .exe, with SteamVR closed beforehand. SteamVR showed the controllers;
VaM didn't. SteamVR was as before: Meteor's driver held the HMD and both
controllers, and VaM loaded its own Touch bindings. VaM's own log
(`%USERPROFILE%\AppData\LocalLow\MeshedVR\VaM\output_log.txt`) showed the
cause. VaM had started with its working directory at `C:\WINDOWS\system32`:

    UnauthorizedAccessException: Access to the path "Saves" is denied.
      at SuperController.Awake ()
    UnauthorizedAccessException: Access to the path "C:\WINDOWS\system32\Custom" is denied.
    NullReferenceException ... at SuperController.set_solverIterations

VaM opens `Saves`, `Custom` and `Cache` relative to its working directory.
Its main controller (`SuperController`), which builds the player and hand
rig, fails in `Awake`. OpenVR keeps running ("LeftHand connected",
"RightHand connected"), but nothing uses the hands. A Steam shortcut starts
the game in its own folder, which is why that worked. Windows starts a
program in `system32` when it's run as administrator, or from a shortcut
with an empty "Start in".

For users (issue #92): start VaM from its own folder, from a shortcut whose
"Start in" is the VaM folder, or as a non-Steam game in Steam. Don't run it
as administrator.

What's left of C:
- Listing non-Steam shortcuts in the headset library is still worth doing,
  as a convenience. Steam's own `StartDir` gives the right working directory.
- No driver or attach-mode change is needed. The "restart into Meteor's
  SteamVR" and "temporary override" ideas are dropped.

## Small items to fold in

- **D.** Vibepollo turns desktop HDR off at stream start because the headset
  doesn't request HDR (`hdr_state: Disabled` in the display helper log). Leave
  HDR alone unless the stream needs it: find the right `dd_` key, set it the
  way `dd_refresh_rate_option` was set, and add a test.
- **F.** Test tooling: `run_gdscript_tests.sh` should give each test a time
  limit, because Godot doesn't exit after a failed check, which stalled a run
  for 29 minutes. Then look at the flaky `test_grip_scroll_routing` and
  `proxy::tests::multipath_owner_token_change_revokes_old_secondary`.
- **G.** `build_release_wsl.sh` should run `bootstrap_native_xr.sh
  --android-release-only` itself when the engine patch set no longer matches
  the runtime's build stamp, instead of failing the build.
- **E (investigation only).** On the user's PC, both the PC and the headset
  see a network stall at :36 past every hour, of up to 1.2 s. It's
  environmental (a scheduled task, a Wi-Fi scan or the router). B makes PCVR
  far less sensitive to it, so it's worth noting in the docs for users.

## Fork inputs

Jonathan-Eid/nightfall `main`, as of 2026-11-18, is reviewed in the session
notes:

| Fork piece | Goes into |
|---|---|
| Separate PCVR audio, and stopping the desktop stream | B.1–B.2, reviewed against this design |
| USB IPv6 XR control and relay lanes, USB firewall policy | Its own merge, after A–C settle `xr_session`/`xr_relay` |
| Intel QSV encoder (MIT) | Independent; merge any time, with NVIDIA and AMD regression checks |
| Headset video pacing, wider render field of view, 90 Hz | After B, measured on our own setups |
| VDXR backend | Not merged (licensing) |

## Order

1. B.4 (microphone fix) and C.1 (find the cause of the lost controllers).
2. A: detection and catalog fields, plus route (a) for library launches.
3. B: review and adapt the fork's audio, then the desktop shutdown.
4. C: list non-Steam shortcuts in the headset library (optional).
5. A route (b), once Monado games are proven.
6. D, F and G, whenever convenient.

## Game tests, 2026-11-22 evening

Every installed game on the user's PC, all through SteamVR:

| Game | Result | Follow-up |
|---|---|---|
| VaM | Works from its folder or a Steam shortcut | Start-menu shortcut starts it in `system32` (part C) |
| VRChat | Works, voice included (microphone fix) | — |
| Moss | Works on SteamVR | Crashes on Monado (see above) |
| Half-Life: Alyx | Works; "resolution could be better" | Try PCVR Resolution 120–130% and 120–160 Mbps HEVC |
| Subnautica | No hands in the base game (gamepad only); seemed too high | SubmersedVR installed with Tobey's BepInEx pack: runs great |
| Neverout, Telefrag VR | Run, laser ~38° high, Telefrag unusable | Legacy aim (below) |
| STAR WARS: Squadrons | Runs in VR, no hands | Gamepad or HOTAS by design |

**Legacy aim: tried and removed (2026-11-24).** On a Quest controller,
`/pose/raw` points about 37° above where you aim (Valve's
`oculus_quest2_controller` model: `tip` Rx -37.4). Games built for the Vive
wand aim straight out of it.
- What was tried: a driver-generated copy of SteamVR's Touch profile whose
  legacy binding mapped the poses to `/pose/tip`.
- Why it didn't help:
  - SteamVR still loaded the Oculus driver's own `legacy_bindings_touch.json`
    for legacy apps. It seems to pick the legacy binding by controller type,
    not by our `Prop_InputProfilePath`.
  - Telefrag sets its own action manifest, and its `oculus_touch.json`
    binds no poses: it reads the device's raw pose directly, as Unreal 4
    SteamVR games do.
- No SteamVR setting covers this; some games have their own "controller
  angle" option.
- Proposed for after 0.9.1: a per-game **controller angle** in the PCVR
  games window, which the driver applies to the poses it reports while that
  game runs. Other streamers (ALVR) offer similar offsets.

**Seated height: kept.** The driver's chaperone puts the seated origin on
the floor, so seated games rendered a full head height too high. Once the
head is tracking (above 0.3 m), the mirror helper now calls
`IVRChaperone::ResetZeroPose(TrackingUniverseSeated)`, once per session. The
Quest's origin is adopted afresh each session, so a saved seated origin goes
stale. `METEOR_STEAMVR_SEATED_RESET=0` opts out. Confirmed in a session log
(`METEOR_STEAMVR_SEATED_RESET head_y=1.131`). The user noticed no
difference in the seated games they tried.

**Headset reboot (2026-11-24, once).** About 40 s after exiting Telefrag, as
the desktop stream, the microphone and host depth resumed (the depth model
cold-started after a 5.7 s gap), the Quest 3 rebooted fully: the depth
connection dropped at 22:23:06 and `SYSTEM_BOOT` came at 22:23:32. Host depth
had run at about 70 steps/s through the whole game (part B). There was no
headset log at the time. It didn't recur over about 20 minutes and several
more games, with the log recording.

Still open:
- `vrwebhelper.exe` crashes about 3 s after Meteor's graceful `WM_CLOSE` to
  vrmonitor at the end of most sessions (dumps on 11-16, 11-21 and 11-22;
  SteamVR unchanged since 11-04). Steam shows its crash dialog; nothing else
  breaks. One option is to leave SteamVR running after a session; that's a
  behaviour change to decide on.
- Alyx sharpness: SteamVR renders at Meteor's eye size (2064×2208, the Quest
  3 panel, with the user's SteamVR at a manual 100%) and the stream is HEVC at
  80 Mbps. Raising PCVR resolution and bitrate is the first thing to try.
