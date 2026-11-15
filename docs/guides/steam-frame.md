# Steam Frame (Linux arm64) - experimental

Nightfall runs on Valve's Steam Frame as a native SteamOS (aarch64) OpenXR app,
using the Frame's own SteamVR runtime. Desktop streaming from Sunshine works:
pairing, hardware HEVC/H.264 decoding, screens, menus, controllers.

## What was needed

| Area | Change |
|---|---|
| Build | `NIGHTFALL_LINUX_ARCH=arm64 bash docker-build-linux.sh`, run on an arm64 host (the Frame itself works, with podman). The image gets Kitware's CMake 3.31 on aarch64: vcpkg can't download its own there and Ubuntu 22.04's 3.22 is too old for godot-cpp. |
| Decoding | vcpkg's FFmpeg is built with `--disable-autodetect`, which also drops V4L2 mem2mem, so Linux builds decoded in software. The overlay port in `addons/nightfall-stream/vcpkg-overlay/ffmpeg/` adds `--enable-v4l2-m2m`; `FfmpegDecoder` tries `hevc_v4l2m2m` / `h264_v4l2m2m` first on Linux (the Frame's Qualcomm decoder; desktops without an M2M device fall through). |
| Composition | SteamVR has no `XR_KHR_composition_layer_equirect2`. `setup_background_equirect()` returned early without it and skipped the UI, cursor and ray layers, so the pointer was drawn behind every panel. |
| Input | SteamVR keeps reporting `XR_EXT_hand_tracking` joints derived from the held controllers, so Nightfall flipped to hand mode and hid the pointer. On SteamVR a tracked controller now owns the pointers. |

## Building and running on the Frame

1. Enable Developer Mode on the Frame (Settings -> System) for SSH.
2. Native library, on the Frame (or any arm64 Linux host with podman/docker):
   `NIGHTFALL_LINUX_ARCH=arm64 bash docker-build-linux.sh`
   -> `addons/nightfall-stream/bin/linux/libnightfall-stream.linux.template_release.arm64.so`.
   The first build compiles every vcpkg dependency (allow ~20 minutes); later
   builds are incremental.
3. PCK, on any machine with Godot 4.7: `godot --headless --export-pack NightfallLinux nightfall.pck`
   (exit status 134 after "savepack DONE" is the known Godot 4.7 shutdown abort).
4. App layout: Godot's `linux_release.arm64` export template as the binary, the
   PCK next to it with the same base name, plus
   `addons/nightfall-stream/bin/linux/<the .so>` and
   `addons/godotopenxrvendors/` (5.2.0 ships `linux/template_release/arm64`).
5. Run it from SSH with the session environment, e.g.
   `DISPLAY=:1 XDG_RUNTIME_DIR=/run/user/1000 ./nightfall`, or add it to Steam as
   a non-Steam game through the launcher below. SteamVR makes it the scene app.

## Adding Nightfall to Steam on the Frame

Added to Steam directly (the binary as a non-Steam game), Nightfall starts, and
a couple of seconds later Steam's **Now Playing** panel opens over it. Steam
treats any window from a game's launch process tree as a flat game: it mirrors
Nightfall's 2D desktop window as a `valve.steam.desktopgame.<appid>` overlay and
opens the dashboard to show it (`ShowGame/ShowOverlay` in
`~/.local/share/Steam/logs/vrwebhelper_systemui.txt`). Unsetting `SteamAppId`
doesn't help (Steam goes by the process tree) and makes SteamVR treat the app
as a new one, so its per-app settings (refresh rate, render size) are lost.

`tools/steam_frame/launch-from-steam.sh` avoids both: put it next to the
`nightfall` binary and add **the script** to Steam as the non-Steam game. It
runs Nightfall as a systemd user unit outside Steam's launch tree, passes the
Steam ids on (SteamVR keeps the `steam.app.<id>` settings), waits for Nightfall
so Steam shows it running, and stops Nightfall if Steam stops the game. The log
goes to `nightfall.log` next to the binary.

`NIGHTFALL_ALLOW_MISSING_MODELS=1` lets `build.sh --linux` finish without the
on-device depth models (they are not in the repository); AI 3D then needs Meteor.

## Notes

- **Refresh rate**: SteamVR on the Frame runs every app at 72 Hz unless the app
  ships a `vrpreferences.json` (`{"steam_frame": {"preferMinRefreshRate": 120}}`)
  or the user sets SteamVR Settings -> Video -> Per-Application Video Settings ->
  Frame Limit / Refresh Rate Override. That per-app value is what
  `xrEnumerateDisplayRefreshRatesFB` reports, so Nightfall's own choice follows it.
- The decoder has no AV1 (H.264, HEVC, VP9 only).
- SteamVR offers `XR_VALVE_frame_controller_interaction`; the action map has no
  Frame profile yet, so SteamVR maps the generic/Touch bindings.
- Headset screenshots: OpenVR `IVRScreenshots::TakeStereoScreenshot` from any
  background OpenVR app captures the composited view, layers included.

## Not done yet

- A `linux.arm64` export preset and packaging (the app is assembled by hand).
- A Frame interaction profile in `openxr_action_map.tres`, and `vrpreferences.json`.
- Many settings use `OS.get_name() == "Android"` to mean "standalone headset"
  (Screens tab, HDR, Save Log, headset depth options); they are hidden on the Frame.
- Hand/controller ownership via `XR_EXT_hand_tracking_data_source` instead of the
  SteamVR check.
- Only advertise codecs the hardware decodes (AV1 would fall back to software).
